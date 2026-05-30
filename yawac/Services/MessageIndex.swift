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
        var ok = execStep(sql: "DELETE FROM MessageFTS WHERE msgid = ?;",
                          binds: [.text(f.messageID)])
        if ok {
            ok = execStep(sql: """
                INSERT INTO MessageFTS(msgid, chatjid, ts, text, caption, quoted, sender)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                binds: [
                    .text(f.messageID), .text(f.chatJID), .int(f.timestamp),
                    .text(f.text), .text(f.caption),
                    .text(f.quoted), .text(f.sender),
                ])
        }
        sqlite3_exec(db, ok ? "COMMIT;" : "ROLLBACK;", nil, nil, nil)
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
                        INSERT INTO MessageFTS(msgid, chatjid, ts, text, caption, quoted, sender)
                        VALUES (?, ?, ?, ?, ?, ?, ?);
                        """,
                        binds: [
                            .text(f.messageID), .text(f.chatJID), .int(f.timestamp),
                            .text(f.text), .text(f.caption),
                            .text(f.quoted), .text(f.sender),
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
