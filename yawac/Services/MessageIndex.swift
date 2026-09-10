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

    struct MessageFields: Equatable, Sendable {
        let messageID: String
        let chatJID: String
        let timestamp: Int64
        let kind: String
        let text: String
        let caption: String
        let quoted: String
        let sender: String
        let fromMe: Bool
        let senderJID: String
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
        case failed(String)
    }

    // MARK: - Singleton + init

    static let shared = MessageIndex(storeURL: defaultStoreURL())

    let storeURL: URL
    private let queue = DispatchQueue(label: "yawac.MessageIndex")
    // Must be @ObservationIgnored. Same trap as F14: MessageIndex is
    // @Observable, so plain `var` properties are tracked by the macro.
    // `ensureSchemaLocked()` lazily assigns `db` on first call — and
    // `distinctSendersInChat` / `distinctSendersGlobal` are called from
    // SwiftUI body evaluation (ConversationFindBar Sender chip,
    // ChatListView Sender chip). Without this annotation, the first body
    // eval that hits an unopened db triggers willSet → invalidate →
    // re-body → mutate → loop. `progress` stays observed — it drives the
    // bootstrap progress UI.
    @ObservationIgnored private var db: OpaquePointer?
    var progress: BootstrapProgress = .idle

    init(storeURL: URL) {
        self.storeURL = storeURL
        // Restore the cached own push name + bare JID from a prior
        // launch so the bootstrap walk (which runs before .connected
        // fires the live setters) gets non-empty values.
        self.ownPushName = UserDefaults.standard
            .string(forKey: "messageIndexOwnPushName") ?? ""
        let cachedJID = UserDefaults.standard
            .string(forKey: "messageIndexOwnBareJID") ?? ""
        self.ownBareJID = cachedJID
    }

    private static func defaultStoreURL() -> URL { AppPaths.messageStoreURL }

    // MARK: - Schema

    func ensureSchema() {
        queue.sync { ensureSchemaLocked() }
    }

    private func ensureSchemaLocked() {
        if db == nil {
            var handle: OpaquePointer?
            guard sqlite3_open(storeURL.path, &handle) == SQLITE_OK else {
                if let handle { sqlite3_close(handle) }
                progress = .failed("Cannot open search database")
                return
            }
            db = handle
            sqlite3_busy_timeout(db, 2000)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        }
        var statement: OpaquePointer?
        var columns: Set<String> = []
        if sqlite3_prepare_v2(db, "PRAGMA table_info(MessageFTS)", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
            }
        }
        sqlite3_finalize(statement)
        let required: Set<String> = ["msgid", "chatjid", "ts", "kind", "sender_jid", "text", "caption", "quoted", "sender"]
        if !columns.isEmpty && !required.isSubset(of: columns) {
            do { try checked("DROP TABLE MessageFTS") }
            catch { progress = .failed(error.localizedDescription); return }
        }
        let create = """
            CREATE VIRTUAL TABLE IF NOT EXISTS MessageFTS USING fts5(
                msgid UNINDEXED, chatjid UNINDEXED, ts UNINDEXED,
                kind UNINDEXED, sender_jid UNINDEXED,
                text, caption, quoted, sender,
                tokenize = 'unicode61'
            );
        """
        do { try checked(create) } catch { progress = .failed(error.localizedDescription) }
    }

    // MARK: - Write paths

    func upsert(_ fields: MessageFields) {
        do { try apply(upserts: [fields]) }
        catch { reportFailure(error) }
    }

    struct IndexError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func checked(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IndexError(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Search database unavailable")
        }
    }

    func reportFailure(_ error: Error) {
        queue.sync { progress = .failed(error.localizedDescription) }
        NSLog("[yawac/index] %@", error.localizedDescription)
    }

    /// One transaction per committed source batch. Caller serializes source
    /// commits; this queue also excludes concurrent reconciliation.
    func apply(upserts: [MessageFields], removing: [String] = []) throws {
        guard !upserts.isEmpty || !removing.isEmpty else { return }
        try queue.sync {
            ensureSchemaLocked()
            try checked("BEGIN IMMEDIATE;")
            do {
                for id in removing + upserts.map(\.messageID) {
                    guard execStep(sql: "DELETE FROM MessageFTS WHERE msgid = ?;", binds: [.text(id)]) else {
                        throw IndexError(message: "Could not update search index")
                    }
                }
                for fields in upserts { try insertLocked(fields) }
                try checked("COMMIT;")
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    private func insertLocked(_ fields: MessageFields) throws {
        guard execStep(sql: """
            INSERT INTO MessageFTS(msgid, chatjid, ts, kind, sender_jid,
                                   text, caption, quoted, sender)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, binds: [
                .text(fields.messageID), .text(canonicalizer?(fields.chatJID) ?? fields.chatJID),
                .int(fields.timestamp), .text(fields.kind), .text(senderJIDForIndex(fields)),
                .text(fields.text), .text(fields.caption), .text(fields.quoted),
                .text(senderForIndex(fields)),
            ]) else { throw IndexError(message: "Could not insert search row") }
    }

    /// Sender JID we should index for a row. Own outbound rows often
    /// carry no senderJID (or the device-suffixed own JID) — normalise
    /// to the bare own JID. For non-self rows, run the bare value
    /// through the optional canonicalizer so a contact known under
    /// `@lid` and `@s.whatsapp.net` siblings collapses to one chip
    /// entry.
    private func senderJIDForIndex(_ f: MessageFields) -> String {
        if f.fromMe { return ownBareJID }
        let bare = JIDNormalize.bare(f.senderJID)
        if let canon = canonicalizer { return canon(bare) }
        return bare
    }

    /// Optional LID→PN resolver. Set on launch (see
    /// `setCanonicalizer`); used in `senderJIDForIndex` so LID and PN
    /// siblings of the same contact share a single FTS row id.
    @ObservationIgnored private var canonicalizer: ((String) -> String)?

    func setCanonicalizer(_ fn: @escaping (String) -> String) {
        queue.sync { canonicalizer = fn }
    }

    /// Bare paired-account JID. Cached so the upsert path doesn't have
    /// to thread a client reference. Set on .connected.
    @ObservationIgnored private var ownBareJID: String = ""

    func setOwnBareJID(_ jid: String) {
        let bare = JIDNormalize.bare(jid)
        guard !bare.isEmpty else { return }
        queue.sync { ownBareJID = bare }
        UserDefaults.standard.set(bare, forKey: "messageIndexOwnBareJID")
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
    @ObservationIgnored private var ownPushName: String = ""

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

    /// (senderJID, lastSeenPushName) pairs observed in the given chat.
    /// Drives the in-chat Sender filter picker. Filter equality matches
    /// on the JID so push-name changes over time don't fragment the
    /// chip list.
    func distinctSendersInChat(jid: String) -> [(jid: String, name: String)] {
        return queue.sync {
            ensureSchemaLocked()
            var stmt: OpaquePointer?
            let sql = """
                SELECT sender_jid, sender FROM MessageFTS
                WHERE chatjid = ? AND sender_jid != ''
                GROUP BY sender_jid
                ORDER BY sender COLLATE NOCASE ASC;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            let TRANSIENT = unsafeBitCast(
                OpaquePointer(bitPattern: -1)!,
                to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, jid, -1, TRANSIENT)
            var out: [(jid: String, name: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let j = stringCol(stmt, 0)
                let n = stringCol(stmt, 1)
                out.append((jid: j, name: n.isEmpty ? j : n))
            }
            return out
        }
    }

    /// (senderJID, lastSeenPushName) pairs across all chats. Drives the
    /// global ⌘K Sender filter picker.
    func distinctSendersGlobal() -> [(jid: String, name: String)] {
        return queue.sync {
            ensureSchemaLocked()
            var stmt: OpaquePointer?
            let sql = """
                SELECT sender_jid, sender FROM MessageFTS
                WHERE sender_jid != ''
                GROUP BY sender_jid
                ORDER BY sender COLLATE NOCASE ASC;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [(jid: String, name: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let j = stringCol(stmt, 0)
                let n = stringCol(stmt, 1)
                out.append((jid: j, name: n.isEmpty ? j : n))
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
            clauses.append("sender_jid = ?")
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

    /// Reconcile all source rows, including edits with unchanged row counts.
    /// A single checked transaction makes interruption leave the previous
    /// index intact. Rows are streamed rather than materialized as models.
    func bootstrapIfNeeded() async {
        await Task.detached(priority: .utility) { [self] in
            do { try reconcile() }
            catch { reportFailure(error) }
        }.value
    }

    func reconcile() throws {
        try queue.sync {
            ensureSchemaLocked()
            try checked("BEGIN IMMEDIATE;")
            do {
                let total = scalarInt(sql: "SELECT COUNT(*) FROM ZPERSISTEDMESSAGE;")
                progress = .running(indexed: 0, total: total)
                var statement: OpaquePointer?
                let sql = """
                    SELECT ZID, ZCHATJID, ZTIMESTAMP, ZKIND, ZTEXT, ZMEDIACAPTION,
                           ZQUOTEDTEXTSNIPPET, ZSENDERPUSHNAME, ZFROMME, ZSENDERJID
                    FROM ZPERSISTEDMESSAGE
                    WHERE COALESCE(ZLOCALLYDELETED, 0) = 0 AND ZREVOKEDAT IS NULL
                    ORDER BY Z_PK;
                    """
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw IndexError(message: "Could not read messages for search repair")
                }
                defer { sqlite3_finalize(statement) }
                try checked("DELETE FROM MessageFTS;")
                var count = 0
                var result = sqlite3_step(statement)
                while result == SQLITE_ROW {
                    try insertLocked(MessageFields(
                        messageID: stringCol(statement, 0), chatJID: stringCol(statement, 1),
                        timestamp: Int64(sqlite3_column_double(statement, 2)),
                        kind: stringCol(statement, 3), text: stringCol(statement, 4),
                        caption: stringCol(statement, 5), quoted: stringCol(statement, 6),
                        sender: stringCol(statement, 7), fromMe: sqlite3_column_int64(statement, 8) != 0,
                        senderJID: stringCol(statement, 9)))
                    count += 1
                    if count % 1000 == 0 { progress = .running(indexed: count, total: total) }
                    result = sqlite3_step(statement)
                }
                guard result == SQLITE_DONE else { throw IndexError(message: "Search repair read failed") }
                try checked("COMMIT;")
                progress = .done
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
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
