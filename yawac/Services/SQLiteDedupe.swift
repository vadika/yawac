import Foundation
import SQLite3

/// Read-only summaries of the configured SwiftData store.
enum SQLiteDedupe {

    /// Read-only scan: returns `(chatJID, latestTimestamp, latestText, latestKind)`
    /// per chat by selecting MAX(timestamp) grouped by chatJID. Used by
    /// `ChatListViewModel.loadChats` to avoid materialising thousands of
    /// PersistedMessage objects through SwiftData on the main thread.
    struct LatestPerChat {
        let chatJID: String
        let timestampAppleEpoch: Double  // Apple epoch (1 Jan 2001)
        let text: String?
        let kind: String
        let revoked: Bool
        let locallyDeleted: Bool
    }
    static func latestMessagePerChat(at storeURL: URL) -> [LatestPerChat] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        // For each chat, take the row with the max timestamp.
        // F122: skip system/protocol rows — their body text ("Encryption
        // key with X changed.") must never become the sidebar preview.
        let sql = """
            SELECT m.ZCHATJID, m.ZTIMESTAMP, m.ZTEXT, m.ZKIND,
                   m.ZREVOKEDAT, m.ZLOCALLYDELETED
            FROM ZPERSISTEDMESSAGE m
            JOIN (
                SELECT ZCHATJID, MAX(ZTIMESTAMP) AS mx
                FROM ZPERSISTEDMESSAGE
                WHERE ZKIND NOT IN ('system', 'protocol')
                GROUP BY ZCHATJID
            ) j ON j.ZCHATJID = m.ZCHATJID AND j.mx = m.ZTIMESTAMP
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [LatestPerChat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let jidPtr = sqlite3_column_text(stmt, 0) else { continue }
            let jid = String(cString: jidPtr)
            let ts = sqlite3_column_double(stmt, 1)
            let text = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }
            let kind = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""
            // ZREVOKEDAT is a nullable TIMESTAMP column — treat any non-null
            // value as "revoked". ZLOCALLYDELETED is an INTEGER 0/1 flag.
            let revoked = sqlite3_column_type(stmt, 4) != SQLITE_NULL
            let locallyDeleted = sqlite3_column_int(stmt, 5) != 0
            out.append(LatestPerChat(
                chatJID: jid,
                timestampAppleEpoch: ts,
                text: text,
                kind: kind,
                revoked: revoked,
                locallyDeleted: locallyDeleted))
        }
        return out
    }

    /// F123: chats that have at least one message row of any kind.
    /// Combined with `latestMessagePerChat` (previewable kinds only),
    /// a chat present here but absent there holds nothing but
    /// system/protocol rows — it must not float in the sidebar.
    static func chatJIDsWithAnyMessage(at storeURL: URL) -> Set<String> {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT DISTINCT ZCHATJID FROM ZPERSISTEDMESSAGE",
            -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = sqlite3_column_text(stmt, 0) { out.insert(String(cString: p)) }
        }
        return out
    }

    /// F119: orphan quoted references — replies whose quoted target is
    /// absent from the store. Each row carries complete placeholder-resend
    /// coordinates (chat + target message ID + target sender), so the gap
    /// sweep can ask the primary phone to resend the missing original.
    /// Read-only.
    struct OrphanQuotedRef {
        let chatJID: String
        let targetMessageID: String
        let targetSenderJID: String
        let targetFromMe: Bool
    }
    static func orphanQuotedRefs(at storeURL: URL, sinceDays: Int) -> [OrphanQuotedRef] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        // ZTIMESTAMP is Apple-epoch seconds (1 Jan 2001).
        let cutoff = Date().timeIntervalSinceReferenceDate
            - Double(sinceDays) * 86_400
        let sql = """
            SELECT m.ZCHATJID, m.ZQUOTEDMESSAGEID,
                   COALESCE(m.ZQUOTEDSENDERJID, ''),
                   COALESCE(m.ZQUOTEDFROMME, 0)
            FROM ZPERSISTEDMESSAGE m
            WHERE m.ZQUOTEDMESSAGEID IS NOT NULL
              AND m.ZQUOTEDMESSAGEID != ''
              AND m.ZTIMESTAMP > ?
              AND NOT EXISTS (SELECT 1 FROM ZPERSISTEDMESSAGE t
                              WHERE t.ZID = m.ZQUOTEDMESSAGEID)
            GROUP BY m.ZQUOTEDMESSAGEID
            ORDER BY m.ZTIMESTAMP DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)

        var out: [OrphanQuotedRef] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let chatPtr = sqlite3_column_text(stmt, 0),
                  let idPtr = sqlite3_column_text(stmt, 1) else { continue }
            let sender = sqlite3_column_text(stmt, 2)
                .flatMap { String(cString: $0) } ?? ""
            out.append(OrphanQuotedRef(
                chatJID: String(cString: chatPtr),
                targetMessageID: String(cString: idPtr),
                targetSenderJID: sender,
                targetFromMe: sqlite3_column_int(stmt, 3) != 0))
        }
        return out
    }

    /// Read-only scan: returns `(bareSenderJID, mostRecentPushName)` for
    /// every distinct sender that has at least one persisted push name.
    /// Used at startup to rebuild `SessionViewModel.contactNames` so
    /// historical messages render with names instead of raw user ids.
    static func sendersWithPushNames(at storeURL: URL) -> [(jid: String, name: String)] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        // Pick the most-recent push name per sender via MAX(timestamp).
        let sql = """
            SELECT m.ZSENDERJID, m.ZSENDERPUSHNAME
            FROM ZPERSISTEDMESSAGE m
            JOIN (
                SELECT ZSENDERJID, MAX(ZTIMESTAMP) AS mx
                FROM ZPERSISTEDMESSAGE
                WHERE ZSENDERPUSHNAME IS NOT NULL AND ZSENDERPUSHNAME != ''
                GROUP BY ZSENDERJID
            ) j ON j.ZSENDERJID = m.ZSENDERJID AND j.mx = m.ZTIMESTAMP
            WHERE m.ZSENDERPUSHNAME IS NOT NULL AND m.ZSENDERPUSHNAME != ''
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let jidPtr = sqlite3_column_text(stmt, 0),
                  let namePtr = sqlite3_column_text(stmt, 1) else { continue }
            out.append((String(cString: jidPtr), String(cString: namePtr)))
        }
        return out
    }

}
