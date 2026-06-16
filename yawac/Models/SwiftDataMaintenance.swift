import Foundation
import SQLite3

/// F85: periodic VACUUM + ANALYZE on the SwiftData store. SwiftData's
/// public ModelConfiguration doesn't expose SQLite pragmas, so the
/// per-connection knobs (cache_size, mmap_size, synchronous,
/// temp_store) can't be tuned without dropping to NSPersistentStore-
/// Coordinator — out of scope here.
///
/// What we CAN do without touching SwiftData's connections:
///
///   1. `PRAGMA auto_vacuum=INCREMENTAL` — persists in the file header.
///      Lets a future VACUUM be replaced with cheap incremental sweeps.
///      Effective only after the next `VACUUM` converts the page layout.
///
///   2. `ANALYZE` — refreshes the query planner's column statistics.
///      Cheap (~ms on our scale). Run every launch so the planner picks
///      the right index when row distributions shift over time.
///
///   3. `VACUUM` — rebuilds the database to reclaim free pages and
///      defragment. Holds an EXCLUSIVE lock for the duration; on our
///      store (hundreds of MB at worst) takes seconds. Skip unless
///      we haven't done one in a while.
///
/// Runs from a `Task.detached(priority: .utility)` on app launch, after
/// `SwiftDataIndexes.ensure(at:)` lands. SQLite's `busy_timeout(5000)`
/// is set on the maintenance connection so concurrent SwiftData writers
/// don't immediately fail.
enum SwiftDataMaintenance {

    /// UserDefaults key recording the last successful VACUUM time
    /// (epoch seconds). Missing key = never run.
    static let lastVacuumKey = "yawac.lastDBVacuum"

    /// How often to VACUUM. Every-launch would burn user time + drive
    /// I/O for marginal benefit; once a month keeps the file tight
    /// without disrupting normal use.
    static let vacuumIntervalSeconds: TimeInterval = 30 * 24 * 3600

    @discardableResult
    static func maintainIfNeeded(at url: URL) -> Outcome {
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(url.path, &db,
                                     SQLITE_OPEN_READWRITE, nil)
        guard openRC == SQLITE_OK, let db else {
            NSLog("[yawac/maint] open failed rc=%d path=%@",
                  openRC, url.path)
            if let db { sqlite3_close(db) }
            return .openFailed
        }
        defer { sqlite3_close(db) }

        // F84 pattern: wait up to 5s for the lock instead of immediately
        // failing if a SwiftData writer is in flight. Bump to 30s here
        // because VACUUM holds EXCLUSIVE for the whole rebuild.
        _ = sqlite3_exec(db, "PRAGMA busy_timeout=30000;", nil, nil, nil)

        // Persistent header pragma — runs once even if reused. Takes
        // effect on the next VACUUM, which we do below if due.
        _ = sqlite3_exec(db, "PRAGMA auto_vacuum=INCREMENTAL;",
                         nil, nil, nil)

        // Cheap; run every launch.
        let analyzeRC = sqlite3_exec(db, "ANALYZE;", nil, nil, nil)
        let analyzed = analyzeRC == SQLITE_OK
        if !analyzed {
            let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "?"
            NSLog("[yawac/maint] ANALYZE failed rc=%d msg=%@",
                  analyzeRC, msg)
        }

        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastVacuumKey)
        let dueForVacuum = (last == 0) || (now - last > vacuumIntervalSeconds)

        var vacuumed = false
        if dueForVacuum {
            NSLog("[yawac/maint] running VACUUM (last=%.0f now=%.0f)",
                  last, now)
            // VACUUM holds an EXCLUSIVE lock; the busy_timeout above
            // gives SwiftData writers a chance to drain. Even at our
            // worst-case size this completes in a few seconds.
            let vacRC = sqlite3_exec(db, "VACUUM;", nil, nil, nil)
            if vacRC == SQLITE_OK {
                UserDefaults.standard.set(now, forKey: lastVacuumKey)
                vacuumed = true
                NSLog("[yawac/maint] VACUUM ok")
            } else {
                let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "?"
                NSLog("[yawac/maint] VACUUM failed rc=%d msg=%@",
                      vacRC, msg)
            }
        } else {
            NSLog("[yawac/maint] VACUUM skipped (last=%.0f delta=%.0fs interval=%.0fs)",
                  last, now - last, vacuumIntervalSeconds)
        }

        return Outcome(opened: true,
                       analyzed: analyzed,
                       vacuumed: vacuumed,
                       autoVacuumInstalled: true)
    }

    struct Outcome {
        var opened: Bool = false
        var analyzed: Bool = false
        var vacuumed: Bool = false
        var autoVacuumInstalled: Bool = false
        static let openFailed = Outcome(opened: false)
    }
}
