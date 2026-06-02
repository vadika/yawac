import Foundation

extension Notification.Name {
    /// Posted by `AvatarCache.invalidate(jid:)` so on-screen `AvatarView`s
    /// for that JID re-fetch instead of staying stuck on a deleted file.
    /// userInfo["jid"] = String.
    static let avatarCacheInvalidated =
        Notification.Name("yawac.AvatarCacheInvalidated")
}

actor AvatarCache {
    static let shared = AvatarCache()
    private var inflight: [String: Task<URL?, Never>] = [:]
    private var negativeCache: Set<String> = []
    private let baseDir: URL
    // Throttle concurrent profile-picture HTTP calls — too many in
    // flight at once trips WhatsApp's 429 IQ rate limiter (no global
    // IQ throttle on the bridge side; see docs/TODO.md "Rate limits").
    private let semaphore = AvatarSemaphore(limit: 4)

    init() {
        let mediaBase = (try? AppPaths.mediaCacheURL()) ??
                        URL(filePath: NSTemporaryDirectory())
        let dir = mediaBase.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.baseDir = dir
    }

    /// Returns the deterministic cache URL for a JID (file may not
    /// exist). Public + nonisolated so SwiftUI views can sync-probe
    /// without an actor hop.
    nonisolated static func cachedURL(for jid: String) -> URL? {
        let fm = FileManager.default
        guard let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: false) else {
            return nil
        }
        let dir = caches.appendingPathComponent("yawac-media/avatars",
                                                isDirectory: true)
        let safe = jid.replacingOccurrences(of: "@", with: "_")
                      .replacingOccurrences(of: "/", with: "_")
                      .replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent("\(safe).jpg")
    }

    private func file(for jid: String) -> URL {
        // Sanitize JID for filename (replace @ and / with _)
        let safe = jid.replacingOccurrences(of: "@", with: "_")
                      .replacingOccurrences(of: "/", with: "_")
                      .replacingOccurrences(of: ":", with: "_")
        return baseDir.appendingPathComponent("\(safe).jpg")
    }

    /// Drop the on-disk cache + negative-cache entry so the next ensure()
    /// re-fetches from the bridge. Broadcasts on the main thread so all
    /// `AvatarView`s for the same JID re-run their fetch task — without
    /// it, every on-screen avatar holding a stale URL would fall back to
    /// the initials placeholder (file deleted, NSImage(contentsOf:) nil).
    func invalidate(jid: String) {
        let url = file(for: jid)
        try? FileManager.default.removeItem(at: url)
        negativeCache.remove(jid)
        inflight[jid]?.cancel()
        inflight[jid] = nil
        let key = jid
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .avatarCacheInvalidated,
                object: nil,
                userInfo: ["jid": key])
        }
    }

    func ensure(jid: String, using client: WAClient) async -> URL? {
        if negativeCache.contains(jid) { return nil }
        let url = file(for: jid)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let t = inflight[jid] { return await t.value }

        let sem = semaphore
        let task: Task<URL?, Never> = Task.detached(priority: .utility) {
            await sem.acquire()
            defer { Task { await sem.release() } }
            do {
                let result = try client.fetchProfilePicture(jid: jid, outPath: url.path)
                return result.isEmpty ? nil : URL(filePath: result)
            } catch {
                return nil
            }
        }
        inflight[jid] = task
        let result = await task.value
        inflight[jid] = nil
        if result == nil { negativeCache.insert(jid) }
        return result
    }
}

// Counting semaphore for capping concurrent profile-picture fetches.
// Implemented as an actor so it's safe to share across detached tasks
// without locks. Acquire suspends until a permit is free; release
// either hands the permit to the longest-waiting task or returns it
// to the pool.
actor AvatarSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.permits = limit }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        if let w = waiters.first {
            waiters.removeFirst()
            w.resume()
        } else {
            permits += 1
        }
    }
}
