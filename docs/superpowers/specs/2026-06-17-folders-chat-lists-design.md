# Folders / Chat Lists Design

> **Feature flag / roadmap entry:** F91 — Folders (replaces ROADMAP
> entry at `docs/ROADMAP.md:166`).

## Goal

User-defined groupings of chats, exposed as a vertical rail on the
left edge of the sidebar (Telegram-style). Drag a chat onto a folder
to add it; ⌘1..N switches between folders; the current full chat
list moves into a sticky "All chats" sentinel at the bottom of the
rail. "Archived" promotes from an inline expandable section to a
rail-level smart folder. Pure client-side; no whatsmeow / bridge
changes; SwiftData-persisted; local-only (no cross-device sync).

## Scope summary

| In | Out |
|---|---|
| Custom folders (name-only, no per-folder icon picker) | Cross-device folder sync |
| Smart folders: All chats, Archived | VIP / Unread / Has-media smart folders |
| Drag chat row → folder rail (add membership) | Drag chat row OUT of folder via rail (use context menu) |
| Drag folder rail item up/down (reorder) | Auto-folders / rule-based smart filters |
| Context-menu "Add to folder…" submenu on chat row | Folder colors / wallpapers |
| Context-menu Rename / Delete / New on rail | Per-folder notification rules |
| ⌘0 = All chats, ⌘1..9 = first 9 custom folders | Folder ⌘0..9 beyond 9th custom |
| Unread badge per folder (sum across non-archived chats) | Mention badge separately |
| Selection persistence (`@AppStorage`) | Multi-account folder partitioning (out — addressed by future Multi-account work) |

## Architecture

NavigationSplitView stays 2-column. The sidebar column wraps its
existing chat-list body in an `HStack`:

```
NavigationSplitView
├─ Sidebar column
│  └─ HStack
│     ├─ FolderRail (76pt fixed width)
│     ├─ Divider
│     └─ ChatListContent (existing ChatListView body, gated by FolderSelection)
└─ Detail column (ConversationView, unchanged)
```

Smallest blast radius: `ContentView.swift:55` stays untouched; the
rail is internal to the sidebar column. Existing `cachedRows` +
`rebuildDisplayRows` survive — gain a `selectedFolder:
FolderSelection` filter argument.

## Components

### Data model

New SwiftData model `PersistedFolder` at
`yawac/Models/PersistedFolder.swift`:

```swift
@Model
final class PersistedFolder {
    @Attribute(.unique) var id: String     // UUID().uuidString
    var name: String
    var sortIndex: Int                     // 0-based, ascending = top-down
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, sortIndex: Int, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}
```

Membership lives on `PersistedChat` (extends
`yawac/Models/PersistedMessage.swift:232`):

```swift
var folderIDs: [String] = []   // PersistedFolder.id values
```

`[String]` stores natively in SwiftData (Codable). Many-to-many
without a join model. Folder delete → walk PersistedChats, remove
the id from each `folderIDs`.

Smart folders are NOT SwiftData rows. They are enum cases:

```swift
enum FolderSelection: Equatable, Codable {
    case all                              // sentinel: full chat list, current behavior minus archived inline
    case archived                         // archived chats only
    case custom(folderID: String)
}
```

Selection persists via `@AppStorage("yawac.selectedFolderID")`:
- `""` → `.all`
- `"_archived"` → `.archived`
- any other UUID string → `.custom(folderID:)`

Persisted folder id no longer in store → fall back to `.all`,
clear `@AppStorage`.

### FolderRailViewModel

`yawac/ViewModels/FolderRailViewModel.swift` (`@Observable
@MainActor`):

```swift
@Observable @MainActor
final class FolderRailViewModel {
    var folders: [PersistedFolder] = []          // sorted by sortIndex
    var selection: FolderSelection = .all        // mirrors @AppStorage
    var unreadByFolderID: [String: Int] = [:]
    var allUnread: Int = 0
    var archivedUnread: Int = 0

    private let context: ModelContext
    init(context: ModelContext)

    func loadFolders()
    func createFolder(name: String, atIndex: Int) -> PersistedFolder
    func renameFolder(id: String, to newName: String)
    func deleteFolder(id: String)                // scrubs chat folderIDs + collapses selection
    func reorder(fromIndex: Int, toIndex: Int)
    func addChat(jid: String, toFolderID: String)
    func removeChat(jid: String, fromFolderID: String)
    func refreshBadges(chats: [Chat])
}
```

Badge compute is pure — table-driven testable without `Chat` mocks
of `WAClient`:

```swift
func refreshBadges(chats: [Chat]) {
    var byFolder: [String: Int] = [:]
    var all = 0
    var archived = 0
    for c in chats {
        guard c.unread > 0 else { continue }
        if c.archivedAt != nil { archived += c.unread; continue }
        all += c.unread
        for fid in c.folderIDs { byFolder[fid, default: 0] += c.unread }
    }
    self.unreadByFolderID = byFolder
    self.allUnread = all
    self.archivedUnread = archived
}
```

Archived chats count ONLY toward `archivedUnread` (not toward custom
folders they were tagged into pre-archive). Matches mac mental
model — archived = hidden bucket.

### FolderRail view

`yawac/Views/FolderRail.swift` — fixed 76pt wide column:

```
VStack(spacing: 0) {
    ScrollView {
        VStack(spacing: 4) {
            ForEach(vm.folders) { folder in
                FolderRailItem(item: .custom(folder), selection: vm.selection, badge: vm.unreadByFolderID[folder.id] ?? 0)
            }
            FolderRailItem(item: .all, selection: vm.selection, badge: vm.allUnread)
            FolderRailItem(item: .archived, selection: vm.selection, badge: vm.archivedUnread)
        }
    }
}
.frame(width: 76)
.background(Theme.sidebarBackground)
```

`FolderRailItem` row: vertical stack of `Image(systemName: ...) +
unread badge overlay + Text(name).lineLimit(2).scaledUI(11)`.

Icons:
- Custom folder: `folder.fill`
- All chats: `bubble.left.and.bubble.right.fill`
- Archived: `archivebox.fill`

Selected item: blue accent + filled icon (matches mock screenshot).

### ChatListView wraps existing body

`yawac/Views/ChatListView.swift` body root becomes:

```swift
HStack(spacing: 0) {
    FolderRail(vm: folderRailVM)
    Divider()
    chatListContent     // current body, extracted into a private var
}
```

### ChatListViewModel filter

`ChatListViewModel` gains `selectedFolder: FolderSelection` bound to
`folderRailVM.selection`. `rebuildDisplayRows()` filters input chat
list before existing bucket logic:

```swift
func chatsFor(selection: FolderSelection, allChats: [Chat]) -> [Chat] {
    switch selection {
    case .all:
        return allChats.filter { $0.archivedAt == nil }       // archived no longer inline
    case .archived:
        return allChats.filter { $0.archivedAt != nil }
    case .custom(let id):
        return allChats.filter { $0.folderIDs.contains(id) && $0.archivedAt == nil }
    }
}
```

For `.archived`: existing expandable archived section in
`rebuildDisplayRows` is suppressed (flat list of archived chats; no
expansion needed).

For `.custom`: archived chats with the folder tag are hidden.
User who archives a chat sees it move into Archived rail; the
folder tag stays on the row for if/when they unarchive.

For `.all`: archived chats are hidden from the flat list. **This is
a behavior change** — current build shows archived as an
expandable section at the bottom of All chats. New build relegates
them to the Archived rail entry. Release note flags this.

### Interactions

**Drag chat row → folder rail (add membership)**

`ChatRowView` gains:

```swift
.draggable(ChatJIDTransfer(jid: chat.jid))
```

where `ChatJIDTransfer: Transferable, Codable` with custom UTType
`dev.vadikas.yawac.chatjid`. Drag preview = small rounded card with
chat name + avatar.

`FolderRailItem` (only `.custom` case) gains:

```swift
.dropDestination(for: ChatJIDTransfer.self) { transfers, _ in
    for t in transfers { folderRailVM.addChat(jid: t.jid, toFolderID: folder.id) }
    return true
}
```

Drop on `.all` / `.archived` items = ignored (no-op, drop refused).
Drag-over visual: pulsing accent border on the targeted item.

**Folder reorder (drag rail items)**

Custom `FolderRailItem` also `.draggable(FolderIDTransfer(id:
folder.id))` and `.dropDestination(for: FolderIDTransfer.self)`.
Drop reassigns `sortIndex` on affected folders via
`folderRailVM.reorder(fromIndex:toIndex:)`.

Smart items (All chats / Archived) — not draggable, not droppable
for folder transfer. Sticky after the custom folders.

**Chat-row context menu — "Add to folder…" submenu**

```swift
Menu("Add to folder…") {
    ForEach(folderRailVM.folders) { f in
        Button {
            if chat.folderIDs.contains(f.id) {
                folderRailVM.removeChat(jid: chat.jid, fromFolderID: f.id)
            } else {
                folderRailVM.addChat(jid: chat.jid, toFolderID: f.id)
            }
        } label: {
            if chat.folderIDs.contains(f.id) {
                Label(f.name, systemImage: "checkmark")
            } else {
                Text(f.name)
            }
        }
    }
    Divider()
    Button("New folder…") { showNewFolderSheet = true }
}
```

Toggles membership — checkmark indicates current membership.

**Rail item context menu — right-click**

Custom folder item:
- **Rename** → inline alert with `TextField` prefilled
- **Delete** → confirm alert ("Delete folder 'X'? Chats stay in your
  chat list.") → cascades `removeAll` from chat `folderIDs`
- **New folder** → opens `NewFolderSheet`

Smart items (All chats / Archived): single item — **New folder…**.

**New folder sheet** — small 1-field name prompt, Create / Cancel.
Replaces the dropped Edit-sheet design.

**⌘1..N folder switch**

Wired in `yawacApp.swift` `.commands { ... }`:

```swift
CommandMenu("Folders") {
    Button("All chats") { folderRailVM.selection = .all }
        .keyboardShortcut("0", modifiers: .command)
    ForEach(Array(folderRailVM.folders.prefix(9).enumerated()), id: \.element.id) { idx, f in
        Button(f.name) { folderRailVM.selection = .custom(folderID: f.id) }
            .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
    }
}
```

⌘0 → All chats. ⌘1 → top custom folder. ⌘9 → ninth custom folder.
Folders beyond 9 keyboard-unreachable; rail click works. Archived
not bound to any shortcut (rare-use; tap only).

## Data flow

```
WAClient events ──► ChatListViewModel.chats (existing)
                         │
                         ├──► ChatListView.onChange(of: vm.chats)
                         │        │
                         │        └──► folderRailVM.refreshBadges(chats: vm.chats)
                         │                  │
                         │                  └──► unreadByFolderID, allUnread, archivedUnread
                         │
                         └──► rebuildDisplayRows(selection: folderRailVM.selection)
                                  │
                                  └──► cachedRows (current memoization)

User drag chat → rail item
                         │
                         └──► folderRailVM.addChat(jid:toFolderID:)
                                  │
                                  └──► chat.folderIDs append (PersistedChat write)
                                       └──► ChatListViewModel observes → cachedRows rebuild

User selects rail item
                         │
                         └──► folderRailVM.selection = .custom(...)
                                  │
                                  ├──► @AppStorage write
                                  └──► ChatListViewModel.rebuildDisplayRows triggered
```

## Error handling

- **Empty folder name** on create / rename → Create disabled until
  trimmed name non-empty
- **Duplicate folder name** → allowed (UUID-keyed; names cosmetic)
- **Delete folder while selected** → `selection = .all` before
  delete (no orphan render)
- **Folder id in `PersistedChat.folderIDs` no longer exists** →
  ignored at filter time; scrubbed lazily on next folder-edit touch
- **Persisted `selectedFolderID` missing folder** → fall back to
  `.all`, clear `@AppStorage`
- **Drop on disallowed item** (smart folder, self) → drop refused;
  no membership change

## Migration

- Add `PersistedFolder.self` to `Schema([...])` in
  `yawac/yawacApp.swift:39`
- Add `folderIDs: [String] = []` to `PersistedChat` (default-value
  optional → lightweight migration)
- No `#Index` additions → no raw-SQL fallback needed (per SwiftData
  `#Index` migration gotcha)
- Existing users boot to All chats, zero custom folders. Their full
  non-archived chat list reads identical to current build, minus
  the inline expandable archived section which moves to the
  Archived rail item.

## Testing

### Unit — `yawacTests/FolderRailViewModelTests.swift`

In-memory `ModelContainer` per test
(`ModelConfiguration(isStoredInMemoryOnly: true)`), schema =
`[PersistedFolder.self, PersistedChat.self, PersistedMessage.self,
PersistedReaction.self, PersistedPollVote.self]`.

Cases:
1. `createFolder` — single folder, then second at index 0 → asserts
   sortIndex bumps existing folder to 1
2. `renameFolder` — preserves id + sortIndex, updates name
3. `deleteFolder` — also scrubs `folderIDs` from any PersistedChat
   carrying it; selection collapses to `.all` if deleted folder was
   selected
4. `reorder(from:to:)` — table-driven [from, to, expectedOrder] × 5
   cases (head→tail, tail→head, middle→middle, no-op,
   out-of-bounds clamp)
5. `addChat` / `removeChat` — Set-semantics (idempotent), persists
   to `PersistedChat.folderIDs`
6. `refreshBadges` — table-driven over crafted Chat lists; asserts
   `allUnread`, `archivedUnread`, `unreadByFolderID`
7. Persisted `selectedFolderID` references missing folder →
   fallback to `.all`, clears AppStorage
8. Filter logic: pure `chatsFor(selection:allChats:)` —
   table-driven [selection, input chats, expected output]

### View — `yawacTests/FolderRailViewTests.swift`

Cases (NSHostingView-based integration; ViewInspector if codebase
adopts):
1. Rail mounts with N custom folders + All chats + Archived
   sentinels in correct order
2. Drag-to-folder gesture: simulate `DropProposal` accept on
   `.custom`, reject on `.all` / `.archived`
3. Folder-row context menu shows Rename / Delete / New; smart-row
   context menu shows only New
4. Badge: red overlay visible iff unread > 0; renders "99+" when >
   99; hidden when 0

### Integration smoke — manual on Debug build

- Create 3 folders, assign chats via drag, ⌘1/⌘2/⌘3 switches
- Restart yawac → verify selection + folder list persisted
- Delete folder while selected → falls back to All chats
- Archive a chat → moves out of All chats, into Archived rail
- Right-click chat → "Add to folder…" submenu shows folders with
  checkmarks for current membership

### Out-of-scope test surface

- Bridge / Go / whatsmeow code untouched → no bridge tests change
- Existing `ChatListView` snapshot tests (if any) need rail mount
  accounted for in the snapshot

## File summary

| File | Action | Reason |
|---|---|---|
| `yawac/Models/PersistedFolder.swift` | Create | New SwiftData model |
| `yawac/Models/PersistedMessage.swift` (PersistedChat struct) | Modify | Add `folderIDs: [String] = []` |
| `yawac/ViewModels/FolderRailViewModel.swift` | Create | Rail state owner |
| `yawac/Views/FolderRail.swift` | Create | Rail SwiftUI view |
| `yawac/Views/FolderRailItem.swift` | Create | Single rail row (icon + badge + label) |
| `yawac/Views/ChatListView.swift` | Modify | Wrap body in HStack with FolderRail |
| `yawac/Views/ChatRowView.swift` | Modify | `.draggable(ChatJIDTransfer)` + context-menu submenu |
| `yawac/ViewModels/ChatListViewModel.swift` | Modify | `selectedFolder: FolderSelection` filter input |
| `yawac/Util/FolderTransfers.swift` | Create | `ChatJIDTransfer` + `FolderIDTransfer` Transferable types |
| `yawac/yawacApp.swift` | Modify | Schema += PersistedFolder, CommandMenu("Folders") with ⌘0..9 |
| `yawac/Views/NewFolderSheet.swift` | Create | Name prompt sheet |
| `yawacTests/FolderRailViewModelTests.swift` | Create | Unit coverage |
| `yawacTests/FolderRailViewTests.swift` | Create | View coverage |
| `docs/ROADMAP.md` | Modify | Flip Folders bullet → ✅ with F91 reference |

## Open questions resolved

| Question | Answer |
|---|---|
| Replace scope row or coexist? | Replace — rail subsumes scope |
| Smart folders set? | All chats + Archived only |
| Folder icon picker v1? | No — `folder.fill` SF Symbol for all customs |
| Edit sheet? | Dropped — context menus + New folder name prompt cover CRUD |
| Cross-device sync? | Out — local-only this cycle |
| Archived inline expandable section? | Removed — folded into Archived rail folder |
| ⌘N beyond ⌘9? | Unbound — rail click only |
