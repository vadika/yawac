# Message Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship FTS5-powered message search behind two surfaces — in-chat
⌘F find bar with highlight + ↑/↓ navigation, and sectioned global search
in the existing sidebar `⌘K` field.

**Architecture:** One FTS5 virtual table `MessageFTS` in the SwiftData
SQLite store, owned by a new `MessageIndex` service. Write-through from
every `PersistedMessage` construction / mutation site. Background
bootstrap backfills the index on first launch; reconcile on every launch.
Two VMs consume the same backend: `ConversationViewModel`'s find-bar
state for in-chat, `ChatSearchViewModel`'s `messageHits` for global.

**Tech Stack:** Swift 5.10, SwiftUI on macOS 14+, SwiftData, SQLite3
direct via `SQLite3` C API (same pattern as `SQLiteDedupe`), FTS5.

---

## File Map

**New files:**
- `yawac/Services/MessageIndex.swift` — FTS5 owner. Single point of SQL.
- `yawac/ViewModels/MessageSearchViewModel.swift` — debounced async query
  layer.
- `yawac/Views/ConversationFindBar.swift` — slim in-chat find bar.
- `yawac/Views/IndexingChip.swift` — bootstrap progress chip.
- `yawac/Views/Modifiers/FindHighlight.swift` — view modifier reading the
  current hit set + current-index from the VM.
- `yawacTests/MessageIndexTests.swift`
- `yawacTests/MessageSearchViewModelTests.swift`
- `yawacTests/ConversationFindStateTests.swift`

**Modified files:**
- `yawac/Models/PersistedMessage.swift` — no model change; add a
  computed `var indexFields: MessageFields { … }` extension for
  write-through call sites.
- `yawac/ViewModels/ConversationViewModel.swift` — find-bar state group;
  write-through hooks at the 4 `PersistedMessage(...)` construction
  sites (lines 313, 1336, 1362, 1379) + revoke + locally-delete paths.
- `yawac/ViewModels/ChatListViewModel.swift` — write-through hook at
  line 367 site.
- `yawac/ViewModels/ChatSearchViewModel.swift` — add `messageHits`,
  `refreshMessages(query:)`, cancellation.
- `yawac/Views/ConversationView.swift` — slot `ConversationFindBar`
  above the scroll view; bind ⌘F.
- `yawac/Views/MessageRow.swift` — apply `FindHighlight` modifier.
- `yawac/Views/ChatListView.swift` (sidebar search result host) —
  sectioned layout with Chats / Messages; render `IndexingChip`; tap
  hit → `selectChat` + `jumpToQuoted(id:)`.
- `yawac/Design/Theme.swift` — `Theme.findHighlight` color.
- `yawac/yawacApp.swift` — kick `MessageIndex.shared.bootstrapIfNeeded()`
  in a detached low-priority task after `ModelContainer` is up.

Order chosen: backend foundation first (Tasks 1–3), so it's testable in
isolation. Then in-chat ⌘F (Tasks 4–6), each shippable on its own. Then
global sidebar (Tasks 7–9). Polish + manual gate (Tasks 10–11).

---

## Task 1: `MessageIndex` core — schema + upsert/delete/search

Build the FTS table owner against an in-memory SQLite, fully TDD. No app
integration yet.

**Files:**
- Create: `yawac/Services/MessageIndex.swift`
- Test: `yawacTests/MessageIndexTests.swift`

- [ ] **Step 1: Write the failing test file**

```swift
import XCTest
import SQLite3
@testable import yawac

final class MessageIndexTests: XCTestCase {

    private var tmpDB: URL!

    override func setUp() {
        super.setUp()
        tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-fts-\(UUID().uuidString).sqlite")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDB)
        super.tearDown()
    }

    private func makeIndex() -> MessageIndex {
        let idx = MessageIndex(storeURL: tmpDB)
        idx.ensureSchema()
        return idx
    }

    private func field(_ id: String, _ text: String,
                       chat: String = "c@s.whatsapp.net",
                       ts: Int64 = 0, caption: String = "",
                       quoted: String = "", sender: String = "")
        -> MessageIndex.MessageFields
    {
        MessageIndex.MessageFields(
            messageID: id, chatJID: chat, timestamp: ts,
            text: text, caption: caption, quoted: quoted, sender: sender)
    }

    func testSchemaIsIdempotent() {
        let idx = makeIndex()
        idx.ensureSchema()
        idx.ensureSchema()
        XCTAssertEqual(idx.countAll(), 0)
    }

    func testUpsertInsertsRow() {
        let idx = makeIndex()
        idx.upsert(field("m1", "Hello Finland"))
        XCTAssertEqual(idx.countAll(), 1)
    }

    func testUpsertReplacesByID() {
        let idx = makeIndex()
        idx.upsert(field("m1", "first"))
        idx.upsert(field("m1", "second"))
        XCTAssertEqual(idx.countAll(), 1)
        let g = idx.searchGlobal(query: "first", limit: 10)
        XCTAssertEqual(g.count, 0)
        let g2 = idx.searchGlobal(query: "second", limit: 10)
        XCTAssertEqual(g2.count, 1)
    }

    func testDeleteByID() {
        let idx = makeIndex()
        idx.upsert(field("m1", "Finland"))
        idx.delete(messageID: "m1")
        XCTAssertEqual(idx.countAll(), 0)
    }

    func testPrefixMatch() {
        let idx = makeIndex()
        idx.upsert(field("m1", "Finland"))
        XCTAssertEqual(idx.searchGlobal(query: "fin", limit: 10).count, 1)
        XCTAssertEqual(idx.searchGlobal(query: "nland", limit: 10).count, 0)
    }

    func testSearchInChatFilters() {
        let idx = makeIndex()
        idx.upsert(field("m1", "shared term", chat: "A@s.whatsapp.net"))
        idx.upsert(field("m2", "shared term", chat: "B@s.whatsapp.net"))
        let hits = idx.searchInChat(jid: "A@s.whatsapp.net",
                                    query: "shared", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.chatJID, "A@s.whatsapp.net")
    }

    func testInChatOrderedByTimestampAscending() {
        let idx = makeIndex()
        idx.upsert(field("a", "x", ts: 30))
        idx.upsert(field("b", "x", ts: 10))
        idx.upsert(field("c", "x", ts: 20))
        let hits = idx.searchInChat(jid: "c@s.whatsapp.net",
                                    query: "x", limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["b", "c", "a"])
    }

    func testEmptyQueryReturnsEmpty() {
        let idx = makeIndex()
        idx.upsert(field("m1", "Finland"))
        XCTAssertTrue(idx.searchGlobal(query: "", limit: 10).isEmpty)
        XCTAssertTrue(idx.searchGlobal(query: "   ", limit: 10).isEmpty)
    }

    func testSpecialCharsAreStripped() {
        let idx = makeIndex()
        idx.upsert(field("m1", "foo bar"))
        // Must not throw / crash on FTS5 syntax chars.
        XCTAssertNoThrow(idx.searchGlobal(query: "foo(bar)\"*:", limit: 10))
    }

    func testSnippetMarksHits() {
        let idx = makeIndex()
        idx.upsert(field("m1", "the quick brown fox jumps over"))
        let hits = idx.searchGlobal(query: "brown", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].snippet.contains("⟦brown⟧"),
                      "expected ⟦…⟧ markers, got \(hits[0].snippet)")
    }

    func testMultiFieldIndexed() {
        let idx = makeIndex()
        idx.upsert(MessageIndex.MessageFields(
            messageID: "m1", chatJID: "c@s.whatsapp.net", timestamp: 0,
            text: "", caption: "vacation pic",
            quoted: "earlier reply", sender: "Alice"))
        XCTAssertEqual(idx.searchGlobal(query: "vacation", limit: 10).count, 1)
        XCTAssertEqual(idx.searchGlobal(query: "earlier", limit: 10).count, 1)
        XCTAssertEqual(idx.searchGlobal(query: "alice", limit: 10).count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MessageIndexTests 2>&1 | tail -10
```

Expected: build failure ("Cannot find 'MessageIndex' in scope").

- [ ] **Step 3: Write `MessageIndex.swift`**

Create `yawac/Services/MessageIndex.swift`:

```swift
import Foundation
import Observation
import SQLite3

/// Owns the FTS5 virtual table used by both in-chat and global message
/// search. Single point of SQL — every UI / VM consumer goes through this
/// service. Thread-affine to a serial dispatch queue; UI callers use the
/// async `searchInChat` / `searchGlobal` wrappers.
@Observable
final class MessageIndex {

    // MARK: - Public types

    struct MessageFields: Equatable {
        let messageID: String
        let chatJID: String
        let timestamp: Int64
        let text: String
        let caption: String
        let quoted: String
        let sender: String
    }

    struct Hit: Equatable {
        let messageID: String
        let chatJID: String
        let timestamp: Int64
        let sender: String
        let snippet: String
    }

    enum BootstrapProgress: Equatable {
        case idle
        case running(indexed: Int, total: Int)
        case done
    }

    // MARK: - Singleton + init

    /// Default singleton wired to the SwiftData store.
    static let shared = MessageIndex(storeURL: defaultStoreURL())

    private let storeURL: URL
    private let queue = DispatchQueue(label: "yawac.MessageIndex")
    private var db: OpaquePointer?
    var progress: BootstrapProgress = .idle

    init(storeURL: URL) {
        self.storeURL = storeURL
    }

    private static func defaultStoreURL() -> URL {
        let supportDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return supportDir.appendingPathComponent("default.store")
    }

    // MARK: - Schema

    /// Opens the connection (creating the file if needed) and creates
    /// MessageFTS if it doesn't exist. Idempotent.
    func ensureSchema() {
        queue.sync { ensureSchemaLocked() }
    }

    private func ensureSchemaLocked() {
        if db == nil {
            var handle: OpaquePointer?
            guard sqlite3_open(storeURL.path, &handle) == SQLITE_OK else {
                NSLog("[yawac/index] sqlite3_open failed")
                return
            }
            db = handle
            sqlite3_busy_timeout(db, 2000)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        }
        let create = """
            CREATE VIRTUAL TABLE IF NOT EXISTS MessageFTS USING fts5(
                msgid UNINDEXED, chatjid UNINDEXED, ts UNINDEXED,
                text, caption, quoted, sender,
                tokenize = 'unicode61'
            );
        """
        sqlite3_exec(db, create, nil, nil, nil)
    }

    // MARK: - Write paths

    func upsert(_ f: MessageFields) {
        queue.sync { upsertLocked(f) }
    }

    private func upsertLocked(_ f: MessageFields) {
        ensureSchemaLocked()
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT;", nil, nil, nil) }
        execStep(sql: "DELETE FROM MessageFTS WHERE msgid = ?;",
                 binds: [.text(f.messageID)])
        execStep(sql: """
            INSERT INTO MessageFTS(msgid, chatjid, ts, text, caption, quoted, sender)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            binds: [
                .text(f.messageID), .text(f.chatJID), .int(f.timestamp),
                .text(f.text), .text(f.caption),
                .text(f.quoted), .text(f.sender),
            ])
    }

    func delete(messageID: String) {
        queue.sync {
            ensureSchemaLocked()
            execStep(sql: "DELETE FROM MessageFTS WHERE msgid = ?;",
                     binds: [.text(messageID)])
        }
    }

    func countAll() -> Int {
        queue.sync {
            ensureSchemaLocked()
            return scalarInt(sql: "SELECT COUNT(*) FROM MessageFTS;")
        }
    }

    // MARK: - Read paths

    func searchInChat(jid: String, query: String, limit: Int = 500) -> [Hit] {
        guard let match = makeMatch(query) else { return [] }
        return queue.sync {
            ensureSchemaLocked()
            return runQuery(sql: """
                SELECT msgid, chatjid, ts, sender,
                       snippet(MessageFTS, -1, '⟦', '⟧', '…', 12)
                FROM MessageFTS
                WHERE chatjid = ? AND MessageFTS MATCH ?
                ORDER BY ts ASC
                LIMIT ?;
                """,
                binds: [.text(jid), .text(match), .int(Int64(limit))])
        }
    }

    func searchGlobal(query: String, limit: Int = 200) -> [Hit] {
        guard let match = makeMatch(query) else { return [] }
        return queue.sync {
            ensureSchemaLocked()
            return runQuery(sql: """
                SELECT msgid, chatjid, ts, sender,
                       snippet(MessageFTS, -1, '⟦', '⟧', '…', 12)
                FROM MessageFTS
                WHERE MessageFTS MATCH ?
                ORDER BY bm25(MessageFTS) ASC, ts DESC
                LIMIT ?;
                """,
                binds: [.text(match), .int(Int64(limit))])
        }
    }

    // MARK: - Query construction

    /// Strip FTS5 special chars and append `*` for prefix-match per token.
    /// Returns nil when the cleaned query has no tokens.
    private func makeMatch(_ raw: String) -> String? {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        let invalid = CharacterSet(charactersIn: "\"*:()")
        let tokens = stripped
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0.unicodeScalars.filter { !invalid.contains($0) }) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - SQLite plumbing (private)

    private enum Bind {
        case text(String)
        case int(Int64)
    }

    @discardableResult
    private func execStep(sql: String, binds: [Bind]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, binds)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func scalarInt(sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func runQuery(sql: String, binds: [Bind]) -> [Hit] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, binds)
        var out: [Hit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Hit(
                messageID: stringCol(stmt, 0),
                chatJID:   stringCol(stmt, 1),
                timestamp: sqlite3_column_int64(stmt, 2),
                sender:    stringCol(stmt, 3),
                snippet:   stringCol(stmt, 4)))
        }
        return out
    }

    private func bindAll(_ stmt: OpaquePointer?, _ binds: [Bind]) {
        // SQLITE_TRANSIENT tells SQLite to copy the string. -1 lets us
        // not pre-compute byte length.
        let SQLITE_TRANSIENT = unsafeBitCast(
            OpaquePointer(bitPattern: -1)!, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let v):
                sqlite3_bind_int64(stmt, idx, v)
            }
        }
    }

    private func stringCol(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
}
```

- [ ] **Step 4: Run tests, confirm all pass**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MessageIndexTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, all 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add yawac/Services/MessageIndex.swift yawacTests/MessageIndexTests.swift
git commit -m "search: add MessageIndex FTS5 service (schema + upsert/delete/search)"
```

---

## Task 2: Bootstrap reconcile from `ZPERSISTEDMESSAGE`

Backfills MessageFTS from the SwiftData store on first launch.

**Files:**
- Modify: `yawac/Services/MessageIndex.swift`
- Modify: `yawacTests/MessageIndexTests.swift` (append two tests)

- [ ] **Step 1: Add failing bootstrap tests**

Append to `yawacTests/MessageIndexTests.swift`:

```swift
    private func seedZPersistedMessage(_ url: URL,
                                       _ rows: [(String, String, Int64, String, String, String, String)]) {
        // rows: (ZID, ZCHATJID, ZTIMESTAMP, ZTEXT, ZMEDIACAPTION,
        //        ZQUOTEDTEXTSNIPPET, ZSENDERPUSHNAME)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE ZPERSISTEDMESSAGE (
                Z_PK INTEGER PRIMARY KEY,
                ZID TEXT,
                ZCHATJID TEXT,
                ZTIMESTAMP REAL,
                ZTEXT TEXT,
                ZMEDIACAPTION TEXT,
                ZQUOTEDTEXTSNIPPET TEXT,
                ZSENDERPUSHNAME TEXT
            );
        """, nil, nil, nil)
        for (id, jid, ts, txt, cap, quo, sender) in rows {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, """
                INSERT INTO ZPERSISTEDMESSAGE
                (ZID, ZCHATJID, ZTIMESTAMP, ZTEXT, ZMEDIACAPTION,
                 ZQUOTEDTEXTSNIPPET, ZSENDERPUSHNAME)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """, -1, &stmt, nil)
            let TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1)!,
                                          to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, id, -1, TRANSIENT)
            sqlite3_bind_text(stmt, 2, jid, -1, TRANSIENT)
            sqlite3_bind_double(stmt, 3, Double(ts))
            sqlite3_bind_text(stmt, 4, txt, -1, TRANSIENT)
            sqlite3_bind_text(stmt, 5, cap, -1, TRANSIENT)
            sqlite3_bind_text(stmt, 6, quo, -1, TRANSIENT)
            sqlite3_bind_text(stmt, 7, sender, -1, TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func testBootstrapBackfillsFromZPersistedMessage() async {
        seedZPersistedMessage(tmpDB, [
            ("m1", "A@s.whatsapp.net", 100, "Hello Finland", "", "", "Alice"),
            ("m2", "A@s.whatsapp.net", 110, "", "Lake photo",  "", "Alice"),
            ("m3", "B@s.whatsapp.net", 120, "Goodbye", "", "earlier reply", "Bob"),
        ])
        let idx = MessageIndex(storeURL: tmpDB)
        await idx.bootstrapIfNeeded()
        XCTAssertEqual(idx.countAll(), 3)
        XCTAssertEqual(idx.searchGlobal(query: "finland", limit: 10).count, 1)
        XCTAssertEqual(idx.searchGlobal(query: "lake", limit: 10).count, 1)
        XCTAssertEqual(idx.searchGlobal(query: "earlier", limit: 10).count, 1)
        if case .done = idx.progress {} else { XCTFail("expected .done, got \(idx.progress)") }
    }

    func testBootstrapIsNoOpWhenAlreadyIndexed() async {
        seedZPersistedMessage(tmpDB, [
            ("m1", "A@s.whatsapp.net", 100, "Hello", "", "", "Alice"),
        ])
        let idx = MessageIndex(storeURL: tmpDB)
        await idx.bootstrapIfNeeded()
        XCTAssertEqual(idx.countAll(), 1)
        await idx.bootstrapIfNeeded()
        XCTAssertEqual(idx.countAll(), 1, "second run must not duplicate")
    }
```

- [ ] **Step 2: Run tests, confirm two new ones fail**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MessageIndexTests 2>&1 | tail -10
```

Expected: build failure ("Value of type 'MessageIndex' has no member
'bootstrapIfNeeded'").

- [ ] **Step 3: Add bootstrap implementation to `MessageIndex.swift`**

Append inside the `MessageIndex` class, after `searchGlobal`:

```swift
    // MARK: - Bootstrap

    /// Backfills MessageFTS from ZPERSISTEDMESSAGE. Safe to call on every
    /// launch — exits early if the FTS row count is already at or above
    /// the persisted-message count.
    func bootstrapIfNeeded() async {
        await Task.detached(priority: .utility) { [self] in
            self.runBootstrap()
        }.value
    }

    private func runBootstrap() {
        queue.sync { ensureSchemaLocked() }

        let total = scalarFromStore(
            sql: "SELECT COUNT(*) FROM ZPERSISTEDMESSAGE;")
        let already = countAll()
        if already >= total || total == 0 {
            queue.sync { self.progress = .done }
            return
        }

        queue.sync {
            self.progress = .running(indexed: already, total: total)
        }

        // Stream rows in 1000-row pages, ascending by Z_PK so resumption
        // after a crash continues forward.
        let pageSize = 1000
        var offset = already
        var indexed = already
        while offset < total {
            let page = readPage(offset: offset, limit: pageSize)
            if page.isEmpty { break }
            queue.sync {
                ensureSchemaLocked()
                sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
                for f in page { upsertLocked(f) }
                sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            }
            indexed += page.count
            offset  += page.count
            queue.sync {
                self.progress = .running(indexed: indexed, total: total)
            }
        }

        queue.sync { self.progress = .done }
    }

    /// Reads a paged slice of ZPERSISTEDMESSAGE via a fresh read-only
    /// connection (avoids stepping on the main connection's transaction).
    private func readPage(offset: Int, limit: Int) -> [MessageFields] {
        var read: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &read,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let read else { return [] }
        defer { sqlite3_close(read) }
        sqlite3_busy_timeout(read, 1000)

        var stmt: OpaquePointer?
        let sql = """
            SELECT ZID, ZCHATJID, ZTIMESTAMP, ZTEXT, ZMEDIACAPTION,
                   ZQUOTEDTEXTSNIPPET, ZSENDERPUSHNAME
            FROM ZPERSISTEDMESSAGE
            ORDER BY Z_PK ASC
            LIMIT ? OFFSET ?;
        """
        guard sqlite3_prepare_v2(read, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        sqlite3_bind_int64(stmt, 2, Int64(offset))

        var out: [MessageFields] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = stringFromStmt(stmt, 0)
            // ZID is unique-non-null in our model; skip if missing.
            guard !id.isEmpty else { continue }
            let ts = Int64(sqlite3_column_double(stmt, 2))
            out.append(MessageFields(
                messageID: id,
                chatJID:   stringFromStmt(stmt, 1),
                timestamp: ts,
                text:      stringFromStmt(stmt, 3),
                caption:   stringFromStmt(stmt, 4),
                quoted:    stringFromStmt(stmt, 5),
                sender:    stringFromStmt(stmt, 6)))
        }
        return out
    }

    private func scalarFromStore(sql: String) -> Int {
        var read: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &read,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let read else { return 0 }
        defer { sqlite3_close(read) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(read, sql, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func stringFromStmt(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
```

- [ ] **Step 4: Run tests, confirm all pass**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MessageIndexTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add yawac/Services/MessageIndex.swift yawacTests/MessageIndexTests.swift
git commit -m "search: backfill MessageFTS from ZPERSISTEDMESSAGE in bootstrap"
```

---

## Task 3: Write-through hooks at PersistedMessage construction sites

Wire `MessageIndex.shared.upsert` after every `modelContext.insert(PersistedMessage(...))` /
revoke / locally-delete path. Also kick `bootstrapIfNeeded()` at app
startup.

**Files:**
- Modify: `yawac/Models/PersistedMessage.swift` — add `indexFields`
  extension.
- Modify: `yawac/ViewModels/ChatListViewModel.swift:367` (one insert site).
- Modify: `yawac/ViewModels/ConversationViewModel.swift` (4 insert sites:
  313, 1336, 1362, 1379; plus revoke + locally-delete handlers — locate
  by grep, see Step 1).
- Modify: `yawac/yawacApp.swift` — kick bootstrap.

- [ ] **Step 1: Locate every mutation site**

```bash
grep -n 'PersistedMessage(' yawac/ViewModels/ConversationViewModel.swift \
  yawac/ViewModels/ChatListViewModel.swift
grep -n 'locallyDeleted = true\|revokedAt = .now\|revokedAt =' \
  yawac/ViewModels/ConversationViewModel.swift
```

Expected: 5 construction sites (1 in ChatListViewModel, 4 in
ConversationViewModel), plus the revoke / locally-delete mutation paths
in `ConversationViewModel` (around lines 1412 / 1421 — the
`deleteForEveryone` and `deleteForMe` functions reach
`persistRevoke` / `persistLocallyDeleted`).

- [ ] **Step 2: Add `indexFields` extension to PersistedMessage**

Append to `yawac/Models/PersistedMessage.swift` (after the
`PersistedMessage` class):

```swift
extension PersistedMessage {
    /// View of the row in the shape `MessageIndex` expects. Empty strings
    /// where the SwiftData column is nil — FTS5 tolerates them.
    var indexFields: MessageIndex.MessageFields {
        MessageIndex.MessageFields(
            messageID: id,
            chatJID:   chatJID,
            timestamp: Int64(timestamp.timeIntervalSinceReferenceDate),
            text:      text ?? "",
            caption:   mediaCaption ?? "",
            quoted:    quotedTextSnippet ?? "",
            sender:    senderPushName ?? "")
    }
}
```

- [ ] **Step 3: Wire write-through at every insert site**

Add this line **immediately after** each `context.insert(row)` (or
`modelContext.insert(row)`) for a `PersistedMessage` in the 5 sites:

```swift
MessageIndex.shared.upsert(row.indexFields)
```

In `ConversationViewModel.swift`, also add to the revoke + locally-delete
paths — find the function body that sets `revokedAt = .now` or
`locallyDeleted = true` on a persisted row, and add **after** the
`context.save()` (or equivalent) call:

```swift
MessageIndex.shared.upsert(row.indexFields)
```

(Why upsert and not delete: per spec, revoked / locally-deleted messages
remain searchable. Re-upserting keeps their content current in case the
text was cleared at revoke time.)

- [ ] **Step 4: Kick bootstrap at app startup**

In `yawac/yawacApp.swift`, replace the `init()` body's tail with:

```swift
    init() {
        do {
            self.container = try ModelContainer(
                for: PersistedMessage.self,
                PersistedChat.self,
                PersistedReaction.self,
                PersistedPollVote.self)
        } catch {
            fatalError("ModelContainer: \(error)")
        }
        Task { await NotificationService.requestAuthorization() }
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared

        // Kick the FTS5 index backfill / reconcile in the background.
        Task.detached(priority: .utility) {
            await MessageIndex.shared.bootstrapIfNeeded()
        }
    }
```

- [ ] **Step 5: Build verify**

```bash
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add yawac/Models/PersistedMessage.swift \
        yawac/ViewModels/ConversationViewModel.swift \
        yawac/ViewModels/ChatListViewModel.swift \
        yawac/yawacApp.swift
git commit -m "search: write-through MessageIndex on every PersistedMessage mutation"
```

---

## Task 4: `MessageSearchViewModel` — debounced async query layer

**Files:**
- Create: `yawac/ViewModels/MessageSearchViewModel.swift`
- Test: `yawacTests/MessageSearchViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `yawacTests/MessageSearchViewModelTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class MessageSearchViewModelTests: XCTestCase {

    private var tmpDB: URL!
    private var idx: MessageIndex!

    override func setUp() async throws {
        try await super.setUp()
        tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-search-\(UUID().uuidString).sqlite")
        idx = MessageIndex(storeURL: tmpDB)
        idx.ensureSchema()
        idx.upsert(.init(messageID: "m1", chatJID: "A@s.whatsapp.net",
                         timestamp: 10, text: "Hello Finland", caption: "",
                         quoted: "", sender: "Alice"))
        idx.upsert(.init(messageID: "m2", chatJID: "B@s.whatsapp.net",
                         timestamp: 20, text: "Hello world", caption: "",
                         quoted: "", sender: "Bob"))
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDB)
        try await super.tearDown()
    }

    func testDebouncedGlobalReturnsResults() async throws {
        let vm = MessageSearchViewModel(index: idx, debounceMs: 30)
        vm.query = "hello"
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(vm.globalHits.count, 2)
    }

    func testInChatFiltersByJID() async throws {
        let vm = MessageSearchViewModel(index: idx, debounceMs: 30)
        await vm.runInChat(jid: "A@s.whatsapp.net", query: "hello")
        XCTAssertEqual(vm.inChatHits.count, 1)
        XCTAssertEqual(vm.inChatHits.first?.chatJID, "A@s.whatsapp.net")
    }

    func testNewQueryCancelsPrior() async throws {
        let vm = MessageSearchViewModel(index: idx, debounceMs: 30)
        vm.query = "hello"     // would yield 2 hits if it lands
        vm.query = "finland"   // new query before debounce fires
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(vm.globalHits.map(\.messageID), ["m1"],
                       "prior debounced query must be cancelled")
    }

    func testEmptyQueryClearsResults() async throws {
        let vm = MessageSearchViewModel(index: idx, debounceMs: 30)
        vm.query = "hello"
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(vm.globalHits.isEmpty)
        vm.query = ""
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(vm.globalHits.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MessageSearchViewModelTests 2>&1 | tail -10
```

Expected: build failure ("Cannot find 'MessageSearchViewModel' in scope").

- [ ] **Step 3: Create `MessageSearchViewModel.swift`**

```swift
import Foundation
import Observation

/// Debounced async wrapper over `MessageIndex`. Holds the current query
/// and result arrays for both surfaces. The global path is debounced on
/// `query` assignment; the in-chat path is one-shot per call (the find
/// bar's own state owns debouncing — see ConversationViewModel).
@Observable @MainActor
final class MessageSearchViewModel {

    var query: String = "" {
        didSet { onQueryChanged() }
    }
    private(set) var globalHits: [MessageIndex.Hit] = []
    private(set) var inChatHits: [MessageIndex.Hit] = []

    private let index: MessageIndex
    private let debounceMs: Int
    private var debounceTask: Task<Void, Never>?

    init(index: MessageIndex = .shared, debounceMs: Int = 120) {
        self.index = index
        self.debounceMs = debounceMs
    }

    func clear() {
        debounceTask?.cancel()
        query = ""
        globalHits = []
        inChatHits = []
    }

    func runInChat(jid: String, query: String) async {
        let hits = await Task.detached(priority: .userInitiated) { [index] in
            index.searchInChat(jid: jid, query: query)
        }.value
        inChatHits = hits
    }

    private func onQueryChanged() {
        debounceTask?.cancel()
        let q = query
        if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            globalHits = []
            return
        }
        debounceTask = Task { [weak self, debounceMs, index] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self, !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                index.searchGlobal(query: q)
            }.value
            guard !Task.isCancelled else { return }
            self.globalHits = hits
        }
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MessageSearchViewModelTests 2>&1 | tail -15
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/MessageSearchViewModel.swift \
        yawacTests/MessageSearchViewModelTests.swift
git commit -m "search: add MessageSearchViewModel debounced async layer"
```

---

## Task 5: Find-bar state on `ConversationViewModel`

Add `findActive` / `findQuery` / `findHits` / `findCurrentIdx` to the
conversation VM, plus a debounced `runFind()` that calls
`MessageIndex.searchInChat`.

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`
- Test: `yawacTests/ConversationFindStateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `yawacTests/ConversationFindStateTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class ConversationFindStateTests: XCTestCase {

    private var tmpDB: URL!
    private var idx: MessageIndex!

    override func setUp() async throws {
        try await super.setUp()
        tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-find-\(UUID().uuidString).sqlite")
        idx = MessageIndex(storeURL: tmpDB)
        idx.ensureSchema()
        let jid = "A@s.whatsapp.net"
        idx.upsert(.init(messageID: "a", chatJID: jid, timestamp: 10,
                         text: "alpha", caption: "", quoted: "", sender: ""))
        idx.upsert(.init(messageID: "b", chatJID: jid, timestamp: 20,
                         text: "alpha beta", caption: "", quoted: "", sender: ""))
        idx.upsert(.init(messageID: "c", chatJID: jid, timestamp: 30,
                         text: "alpha gamma", caption: "", quoted: "", sender: ""))
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDB)
        try await super.tearDown()
    }

    private func make() -> ConversationViewModel {
        let vm = ConversationViewModel(chatJID: "A@s.whatsapp.net",
                                       messageIndex: idx)
        return vm
    }

    func testToggleFindActiveClearsState() {
        let vm = make()
        vm.findActive = true
        vm.findQuery = "alpha"
        vm.findActive = false
        XCTAssertEqual(vm.findQuery, "")
        XCTAssertTrue(vm.findHits.isEmpty)
        XCTAssertEqual(vm.findCurrentIdx, 0)
    }

    func testRunFindPopulatesHits() async {
        let vm = make()
        vm.findQuery = "alpha"
        await vm.runFindForTest()   // synchronous test seam (see Step 3)
        XCTAssertEqual(vm.findHits.map(\.messageID), ["a", "b", "c"])
    }

    func testNextAndPrevWrap() async {
        let vm = make()
        vm.findQuery = "alpha"
        await vm.runFindForTest()
        XCTAssertEqual(vm.findCurrentIdx, 0)
        vm.findNext()
        XCTAssertEqual(vm.findCurrentIdx, 1)
        vm.findNext(); vm.findNext()           // wrap
        XCTAssertEqual(vm.findCurrentIdx, 0)
        vm.findPrev()                          // wrap back
        XCTAssertEqual(vm.findCurrentIdx, 2)
    }

    func testFindHitIDsReflectsHits() async {
        let vm = make()
        vm.findQuery = "alpha"
        await vm.runFindForTest()
        XCTAssertEqual(vm.findHitIDs, ["a", "b", "c"])
    }
}
```

- [ ] **Step 2: Verify it fails (build error)**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/ConversationFindStateTests 2>&1 | tail -10
```

Expected: build failure on the `messageIndex:` init param + missing
`findActive` / `runFindForTest` / `findNext`.

- [ ] **Step 3: Add find-bar state + helpers to `ConversationViewModel.swift`**

Add a new convenience initializer parameter — find the existing
`init(chatJID:` (in `ConversationViewModel.swift`); add a second
`init(chatJID: String, messageIndex: MessageIndex)` overload that stores
the index and otherwise mirrors the existing init's defaults. Then add
these stored properties near the other `@Published` / state declarations
(below `var unreadInboundIDs: Set<String>`):

```swift
    // MARK: - In-chat find bar
    private let messageIndex: MessageIndex
    var findActive: Bool = false {
        didSet {
            if !findActive {
                findQuery = ""
                findHits = []
                findCurrentIdx = 0
            }
        }
    }
    var findQuery: String = "" {
        didSet { scheduleFind() }
    }
    var findHits: [MessageIndex.Hit] = []
    var findCurrentIdx: Int = 0
    var findHitIDs: Set<String> { Set(findHits.map(\.messageID)) }

    private var findTask: Task<Void, Never>?
    private let findDebounceMs: Int = 120

    private func scheduleFind() {
        findTask?.cancel()
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            findHits = []
            findCurrentIdx = 0
            return
        }
        let jid = chatJID
        let idx = messageIndex
        findTask = Task { [weak self, findDebounceMs] in
            try? await Task.sleep(for: .milliseconds(findDebounceMs))
            guard let self, !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                idx.searchInChat(jid: jid, query: q)
            }.value
            guard !Task.isCancelled else { return }
            self.findHits = hits
            self.findCurrentIdx = 0
            if let first = hits.first { self.pendingScrollToID = first.messageID }
        }
    }

    /// Synchronous test seam — bypasses the debounce.
    func runFindForTest() async {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { findHits = []; findCurrentIdx = 0; return }
        let idx = messageIndex; let jid = chatJID
        let hits = await Task.detached(priority: .userInitiated) {
            idx.searchInChat(jid: jid, query: q)
        }.value
        findHits = hits
        findCurrentIdx = 0
    }

    func findNext() {
        guard !findHits.isEmpty else { return }
        findCurrentIdx = (findCurrentIdx + 1) % findHits.count
        pendingScrollToID = findHits[findCurrentIdx].messageID
    }

    func findPrev() {
        guard !findHits.isEmpty else { return }
        findCurrentIdx = (findCurrentIdx - 1 + findHits.count) % findHits.count
        pendingScrollToID = findHits[findCurrentIdx].messageID
    }
```

Then update the existing `init(chatJID:` to default `messageIndex` to
`MessageIndex.shared`. Concretely, if the current init signature is
`init(chatJID: String)` (find it in the file — look for the existing
initializer that callers pass `chatJID` to), change it to:

```swift
    init(chatJID: String,
         messageIndex: MessageIndex = .shared) {
        self.chatJID = chatJID
        self.messageIndex = messageIndex
        // … keep the rest of the existing init body verbatim …
    }
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/ConversationFindStateTests 2>&1 | tail -15
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift \
        yawacTests/ConversationFindStateTests.swift
git commit -m "convo: find-bar state on ConversationViewModel + debounced searchInChat"
```

---

## Task 6: `ConversationFindBar` view + ⌘F integration

Slot a slim find bar above the message scroll view; bind ⌘F to toggle it.

**Files:**
- Create: `yawac/Views/ConversationFindBar.swift`
- Create: `yawac/Views/Modifiers/FindHighlight.swift`
- Modify: `yawac/Views/ConversationView.swift`
- Modify: `yawac/Views/MessageRow.swift`
- Modify: `yawac/Design/Theme.swift`

This task is view-layer only — no unit tests. Verification = build +
manual visual.

- [ ] **Step 1: Add `Theme.findHighlight`**

In `yawac/Design/Theme.swift`, locate the existing color declarations
(e.g. `static let bg`, `static let accent`) and add:

```swift
    /// Background tint for messages matching the active in-chat find query.
    static let findHighlight = Color(red: 0.95, green: 0.84, blue: 0.27)
        .opacity(0.28)
    /// Stronger tint for the current find-bar selection (↑/↓ cursor).
    static let findHighlightCurrent = Color(red: 0.95, green: 0.84, blue: 0.27)
        .opacity(0.55)
```

- [ ] **Step 2: Create `Views/Modifiers/FindHighlight.swift`**

```swift
import SwiftUI

/// Tints a message row when its `messageID` is in the conversation VM's
/// active find-hit set. The current `findCurrentIdx` row gets a stronger
/// tint so the user can see where ↑/↓ is anchored.
struct FindHighlight: ViewModifier {
    let messageID: String
    @Environment(ConversationViewModel.self) private var vm

    func body(content: Content) -> some View {
        let isHit = vm.findHitIDs.contains(messageID)
        let isCurrent = isHit
            && vm.findHits.indices.contains(vm.findCurrentIdx)
            && vm.findHits[vm.findCurrentIdx].messageID == messageID
        content.background(
            isCurrent ? Theme.findHighlightCurrent
            : isHit   ? Theme.findHighlight
            : Color.clear
        )
    }
}

extension View {
    /// Apply find-bar highlight to a message row keyed by id.
    func findHighlight(messageID: String) -> some View {
        modifier(FindHighlight(messageID: messageID))
    }
}
```

- [ ] **Step 3: Apply `findHighlight` to `MessageRow`**

In `yawac/Views/MessageRow.swift`, locate the outermost row container
(the `VStack` / `HStack` that holds the bubble) and append the
modifier near its end:

```swift
        .findHighlight(messageID: message.id)
```

(Place it before `.contentShape(...)` if that exists, so the highlight
sits behind the tap area.)

- [ ] **Step 4: Create `Views/ConversationFindBar.swift`**

```swift
import SwiftUI

/// Slim find bar that slides down from above the conversation scroll
/// view when `vm.findActive` is true. Highlights matches, ↑/↓ navigate.
struct ConversationFindBar: View {

    @Environment(ConversationViewModel.self) private var vm
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                vm.findActive = false
            } label: {
                Image(systemName: "xmark")
                    .scaledIcon(12, weight: .semibold)
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            TextField("Find in conversation",
                      text: Binding(get: { vm.findQuery },
                                    set: { vm.findQuery = $0 }))
                .textFieldStyle(.plain)
                .scaledUI(13)
                .focused($fieldFocused)
                .onSubmit { vm.findNext() }

            counter

            Button { vm.findPrev() } label: {
                Image(systemName: "chevron.up")
                    .scaledIcon(11, weight: .semibold)
            }
            .buttonStyle(.plain)
            .disabled(vm.findHits.isEmpty)
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button { vm.findNext() } label: {
                Image(systemName: "chevron.down")
                    .scaledIcon(11, weight: .semibold)
            }
            .buttonStyle(.plain)
            .disabled(vm.findHits.isEmpty)
            .keyboardShortcut("g", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface)
        .overlay(Rectangle().frame(height: 1)
                    .foregroundStyle(Theme.border), alignment: .bottom)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder
    private var counter: some View {
        let q = vm.findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            EmptyView()
        } else if vm.findHits.isEmpty {
            Text("No matches")
                .scaledUI(11)
                .foregroundStyle(Theme.textFaint)
        } else {
            Text("\(vm.findCurrentIdx + 1) / \(vm.findHits.count)")
                .scaledMono(11)
                .foregroundStyle(Theme.textMuted)
        }
    }
}
```

(`Theme.surface` / `Theme.border` / `Theme.textMuted` / `Theme.textFaint`
are existing palette colors used across the app — they exist in
`Theme.swift`.)

- [ ] **Step 5: Slot the find bar into `ConversationView.swift` and bind ⌘F**

In `yawac/Views/ConversationView.swift`, locate the body where
`headerBar` is followed by the message `ScrollView`. Insert the find bar
between them, gated on `vm.findActive`. The change looks like:

```swift
        VStack(spacing: 0) {
            headerBar
            if vm.findActive {
                ConversationFindBar()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // … existing ScrollViewReader / scroll view …
        }
        .animation(.easeOut(duration: 0.15), value: vm.findActive)
        .background(
            Button("") {
                vm.findActive.toggle()
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
```

(The hidden button is a SwiftUI idiom on macOS for a global shortcut that
isn't tied to any visible control. Placing it in `.background` keeps it
in the responder chain without affecting layout.)

- [ ] **Step 6: Build + commit**

```bash
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

```bash
git add yawac/Views/ConversationFindBar.swift \
        yawac/Views/Modifiers/FindHighlight.swift \
        yawac/Views/ConversationView.swift \
        yawac/Views/MessageRow.swift \
        yawac/Design/Theme.swift
git commit -m "convo: ConversationFindBar + ⌘F + per-row highlight modifier"
```

---

## Task 7: `IndexingChip` + sidebar progress wiring

Surface bootstrap progress above the sidebar search field.

**Files:**
- Create: `yawac/Views/IndexingChip.swift`
- Modify: `yawac/Views/ChatListView.swift` (search header area)

- [ ] **Step 1: Create `Views/IndexingChip.swift`**

```swift
import SwiftUI

/// Slim "Indexing… N / M" chip shown above the sidebar search field
/// while `MessageIndex.shared.progress == .running`. Auto-hides on
/// `.done` / `.idle`.
struct IndexingChip: View {

    @Bindable var index: MessageIndex = .shared

    var body: some View {
        switch index.progress {
        case .running(let indexed, let total):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Indexing… \(indexed) / \(total)")
                    .scaledUI(11)
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.surfaceAlt, in: Capsule())
            .padding(.horizontal, 8)
        case .idle, .done:
            EmptyView()
        }
    }
}
```

- [ ] **Step 2: Slot the chip into the sidebar**

In `yawac/Views/ChatListView.swift`, locate the existing search header
(the area containing the sidebar's `TextField` bound to `vm.searchVM.query`,
typically immediately above the chats list). Insert directly above the
text field:

```swift
            IndexingChip()
```

- [ ] **Step 3: Build verify**

```bash
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/IndexingChip.swift yawac/Views/ChatListView.swift
git commit -m "sidebar: IndexingChip surfacing FTS bootstrap progress"
```

---

## Task 8: Global message search in `ChatSearchViewModel`

Extend the existing sidebar search VM with `messageHits` + cancellation.

**Files:**
- Modify: `yawac/ViewModels/ChatSearchViewModel.swift`
- Modify: `yawacTests/ChatSearchViewModelTests.swift` (append tests)

- [ ] **Step 1: Append failing tests**

Append to `yawacTests/ChatSearchViewModelTests.swift` (inside the
existing `ChatSearchViewModelTests` class):

```swift
    func testGlobalMessageSearchPopulatesHits() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-sbs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let idx = MessageIndex(storeURL: tmp)
        idx.ensureSchema()
        idx.upsert(.init(messageID: "m1", chatJID: "A@s.whatsapp.net",
                         timestamp: 10, text: "Hello Finland",
                         caption: "", quoted: "", sender: "Alice"))
        idx.upsert(.init(messageID: "m2", chatJID: "B@s.whatsapp.net",
                         timestamp: 20, text: "Goodbye Finland",
                         caption: "", quoted: "", sender: "Bob"))

        let listVM = makeListVM(chats: [])  // existing helper in this file
        let vm = ChatSearchViewModel(listVM: listVM,
                                     validator: StubValidator(),
                                     messageIndex: idx)
        vm.debounceMs = 20
        vm.query = "finland"
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(vm.messageHits.count, 2)
    }

    func testGlobalSearchCancellation() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-sbs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let idx = MessageIndex(storeURL: tmp)
        idx.ensureSchema()
        idx.upsert(.init(messageID: "m1", chatJID: "A@s.whatsapp.net",
                         timestamp: 10, text: "Finland",
                         caption: "", quoted: "", sender: ""))
        idx.upsert(.init(messageID: "m2", chatJID: "A@s.whatsapp.net",
                         timestamp: 20, text: "Sweden",
                         caption: "", quoted: "", sender: ""))

        let listVM = makeListVM(chats: [])
        let vm = ChatSearchViewModel(listVM: listVM,
                                     validator: StubValidator(),
                                     messageIndex: idx)
        vm.debounceMs = 20
        vm.query = "fin"
        vm.query = "swe"
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(vm.messageHits.map(\.messageID), ["m2"])
    }
```

(If `makeListVM` / `StubValidator` don't exist as helpers in the test
file, add minimal stubs. Read the existing
`ChatSearchViewModelTests.swift` to see the existing pattern — adapt
verbatim.)

- [ ] **Step 2: Run tests, confirm fail**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatSearchViewModelTests 2>&1 | tail -10
```

Expected: build failure on the `messageIndex:` init param and
`messageHits` property.

- [ ] **Step 3: Extend `ChatSearchViewModel`**

In `yawac/ViewModels/ChatSearchViewModel.swift`:

1. Add a stored property and a new initializer overload:

```swift
    private(set) var messageHits: [MessageIndex.Hit] = []
    private let messageIndex: MessageIndex
    private var messageTask: Task<Void, Never>? = nil
```

2. Replace the existing initializer with:

```swift
    init(listVM: ChatListViewModel,
         validator: PhoneValidating,
         messageIndex: MessageIndex = .shared) {
        self.listVM = listVM
        self.validator = validator
        self.messageIndex = messageIndex
        self.filteredChats = listVM.chats
    }
```

3. Extend `clear()`:

```swift
    func clear() {
        debounceTask?.cancel()
        messageTask?.cancel()
        query = ""
        suggestion = nil
        validating = false
        filteredChats = listVM?.chats ?? []
        messageHits = []
    }
```

4. Extend `onQueryChanged()` — inside the existing detached debounce
   task (after `await self.runFilter(q)` and the validate call), add a
   call to a new `refreshMessages`:

```swift
        debounceTask = Task { [weak self, debounceMs] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self, !Task.isCancelled else { return }
            await self.runFilter(q)
            await self.maybeValidate(q)
            await self.refreshMessages(q)
        }
```

5. Add the new method:

```swift
    private func refreshMessages(_ q: String) async {
        messageTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            messageHits = []
            return
        }
        let idx = messageIndex
        messageTask = Task { [weak self] in
            let hits = await Task.detached(priority: .userInitiated) {
                idx.searchGlobal(query: trimmed)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.messageHits = hits
        }
        await messageTask?.value
    }
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatSearchViewModelTests 2>&1 | tail -20
```

Expected: all `ChatSearchViewModelTests` pass.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ChatSearchViewModel.swift \
        yawacTests/ChatSearchViewModelTests.swift
git commit -m "sidebar: ChatSearchViewModel surfaces global message hits"
```

---

## Task 9: Sectioned sidebar rendering + tap-to-jump

Render a "Messages" section under "Chats" in the sidebar search results;
tap → select chat + jumpToQuoted.

**Files:**
- Modify: `yawac/Views/ChatListView.swift`

This is view-layer only — verification = build + manual visual.

- [ ] **Step 1: Add the Messages section**

In `yawac/Views/ChatListView.swift`, find the sidebar list that renders
`vm.searchVM.filteredChats` (typically a `List` or `ScrollView` of
`ChatRow`s, guarded by `!vm.searchVM.query.isEmpty`). Wrap the existing
chat rows in a `Section("Chats")` and add a new
`Section("Messages")` below it. Approximate shape (adapt to the
existing layout):

```swift
            if !vm.searchVM.query.isEmpty {
                List {
                    Section("Chats") {
                        ForEach(vm.searchVM.filteredChats) { chat in
                            ChatRow(chat: chat) // existing
                                .onTapGesture { vm.selectChat(jid: chat.jid) }
                        }
                    }
                    if !vm.searchVM.messageHits.isEmpty {
                        Section("Messages (\(vm.searchVM.messageHits.count))") {
                            ForEach(vm.searchVM.messageHits, id: \.messageID) { hit in
                                MessageHitRow(hit: hit,
                                              chatName: vm.chatName(forJID: hit.chatJID))
                                    .onTapGesture {
                                        vm.selectChat(jid: hit.chatJID)
                                        // Defer jumpToQuoted by one runloop
                                        // tick so the ConversationViewModel
                                        // for the newly-selected chat is up.
                                        Task { @MainActor in
                                            try? await Task.sleep(for: .milliseconds(50))
                                            vm.activeConversation?
                                                .jumpToQuoted(id: hit.messageID)
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                // existing non-search chat list
            }
```

If `vm.chatName(forJID:)` doesn't exist, add a one-liner helper in
`ChatListViewModel` that looks up the chat in `chats` and returns its
name (or the JID as fallback). Likewise `vm.activeConversation` —
whatever the established way to reach the currently-loaded
`ConversationViewModel` is.

- [ ] **Step 2: Define `MessageHitRow`**

At the bottom of `yawac/Views/ChatListView.swift` (private to the
file), add:

```swift
private struct MessageHitRow: View {
    let hit: MessageIndex.Hit
    let chatName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(chatName)
                    .scaledUI(12, weight: .semibold)
                    .foregroundStyle(Theme.text)
                if !hit.sender.isEmpty {
                    Text("·").foregroundStyle(Theme.textFaint)
                    Text(hit.sender)
                        .scaledUI(12)
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 4)
                Text(timestampShort(hit.timestamp))
                    .scaledMono(10)
                    .foregroundStyle(Theme.textFaint)
            }
            snippetText
                .scaledUI(11)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }

    private var snippetText: some View {
        // Replace ⟦…⟧ markers with bold ranges.
        var out = AttributedString()
        var s = Substring(hit.snippet)
        while let open = s.range(of: "⟦"),
              let close = s.range(of: "⟧"), close.lowerBound > open.upperBound {
            out.append(AttributedString(s[s.startIndex..<open.lowerBound]))
            var bold = AttributedString(s[open.upperBound..<close.lowerBound])
            bold.font = Theme.ui(11, weight: .bold)
            out.append(bold)
            s = s[close.upperBound...]
        }
        out.append(AttributedString(s))
        return Text(out)
    }

    private func timestampShort(_ apple: Int64) -> String {
        // ZTIMESTAMP is Apple epoch seconds (REAL).
        let d = Date(timeIntervalSinceReferenceDate: TimeInterval(apple))
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }
}
```

- [ ] **Step 3: Build verify**

```bash
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ChatListView.swift
git commit -m "sidebar: sectioned search results — Chats + Messages with tap-to-jump"
```

---

## Task 10: Full suite + smoke test

**Files:** none.

- [ ] **Step 1: Run full test suite**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. All previously passing tests still
pass; new `MessageIndexTests`, `MessageSearchViewModelTests`,
`ConversationFindStateTests`, and the appended
`ChatSearchViewModelTests` cases pass.

- [ ] **Step 2: If anything fails, debug + fix; do not declare done with red tests**

---

## Task 11: Manual visual verification

No commits — interactive check.

- [ ] Launch the app. Sidebar shows `IndexingChip` for a few seconds if
      this is the first launch post-bootstrap; auto-hides when done.
- [ ] Open any chat. Press ⌘F. Find bar slides in; text field focused.
- [ ] Type a term that exists in the conversation. Matching message
      rows tint yellow; current row tints stronger; counter reads "1 of N".
- [ ] Press ⌘G (or ↓). Cursor advances; scroll snaps to next match.
      ⇧⌘G / ↑ goes back. Both wrap at ends.
- [ ] Press Esc. Find bar collapses; highlights vanish; query cleared.
- [ ] In the sidebar, type a term that appears in some message body.
      Two sections appear: "Chats" (existing behavior) and "Messages
      (N)". Tap a message hit — chat opens, conversation scrolls to the
      message, brief 1.2-second highlight pulse.
- [ ] Open a chat with a previously-deleted message. Search for a
      surviving word from before the delete — the tombstoned message
      appears in results (per the no-filter design decision).

---

## Done When

- All commands in Task 10 succeed.
- All seven manual checks in Task 11 pass.
- 11 commits land on `main` (Tasks 1, 2, 3, 4, 5, 6, 7, 8, 9 each one
  commit; Tasks 10 / 11 are gates, no commits).
