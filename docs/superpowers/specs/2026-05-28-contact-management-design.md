# Contact & Chat Management — Design Spec

**Date:** 2026-05-28
**Status:** Approved (design)
**Topic:** Add-to-contacts, delete chat, block/ban, archive

## Goal

Add four chat-level management actions to yawac, surfaced from both the
sidebar row right-click menu and the open conversation's header menu:

1. **Add to contacts** — save a display name for a JID, synced to the phone
   address book (and all linked devices).
2. **Delete chat** — remove the conversation locally **and** on every device
   (clears history). Destructive; confirmation required.
3. **Block / Unblock** (ban) — add/remove a user from the WhatsApp blocklist.
   Confirmation required to block.
4. **Archive / Unarchive** — hide a chat from the main list into a collapsible
   "Archived" section. Reversible; silent.

All four reuse the existing app-state / event-dispatch / sidebar patterns
already established by pin and star.

## Action semantics (confirmed)

| Action          | WhatsApp meaning                                          | Reversible | Confirm |
|-----------------|-----------------------------------------------------------|------------|---------|
| Add to contacts | Give a JID a saved name (synced to phone)                 | yes        | no      |
| Delete chat     | Remove conversation, clear history on all devices         | **no**     | **yes** |
| Block / ban     | Blocklist the user; they can't message you                | yes        | **yes** (block only) |
| Archive         | Hide from main list; viewable under "Archived"            | yes        | no      |

Scope of each action:
- **Block** and **Add to contacts**: 1:1 user chats only (not groups/communities).
- **Archive** and **Delete**: any chat (direct, group, community).

## Architecture

Mirror the pin/star pattern end-to-end:

- **Go bridge** gains five methods + four dispatched inbound events.
- **Persisted model** gains `archivedAt` (parallels `pinnedAt`). Blocklist is
  in-memory (authoritative, refetched on connect).
- **ViewModels**: chat-level handlers on `ChatListViewModel`; blocklist state
  on `SessionViewModel`.
- **UI**: extend the sidebar `Row` enum + `contextMenu`; add a conversation
  header `⋯` menu + blocked banner; add a Settings "Blocked contacts" section.

---

## Component 1 — Go bridge

### 1a. App-state / blocklist methods

`bridge/appstate.go` (archive + delete + contact) and new
`bridge/blocklist.go` (block + list). All take JID strings, parse with
`types.ParseJID`, guard `c.wa == nil`.

```go
// ArchiveChat archives/unarchives a chat. lastTS/lastMsgID/fromMe identify
// the chat's last message so the server anchors the archive state; pass
// 0/""/false when unknown (newMessageRange is zero-safe → uses now()).
// BuildArchive is WAPatchRegularLow, version 3, and auto-unpins on archive.
func (c *Client) ArchiveChat(chatJID string, archived bool, lastTS int64, lastMsgID string, fromMe bool) error

// DeleteChat clears a conversation on all devices. BuildDeleteChat is
// WAPatchRegularHigh, version 6, deleteMedia=false.
func (c *Client) DeleteChat(chatJID string, lastTS int64, lastMsgID string, fromMe bool) error

// SetContactName saves a contact name, synced to the phone address book.
// Hand-built patch (no whatsmeow helper): Type WAPatchCriticalUnblockLow,
// Index ["contact", jid], Value ContactAction{FullName, FirstName,
// SaveOnPrimaryAddressbook:true}. firstName may be "".
func (c *Client) SetContactName(jid, fullName, firstName string) error

// SetBlocked blocks/unblocks a user via UpdateBlocklist (server IQ).
func (c *Client) SetBlocked(jid string, blocked bool) error

// ListBlocked returns a JSON array of blocked JID strings (GetBlocklist).
func (c *Client) ListBlocked() (string, error)
```

**Message-key construction** for archive/delete: when `lastMsgID != ""`, build
`&waCommon.MessageKey{RemoteJID: proto.String(chatJID), FromMe: proto.Bool(fromMe), ID: proto.String(lastMsgID)}`
and pass `time.Unix(lastTS, 0)`; otherwise pass `time.Time{}` + `nil`.

**Contact patch version risk:** whatsmeow ships no `BuildContact`, so the
`Version` for the `contact` index isn't referenced in the library. Start with
`Version: 2` (the WA contact-action version). If the server rejects the patch
(LTHash mismatch on the next sync, or the name never lands on the phone),
adjust the version — this is verified live during manual testing.

`SetContactName` model:

```go
func (c *Client) SetContactName(jid, fullName, firstName string) error {
    if c.wa == nil {
        return errors.New("client closed")
    }
    target, err := types.ParseJID(jid)
    if err != nil {
        return fmt.Errorf("parse jid: %w", err)
    }
    action := &waSyncAction.ContactAction{
        FullName:                 proto.String(fullName),
        SaveOnPrimaryAddressbook: proto.Bool(true),
    }
    if firstName != "" {
        action.FirstName = proto.String(firstName)
    }
    patch := appstate.PatchInfo{
        Type: appstate.WAPatchCriticalUnblockLow,
        Mutations: []appstate.MutationInfo{{
            Index:   []string{appstate.IndexContact, target.String()},
            Version: 2,
            Value:   &waSyncAction.SyncActionValue{ContactAction: action},
        }},
    }
    return c.wa.SendAppState(context.Background(), patch)
}
```

### 1b. Inbound events

`bridge/events.go` — new cases in `handleWAEvent` + dispatch helpers, following
`dispatchPin`/`dispatchStar`:

| whatsmeow event     | dispatch kind      | JSON payload (jsonmodels.go)                              |
|---------------------|--------------------|----------------------------------------------------------|
| `events.Archive`    | `"ChatArchived"`   | `JChatArchived{ChatJID, Archived bool, Timestamp}`       |
| `events.DeleteChat` | `"ChatDeleted"`    | `JChatDeleted{ChatJID, Timestamp}`                       |
| `events.Contact`    | `"ContactUpdated"` | `JContactUpdated{JID, FullName, FirstName}`              |
| `events.Blocklist`  | `"BlocklistChanged"`| `JBlocklistChanged{Action string, Changes []JBlockChange{JID, Action}}` |

`events.Archive.Action.GetArchived()` gives the bool. `events.Blocklist` may
arrive as `Action="modify"` with an empty `Changes` list — in that case Swift
re-requests via `ListBlocked` (the event signals "blocklist changed, re-sync").

### 1c. JSON models

Add to `bridge/jsonmodels.go`: `JChatArchived`, `JChatDeleted`,
`JContactUpdated`, `JBlocklistChanged`, `JBlockChange` (snake_case json tags
matching the existing `JChatPinned` style).

---

## Component 2 — Persisted model

`yawac/Models/PersistedMessage.swift` (chat model lives here alongside
`PersistedChat`): add

```swift
var archivedAt: Date?
```

with matching init param (light migration — new optional, like `pinnedAt`).
`yawac/Models/Chat.swift`: add `archivedAt: Date?` to the in-memory `Chat`
struct + its `init(_:)` hydration.

Blocked state is **not** persisted — it is an in-memory `Set<String>` on
`SessionViewModel`, seeded from `ListBlocked()` on connect and updated by
`BlocklistChanged` events. Authoritative source is always the server.

---

## Component 3 — ViewModels

### 3a. `ChatListViewModel`

New methods (each: optimistic local update → bridge call; revert/log on error,
matching `pinChat`):

```swift
func archiveChat(_ chat: Chat, archived: Bool)            // set archivedAt, call ArchiveChat
func deleteChat(_ chat: Chat)                              // delete PersistedChat + its messages, call DeleteChat
func addContact(_ chat: Chat, fullName: String, firstName: String)  // call SetContactName
func setBlocked(_ chat: Chat, blocked: Bool)               // delegate to session.setBlocked

func applyIncomingArchive(chatJID: String, archived: Bool) // reconcile archivedAt
func applyIncomingDelete(chatJID: String)                  // remove chat + messages
func applyIncomingContact(jid: String, fullName: String)   // update stored display name
```

`deleteChat` must remove the chat's `PersistedMessage` rows and the
`PersistedChat`, then save the context; if the deleted chat is the open one,
clear the selection.

`displayRows()` (in `ChatListView`) changes — see Component 4.

### 3b. `SessionViewModel`

```swift
private(set) var blockedJIDs: Set<String> = []

func loadBlocklist() async        // call ListBlocked() on .connected, decode, assign
func setBlocked(_ jid: String, blocked: Bool) async  // call SetBlocked, update set optimistically
func applyBlocklistChange(_ payload: BridgeBlocklistChanged)  // apply Changes, or re-fetch on "modify"
func isBlocked(_ jid: String) -> Bool { blockedJIDs.contains(jid) }
```

`loadBlocklist()` is invoked from the existing `.connected` handling (alongside
the pin reconcile in `ContentView`).

---

## Component 4 — UI

### 4a. Sidebar (`ChatListView`)

- `Row` enum gains `case archivedHeader(count: Int)`.
- `@State private var archivedExpanded = false` (collapsed each launch).
- `displayRows()`: chats with `archivedAt != nil` are pulled out of the
  pinned/community/group/direct buckets into an `archived` list, scope-filtered
  like `pinned`. When non-empty, prepend `.archivedHeader(count:)` at the very
  top (above Pinned); if `archivedExpanded`, follow it with the archived chats
  as normal `.chat` rows.
- The header row renders an "Archived (N)" label with a disclosure chevron;
  tapping toggles `archivedExpanded`.
- `contextMenu` (in `chatRowButton`) expands to, in order:
  - **Pin/Unpin chat** (existing)
  - **Archive/Unarchive** → `vm.archiveChat(chat, archived: chat.archivedAt == nil)`
  - **Add to contacts… / Edit name…** (1:1 only) → opens name-entry dialog
  - **Block / Unblock** (1:1 only) → `chat.isGroup ? nil` ; block path shows confirm
  - Divider, then **Delete chat…** (destructive) → shows confirm

"1:1 only" = `!chat.isGroup && !chat.isCommunityParent`.

### 4b. Conversation header (`ConversationView`)

- A `Menu` (`⋯`, `ellipsis` glyph) in the header bar mirroring the same actions
  for the open chat, calling the same `ChatListViewModel` methods.
- A **blocked banner** above the composer when `session.isBlocked(chatJID)`:
  text "You blocked this contact" + an **Unblock** button →
  `session.setBlocked(chatJID, blocked: false)`. (The banner does not disable
  the composer; unblock is one click.)

### 4c. Confirmations + name entry

- **Delete confirm:** `confirmationDialog`/`alert` — title
  "Delete chat with \(name)?", message "This clears the conversation on all
  your devices.", destructive "Delete" + "Cancel".
- **Block confirm:** alert — "Block \(name)?", "Block" + "Cancel".
- **Name entry:** a small sheet/alert with a "Full name" `TextField`
  (pre-filled with the current display name when editing) and optional
  "First name"; "Save" calls `addContact`.

These dialogs are owned by whichever surface triggers them; both surfaces drive
the same VM methods, so the dialog state can live on the shared view holding
the menu (sidebar row binds its own `@State` per the existing context-menu
pattern; conversation header holds its own).

### 4d. Settings (`SettingsView`)

A new `Section("Blocked contacts")`:
- If `session.blockedJIDs.isEmpty` → "No blocked contacts." (secondary text).
- Else `ForEach` the sorted JIDs, each row: resolved display name (via
  `session.displayName(for:)`) + an **Unblock** button →
  `Task { await session.setBlocked(jid, blocked: false) }`.

`SettingsView` gains `@Environment(SessionViewModel.self)`.

---

## Component 5 — Swift bridge wrappers

`yawac/Bridge/WAClient.swift`: async wrappers `archiveChat`, `deleteChat`,
`addContact`, `setBlocked`, `listBlocked` over the gomobile selectors; new
decode cases in the event router for `ChatArchived`, `ChatDeleted`,
`ContactUpdated`, `BlocklistChanged`. `yawac/Bridge/JSONModels.swift`: matching
`Bridge…` decodables.

`ContentView` routes the four new events to the right VM and calls
`session.loadBlocklist()` on `.connected`.

---

## Data flow

**Outbound (user archives a chat):**
1. Right-click → "Archive" → `ChatListViewModel.archiveChat(chat, true)`.
2. VM sets `archivedAt = .now` optimistically (chat drops into Archived section).
3. VM calls `client.archiveChat(...)` → bridge `ArchiveChat` → `SendAppState`.
4. Phone + other devices receive the patch; archive reflected everywhere.

**Inbound (archived on the phone):**
1. `events.Archive` → bridge `"ChatArchived"` → Swift decode.
2. `ContentView` → `ChatListViewModel.applyIncomingArchive(jid, archived)`.
3. `archivedAt` reconciled; sidebar re-sections.

**Block:** outbound via `UpdateBlocklist`; inbound via `events.Blocklist` →
re-fetch or apply changes → `blockedJIDs` updated → banner + Settings refresh.

**Delete:** outbound removes local rows + sends `DeleteChat`; inbound
`events.DeleteChat` removes local rows (idempotent if already gone).

## Error handling

- Bridge methods return wrapped errors; Swift logs and reverts the optimistic
  change (e.g., restore `archivedAt`, re-add to `blockedJIDs`) on failure,
  mirroring `pinChat`.
- `BlocklistChanged` with `Action == "modify"` and empty changes → call
  `loadBlocklist()` to re-sync the whole set.
- Deleting/archiving a stub chat with no messages: `lastMsgID == ""`,
  zero-safe message range handles it.
- Contact patch version uncertainty: see Component 1a risk note.

## Testing

**Go (`bridge/*_test.go`):**
- `appstate_test`: `ArchiveChat`/`DeleteChat`/`SetContactName` build the
  expected `PatchInfo` (type, index, version, action fields) — assert via the
  patch struct before send, like `forward_test`.
- `blocklist_test`: `SetBlocked`/`ListBlocked` round-trip with a fake/guarded
  client; `ListBlocked` JSON shape.
- `events_dispatch_test`: each new event → correct kind + JSON payload.

**Swift (logic, unit-testable):**
- `displayRows()` archived filtering: archived chats excluded from buckets;
  header present iff archived non-empty in scope; expanded reveals them.
- `SessionViewModel` blocked-set membership + `applyBlocklistChange`.

**Manual verify (UI + live sync):** archive/unarchive round-trip phone↔app;
delete clears on phone; block stops messages + banner shows; add-to-contacts
name lands on the phone (confirms the contact patch version). Consistent with
how pin/star/forward were validated.

## Out of scope (YAGNI)

- Mute (separate action, not requested).
- Multi-select bulk archive/delete.
- Auto-unarchive on new message (explicitly declined).
- Persisted blocklist cache (in-memory + refetch is sufficient).
- Blocked-contact avatars/About hiding beyond the banner.
