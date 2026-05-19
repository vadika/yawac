import Foundation

/// Singleton actor that owns the on-disk media cache directory.
/// Downloads via WAClient are wired up here so concurrent renders
/// of the same message ID share a single in-flight task.
actor MediaCache {
    static let shared = MediaCache()
    private var inflight: [String: Task<URL, Error>] = [:]
    private let baseDir: URL

    init() {
        self.baseDir = (try? AppPaths.mediaCacheURL()) ??
                       URL(filePath: NSTemporaryDirectory())
    }

    func file(for messageID: String, ext: String) -> URL {
        baseDir.appendingPathComponent("\(messageID).\(ext)")
    }

    /// Returns a local URL for the media of `messageID`. If `refJSON` is non-nil
    /// and the file doesn't exist yet, kicks off a download via the bridge.
    /// Otherwise returns the file URL if it exists or nil.
    func ensure(messageID: String, ext: String,
                refJSON: String?, using client: WAClient) async -> URL? {
        let url = file(for: messageID, ext: ext)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let refJSON else { return nil }
        if let t = inflight[messageID] {
            return try? await t.value
        }
        let task = Task<URL, Error> {
            try await MainActor.run {
                _ = try client.downloadMedia(refJSON, to: url.path)
            }
            return url
        }
        inflight[messageID] = task
        defer { inflight[messageID] = nil }
        return try? await task.value
    }
}
