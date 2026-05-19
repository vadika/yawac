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

    enum Result {
        case file(URL)
        case missingRef
        case failed(String)
    }

    /// Returns a local URL for the media of `messageID`. If `refJSON` is non-nil
    /// and the file doesn't exist yet, kicks off a download via the bridge.
    /// Returns `.failed` with a reason on download error so callers can surface it.
    func ensure(messageID: String, ext: String,
                refJSON: String?, using client: WAClient) async -> Result {
        let url = file(for: messageID, ext: ext)
        if FileManager.default.fileExists(atPath: url.path) { return .file(url) }
        guard let refJSON else { return .missingRef }
        if let t = inflight[messageID] {
            do { return .file(try await t.value) }
            catch { return .failed(error.localizedDescription) }
        }
        let task = Task<URL, Error>.detached(priority: .userInitiated) {
            _ = try client.downloadMedia(refJSON, to: url.path)
            return url
        }
        inflight[messageID] = task
        defer { inflight[messageID] = nil }
        do {
            return .file(try await task.value)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
