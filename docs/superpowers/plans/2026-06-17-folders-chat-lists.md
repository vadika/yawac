# F91 — Folders / Chat Lists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Telegram-style vertical folder rail on the LEFT of the chat list, with smart sentinels (All chats / Archived), user-defined custom folders, drag-to-add membership, ⌘0..9 quick switch, and per-folder unread badges. Pure Swift; no whatsmeow / bridge changes.

**Architecture:** New `PersistedFolder` SwiftData model + `folderIDs: [String]` field on `PersistedChat`. New `FolderRailViewModel` owns rail state. `ChatListView` body wraps its existing content in `HStack { FolderRail | Divider | chatListContent }`. `ChatListViewModel.rebuildDisplayRows` accepts a `FolderSelection` filter; the existing inline expandable archived section is replaced by the rail's Archived sentinel.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData, macOS 14+, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-17-folders-chat-lists-design.md`

---

## File map

| File | Action |
|---|---|
| `yawac/Models/PersistedFolder.swift` | Create |
| `yawac/Models/PersistedMessage.swift` (PersistedChat) | Modify — add `folderIDs: [String]` |
| `yawac/Models/Chat.swift` | Modify — add `folderIDs: [String]` |
| `yawac/Models/FolderSelection.swift` | Create |
| `yawac/ViewModels/FolderRailViewModel.swift` | Create |
| `yawac/ViewModels/ChatListViewModel.swift` | Modify — `chatsFor(selection:allChats:)` pure helper + hydrate `folderIDs` on Chat |
| `yawac/Util/FolderTransfers.swift` | Create — `ChatJIDTransfer` + `FolderIDTransfer` |
| `yawac/Views/FolderRailItem.swift` | Create |
| `yawac/Views/FolderRail.swift` | Create |
| `yawac/Views/NewFolderSheet.swift` | Create |
| `yawac/Views/ChatListView.swift` | Modify — HStack wrap, remove Scope row, use chatsFor, drop archived expandable, drag source, context-menu submenu |
| `yawac/yawacApp.swift` | Modify — Schema += PersistedFolder, CommandMenu("Folders") |
| `yawacTests/PersistedFolderModelTests.swift` | Create |
| `yawacTests/FolderSelectionTests.swift` | Create |
| `yawacTests/FolderRailViewModelCRUDTests.swift` | Create |
| `yawacTests/FolderRailViewModelBadgeTests.swift` | Create |
| `yawacTests/ChatListFolderFilterTests.swift` | Create |
| `yawacTests/FolderTransfersTests.swift` | Create |
| `docs/ROADMAP.md` | Modify — flip Folders bullet ☐ → ✅; F91 shipped entry |
| `project.yml` | Modify — 0.10.18 → 0.10.19, CFBundleVersion 101 → 102 |

---

## Pre-flight

The codebase carries an F72 single-instance gate (`LSMultipleInstancesProhibited = true`). When the user has the installed `/Applications/yawac.app` running, `xcodebuild test` is blocked. Before any test run:

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
```

XCFramework rebuild is NOT required for F91 — this is a pure Swift / SwiftData / SwiftUI feature. Bridge / Go untouched.

---

## Task 1: PersistedFolder SwiftData model + schema registration + lightweight `folderIDs` migration

**Files:**
- Create: `yawac/Models/PersistedFolder.swift`
- Modify: `yawac/Models/PersistedMessage.swift:233-286` (PersistedChat class)
- Modify: `yawac/yawacApp.swift:39-43` (Schema list)
- Test: `yawacTests/PersistedFolderModelTests.swift`

- [ ] **Step 1: Write the failing test**

`yawacTests/PersistedFolderModelTests.swift`:

```swift
import XCTest
import SwiftData
@testable import yawac

@MainActor
final class PersistedFolderModelTests: XCTestCase {

    func testInsertAndFetchPersistedFolder() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        let f = PersistedFolder(name: "Work", sortIndex: 0)
        context.insert(f)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PersistedFolder>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Work")
        XCTAssertEqual(fetched.first?.sortIndex, 0)
        XCTAssertFalse(fetched.first?.id.isEmpty ?? true)
    }

    func testUniqueIDConstraint() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        let id = "fixed-id-for-test"
        context.insert(PersistedFolder(id: id, name: "A", sortIndex: 0))
        try context.save()

        // Second insert with same id: SwiftData unique constraint upserts.
        context.insert(PersistedFolder(id: id, name: "B", sortIndex: 1))
        try context.save()

        let rows = try context.fetch(FetchDescriptor<PersistedFolder>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "B")
    }

    func testPersistedChatFolderIDsRoundTrip() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        let chat = PersistedChat(jid: "111@s.whatsapp.net", name: "Alice")
        chat.folderIDs = ["folder-1", "folder-2"]
        context.insert(chat)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PersistedChat>())
        XCTAssertEqual(fetched.first?.folderIDs, ["folder-1", "folder-2"])
    }

    private static func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: PersistedMessage.self,
            PersistedChat.self,
            PersistedReaction.self,
            PersistedPollVote.self,
            PersistedFolder.self,
            configurations: config)
    }
}
```

- [ ] **Step 2: Run test — expect compile failure**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/PersistedFolderModelTests test 2>&1 | tail -15
```

Expected: compile error "cannot find 'PersistedFolder' in scope".

- [ ] **Step 3: Create `yawac/Models/PersistedFolder.swift`**

```swift
import Foundation
import SwiftData

/// F91: user-defined chat-grouping folder. Membership lives on
/// PersistedChat.folderIDs (Codable [String]); names are cosmetic;
/// sortIndex drives top-to-bottom order in the FolderRail.
@Model
final class PersistedFolder {
    @Attribute(.unique) var id: String
    var name: String
    var sortIndex: Int
    var createdAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         sortIndex: Int,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 4: Add `folderIDs` field to PersistedChat**

In `yawac/Models/PersistedMessage.swift`, inside the `PersistedChat` class body, after the `bellEnabled` field (around line 259):

```swift
    /// F91: folder memberships. Plain Codable [String] of
    /// PersistedFolder.id values. Default-value optional so existing
    /// rows lightweight-migrate transparently. Not added to init(...)
    /// because the default-value path keeps every existing call site
    /// compiling; upsertPersisted / addChat assigns explicitly.
    var folderIDs: [String] = []
```

- [ ] **Step 5: Register PersistedFolder in the Schema**

In `yawac/yawacApp.swift:39-43`, change the `ModelContainer` constructor:

```swift
self.container = try ModelContainer(
    for: PersistedMessage.self,
    PersistedChat.self,
    PersistedReaction.self,
    PersistedPollVote.self,
    PersistedFolder.self)
```

- [ ] **Step 6: Run test — expect pass**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/PersistedFolderModelTests test 2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **` with all 3 cases green.

- [ ] **Step 7: Commit**

```bash
git add yawac/Models/PersistedFolder.swift \
        yawac/Models/PersistedMessage.swift \
        yawac/yawacApp.swift \
        yawacTests/PersistedFolderModelTests.swift
git commit -m "F91: PersistedFolder model + folderIDs on PersistedChat"
```

---

## Task 2: Mirror `folderIDs` onto Chat struct + hydrate from PersistedChat in ChatListViewModel

The `Chat` struct (used by ChatListViewModel and all view code) needs a `folderIDs: [String]` field so views can read membership without re-fetching SwiftData. `ChatListViewModel.bootstrapFromPersistedChats` already hydrates Chat from PersistedChat — add the new field there.

**Files:**
- Modify: `yawac/Models/Chat.swift`
- Modify: `yawac/ViewModels/ChatListViewModel.swift` (every PersistedChat → Chat hydration site)

- [ ] **Step 1: Add `folderIDs` to the Chat struct**

`yawac/Models/Chat.swift`, after the `bellEnabled` field (line 9):

```swift
    var bellEnabled: Bool = true
    /// F91: folder memberships (PersistedFolder.id values).
    var folderIDs: [String] = []
```

- [ ] **Step 2: Find all sites that build Chat from PersistedChat**

```bash
grep -n "Chat(" yawac/ViewModels/ChatListViewModel.swift | head -20
```

Expected: at least one site that constructs `Chat(jid:..., name:..., ...)` from a PersistedChat row, plus `let fresh = Chat(` at line 840.

- [ ] **Step 3: Add `folderIDs:` parameter to each Chat construction from PersistedChat**

For every site that constructs Chat by reading PersistedChat fields, add `folderIDs: persisted.folderIDs` (or `folderIDs: []` for Chat constructions that don't have a PersistedChat source, e.g. transient stubs).

The Chat init is auto-synthesized (memberwise); the new `folderIDs: [String] = []` default means existing call sites remain valid. Only explicitly pass it where the PersistedChat row carries memberships:
- `upsertPersisted` (sets PersistedChat.folderIDs from Chat.folderIDs on write)
- `bootstrapFromPersistedChats` (reads PersistedChat.folderIDs into Chat.folderIDs on read)

Use grep to find the bootstrap site:

```bash
grep -n "PersistedChat\b\|fromPersisted\|hydrate" yawac/ViewModels/ChatListViewModel.swift | head -20
```

In the read site (typically `bootstrapFromPersistedChats` or its equivalent loop that maps PersistedChat → Chat), add:

```swift
fresh.folderIDs = persisted.folderIDs
```

In the write site (`upsertPersisted` or equivalent that mutates a PersistedChat row from a Chat):

```swift
persisted.folderIDs = c.folderIDs
```

- [ ] **Step 4: Build to verify no compile errors**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Re-run Task 1 tests + the full test target**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`; no regressions.

- [ ] **Step 6: Commit**

```bash
git add yawac/Models/Chat.swift yawac/ViewModels/ChatListViewModel.swift
git commit -m "F91: hydrate folderIDs from PersistedChat into Chat struct"
```

---

## Task 3: FolderSelection enum + AppStorage codec helpers

**Files:**
- Create: `yawac/Models/FolderSelection.swift`
- Test: `yawacTests/FolderSelectionTests.swift`

- [ ] **Step 1: Write the failing test**

`yawacTests/FolderSelectionTests.swift`:

```swift
import XCTest
@testable import yawac

final class FolderSelectionTests: XCTestCase {

    func testStorageKeyRoundTrip() {
        XCTAssertEqual(FolderSelection.all.storageValue, "")
        XCTAssertEqual(FolderSelection.archived.storageValue, "_archived")
        XCTAssertEqual(FolderSelection.custom(folderID: "abc").storageValue, "abc")
    }

    func testFromStorageValue() {
        XCTAssertEqual(FolderSelection(storageValue: ""), .all)
        XCTAssertEqual(FolderSelection(storageValue: "_archived"), .archived)
        XCTAssertEqual(FolderSelection(storageValue: "uuid-1234"),
                       .custom(folderID: "uuid-1234"))
    }

    func testFallbackForMissingFolderID() {
        // When the persisted folder id no longer exists in `validIDs`,
        // FolderSelection.resolved(...) collapses to .all.
        let knownIDs: Set<String> = ["folder-A", "folder-B"]
        XCTAssertEqual(
            FolderSelection.resolved(storageValue: "folder-A", knownIDs: knownIDs),
            .custom(folderID: "folder-A"))
        XCTAssertEqual(
            FolderSelection.resolved(storageValue: "missing-folder",
                                      knownIDs: knownIDs),
            .all)
        XCTAssertEqual(
            FolderSelection.resolved(storageValue: "_archived", knownIDs: knownIDs),
            .archived)
        XCTAssertEqual(
            FolderSelection.resolved(storageValue: "", knownIDs: knownIDs),
            .all)
    }
}
```

- [ ] **Step 2: Run test — expect compile failure**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/FolderSelectionTests test 2>&1 | tail -10
```

Expected: compile error "cannot find 'FolderSelection' in scope".

- [ ] **Step 3: Create FolderSelection.swift**

`yawac/Models/FolderSelection.swift`:

```swift
import Foundation

/// F91: which rail item is currently selected.
/// Smart folders ("All chats", "Archived") are enum cases, not
/// SwiftData rows. Custom folders carry their PersistedFolder.id.
enum FolderSelection: Equatable, Hashable {
    case all
    case archived
    case custom(folderID: String)

    /// Stable string representation for @AppStorage round-trip.
    /// Reserved value `_archived` for the Archived smart folder; empty
    /// string for All chats; any other string is a folder UUID.
    var storageValue: String {
        switch self {
        case .all: return ""
        case .archived: return "_archived"
        case .custom(let id): return id
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "": self = .all
        case "_archived": self = .archived
        default: self = .custom(folderID: storageValue)
        }
    }

    /// Like `init(storageValue:)` but collapses .custom selections whose
    /// folderID is not in `knownIDs` down to .all. Used at app launch to
    /// recover from a folder that was deleted in a prior session.
    static func resolved(storageValue: String,
                         knownIDs: Set<String>) -> FolderSelection {
        let s = FolderSelection(storageValue: storageValue)
        if case .custom(let id) = s, !knownIDs.contains(id) {
            return .all
        }
        return s
    }
}
```

- [ ] **Step 4: Run test — expect pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/FolderSelectionTests test 2>&1 | tail -10
```

Expected: 3/3 cases green.

- [ ] **Step 5: Commit**

```bash
git add yawac/Models/FolderSelection.swift yawacTests/FolderSelectionTests.swift
git commit -m "F91: FolderSelection enum + AppStorage codec"
```

---

## Task 4: FolderRailViewModel CRUD + reorder + chat add/remove

**Files:**
- Create: `yawac/ViewModels/FolderRailViewModel.swift`
- Test: `yawacTests/FolderRailViewModelCRUDTests.swift`

- [ ] **Step 1: Write the failing test**

`yawacTests/FolderRailViewModelCRUDTests.swift`:

```swift
import XCTest
import SwiftData
@testable import yawac

@MainActor
final class FolderRailViewModelCRUDTests: XCTestCase {

    func testCreateFirstFolder() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        vm.loadFolders()
        XCTAssertEqual(vm.folders.count, 0)

        let created = vm.createFolder(name: "Work", atIndex: 0)
        XCTAssertEqual(vm.folders.count, 1)
        XCTAssertEqual(vm.folders[0].id, created.id)
        XCTAssertEqual(created.sortIndex, 0)
    }

    func testCreateSecondFolderAtIndexZeroBumpsExisting() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "First", atIndex: 0)
        _ = vm.createFolder(name: "Second", atIndex: 0)

        XCTAssertEqual(vm.folders.map(\.name), ["Second", "First"])
        XCTAssertEqual(vm.folders.map(\.sortIndex), [0, 1])
    }

    func testRenameFolderPreservesSortIndex() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        let f = vm.createFolder(name: "Old", atIndex: 0)
        vm.renameFolder(id: f.id, to: "New")
        XCTAssertEqual(vm.folders.first?.name, "New")
        XCTAssertEqual(vm.folders.first?.sortIndex, 0)
    }

    func testDeleteFolderScrubsChatMemberships() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let vm = FolderRailViewModel(context: context)
        let f = vm.createFolder(name: "Work", atIndex: 0)

        let chat = PersistedChat(jid: "111@s.whatsapp.net", name: "A")
        chat.folderIDs = [f.id, "other-folder"]
        context.insert(chat)
        try context.save()

        vm.deleteFolder(id: f.id)

        let fetched = try context.fetch(FetchDescriptor<PersistedChat>())
        XCTAssertEqual(fetched.first?.folderIDs, ["other-folder"])
        XCTAssertEqual(vm.folders.count, 0)
    }

    func testReorderMidToHead() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "A", atIndex: 0)
        _ = vm.createFolder(name: "B", atIndex: 1)
        _ = vm.createFolder(name: "C", atIndex: 2)

        vm.reorder(fromIndex: 2, toIndex: 0)
        XCTAssertEqual(vm.folders.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(vm.folders.map(\.sortIndex), [0, 1, 2])
    }

    func testReorderHeadToTail() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "A", atIndex: 0)
        _ = vm.createFolder(name: "B", atIndex: 1)
        _ = vm.createFolder(name: "C", atIndex: 2)

        vm.reorder(fromIndex: 0, toIndex: 2)
        XCTAssertEqual(vm.folders.map(\.name), ["B", "C", "A"])
    }

    func testReorderNoOp() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "A", atIndex: 0)
        _ = vm.createFolder(name: "B", atIndex: 1)

        vm.reorder(fromIndex: 1, toIndex: 1)
        XCTAssertEqual(vm.folders.map(\.name), ["A", "B"])
    }

    func testReorderOutOfBoundsClamps() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "A", atIndex: 0)
        _ = vm.createFolder(name: "B", atIndex: 1)

        // Out-of-bounds: silently no-op (don't crash).
        vm.reorder(fromIndex: 5, toIndex: 0)
        vm.reorder(fromIndex: 0, toIndex: 99)
        XCTAssertEqual(vm.folders.map(\.name), ["A", "B"])
    }

    func testAddChatIsIdempotent() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let vm = FolderRailViewModel(context: context)
        let f = vm.createFolder(name: "Work", atIndex: 0)
        let chat = PersistedChat(jid: "111@s.whatsapp.net", name: "A")
        context.insert(chat)
        try context.save()

        vm.addChat(jid: "111@s.whatsapp.net", toFolderID: f.id)
        vm.addChat(jid: "111@s.whatsapp.net", toFolderID: f.id)  // dup

        let fetched = try context.fetch(FetchDescriptor<PersistedChat>())
        XCTAssertEqual(fetched.first?.folderIDs, [f.id])
    }

    func testRemoveChat() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let vm = FolderRailViewModel(context: context)
        let f = vm.createFolder(name: "Work", atIndex: 0)
        let chat = PersistedChat(jid: "111@s.whatsapp.net", name: "A")
        chat.folderIDs = [f.id, "other"]
        context.insert(chat)
        try context.save()

        vm.removeChat(jid: "111@s.whatsapp.net", fromFolderID: f.id)
        let fetched = try context.fetch(FetchDescriptor<PersistedChat>())
        XCTAssertEqual(fetched.first?.folderIDs, ["other"])
    }

    func testDeleteSelectedFolderCollapsesSelectionToAll() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        let f = vm.createFolder(name: "X", atIndex: 0)
        vm.selection = .custom(folderID: f.id)
        vm.deleteFolder(id: f.id)
        XCTAssertEqual(vm.selection, .all)
    }

    private static func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: PersistedMessage.self,
            PersistedChat.self,
            PersistedReaction.self,
            PersistedPollVote.self,
            PersistedFolder.self,
            configurations: config)
    }
}
```

- [ ] **Step 2: Run test — expect compile failure**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/FolderRailViewModelCRUDTests test 2>&1 | tail -10
```

Expected: `cannot find 'FolderRailViewModel' in scope`.

- [ ] **Step 3: Create FolderRailViewModel.swift**

`yawac/ViewModels/FolderRailViewModel.swift`:

```swift
import Foundation
import Observation
import SwiftData

/// F91: state owner for the folder rail.
///
/// Holds the loaded folder list (sorted by sortIndex), the current
/// selection, and the per-folder unread badge totals. CRUD methods
/// persist directly to the injected ModelContext and re-load folders
/// to refresh `self.folders`.
@Observable @MainActor
final class FolderRailViewModel {

    var folders: [PersistedFolder] = []
    var selection: FolderSelection = .all
    var unreadByFolderID: [String: Int] = [:]
    var allUnread: Int = 0
    var archivedUnread: Int = 0

    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Load

    func loadFolders() {
        let descriptor = FetchDescriptor<PersistedFolder>(
            sortBy: [SortDescriptor(\.sortIndex, order: .forward)])
        folders = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - CRUD

    @discardableResult
    func createFolder(name: String, atIndex insertIdx: Int) -> PersistedFolder {
        loadFolders()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = max(0, min(insertIdx, folders.count))
        // Bump sortIndex on all folders at or after target.
        for f in folders where f.sortIndex >= target {
            f.sortIndex += 1
        }
        let new = PersistedFolder(name: trimmed.isEmpty ? "Folder" : trimmed,
                                  sortIndex: target)
        context.insert(new)
        try? context.save()
        loadFolders()
        return new
    }

    func renameFolder(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let f = folders.first(where: { $0.id == id }) else { return }
        f.name = trimmed
        try? context.save()
        loadFolders()
    }

    func deleteFolder(id: String) {
        // Collapse selection BEFORE delete so the view doesn't try to
        // render a folder that's about to disappear.
        if selection == .custom(folderID: id) {
            selection = .all
        }
        // Scrub chat memberships first.
        let chatDescriptor = FetchDescriptor<PersistedChat>()
        let chats = (try? context.fetch(chatDescriptor)) ?? []
        for c in chats where c.folderIDs.contains(id) {
            c.folderIDs.removeAll { $0 == id }
        }
        // Delete the folder row.
        if let f = folders.first(where: { $0.id == id }) {
            context.delete(f)
        }
        try? context.save()
        loadFolders()
    }

    func reorder(fromIndex: Int, toIndex: Int) {
        loadFolders()
        guard fromIndex >= 0, fromIndex < folders.count else { return }
        guard toIndex >= 0, toIndex < folders.count else { return }
        guard fromIndex != toIndex else { return }

        var working = folders
        let moved = working.remove(at: fromIndex)
        working.insert(moved, at: toIndex)
        // Reassign sortIndex by working order.
        for (i, f) in working.enumerated() {
            f.sortIndex = i
        }
        try? context.save()
        loadFolders()
    }

    // MARK: - Membership

    func addChat(jid: String, toFolderID folderID: String) {
        let descriptor = FetchDescriptor<PersistedChat>(
            predicate: #Predicate { $0.jid == jid })
        guard let c = (try? context.fetch(descriptor))?.first else { return }
        if !c.folderIDs.contains(folderID) {
            c.folderIDs.append(folderID)
            try? context.save()
        }
    }

    func removeChat(jid: String, fromFolderID folderID: String) {
        let descriptor = FetchDescriptor<PersistedChat>(
            predicate: #Predicate { $0.jid == jid })
        guard let c = (try? context.fetch(descriptor))?.first else { return }
        if c.folderIDs.contains(folderID) {
            c.folderIDs.removeAll { $0 == folderID }
            try? context.save()
        }
    }

    // MARK: - Badge compute (implemented in Task 5)

    func refreshBadges(chats: [Chat]) {
        // Filled in Task 5. For Task 4 leave as a stub.
    }
}
```

- [ ] **Step 4: Run test — expect pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/FolderRailViewModelCRUDTests test 2>&1 | tail -15
```

Expected: 11/11 cases green.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/FolderRailViewModel.swift \
        yawacTests/FolderRailViewModelCRUDTests.swift
git commit -m "F91: FolderRailViewModel CRUD + reorder + membership"
```

---

## Task 5: FolderRailViewModel.refreshBadges + tests

**Files:**
- Modify: `yawac/ViewModels/FolderRailViewModel.swift` (replace `refreshBadges` stub)
- Test: `yawacTests/FolderRailViewModelBadgeTests.swift`

- [ ] **Step 1: Write the failing test**

`yawacTests/FolderRailViewModelBadgeTests.swift`:

```swift
import XCTest
import SwiftData
@testable import yawac

@MainActor
final class FolderRailViewModelBadgeTests: XCTestCase {

    func testEmptyChatListZeroesAllBadges() throws {
        let vm = try makeVM()
        vm.refreshBadges(chats: [])
        XCTAssertEqual(vm.allUnread, 0)
        XCTAssertEqual(vm.archivedUnread, 0)
        XCTAssertEqual(vm.unreadByFolderID, [:])
    }

    func testUnreadOnNonArchivedChatBumpsAllAndFolder() throws {
        let vm = try makeVM()
        var c = makeChat(jid: "111@s.whatsapp.net", unread: 3,
                        folderIDs: ["folder-A"], archived: false)
        vm.refreshBadges(chats: [c])
        XCTAssertEqual(vm.allUnread, 3)
        XCTAssertEqual(vm.unreadByFolderID, ["folder-A": 3])
        XCTAssertEqual(vm.archivedUnread, 0)
    }

    func testUnreadOnArchivedChatBumpsOnlyArchived() throws {
        let vm = try makeVM()
        let c = makeChat(jid: "222@s.whatsapp.net", unread: 2,
                        folderIDs: ["folder-A"], archived: true)
        vm.refreshBadges(chats: [c])
        XCTAssertEqual(vm.archivedUnread, 2)
        XCTAssertEqual(vm.allUnread, 0)
        XCTAssertEqual(vm.unreadByFolderID, [:],
                       "archived chat must not bump its custom folder badge")
    }

    func testMultipleFoldersSummedIndependently() throws {
        let vm = try makeVM()
        let a = makeChat(jid: "1@s.whatsapp.net", unread: 5,
                        folderIDs: ["f1", "f2"], archived: false)
        let b = makeChat(jid: "2@s.whatsapp.net", unread: 2,
                        folderIDs: ["f1"], archived: false)
        vm.refreshBadges(chats: [a, b])
        XCTAssertEqual(vm.allUnread, 7)
        XCTAssertEqual(vm.unreadByFolderID, ["f1": 7, "f2": 5])
    }

    func testZeroUnreadIgnored() throws {
        let vm = try makeVM()
        let c = makeChat(jid: "0@s.whatsapp.net", unread: 0,
                        folderIDs: ["f1"], archived: false)
        vm.refreshBadges(chats: [c])
        XCTAssertEqual(vm.allUnread, 0)
        XCTAssertEqual(vm.unreadByFolderID, [:])
    }

    // MARK: helpers

    @MainActor
    private func makeVM() throws -> FolderRailViewModel {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: PersistedMessage.self,
            PersistedChat.self,
            PersistedReaction.self,
            PersistedPollVote.self,
            PersistedFolder.self,
            configurations: config)
        return FolderRailViewModel(context: ModelContext(container))
    }

    private func makeChat(jid: String,
                          unread: Int,
                          folderIDs: [String],
                          archived: Bool) -> Chat {
        var c = Chat(jid: jid, name: "Test",
                     lastMessage: "", lastTimestamp: 0, unread: unread)
        c.folderIDs = folderIDs
        if archived { c.archivedAt = Date() }
        return c
    }
}
```

- [ ] **Step 2: Run test — expect failure (4 of 5 fail because refreshBadges is a stub)**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/FolderRailViewModelBadgeTests test 2>&1 | tail -15
```

Expected: 1 pass (`testEmptyChatListZeroesAllBadges` — stub keeps zeros), 4 fail.

- [ ] **Step 3: Replace `refreshBadges` stub with real implementation**

In `yawac/ViewModels/FolderRailViewModel.swift`, replace the `refreshBadges` stub with:

```swift
    func refreshBadges(chats: [Chat]) {
        var byFolder: [String: Int] = [:]
        var all = 0
        var archived = 0
        for c in chats {
            guard c.unread > 0 else { continue }
            if c.archivedAt != nil {
                archived += c.unread
                continue
            }
            all += c.unread
            for fid in c.folderIDs {
                byFolder[fid, default: 0] += c.unread
            }
        }
        self.unreadByFolderID = byFolder
        self.allUnread = all
        self.archivedUnread = archived
    }
```

- [ ] **Step 4: Run test — expect pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/FolderRailViewModelBadgeTests test 2>&1 | tail -10
```

Expected: 5/5 green.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/FolderRailViewModel.swift \
        yawacTests/FolderRailViewModelBadgeTests.swift
git commit -m "F91: FolderRailViewModel.refreshBadges (archived-aware)"
```

---

## Task 6: Pure chat-list filter `chatsFor(selection:allChats:)`

This is the single filter that the ChatListView display logic will call before bucketing into pinned / sections / etc.

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift` (add static pure helper)
- Test: `yawacTests/ChatListFolderFilterTests.swift`

- [ ] **Step 1: Write the failing test**

`yawacTests/ChatListFolderFilterTests.swift`:

```swift
import XCTest
@testable import yawac

final class ChatListFolderFilterTests: XCTestCase {

    func testAllSelectionExcludesArchived() {
        let alive = makeChat(jid: "1", archived: false, folderIDs: [])
        let arch  = makeChat(jid: "2", archived: true, folderIDs: [])
        let out = ChatListViewModel.chatsFor(selection: .all,
                                             allChats: [alive, arch])
        XCTAssertEqual(out.map(\.jid), ["1"])
    }

    func testArchivedSelectionIncludesOnlyArchived() {
        let alive = makeChat(jid: "1", archived: false, folderIDs: [])
        let arch  = makeChat(jid: "2", archived: true, folderIDs: ["folder-X"])
        let out = ChatListViewModel.chatsFor(selection: .archived,
                                             allChats: [alive, arch])
        XCTAssertEqual(out.map(\.jid), ["2"])
    }

    func testCustomSelectionMatchesFolderIDs() {
        let inFolder = makeChat(jid: "1", archived: false,
                                 folderIDs: ["folder-X"])
        let outFolder = makeChat(jid: "2", archived: false,
                                  folderIDs: ["folder-Y"])
        let result = ChatListViewModel.chatsFor(
            selection: .custom(folderID: "folder-X"),
            allChats: [inFolder, outFolder])
        XCTAssertEqual(result.map(\.jid), ["1"])
    }

    func testCustomSelectionHidesArchivedEvenIfTagged() {
        let archivedInFolder = makeChat(jid: "1", archived: true,
                                        folderIDs: ["folder-X"])
        let aliveInFolder = makeChat(jid: "2", archived: false,
                                     folderIDs: ["folder-X"])
        let result = ChatListViewModel.chatsFor(
            selection: .custom(folderID: "folder-X"),
            allChats: [archivedInFolder, aliveInFolder])
        XCTAssertEqual(result.map(\.jid), ["2"])
    }

    func testCustomSelectionEmptyWhenNoMatches() {
        let chat = makeChat(jid: "1", archived: false, folderIDs: ["folder-Y"])
        let result = ChatListViewModel.chatsFor(
            selection: .custom(folderID: "folder-X"),
            allChats: [chat])
        XCTAssertEqual(result.count, 0)
    }

    private func makeChat(jid: String, archived: Bool,
                          folderIDs: [String]) -> Chat {
        var c = Chat(jid: jid, name: jid, lastMessage: "",
                     lastTimestamp: 0, unread: 0)
        if archived { c.archivedAt = Date() }
        c.folderIDs = folderIDs
        return c
    }
}
```

- [ ] **Step 2: Run test — expect compile failure**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatListFolderFilterTests test 2>&1 | tail -10
```

Expected: `type 'ChatListViewModel' has no member 'chatsFor'`.

- [ ] **Step 3: Add the pure static helper**

In `yawac/ViewModels/ChatListViewModel.swift`, add (anywhere inside the class body — place near other pure helpers or at the bottom):

```swift
    /// F91: pure folder-selection filter applied BEFORE bucket logic
    /// (pinned / archived header / sections). `.all` and `.custom` hide
    /// archived chats — the rail's Archived sentinel is now their only
    /// surface. `.archived` shows them flat.
    nonisolated static func chatsFor(selection: FolderSelection,
                                     allChats: [Chat]) -> [Chat] {
        switch selection {
        case .all:
            return allChats.filter { $0.archivedAt == nil }
        case .archived:
            return allChats.filter { $0.archivedAt != nil }
        case .custom(let id):
            return allChats.filter {
                $0.archivedAt == nil && $0.folderIDs.contains(id)
            }
        }
    }
```

- [ ] **Step 4: Run test — expect pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatListFolderFilterTests test 2>&1 | tail -10
```

Expected: 5/5 green.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ChatListViewModel.swift \
        yawacTests/ChatListFolderFilterTests.swift
git commit -m "F91: pure chatsFor(selection:allChats:) filter"
```

---

## Task 7: Transferable types for drag-and-drop

**Files:**
- Create: `yawac/Util/FolderTransfers.swift`
- Test: `yawacTests/FolderTransfersTests.swift`

- [ ] **Step 1: Write the failing test**

`yawacTests/FolderTransfersTests.swift`:

```swift
import XCTest
import UniformTypeIdentifiers
@testable import yawac

final class FolderTransfersTests: XCTestCase {

    func testChatJIDTransferRoundTripsJSON() throws {
        let original = ChatJIDTransfer(jid: "111@s.whatsapp.net")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatJIDTransfer.self, from: data)
        XCTAssertEqual(decoded.jid, "111@s.whatsapp.net")
    }

    func testFolderIDTransferRoundTripsJSON() throws {
        let original = FolderIDTransfer(id: "uuid-1234")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FolderIDTransfer.self, from: data)
        XCTAssertEqual(decoded.id, "uuid-1234")
    }

    func testUTTypesRegistered() {
        XCTAssertNotNil(UTType(ChatJIDTransfer.utTypeIdentifier))
        XCTAssertNotNil(UTType(FolderIDTransfer.utTypeIdentifier))
    }
}
```

- [ ] **Step 2: Run test — expect compile failure**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/FolderTransfersTests test 2>&1 | tail -10
```

Expected: `cannot find 'ChatJIDTransfer' in scope`.

- [ ] **Step 3: Create FolderTransfers.swift**

`yawac/Util/FolderTransfers.swift`:

```swift
import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// F91: drag payload — a single chat JID being dragged from a chat
/// row onto a folder rail item. Custom UT type avoids collision with
/// public file/URL drop handlers that might otherwise eat the drop.
struct ChatJIDTransfer: Codable, Transferable {
    let jid: String

    static let utTypeIdentifier = "dev.vadikas.yawac.chatjid"

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .chatJID)
    }
}

/// F91: drag payload — a folder rail item being dragged to reorder.
struct FolderIDTransfer: Codable, Transferable {
    let id: String

    static let utTypeIdentifier = "dev.vadikas.yawac.folderid"

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .folderID)
    }
}

extension UTType {
    static let chatJID = UTType(exportedAs: ChatJIDTransfer.utTypeIdentifier)
    static let folderID = UTType(exportedAs: FolderIDTransfer.utTypeIdentifier)
}
```

- [ ] **Step 4: Run test — expect pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/FolderTransfersTests test 2>&1 | tail -10
```

Expected: 3/3 green.

- [ ] **Step 5: Commit**

```bash
git add yawac/Util/FolderTransfers.swift yawacTests/FolderTransfersTests.swift
git commit -m "F91: ChatJIDTransfer + FolderIDTransfer drag payloads"
```

---

## Task 8: FolderRailItem visual row

**Files:**
- Create: `yawac/Views/FolderRailItem.swift`

No unit test — pure visual. Verified via build + Task 11 integration.

- [ ] **Step 1: Create FolderRailItem.swift**

```swift
import SwiftUI

/// F91: single row in the FolderRail. Visual only — selection and
/// badge state pass in via the parent. Three flavors via `Kind`:
/// custom folder (PersistedFolder-backed), "All chats", "Archived".
struct FolderRailItem: View {

    enum Kind {
        case custom(PersistedFolder)
        case all
        case archived
    }

    let kind: Kind
    let isSelected: Bool
    let badge: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: iconName)
                        .scaledIcon(20, weight: isSelected ? .semibold : .regular)
                        .foregroundStyle(iconColor)
                        .frame(width: 44, height: 36)
                        .background(
                            isSelected ? Theme.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                    if badge > 0 {
                        Text(badgeText)
                            .scaledMono(9, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                            .offset(x: 4, y: -2)
                    }
                }
                Text(label)
                    .scaledUI(10.5, weight: isSelected ? .semibold : .regular)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(labelColor)
            }
            .frame(width: 72)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch kind {
        case .custom: return "folder.fill"
        case .all: return "bubble.left.and.bubble.right.fill"
        case .archived: return "archivebox.fill"
        }
    }

    private var label: String {
        switch kind {
        case .custom(let f): return f.name
        case .all: return "All chats"
        case .archived: return "Archived"
        }
    }

    private var iconColor: Color {
        isSelected ? Theme.accentText : Theme.textMuted
    }

    private var labelColor: Color {
        isSelected ? Theme.accentText : Theme.textMuted
    }

    private var badgeText: String {
        badge > 99 ? "99+" : "\(badge)"
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/FolderRailItem.swift
git commit -m "F91: FolderRailItem visual row"
```

---

## Task 9: FolderRail view

**Files:**
- Create: `yawac/Views/FolderRail.swift`

- [ ] **Step 1: Create FolderRail.swift**

```swift
import SwiftUI

/// F91: vertical rail on the left of the chat list. Custom folders
/// on top (sorted by sortIndex), then "All chats" sentinel, then
/// "Archived" sentinel. Fixed 76pt width.
struct FolderRail: View {

    let vm: FolderRailViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(vm.folders, id: \.id) { folder in
                        FolderRailItem(
                            kind: .custom(folder),
                            isSelected: vm.selection == .custom(folderID: folder.id),
                            badge: vm.unreadByFolderID[folder.id] ?? 0,
                            onTap: { vm.selection = .custom(folderID: folder.id) })
                    }

                    FolderRailItem(
                        kind: .all,
                        isSelected: vm.selection == .all,
                        badge: vm.allUnread,
                        onTap: { vm.selection = .all })

                    FolderRailItem(
                        kind: .archived,
                        isSelected: vm.selection == .archived,
                        badge: vm.archivedUnread,
                        onTap: { vm.selection = .archived })
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 76)
        .background(Theme.surface)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/FolderRail.swift
git commit -m "F91: FolderRail container view"
```

---

## Task 10: NewFolderSheet (name prompt)

**Files:**
- Create: `yawac/Views/NewFolderSheet.swift`

- [ ] **Step 1: Create NewFolderSheet.swift**

```swift
import SwiftUI

/// F91: small modal that asks for a folder name. Used by the rail
/// context menu's "New folder…" and the chat-row "Add to folder…"
/// submenu's "New folder…" trailing item.
struct NewFolderSheet: View {

    @Binding var isPresented: Bool
    let onCreate: (String) -> Void

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New folder")
                .scaledUI(14, weight: .semibold)
                .foregroundStyle(Theme.text)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { nameFocused = true }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        isPresented = false
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/NewFolderSheet.swift
git commit -m "F91: NewFolderSheet name prompt"
```

---

## Task 11: Mount FolderRail in ChatListView + remove Scope row + use chatsFor

This is the biggest single edit. It wires the rail in, drops the 4-segment Scope picker (the rail subsumes it), drops the inline expandable archived section (the Archived sentinel takes over), and routes `rebuildDisplayRows` through `chatsFor(selection:allChats:)`.

**Files:**
- Modify: `yawac/Views/ChatListView.swift`

- [ ] **Step 1: Add the rail view model state + load on appear**

At the top of `ChatListView` (near the existing `@State private var cachedRows: [Row] = []`, around line 23), add:

```swift
    @State private var folderRail: FolderRailViewModel?
    @State private var showNewFolderSheet: Bool = false
    @State private var renamingFolder: PersistedFolder?
    @State private var folderPendingDelete: PersistedFolder?
    @State private var newFolderInsertIndex: Int = 0
    @AppStorage("yawac.selectedFolderID") private var selectedFolderIDRaw: String = ""
    @Environment(\.modelContext) private var modelContext
```

- [ ] **Step 2: Remove the Scope enum, @AppStorage, and scope tabs row**

At ChatListView top (around lines 15-47), DELETE:

```swift
@AppStorage("yawac.chatListScope") private var scopeRaw: String = Scope.all.r...
enum Scope: String, CaseIterable, Identifiable { ... }   // entire enum
private var scope: Scope { Scope(rawValue: scopeRaw) ?? .all }
```

In `body` (around lines 341-373), DELETE the entire `HStack(spacing: 4) { ForEach(Scope.allCases) { ... } } ...` block (the scope-tabs strip).

Around line 510, DELETE:

```swift
.onChange(of: scopeRaw) { _, _ in
    cachedRows = rebuildDisplayRows()
}
```

- [ ] **Step 3: Wrap body in HStack with FolderRail**

In `var body: some View` (line 259), wrap the existing `VStack(spacing: 0) { … }` in an `HStack`:

```swift
    var body: some View {
        HStack(spacing: 0) {
            if let rail = folderRail {
                FolderRail(vm: rail)
                    .contextMenu {     // wired in Task 14
                        Button("New folder…") {
                            newFolderInsertIndex = rail.folders.count
                            showNewFolderSheet = true
                        }
                    }
                Divider()
            }
            chatListContent
        }
        .task {
            if folderRail == nil {
                let rail = FolderRailViewModel(context: modelContext)
                rail.loadFolders()
                let knownIDs = Set(rail.folders.map(\.id))
                rail.selection = FolderSelection.resolved(
                    storageValue: selectedFolderIDRaw,
                    knownIDs: knownIDs)
                folderRail = rail
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(isPresented: $showNewFolderSheet) { name in
                folderRail?.createFolder(name: name, atIndex: newFolderInsertIndex)
            }
        }
    }

    // Extract the prior body VStack contents into a private computed view.
    private var chatListContent: some View {
        VStack(spacing: 0) {
            // … the existing WindowDragHandle + search field + (the deleted
            //   Scope tabs block goes here, now empty) + ScrollView + …
        }
    }
```

(The full body refactor: cut every line from the original `VStack(spacing: 0) { … }` open through its close brace, then paste it inside `chatListContent`. Drop the Scope tabs `HStack`.)

- [ ] **Step 4: Route selection persistence to AppStorage**

Add an `.onChange(of: folderRail?.selection)` to `chatListContent` (or to the outer `HStack`):

```swift
.onChange(of: folderRail?.selection) { _, newValue in
    if let s = newValue {
        selectedFolderIDRaw = s.storageValue
        cachedRows = rebuildDisplayRows()
    }
}
```

- [ ] **Step 5: Wire badge refresh on chats change**

Existing `.onChange(of: vm.chats.count)` / `.onChange(of: vm.chats)` blocks rebuild `cachedRows`. Add a folder-rail badge refresh alongside the first one (around line 487):

```swift
.onChange(of: vm.chats) { _, _ in
    cachedRows = rebuildDisplayRows()
    folderRail?.refreshBadges(chats: vm.chats)
}
```

- [ ] **Step 6: Use chatsFor at the entry to rebuildDisplayRows**

In `rebuildDisplayRows()` (line 101), at the very top:

```swift
private func rebuildDisplayRows() -> [Row] {
    let selection = folderRail?.selection ?? .all
    let visibleChats = ChatListViewModel.chatsFor(
        selection: selection,
        allChats: vm.chats)
    // Existing logic now operates on `visibleChats` instead of `vm.chats`.
    // Search/replace every `vm.chats` reference inside this function with
    // `visibleChats`.
    …
}
```

For the `.archived` selection, the existing inline expandable archived section logic must be skipped — the rail now owns archived display:

```swift
    if selection == .archived {
        // Flat list of archived chats — no header, no expansion, no other sections.
        return visibleChats
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
            .map { Row.chat($0, 0) }
    }
```

For `.all` and `.custom`, drop the archived-expandable rows entirely — `visibleChats` no longer contains archived rows, so the existing archive-section logic (`.archivedHeader`, expansion state) produces zero output. The `.archivedHeader` Row case can stay (dead) or be removed in a later cleanup; leave for now.

- [ ] **Step 7: Build to verify**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. If `Scope` references remain elsewhere (e.g. another file imports the enum), delete them; this enum was only used in `ChatListView.swift`.

- [ ] **Step 8: Run the full test target**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`; existing tests (`ChatListBlockArchiveTests`, etc.) green.

- [ ] **Step 9: Commit**

```bash
git add yawac/Views/ChatListView.swift
git commit -m "F91: mount FolderRail in ChatListView; drop Scope row + inline archived"
```

---

## Task 12: Drag chat row → folder rail (add membership)

**Files:**
- Modify: `yawac/Views/ChatListView.swift` (`chatRowButton` at line 561 — add `.draggable`)
- Modify: `yawac/Views/FolderRail.swift` (add `.dropDestination` on custom items)

- [ ] **Step 1: Add `.draggable` to `chatRowButton`**

In `chatRowButton(_ chat: Chat, indent: CGFloat = 0)` at line 561, after the existing `.contextMenu { … }` (line 568-605), append:

```swift
        .draggable(ChatJIDTransfer(jid: chat.jid)) {
            // Drag preview: just the row body at half opacity.
            chatRowBody(chat, indent: 0)
                .frame(width: 240)
                .opacity(0.75)
        }
```

- [ ] **Step 2: Add `.dropDestination` to custom items in FolderRail**

In `yawac/Views/FolderRail.swift`, wrap the custom-folder `FolderRailItem` (the one inside the `ForEach(vm.folders)`) with a drop destination:

```swift
                    ForEach(vm.folders, id: \.id) { folder in
                        FolderRailItem(
                            kind: .custom(folder),
                            isSelected: vm.selection == .custom(folderID: folder.id),
                            badge: vm.unreadByFolderID[folder.id] ?? 0,
                            onTap: { vm.selection = .custom(folderID: folder.id) })
                        .dropDestination(for: ChatJIDTransfer.self) { transfers, _ in
                            for t in transfers {
                                vm.addChat(jid: t.jid, toFolderID: folder.id)
                            }
                            return !transfers.isEmpty
                        } isTargeted: { _ in
                            // visual feedback handled by FolderRailItem if needed
                        }
                    }
```

The All chats / Archived sentinel items do NOT get this modifier — drops on them are refused.

- [ ] **Step 3: Build + manual smoke**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

Manual smoke (Debug build, run via Xcode or open the just-built app):

1. Open the app
2. Create a folder via the rail context menu → "New folder…" → enter "Test"
3. Drag a chat row from the chat list onto the "Test" rail icon
4. Click the "Test" rail icon — the dragged chat should appear in the list
5. Click "All chats" rail icon — the chat should reappear in the full list

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ChatListView.swift yawac/Views/FolderRail.swift
git commit -m "F91: drag chat row → folder rail (add membership)"
```

---

## Task 13: Drag rail item up/down (folder reorder)

**Files:**
- Modify: `yawac/Views/FolderRail.swift` (add `.draggable` + folder-id `.dropDestination` on custom items)

- [ ] **Step 1: Wrap custom FolderRailItem with reorder drag + drop**

In `yawac/Views/FolderRail.swift`, expand the custom-folder `FolderRailItem` block to also be draggable as a `FolderIDTransfer` and accept other `FolderIDTransfer` drops:

```swift
                    ForEach(Array(vm.folders.enumerated()), id: \.element.id) { idx, folder in
                        FolderRailItem(
                            kind: .custom(folder),
                            isSelected: vm.selection == .custom(folderID: folder.id),
                            badge: vm.unreadByFolderID[folder.id] ?? 0,
                            onTap: { vm.selection = .custom(folderID: folder.id) })
                        .draggable(FolderIDTransfer(id: folder.id)) {
                            FolderRailItem(
                                kind: .custom(folder),
                                isSelected: true,
                                badge: 0,
                                onTap: {})
                                .opacity(0.6)
                        }
                        .dropDestination(for: ChatJIDTransfer.self) { transfers, _ in
                            for t in transfers {
                                vm.addChat(jid: t.jid, toFolderID: folder.id)
                            }
                            return !transfers.isEmpty
                        }
                        .dropDestination(for: FolderIDTransfer.self) { transfers, _ in
                            guard let moved = transfers.first,
                                  let from = vm.folders.firstIndex(where: { $0.id == moved.id })
                            else { return false }
                            vm.reorder(fromIndex: from, toIndex: idx)
                            return true
                        }
                    }
```

(SwiftUI allows multiple `.dropDestination` modifiers with different payload types — each fires for its own type.)

- [ ] **Step 2: Build + manual smoke**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

Manual smoke:
1. Create 3 folders (A, B, C) via rail context menu
2. Drag C above A — order should become C, A, B
3. Quit + relaunch; order persists

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/FolderRail.swift
git commit -m "F91: drag folder rail item up/down (reorder)"
```

---

## Task 14: Chat-row context menu "Add to folder…" submenu

**Files:**
- Modify: `yawac/Views/ChatListView.swift` (`chatRowButton` `.contextMenu` block at lines 568-605)

- [ ] **Step 1: Insert the submenu before the existing Divider + Delete**

In `chatRowButton`'s `.contextMenu` block, before `Divider()` (line 603), add:

```swift
            if let rail = folderRail, !rail.folders.isEmpty || rail.folders.isEmpty {
                Menu("Add to folder…") {
                    ForEach(rail.folders, id: \.id) { f in
                        Button {
                            if chat.folderIDs.contains(f.id) {
                                rail.removeChat(jid: chat.jid, fromFolderID: f.id)
                            } else {
                                rail.addChat(jid: chat.jid, toFolderID: f.id)
                            }
                        } label: {
                            if chat.folderIDs.contains(f.id) {
                                Label(f.name, systemImage: "checkmark")
                            } else {
                                Text(f.name)
                            }
                        }
                    }
                    if !rail.folders.isEmpty {
                        Divider()
                    }
                    Button("New folder…") {
                        newFolderInsertIndex = rail.folders.count
                        showNewFolderSheet = true
                    }
                }
            }
```

(The `!rail.folders.isEmpty || rail.folders.isEmpty` always-true guard exists so the `Menu` always appears — even with zero folders the user can still tap "New folder…" from this menu.)

- [ ] **Step 2: Build + manual smoke**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

Manual smoke:
1. Create 2 folders via rail
2. Right-click a chat → "Add to folder…" → tick one folder → close menu
3. Re-open the same chat's "Add to folder…" → the ticked folder shows a checkmark
4. Tap the ticked folder again → checkmark clears

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/ChatListView.swift
git commit -m "F91: chat-row context menu \"Add to folder…\" submenu"
```

---

## Task 15: Rail item context menu (Rename / Delete / New)

**Files:**
- Modify: `yawac/Views/FolderRail.swift` (custom item gains context menu)
- Modify: `yawac/Views/ChatListView.swift` (rename alert + delete confirm alert)

- [ ] **Step 1: Add a `RailEvent` callback to FolderRail**

Replace `FolderRail`'s init/body so the parent receives rename / delete / new-folder requests:

```swift
import SwiftUI

struct FolderRail: View {

    enum Event {
        case rename(PersistedFolder)
        case delete(PersistedFolder)
        case newFolder(insertIndex: Int)
    }

    let vm: FolderRailViewModel
    let onEvent: (Event) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(vm.folders.enumerated()), id: \.element.id) { idx, folder in
                        FolderRailItem(
                            kind: .custom(folder),
                            isSelected: vm.selection == .custom(folderID: folder.id),
                            badge: vm.unreadByFolderID[folder.id] ?? 0,
                            onTap: { vm.selection = .custom(folderID: folder.id) })
                        .draggable(FolderIDTransfer(id: folder.id)) {
                            FolderRailItem(kind: .custom(folder),
                                           isSelected: true,
                                           badge: 0,
                                           onTap: {})
                                .opacity(0.6)
                        }
                        .dropDestination(for: ChatJIDTransfer.self) { transfers, _ in
                            for t in transfers {
                                vm.addChat(jid: t.jid, toFolderID: folder.id)
                            }
                            return !transfers.isEmpty
                        }
                        .dropDestination(for: FolderIDTransfer.self) { transfers, _ in
                            guard let moved = transfers.first,
                                  let from = vm.folders.firstIndex(where: { $0.id == moved.id })
                            else { return false }
                            vm.reorder(fromIndex: from, toIndex: idx)
                            return true
                        }
                        .contextMenu {
                            Button("Rename…") { onEvent(.rename(folder)) }
                            Button("Delete folder…", role: .destructive) {
                                onEvent(.delete(folder))
                            }
                            Divider()
                            Button("New folder…") {
                                onEvent(.newFolder(insertIndex: vm.folders.count))
                            }
                        }
                    }

                    FolderRailItem(
                        kind: .all,
                        isSelected: vm.selection == .all,
                        badge: vm.allUnread,
                        onTap: { vm.selection = .all })

                    FolderRailItem(
                        kind: .archived,
                        isSelected: vm.selection == .archived,
                        badge: vm.archivedUnread,
                        onTap: { vm.selection = .archived })
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 76)
        .background(Theme.surface)
    }
}
```

- [ ] **Step 2: Wire the callback in ChatListView**

In `ChatListView.body`, replace the bare `FolderRail(vm: rail)` mount with:

```swift
                FolderRail(vm: rail) { event in
                    switch event {
                    case .rename(let f):
                        renamingFolder = f
                    case .delete(let f):
                        folderPendingDelete = f
                    case .newFolder(let idx):
                        newFolderInsertIndex = idx
                        showNewFolderSheet = true
                    }
                }
```

Also drop the duplicate `.contextMenu { Button("New folder…") ... }` from the old wrapper — the rail items now own their context menus, and a context menu on the rail container is no longer needed for empty space.

- [ ] **Step 3: Add Rename alert + Delete confirm alert**

In `ChatListView` body modifiers (alongside the existing `.sheet(isPresented: $showNewFolderSheet)`), add:

```swift
        .alert("Rename folder",
               isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } })) {
            TextField("Folder name", text: $renameDraft)
            Button("Save") {
                if let f = renamingFolder {
                    folderRail?.renameFolder(id: f.id, to: renameDraft)
                }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        } message: {
            Text("Enter a new name for the folder.")
        }
        .alert("Delete folder",
               isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { if !$0 { folderPendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let f = folderPendingDelete {
                    folderRail?.deleteFolder(id: f.id)
                }
                folderPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { folderPendingDelete = nil }
        } message: {
            Text("\"\(folderPendingDelete?.name ?? "")\" will be removed from the rail. Chats stay in your chat list.")
        }
        .onChange(of: renamingFolder?.id) { _, _ in
            renameDraft = renamingFolder?.name ?? ""
        }
```

Add the `@State` for `renameDraft` near the other folder state at the top of ChatListView:

```swift
    @State private var renameDraft: String = ""
```

- [ ] **Step 4: Build + manual smoke**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

Manual smoke:
1. Create a folder named "Old"
2. Right-click rail icon → Rename… → change to "New" → Save
3. Right-click rail icon → Delete folder… → Delete → folder disappears

- [ ] **Step 5: Commit**

```bash
git add yawac/Views/FolderRail.swift yawac/Views/ChatListView.swift
git commit -m "F91: rail item context menu (Rename / Delete / New)"
```

---

## Task 16: ⌘0..9 CommandMenu("Folders")

**Files:**
- Modify: `yawac/yawacApp.swift` (`.commands { … }` block at line 132-154)

The CommandMenu must reach the FolderRailViewModel. The cleanest path: expose `folderRail` on the session and route shortcuts via a `@FocusedValue` (matching the existing `FindCommands` pattern at line 164-174), OR drive the shortcut by mutating `@AppStorage("yawac.selectedFolderID")` directly (the rail's `.task` initializer + `.onChange(of:)` will pick it up).

Use the AppStorage path — simpler and no extra plumbing.

- [ ] **Step 1: Add a `CommandMenu("Folders")` to `.commands`**

In `yawacApp.swift` `.commands { … }` block, before the closing `}`, insert:

```swift
            CommandMenu("Folders") {
                FolderCommands()
            }
```

- [ ] **Step 2: Add the FolderCommands view**

Below `FindCommands` (around line 174), add:

```swift
/// F91: ⌘0 = All chats; ⌘1..9 = first 9 custom folders. Writes through
/// the @AppStorage key that the rail's view-model reads on load and
/// observes on .onChange — the rail updates without any direct VM hand-off.
private struct FolderCommands: View {

    @AppStorage("yawac.selectedFolderID") private var selectedFolderIDRaw: String = ""
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button("All chats") {
            selectedFolderIDRaw = FolderSelection.all.storageValue
        }
        .keyboardShortcut("0", modifiers: .command)

        // Re-fetch on every render — cheap (folders are O(10)).
        let folders = (try? modelContext.fetch(
            FetchDescriptor<PersistedFolder>(
                sortBy: [SortDescriptor(\.sortIndex, order: .forward)]))) ?? []
        ForEach(Array(folders.prefix(9).enumerated()), id: \.element.id) { idx, f in
            Button(f.name) {
                selectedFolderIDRaw = FolderSelection.custom(folderID: f.id).storageValue
            }
            .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
        }
    }
}
```

- [ ] **Step 3: Make the rail react to AppStorage selection changes**

In `ChatListView`, add an `.onChange(of: selectedFolderIDRaw)` to update the rail VM when CommandMenu changes the key:

```swift
.onChange(of: selectedFolderIDRaw) { _, newRaw in
    guard let rail = folderRail else { return }
    let knownIDs = Set(rail.folders.map(\.id))
    let resolved = FolderSelection.resolved(storageValue: newRaw, knownIDs: knownIDs)
    if rail.selection != resolved {
        rail.selection = resolved
    }
}
```

Place this alongside the existing `.onChange(of: folderRail?.selection)` from Task 11. The two changes are kept in sync via `if rail.selection != resolved` so the loop doesn't ping-pong.

- [ ] **Step 4: Build + manual smoke**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

Manual smoke:
1. Create 3 folders (A, B, C)
2. ⌘0 → All chats highlighted
3. ⌘1 → A highlighted, list shows only A's members
4. ⌘2 → B; ⌘3 → C
5. Restart app → selection persisted

- [ ] **Step 5: Commit**

```bash
git add yawac/yawacApp.swift yawac/Views/ChatListView.swift
git commit -m "F91: ⌘0..9 CommandMenu(\"Folders\") shortcut wiring"
```

---

## Task 17: Release — v0.10.19

**Files:**
- Modify: `project.yml` (version bump 0.10.18 → 0.10.19, CFBundleVersion 101 → 102)
- Modify: `docs/ROADMAP.md` (flip Folders bullet ☐ → ✅; F91 shipped entry)
- Modify: `yawac/Info.plist` (regenerated by xcodegen)

- [ ] **Step 1: Pre-flight — verify on main + clean**

```bash
git status
git pull --rebase origin main
```

Expected: working tree clean, branch up to date with origin/main.

- [ ] **Step 2: Bump version in project.yml**

In `project.yml`:

```
CFBundleShortVersionString: "0.10.19"
CFBundleVersion: "102"
```

- [ ] **Step 3: Regenerate Xcode project**

```bash
xcodegen
```

Expected: `yawac.xcodeproj` regenerated. `yawac/Info.plist` updated to match the new version strings.

- [ ] **Step 4: Flip ROADMAP bullet + add F91 shipped entry**

In `docs/ROADMAP.md`:

Find the `☐ **Folders / chat lists**` bullet (around line 166) and replace it with:

```markdown
- ✅ **Folders / chat lists** — landed as F91 in v0.10.19.
```

Then, in the `# Shipped (✅)` section near the top, prepend a new entry before the F90 entry:

```markdown
- ✅ **F91 — Folders / chat lists (Telegram-style rail)** (v0.10.19) —
  Vertical folder rail on the left of the chat list. Custom
  user-defined folders (`PersistedFolder` SwiftData model, name-only;
  no per-folder icon picker v1) live above two sticky smart
  sentinels: **All chats** and **Archived**. The latter replaces the
  prior inline expandable archived section — archived chats are now
  hidden from the main list and surface only via the Archived rail
  icon.
  - **Membership.** Three input paths: drag a chat row onto a custom
    rail item (`ChatJIDTransfer` custom UT type
    `dev.vadikas.yawac.chatjid`), right-click the chat → "Add to
    folder…" submenu with per-folder checkmarks (toggles
    membership), and "Add to folder…" inside that submenu's trailing
    "New folder…" item. Storage is a Codable `[String]` `folderIDs`
    field on `PersistedChat`; `addChat` is Set-semantics idempotent.
  - **Rail CRUD.** Right-click a custom folder → Rename / Delete
    folder… / New folder…. Delete cascades a scrub of every chat's
    `folderIDs`. Rename + Create flow through a small
    `NewFolderSheet` (1-field name prompt).
  - **Reorder.** Drag custom folder rail items up/down via a
    second `FolderIDTransfer` UT type (`dev.vadikas.yawac.folderid`).
    `sortIndex` re-assigns by working order on drop. Smart
    sentinels not draggable.
  - **Unread badges.** Red top-right capsule on each rail item =
    sum of `unread` across chats in the folder; "99+" cap. Archived
    chats count ONLY toward the Archived sentinel — they don't bump
    a custom folder badge they were tagged into pre-archive.
  - **⌘0..9 quick switch.** New `CommandMenu("Folders")` wired in
    `yawacApp.swift`. ⌘0 = All chats; ⌘1..9 = first 9 custom
    folders by rail order. Writes through `@AppStorage("yawac
    .selectedFolderID")` which the rail observes; folders beyond
    ⌘9 reachable only via rail click. Archived not bound to any
    shortcut (rare-use).
  - **Behavior change vs prior build.** The 4-segment scope picker
    (`@AppStorage("yawac.chatListScope")` driving All / Direct /
    Groups / Communities) is REMOVED — the rail subsumes it. The
    inline expandable Archived section in the chat list is REMOVED
    — archived chats now live in the Archived rail entry only.
    Replaces ROADMAP entry "Folders / chat lists".
  - **Local-only.** Folders are NOT cross-device synced. Each
    yawac install has its own folder set. Multi-account splitting
    is out of scope (covered by future Multi-account work).
  - **Spec / plan.** Design at `docs/superpowers/specs/2026-06-17
    -folders-chat-lists-design.md`; TDD plan at
    `docs/superpowers/plans/2026-06-17-folders-chat-lists.md`.
    Subagent-driven execution.
```

- [ ] **Step 5: Stage + commit + tag**

```bash
git add project.yml yawac/Info.plist docs/ROADMAP.md
git commit -m "$(cat <<'EOF'
release: 0.10.19 — F91 Folders / chat lists

Telegram-style folder rail on the left of the chat list. Custom
folders + sticky All chats + Archived sentinels. Drag chat row →
folder; ⌘0..9 quick switch; unread badges; rail context menu for
Rename / Delete / New. Replaces the 4-segment scope picker and the
inline expandable archived section.
EOF
)"
git tag -a v0.10.19 -m "yawac 0.10.19 — F91 Folders"
```

- [ ] **Step 6: Push**

```bash
git push origin main
git push origin v0.10.19
```

- [ ] **Step 7: Wait for CI + verify**

```bash
gh run watch
```

Expected: release workflow succeeds; `yawac-0.10.19.zip` + `appcast.xml` published to the GitHub release; cask bump PR opens automatically.

```bash
gh release view v0.10.19
```

Expected: `isDraft: false`, both assets present.

---

## Self-review

**1. Spec coverage**

| Spec section | Task |
|---|---|
| `PersistedFolder` model | Task 1 |
| `folderIDs: [String]` on PersistedChat | Task 1 (model) + Task 2 (Chat struct hydration) |
| `FolderSelection` enum + AppStorage codec | Task 3 |
| `FolderRailViewModel` CRUD | Task 4 |
| `refreshBadges` archived-aware | Task 5 |
| Pure `chatsFor` filter | Task 6 |
| `ChatJIDTransfer` + `FolderIDTransfer` UT types | Task 7 |
| `FolderRailItem` view | Task 8 |
| `FolderRail` view | Task 9 |
| `NewFolderSheet` | Task 10 |
| `ChatListView` HStack wrap + scope removal + chatsFor + drop archived expandable | Task 11 |
| Drag chat → rail (add membership) + context-menu submenu | Tasks 12 + 14 |
| Folder reorder via drag | Task 13 |
| Rail context menu (Rename / Delete / New) | Task 15 |
| ⌘0..9 shortcuts | Task 16 |
| Selection persistence + missing-folder fallback | Tasks 3 + 11 + 16 |
| Unread badges (rendered) | Tasks 8 + 9 (visible via Task 11 mount) |
| Release | Task 17 |

No gaps.

**2. Placeholder scan**

No TBD / TODO / vague reqs. Every step has explicit code + commands + expected output.

**3. Type consistency**

- `FolderSelection` cases match across Tasks 3, 6, 11, 15, 16
- `FolderRailViewModel` method signatures consistent — `createFolder(name:atIndex:) -> PersistedFolder`, `renameFolder(id:to:)`, `deleteFolder(id:)`, `reorder(fromIndex:toIndex:)`, `addChat(jid:toFolderID:)`, `removeChat(jid:fromFolderID:)`, `refreshBadges(chats:)`
- `ChatJIDTransfer.jid` and `FolderIDTransfer.id` field names match between Task 7 (define) and Tasks 12 + 13 (consume)
- `selectedFolderIDRaw` AppStorage key consistent across Tasks 11 (read on init + write on selection change) and 16 (write from CommandMenu)
- `folderIDs: [String]` field name consistent across `Chat` (Task 2) and `PersistedChat` (Task 1)
- `chatsFor(selection:allChats:)` signature consistent across Task 6 (define) and Task 11 (call)
