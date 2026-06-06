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
    @State private var thumb: NSImage?

    var body: some View {
        ZStack {
            if let thumb {
                Image(nsImage: thumb)
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
        .task(id: path) {
            if Task.isCancelled { return }
            // Check disk cache first — avoids the AVAsset spin-up which
            // hauls in `AVAssetInspectorLoader`, a render pipeline, and
            // a one-frame decompression session per bubble. On a chat
            // with N video bubbles this used to fire N times per open.
            if let cached = await Self.loadFromDisk(path: path) {
                self.thumb = cached
                return
            }
            if Task.isCancelled { return }
            let generated = await Self.generateAndCache(path: path)
            if Task.isCancelled { return }
            self.thumb = generated
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

    private static func cachePath(for path: String) -> URL {
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
