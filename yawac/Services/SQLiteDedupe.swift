import Foundation
import SQLite3

/// Drops `@lid` rows from the SwiftData `default.store` that have a
/// corresponding `@s.whatsapp.net` row. SwiftData's `ModelContext.delete +
/// save` was silently failing in our app (verified by tailing the WAL
/// after exit), so we fall through to direct SQLite for this one-off
/// cleanup. Future writes still go through SwiftData; only the bulk
/// dedupe is raw.
enum SQLiteDedupe {
    /// `deletions` is a list of `(lidJID, canonicalPN)` pairs. The PN row
    /// is preserved; the LID row is deleted, and its `ZLASTTIMESTAMP` /
    /// `ZUNREAD` are folded into the PN row first.
    /// Returns the number of LID rows actually deleted.
    static func collapseLIDRows(_ deletions: [(lid: String, pn: String)]) -> Int {
        let supportDir: URL
        do {
            supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false)
        } catch {
            return 0
        }
        let storeURL = supportDir.appendingPathComponent("default.store")
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return 0
        }
        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK, let db else {
            return 0
        }
        defer { sqlite3_close(db) }

        // Be a good neighbour with SwiftData's writes by waiting briefly.
        sqlite3_busy_timeout(db, 2000)
        // Match SwiftData's journaling so our writes land in the same WAL
        // and aren't discarded as a rival connection's rollback.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        var deleted = 0
        for (lid, pn) in deletions {
            // Merge timestamps/unread first.
            let merge = """
                UPDATE ZPERSISTEDCHAT
                SET ZLASTTIMESTAMP = MAX(ZLASTTIMESTAMP,
                    (SELECT ZLASTTIMESTAMP FROM ZPERSISTEDCHAT WHERE ZJID = ?)),
                    ZUNREAD = ZUNREAD +
                    COALESCE((SELECT ZUNREAD FROM ZPERSISTEDCHAT WHERE ZJID = ?), 0)
                WHERE ZJID = ?;
            """
            if !execStep(db: db, sql: merge, args: [lid, lid, pn]) { continue }

            // Delete the LID row.
            let del = "DELETE FROM ZPERSISTEDCHAT WHERE ZJID = ?;"
            if execStep(db: db, sql: del, args: [lid]) {
                deleted += 1
            }
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
        return deleted
    }

    /// Read-only scan: returns `(chatJID, latestTimestamp, latestText, latestKind)`
    /// per chat by selecting MAX(timestamp) grouped by chatJID. Used by
    /// `ChatListViewModel.loadChats` to avoid materialising thousands of
    /// PersistedMessage objects through SwiftData on the main thread.
    struct LatestPerChat {
        let chatJID: String
        let timestampAppleEpoch: Double  // Apple epoch (1 Jan 2001)
        let text: String?
        let kind: String
    }
    static func latestMessagePerChat() -> [LatestPerChat] {
        let supportDir: URL
        do {
            supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
        } catch { return [] }
        let storeURL = supportDir.appendingPathComponent("default.store")
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        // For each chat, take the row with the max timestamp.
        let sql = """
            SELECT m.ZCHATJID, m.ZTIMESTAMP, m.ZTEXT, m.ZKIND
            FROM ZPERSISTEDMESSAGE m
            JOIN (
                SELECT ZCHATJID, MAX(ZTIMESTAMP) AS mx
                FROM ZPERSISTEDMESSAGE
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
            out.append(LatestPerChat(
                chatJID: jid,
                timestampAppleEpoch: ts,
                text: text,
                kind: kind))
        }
        return out
    }

    private static func execStep(db: OpaquePointer, sql: String, args: [String]) -> Bool {
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if prep != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            NSLog("[yawac/sqlite] prepare rc=%d msg=%@ sql=%@", prep, msg, sql)
            return false
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), a, -1, transient)
        }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            NSLog("[yawac/sqlite] step rc=%d msg=%@ args=%@", rc, msg, args)
            return false
        }
        return true
    }
}
