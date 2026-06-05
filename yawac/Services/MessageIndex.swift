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
        let kind: String
        let text: String
        let caption: String
        let quoted: String
        let sender: String
        let fromMe: Bool
    }

    /// Optional filter knobs layered on top of the FTS5 MATCH clause.
    /// All fields nil = no extra constraints (back-compat with the
    /// pre-v0.8.4 single-arg query API).
    struct SearchFilters: Equatable {
        var sender: String?
        var kind: String?
        var fromTimestamp: Int64?
        var toTimestamp: Int64?

        var isEmpty: Bool {
            sender == nil && kind == nil
                && fromTimestamp == nil && toTimestamp == nil
        }
    }

    struct Hit: Equatable, Hashable {
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

    static let shared = MessageIndex(storeURL: defaultStoreURL())

    private let storeURL: URL
    private let queue = DispatchQueue(label: "yawac.MessageIndex")
    private var db: OpaquePointer?
    var progress: BootstrapProgress = .idle

    init(storeURL: URL) {
        self.storeURL = storeURL
        // Restore the cached own push name from a prior launch so the
        // bootstrap walk (which runs before .connected fires the live
        // pushName setter) can fill in fromMe rows with a non-empty
        // sender value.
        let cached = UserDefaults.standard
            .string(forKey: "messageIndexOwnPushName") ?? ""
        self.ownPushName = cached
    }

    private static func defaultStoreURL() -> URL {
        let supportDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return supportDir.appendingPathComponent("default.store")
    }

    // MARK: - Schema

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
        // Schema v1 → v2: added `kind` column. Schema v2 → v3: rebuilds
        // the index so fromMe rows with empty `senderPushName` get the
        // own-push-name fallback at upsert time. FTS5 can't ALTER ADD
        // COLUMN; both bumps drop and re-create, letting
        // `bootstrapIfNeeded` repopulate from ZPERSISTEDMESSAGE.
        let schemaKey = "messageIndexSchemaVersion"
        let currentVersion = UserDefaults.standard.integer(forKey: schemaKey)
        if currentVersion < 3 {
            sqlite3_exec(db, "DROP TABLE IF EXISTS MessageFTS;", nil, nil, nil)
            UserDefaults.standard.set(3, forKey: schemaKey)
        }
        let create = """
            CREATE VIRTUAL TABLE IF NOT EXISTS MessageFTS USING fts5(
                msgid UNINDEXED, chatjid UNINDEXED, ts UNINDEXED,
                kind UNINDEXED,
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
        let sender = senderForIndex(f)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        var ok = execStep(sql: "DELETE FROM MessageFTS WHERE msgid = ?;",
                          binds: [.text(f.messageID)])
        if ok {
            ok = execStep(sql: """
                INSERT INTO MessageFTS(msgid, chatjid, ts, kind, text, caption, quoted, sender)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """,
                binds: [
                    .text(f.messageID), .text(f.chatJID), .int(f.timestamp),
                    .text(f.kind),
                    .text(f.text), .text(f.caption),
                    .text(f.quoted), .text(sender),
                ])
        }
        sqlite3_exec(db, ok ? "COMMIT;" : "ROLLBACK;", nil, nil, nil)
    }

    /// Returns the sender string we should index for a row. Own outbound
    /// messages with no push-name persisted (the WhatsApp side never
    /// echoes one for fromMe = true) fall back to the paired account's
    /// own push name so Sender-filter equality matches own messages
    /// consistently across chats.
    private func senderForIndex(_ f: MessageFields) -> String {
        if !f.sender.isEmpty { return f.sender }
        if f.fromMe { return ownPushName }
        return ""
    }

    /// Cache of the paired account's own push name — read at upsert
    /// time when a fromMe row has no `senderPushName` of its own.
    /// Set once on launch (see `setOwnPushName(_:)`); changes between
    /// launches trigger a re-bootstrap via schema-version bump.
    private var ownPushName: String = ""

    /// Update the cached own push name. Safe to call repeatedly — only
    /// non-empty values overwrite (the bridge may return "" before
    /// app-state has settled).
    func setOwnPushName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync { ownPushName = trimmed }
        UserDefaults.standard.set(
            trimmed, forKey: "messageIndexOwnPushName")
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

    func searchInChat(jid: String, query: String,
                      filters: SearchFilters = .init(),
                      limit: Int = 500) -> [Hit] {
        let match = makeMatch(query)
        if match == nil && filters.isEmpty { return [] }
        var clauses = ["chatjid = ?"]
        var binds: [Bind] = [.text(jid)]
        if let match {
            clauses.append("MessageFTS MATCH ?")
            binds.append(.text(match))
        }
        appendFilterClauses(filters, clauses: &clauses, binds: &binds)
        binds.append(.int(Int64(limit)))
        let snippetExpr = match != nil
            ? "snippet(MessageFTS, -1, '⟦', '⟧', '…', 12)"
            : "substr(coalesce(nullif(text, ''), caption), 1, 80)"
        let sql = """
            SELECT msgid, chatjid, ts, sender, \(snippetExpr)
            FROM MessageFTS
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY ts ASC
            LIMIT ?;
            """
        return queue.sync {
            ensureSchemaLocked()
            return runQuery(sql: sql, binds: binds)
        }
    }

    func searchGlobal(query: String,
                      filters: SearchFilters = .init(),
                      chatJID: String? = nil,
                      limit: Int = 200) -> [Hit] {
        let match = makeMatch(query)
        if match == nil && filters.isEmpty && (chatJID?.isEmpty ?? true) {
            return []
        }
        var clauses: [String] = []
        var binds: [Bind] = []
        if let match {
            clauses.append("MessageFTS MATCH ?")
            binds.append(.text(match))
        }
        if let chatJID, !chatJID.isEmpty {
            clauses.append("chatjid = ?")
            binds.append(.text(chatJID))
        }
        appendFilterClauses(filters, clauses: &clauses, binds: &binds)
        binds.append(.int(Int64(limit)))
        let snippetExpr = match != nil
            ? "snippet(MessageFTS, -1, '⟦', '⟧', '…', 12)"
            : "substr(coalesce(nullif(text, ''), caption), 1, 80)"
        let orderBy = match != nil
            ? "bm25(MessageFTS) ASC, ts DESC"
            : "ts DESC"
        let sql = """
            SELECT msgid, chatjid, ts, sender, \(snippetExpr)
            FROM MessageFTS
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(orderBy)
            LIMIT ?;
            """
        return queue.sync {
            ensureSchemaLocked()
            return runQuery(sql: sql, binds: binds)
        }
    }

    /// Distinct, non-empty `sender` values currently indexed for the
    /// given chat. Drives the in-chat Sender filter picker — values
    /// match the FTS5 column verbatim so an equality filter never
    /// drifts away from what the chip shows.
    func distinctSendersInChat(jid: String) -> [String] {
        return queue.sync {
            ensureSchemaLocked()
            var stmt: OpaquePointer?
            let sql = """
                SELECT DISTINCT sender FROM MessageFTS
                WHERE chatjid = ? AND sender != ''
                ORDER BY sender COLLATE NOCASE ASC;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            let TRANSIENT = unsafeBitCast(
                OpaquePointer(bitPattern: -1)!,
                to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, jid, -1, TRANSIENT)
            var out: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(stringCol(stmt, 0))
            }
            return out
        }
    }

    /// Distinct, non-empty `sender` values across all chats. Drives the
    /// global ⌘K Sender filter picker.
    func distinctSendersGlobal() -> [String] {
        return queue.sync {
            ensureSchemaLocked()
            var stmt: OpaquePointer?
            let sql = """
                SELECT DISTINCT sender FROM MessageFTS
                WHERE sender != ''
                ORDER BY sender COLLATE NOCASE ASC;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(stringCol(stmt, 0))
            }
            return out
        }
    }

    /// Appends optional WHERE clauses + their bind values for sender /
    /// kind / date-range filters. Keeping this in one place avoids the
    /// two read paths drifting out of sync on bind order.
    private func appendFilterClauses(_ f: SearchFilters,
                                     clauses: inout [String],
                                     binds: inout [Bind]) {
        if let sender = f.sender, !sender.isEmpty {
            clauses.append("sender = ?")
            binds.append(.text(sender))
        }
        if let kind = f.kind, !kind.isEmpty {
            clauses.append("kind = ?")
            binds.append(.text(kind))
        }
        if let from = f.fromTimestamp {
            clauses.append("ts >= ?")
            binds.append(.int(from))
        }
        if let to = f.toTimestamp {
            clauses.append("ts <= ?")
            binds.append(.int(to))
        }
    }

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
                var ok = true
                for f in page {
                    if !execStep(sql: "DELETE FROM MessageFTS WHERE msgid = ?;",
                                 binds: [.text(f.messageID)]) { ok = false; break }
                    if !execStep(sql: """
                        INSERT INTO MessageFTS(msgid, chatjid, ts, kind, text, caption, quoted, sender)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        binds: [
                            .text(f.messageID), .text(f.chatJID), .int(f.timestamp),
                            .text(f.kind),
                            .text(f.text), .text(f.caption),
                            .text(f.quoted), .text(senderForIndex(f)),
                        ]) { ok = false; break }
                }
                sqlite3_exec(db, ok ? "COMMIT;" : "ROLLBACK;", nil, nil, nil)
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
            SELECT ZID, ZCHATJID, ZTIMESTAMP, ZKIND, ZTEXT, ZMEDIACAPTION,
                   ZQUOTEDTEXTSNIPPET, ZSENDERPUSHNAME, ZFROMME
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
            guard !id.isEmpty else { continue }
            let ts = Int64(sqlite3_column_double(stmt, 2))
            out.append(MessageFields(
                messageID: id,
                chatJID:   stringFromStmt(stmt, 1),
                timestamp: ts,
                kind:      stringFromStmt(stmt, 3),
                text:      stringFromStmt(stmt, 4),
                caption:   stringFromStmt(stmt, 5),
                quoted:    stringFromStmt(stmt, 6),
                sender:    stringFromStmt(stmt, 7),
                fromMe:    sqlite3_column_int64(stmt, 8) != 0))
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

    // MARK: - Query construction

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

    deinit {
        if let db { sqlite3_close(db) }
    }
}
