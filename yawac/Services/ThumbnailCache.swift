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
    /// Bumped whenever a burst of decoded images settles. Views that read
    /// this participate in observation and will re-render when new images
    /// arrive. Coalesced via `scheduleRevisionBump()` so N near-simultaneous
    /// decodes produce a single re-render instead of N.
    private(set) var revision: Int = 0
    /// In-flight 50ms coalescing task. `@ObservationIgnored` keeps it out
    /// of the observation graph — touching it must not invalidate views.
    @ObservationIgnored private var pendingBump: Task<Void, Never>?

    /// Returns a cached `NSImage` for `path` if present.
    /// On miss, schedules a detached background decode and returns `nil`;
    /// once the decode completes the cache stores the result and schedules
    /// a coalesced `revision` bump so observers redraw.
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

    /// Synchronously decode and store raw file `Data` → `NSImage` entries.
    /// Called by `ConversationViewModel.applyHistorySnapshot` to warm the
    /// cache for the visible bottom window of messages BEFORE the
    /// LazyVStack starts laying out. No revision bump — preheat happens
    /// before `self.messages` is assigned, so the first body eval sees
    /// the cache populated and the implicit observation read is enough.
    func preheat(_ pairs: [String: Data]) {
        for (path, data) in pairs {
            if cache.object(forKey: path as NSString) != nil { continue }
            guard let img = NSImage(data: data) else { continue }
            let cost = Int(img.size.width * img.size.height * 4)
            cache.setObject(img, forKey: path as NSString, cost: cost)
        }
    }

    private func store(path: String, image: NSImage?) {
        inflight.remove(path)
        guard let image else { return }
        // Rough memory cost in bytes — actual NSImage backing varies but
        // width*height*4 (RGBA) is a reasonable upper-bound proxy. Bounded
        // by countLimit in any case.
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: path as NSString, cost: cost)
        scheduleRevisionBump()
    }

    /// Coalesces decode-completion notifications into a single 50ms-debounced
    /// `revision &+= 1`. Without this, N visible bubbles each fire a separate
    /// decode → N revision bumps → N re-renders spread across successive
    /// frames = flicker as images pop in one-by-one. With this, sub-50ms
    /// bursts settle into a single re-render and bubbles populate together.
    private func scheduleRevisionBump() {
        guard pendingBump == nil else { return }
        pendingBump = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.pendingBump = nil
            self.revision &+= 1
        }
    }
}
