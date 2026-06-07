import AppKit
import Observation

/// In-memory thumbnail cache for image and sticker bubbles.
///
/// SwiftUI bodies must remain cheap; decoding `NSImage(contentsOfFile:)`
/// inline re-decodes the same files on every scroll / re-render. This cache
/// hands back cached `NSImage`s synchronously on hit, and schedules a
/// background decode on miss. Once the decode lands, `revision` is bumped,
/// which (because this is an `@Observable`) re-runs any view body that read
/// `revision` and lets the bubble pick up the now-cached image.
@MainActor
@Observable
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        c.totalCostLimit = 64 * 1024 * 1024  // ~64 MB of NSImage backing
        return c
    }()
    private var inflight: Set<String> = []
    /// Bumped whenever a decoded image is stored. Views that read this
    /// participate in observation and will re-render when new images arrive.
    private(set) var revision: Int = 0

    /// Returns a cached `NSImage` for `path` if present.
    /// On miss, schedules a detached background decode and returns `nil`;
    /// once the decode completes the cache stores the result and bumps
    /// `revision` so observers redraw.
    func image(forPath path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        if inflight.contains(path) { return nil }
        inflight.insert(path)
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = NSImage(contentsOfFile: path)
            await self?.store(path: path, image: img)
        }
        return nil
    }

    private func store(path: String, image: NSImage?) {
        inflight.remove(path)
        guard let image else { return }
        // Rough memory cost in bytes — actual NSImage backing varies but
        // width*height*4 (RGBA) is a reasonable upper-bound proxy. Bounded
        // by countLimit in any case.
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: path as NSString, cost: cost)
        revision &+= 1
    }
}
