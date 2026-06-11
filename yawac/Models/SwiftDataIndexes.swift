import Foundation
import SQLite3

/// SwiftData's `#Index<T>` macro creates SQLite indices when a store
/// is first generated, but does NOT add them retroactively during a
/// VersionedSchema migration whose only delta is index additions —
/// SwiftData inspects the attribute graph (unchanged) and skips the
/// stage. The user's existing v0.9.60 store therefore reaches V2
/// without any of the `chatJID` / `timestamp` / `(chatJID,timestamp)`
/// b-tree indices the predicates in `ConversationViewModel` rely on.
///
/// This helper opens the SwiftData store path as raw SQLite and runs
/// `CREATE INDEX IF NOT EXISTS` per index. Idempotent — re-running it
/// on every launch is a few ms and a no-op once the indices exist.
/// SwiftData's own WAL writers and this read-mostly opener coexist
/// fine under SQLite's default WAL mode.
///
/// Schema names follow CoreData's `Z<UPPERCASE_ENTITY>` table /
/// `Z<UPPERCASE_ATTR>` column convention.
enum SwiftDataIndexes {
    /// CREATE INDEX statements that mirror the `#Index<T>` macros on
    /// PersistedMessage / PersistedReaction / PersistedPollVote.
    /// Names are stable so re-runs skip via IF NOT EXISTS.
    private static let statements: [String] = [
        // PersistedMessage
        "CREATE INDEX IF NOT EXISTS yawac_idx_msg_chat ON ZPERSISTEDMESSAGE(ZCHATJID);",
        "CREATE INDEX IF NOT EXISTS yawac_idx_msg_ts ON ZPERSISTEDMESSAGE(ZTIMESTAMP);",
        "CREATE INDEX IF NOT EXISTS yawac_idx_msg_chat_ts ON ZPERSISTEDMESSAGE(ZCHATJID, ZTIMESTAMP);",
        // PersistedReaction
        "CREATE INDEX IF NOT EXISTS yawac_idx_react_chat ON ZPERSISTEDREACTION(ZCHATJID);",
        "CREATE INDEX IF NOT EXISTS yawac_idx_react_target ON ZPERSISTEDREACTION(ZTARGETMESSAGEID);",
        "CREATE INDEX IF NOT EXISTS yawac_idx_react_ts ON ZPERSISTEDREACTION(ZTIMESTAMP);",
        // PersistedPollVote
        "CREATE INDEX IF NOT EXISTS yawac_idx_poll_chat ON ZPERSISTEDPOLLVOTE(ZCHATJID);",
        "CREATE INDEX IF NOT EXISTS yawac_idx_poll_msg ON ZPERSISTEDPOLLVOTE(ZPOLLMESSAGEID);",
        "CREATE INDEX IF NOT EXISTS yawac_idx_poll_ts ON ZPERSISTEDPOLLVOTE(ZTIMESTAMP);",
    ]

    /// Default SwiftData store path. Mirrors the path SwiftData picks
    /// when `ModelConfiguration` is constructed without an explicit
    /// URL (Application Support / default.store).
    static var defaultStoreURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return appSupport.appendingPathComponent("default.store")
    }

    /// Open the store at `url` and run every `CREATE INDEX IF NOT
    /// EXISTS` statement. Returns count of statements executed (for
    /// logging). Errors are swallowed — index creation is best-effort,
    /// and a failure here doesn't block the app from running on
    /// unindexed scans.
    @discardableResult
    static func ensure(at url: URL) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return 0
        }
        defer { sqlite3_close(db) }
        var ok = 0
        for sql in statements {
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK { ok += 1 }
        }
        return ok
    }
}
