import AVFoundation
import AppKit
import CryptoKit
import SwiftUI

/// Simple async-await semaphore. Caps how many AVAssetImageGenerator
/// jobs run at once; the file-scope `generateGate` instance is shared
/// across all VideoThumbnailView instances.
private actor AsyncSemaphore {
    private let limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { c in waiters.append(c) }
        // slot was transferred to us by release — no in-flight bump
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
            // slot stays in-flight — taken by resumed waiter
        } else {
            inFlight -= 1
        }
    }
}

struct VideoThumbnailView: View {
    let path: String

    var body: some View {
        // Read `revision` so SwiftUI subscribes to ThumbnailCache via
        // its @Observable conformance. When a miss completes (either
        // disk-cache fetch or AVAsset generate), the cache bumps
        // `revision` and this body re-evals, picking up the now-cached
        // NSImage. No per-instance @State + .task — that pattern
        // forced every bubble through a placeholder frame even on
        // disk-cache HIT (one frame of gray per bubble, landing on
        // different frames = flicker). The cache call itself kicks the
        // background load on miss; preheat in applyHistorySnapshot
        // fills the cache for the visible window before first paint.
        let cache = ThumbnailCache.shared
        let _ = cache.videoRevision
        ZStack {
            if let img = cache.videoImage(forPath: path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.gray.opacity(0.2)
            }
            Image(systemName: "play.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
    }

    // MARK: - Cache

    private static let cacheDir: URL = {
        let support = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("yawac/video-thumbs",
                                                 isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// SHA disk-cache PNG path for a video source `path`. Exposed
    /// `internal static` so `ConversationViewModel.buildHistorySnapshot`
    /// can probe / read the pre-existing PNG bytes off-MainActor for the
    /// in-memory `ThumbnailCache.preheatVideo` warm-up.
    static func cachePath(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".png"
        return cacheDir.appendingPathComponent(name)
    }

    private static func loadFromDisk(path: String) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let url = cachePath(for: path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let img = NSImage(data: data)
            else { return nil as NSImage? }
            return img
        }.value
    }

    /// Public entry point for non-view callers (e.g. ReplyPreview).
    /// Same disk-cache fast path as the view's `.task`.
    static func generateThumb(path: String) async -> NSImage? {
        if let cached = await loadFromDisk(path: path) { return cached }
        return await generateAndCache(path: path)
    }

    /// Caps how many AVAssetImageGenerator pipelines spin up at once.
    /// Profile snapshot showed seven parallel spin-ups on a single chat
    /// switch — each one builds its own VMC2 decompressor + render
    /// pipeline, which clobbers the main thread. Two-at-a-time keeps
    /// generation progressing without contention.
    private static let generateGate: AsyncSemaphore = AsyncSemaphore(limit: 2)

    private static func generateAndCache(path: String) async -> NSImage? {
        await generateGate.acquire()
        defer { Task { await generateGate.release() } }
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let cgImage: CGImage
            if #available(macOS 13.0, *) {
                cgImage = try await generator.image(at: time).image
            } else {
                var actualTime = CMTime.zero
                cgImage = try generator.copyCGImage(at: time, actualTime: &actualTime)
            }
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            // Persist to disk so the next open of this chat (or
            // adjacent scroll) skips the AVAsset spin-up entirely.
            Task.detached(priority: .utility) {
                let dst = cachePath(for: path)
                let rep = NSBitmapImageRep(cgImage: cgImage)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dst, options: .atomic)
                }
            }
            return nsImage
        } catch {
            return nil
        }
    }
}
