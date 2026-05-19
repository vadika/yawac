import Foundation

actor AvatarCache {
    static let shared = AvatarCache()
    private var inflight: [String: Task<URL?, Never>] = [:]
    private var negativeCache: Set<String> = []
    private let baseDir: URL

    init() {
        let mediaBase = (try? AppPaths.mediaCacheURL()) ??
                        URL(filePath: NSTemporaryDirectory())
        let dir = mediaBase.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.baseDir = dir
    }

    private func file(for jid: String) -> URL {
        // Sanitize JID for filename (replace @ and / with _)
        let safe = jid.replacingOccurrences(of: "@", with: "_")
                      .replacingOccurrences(of: "/", with: "_")
                      .replacingOccurrences(of: ":", with: "_")
        return baseDir.appendingPathComponent("\(safe).jpg")
    }

    func ensure(jid: String, using client: WAClient) async -> URL? {
        if negativeCache.contains(jid) { return nil }
        let url = file(for: jid)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let t = inflight[jid] { return await t.value }

        let task: Task<URL?, Never> = Task { @MainActor in
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
