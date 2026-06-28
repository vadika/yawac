import AppKit
import CoreGraphics
import ImageIO
import Observation

/// Downsample-decode an image at `path` to at most `maxPixel` on the
/// long edge into a fully-rasterised NSImage that CoreAnimation can draw
/// in one step.
///
/// Two problems this solves:
/// 1. `NSImage(contentsOfFile:)` returns a lazy NSImage whose JPEG bytes
///    decompress on `CA::Transaction::commit` — visible as a blink when
///    LazyVStack instantiates a row during scroll.
/// 2. Full-resolution decode of a 12 MP phone JPEG is ~48 MB of RGBA
///    pixels. With `cache.totalCostLimit = 64 MB`, NSCache holds 1-2
///    full-res images and evicts aggressively — the three on-screen
///    image bubbles compete for slots, missing each other's cache
///    entries on every redraw and forcing repeated re-decodes (~750
///    wake/s on a group chat with 3 large pics in view).
///
/// `CGImageSourceCreateThumbnailAtIndex` does the decode and the
/// downsample in a single ImageIO pass. The resulting CGImage is
/// bitmap-backed (no lazy JPEG provider) so CoreAnimation blits
/// straight to the IOSurface without re-decoding.
func decodedImage(fromFile path: String, maxPixel: Int) -> NSImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// Same downsample-decode path for in-memory Data blobs (snapshot preheat).
func decodedImage(fromData data: Data, maxPixel: Int) -> NSImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

// Target pixel sizes per surface. Display points × 2 covers retina; one
// extra factor of headroom keeps small upscales sharp without paying for
// 4x area on every cache entry.
private let imageBubbleMaxPixel = 720      // 320pt bubble → ~2.25x
private let stickerBubbleMaxPixel = 360    // 160pt bubble
private let avatarMaxPixel = 200           // 80pt max avatar
private let videoThumbMaxPixel = 720

/// In-memory thumbnail cache for image and sticker bubbles.
///
/// SwiftUI bodies must remain cheap; decoding `NSImage(contentsOfFile:)`
/// inline re-decodes the same files on every scroll / re-render. This cache
/// hands back cached `NSImage`s synchronously on hit, and schedules a
/// background decode on miss. Once the decode lands, the corresponding
/// per-type revision is bumped, which (because this is an `@Observable`)
/// re-runs any view body that read that revision and lets the bubble pick
/// up the now-cached image.
@MainActor
@Observable
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Off-MainActor decode entry point used by `buildHistorySnapshot`
    /// so the ImageIO downsample runs on the background task building
    /// the snapshot instead of blocking MainActor in
    /// `applyHistorySnapshot`. The free `decodedImage(fromData:...)`
    /// helper isn't actor-isolated; `nonisolated` here just makes that
    /// contract explicit for callers.
    nonisolated static func decode(data: Data, maxPixel: Int) -> NSImage? {
        decodedImage(fromData: data, maxPixel: maxPixel)
    }

    /// Pixel caps exposed for callers that decode off-MainActor (the
    /// snapshot builder). Mirror the file-private constants below.
    static let imageBubbleMaxPixelExternal = 720
    static let videoThumbMaxPixelExternal = 720
    static let avatarMaxPixelExternal = 200

    init() {}

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // F31: bumped 256 / 64 MB → 1024 / 256 MB. The extendedHistoryLimit
        // bump to 10000 means a single chat-open can paint thousands of
        // image bubbles; previous countLimit triggered eviction storms
        // → re-decode → revision bumps → re-paint = visible flicker.
        c.countLimit = 1024
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()
    /// Separate NSCache for video bubble thumbnails. Decoded PNGs from
    /// the SHA disk cache are tiny (480x480 cap) and we want many of
    /// them resident — a chat with lots of forwarded clips can blow
    /// past 256 entries quickly. Lower per-image cost lets us pack the
    /// budget tighter without evicting decoded images bubbles still
    /// need on screen.
    private let videoCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // F31: bumped 256 / 32 MB → 1024 / 128 MB for the same reason
        // as the image cache above.
        c.countLimit = 1024
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()
    // Must be @ObservationIgnored. The @Observable macro otherwise tracks
    // every `var` and the inflight insert/remove inside `image(forPath:)` /
    // `storeXxx` triggers willSet → ObservationCenter.invalidate → body
    // re-eval → another inflight insert → ... runaway CPU loop (sampled
    // post-v0.9.35 at 146% CPU with main thread stuck in
    // ObservationRegistrar.willSet). Only `revision` should be observed.
    @ObservationIgnored private var inflight: Set<String> = []
    @ObservationIgnored private var videoInflight: Set<String> = []
    /// Per-cache-type revisions, bumped when a burst of decoded
    /// images settles in that cache. Views that read one of these
    /// participate in observation and re-render when new images of
    /// that kind arrive. Split (was a single shared `revision` until
    /// F39+) so an avatar landing doesn't wake every image bubble
    /// (and vice versa) — previously every decode of any kind
    /// re-evaluated every cache-aware body, which on a chat with
    /// 100+ visible rows + active avatar fetches showed up as full
    /// re-paint storms (the "all media bubbles blink" symptom).
    /// Coalesced via `scheduleBump(_:)` so N near-simultaneous
    /// decodes of the same kind produce a single re-render.
    private(set) var imageRevision: Int = 0
    private(set) var videoRevision: Int = 0
    private(set) var avatarRevision: Int = 0
    /// In-flight 50ms coalescing tasks per cache type.
    /// `@ObservationIgnored` keeps these out of the observation
    /// graph — touching them must not invalidate views (per the
    /// `@Observable var` trap: any tracked `var` mutated during a
    /// body eval triggers willSet → invalidate → re-body → ...
    /// runaway loop).
    @ObservationIgnored private var pendingImageBump: Task<Void, Never>?
    @ObservationIgnored private var pendingVideoBump: Task<Void, Never>?
    @ObservationIgnored private var pendingAvatarBump: Task<Void, Never>?

    private enum Bumper { case image, video, avatar }

    /// Returns a cached `NSImage` for `path` if present.
    /// On miss, schedules a detached background decode and returns `nil`;
    /// once the decode completes the cache stores the result and schedules
    /// a coalesced `revision` bump so observers redraw.
    func image(forPath path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        if inflight.contains(path) { return nil }
        inflight.insert(path)
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = decodedImage(fromFile: path, maxPixel: imageBubbleMaxPixel)
            await self?.store(path: path, image: img)
        }
        return nil
    }

    /// Returns a cached video thumbnail `NSImage` for the source video
    /// `path` (NOT the SHA disk-cache PNG path — the cache translates
    /// internally). On miss, schedules a detached load that consults
    /// the existing SHA disk cache first and falls back to AVAsset
    /// generation only if no PNG is on disk. Once the load completes
    /// the cache stores the result and schedules a coalesced `revision`
    /// bump shared with `image(forPath:)` so observers redraw.
    func videoImage(forPath path: String) -> NSImage? {
        if let hit = videoCache.object(forKey: path as NSString) { return hit }
        if videoInflight.contains(path) { return nil }
        videoInflight.insert(path)
        Task.detached(priority: .userInitiated) { [weak self] in
            // generateThumb chains disk-cache → AVAsset generate, exactly
            // what the old view's `.task` did — kept off MainActor so the
            // SHA hash + file read + (worst case) AVAssetImageGenerator
            // spin-up never block the UI.
            let img = await VideoThumbnailView.generateThumb(path: path)
            await self?.storeVideo(path: path, image: img)
        }
        return nil
    }

    /// Store already-decoded `NSImage` entries keyed by absolute file
    /// path. Called by `ConversationViewModel.applyHistorySnapshot` to
    /// warm the cache for the visible bottom window of messages BEFORE
    /// the LazyVStack starts laying out. Decode happens off-MainActor
    /// inside `buildHistorySnapshot` (the prior version called the
    /// ImageIO downsample synchronously here on main, freezing the UI
    /// 600-1200ms on chat switch). No revision bump — preheat happens
    /// before `self.messages` is assigned, so the first body eval sees
    /// the cache populated and the implicit observation read is enough.
    func preheat(_ pairs: [String: PreheatImage]) {
        for (path, holder) in pairs {
            if cache.object(forKey: path as NSString) != nil { continue }
            let img = holder.image
            let cost = Int(img.size.width * img.size.height * 4)
            cache.setObject(img, forKey: path as NSString, cost: cost)
        }
    }

    /// Store pre-decoded video thumbnail `NSImage` entries into the
    /// video cache, keyed by SOURCE video path (not the SHA PNG
    /// path). Same no-revision-bump contract as `preheat(_:)`: called
    /// from `applyHistorySnapshot` BEFORE `self.messages` lands.
    /// Decode runs off-MainActor in the snapshot builder.
    func preheatVideo(_ pairs: [String: PreheatImage]) {
        for (path, holder) in pairs {
            if videoCache.object(forKey: path as NSString) != nil { continue }
            let img = holder.image
            let cost = Int(img.size.width * img.size.height * 4)
            videoCache.setObject(img, forKey: path as NSString, cost: cost)
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
        scheduleBump(.image)
    }

    private func storeVideo(path: String, image: NSImage?) {
        videoInflight.remove(path)
        guard let image else { return }
        let cost = Int(image.size.width * image.size.height * 4)
        videoCache.setObject(image, forKey: path as NSString, cost: cost)
        scheduleBump(.video)
    }

    /// Coalesces decode-completion notifications into a single 50ms-
    /// debounced bump of the matching per-type revision. Without
    /// debounce, N visible bubbles each fire a separate decode → N
    /// revision bumps → N re-renders spread across successive frames
    /// = flicker as images pop in one-by-one. With debounce, sub-50ms
    /// bursts settle into one re-render and bubbles populate together.
    private func scheduleBump(_ which: Bumper) {
        switch which {
        case .image:
            guard pendingImageBump == nil else { return }
            pendingImageBump = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.pendingImageBump = nil
                self.imageRevision &+= 1
            }
        case .video:
            guard pendingVideoBump == nil else { return }
            pendingVideoBump = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.pendingVideoBump = nil
                self.videoRevision &+= 1
            }
        case .avatar:
            guard pendingAvatarBump == nil else { return }
            pendingAvatarBump = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.pendingAvatarBump = nil
                self.avatarRevision &+= 1
            }
        }
    }

    // MARK: - Avatars

    /// Per-person NSImage cache keyed by the canonical JID cache key.
    /// `AvatarView` is on every chat row and every message row in a
    /// group thread — keeping decoded NSImages resident avoids
    /// redundant disk + decode on every scroll. countLimit 512 covers
    /// large group threads; the 16 MB byte budget caps memory.
    private let avatarCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // F31: bumped 512 / 16 MB → 4096 / 64 MB. After the
        // extendedHistoryLimit bump to 10000, a single chat-open in a
        // large group renders an avatar per message — thousands of
        // distinct senders. Previous countLimit blew its budget and
        // every scroll re-evicted half the visible avatars, looking
        // exactly like "all avatars blinking" the user reported.
        c.countLimit = 4096
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()
    @ObservationIgnored private var avatarInflight: Set<String> = []
    /// JIDs that came back without a profile picture (status@broadcast
    /// posters frequently have no avatar). Without this, every body eval
    /// for such a row missed the cache → kicked another fetch → fetch
    /// returned nil → storeAvatar dropped it → next body eval missed
    /// again. Loop pinned the main thread at ~750 wake/s with CA
    /// constantly re-decoding the visible JPEG thumbnails. Negative
    /// entries skip both the cache lookup and the fetch.
    @ObservationIgnored private var avatarNegative: Set<String> = []

    /// Returns the cached avatar `NSImage` for `key` (a canonical JID
    /// cache key — caller's responsibility to canonicalize). On miss,
    /// schedules a detached load: try the on-disk file
    /// (`AvatarCache.cachedURL`) first; if absent, fall back to the
    /// supplied `fetcher` closure which is expected to go through
    /// `AvatarCache.shared.ensure(jid:using:)` (the actor + bridge
    /// path). Once the decode lands the cache stores the result and
    /// schedules a coalesced `revision` bump shared with the image and
    /// video caches.
    ///
    /// The closure exists so `ThumbnailCache` doesn't need to know
    /// about `WAClient` — the view passes its session client in.
    func avatarImage(forCacheKey key: String,
                     fetcher: @escaping @Sendable () async -> URL?) -> NSImage? {
        if let hit = avatarCache.object(forKey: key as NSString) { return hit }
        if avatarNegative.contains(key) { return nil }
        if avatarInflight.contains(key) { return nil }
        avatarInflight.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            // Disk fast path: existing AvatarCache.cachedURL is
            // nonisolated static, safe to call from any thread.
            // decodedImage(fromFile:) forces the JPEG decode here so the
            // cached NSImage hands a pre-rasterised CGImage to CA on the
            // first draw — eliminates the per-row scroll blink.
            let img: NSImage? = await {
                if let url = AvatarCache.cachedURL(for: key),
                   FileManager.default.fileExists(atPath: url.path),
                   let i = decodedImage(fromFile: url.path, maxPixel: avatarMaxPixel) {
                    return i
                }
                guard let url = await fetcher() else { return nil }
                return decodedImage(fromFile: url.path, maxPixel: avatarMaxPixel)
            }()
            await self?.storeAvatar(key: key, image: img)
        }
        return nil
    }

    private func storeAvatar(key: String, image: NSImage?) {
        avatarInflight.remove(key)
        guard let image else {
            // No profile picture available — remember so we don't refetch
            // on every body eval. Cleared by `invalidateAvatar` when the
            // user updates their picture (avatarCacheInvalidated event).
            avatarNegative.insert(key)
            return
        }
        let cost = Int(image.size.width * image.size.height * 4)
        avatarCache.setObject(image, forKey: key as NSString, cost: cost)
        scheduleBump(.avatar)
    }

    /// Drop the cached avatar for `key` so the next body eval misses
    /// and the load path re-runs (after the on-disk file has been
    /// removed by `AvatarCache.invalidate(jid:)`).
    func invalidateAvatar(forCacheKey key: String) {
        avatarCache.removeObject(forKey: key as NSString)
        avatarInflight.remove(key)
        avatarNegative.remove(key)
        scheduleBump(.avatar)
    }

    /// Store pre-decoded avatar `NSImage` entries keyed by canonical
    /// JID cache key. Called by `applyHistorySnapshot` before
    /// `self.messages` lands so every `AvatarView`'s first body eval
    /// hits the in-memory cache. Decode runs off-MainActor in the
    /// snapshot builder.
    func preheatAvatar(_ pairs: [String: PreheatImage]) {
        for (key, holder) in pairs {
            if avatarCache.object(forKey: key as NSString) != nil { continue }
            let img = holder.image
            let cost = Int(img.size.width * img.size.height * 4)
            avatarCache.setObject(img, forKey: key as NSString, cost: cost)
        }
    }

    // MARK: - Maps

    /// NSImage cache for the location-bubble map snapshot keyed by
    /// `"lat,lng"`. The underlying `MapSnapshotCache` already has its
    /// own memory + disk layers, but every location bubble's
    /// `.task(id:)` re-runs on body recreation and the actor hop +
    /// hash format alone shows up in scroll profiles. countLimit 64
    /// covers a busy chat's worth of pins; 32 MB budget caps memory.
    private let mapCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        c.totalCostLimit = 32 * 1024 * 1024
        return c
    }()
    @ObservationIgnored private var mapInflight: Set<String> = []
    /// Coordinates whose MKMapSnapshotter call returned nil. Without this,
    /// the next body eval would miss the positive cache, skip the inflight
    /// gate (already cleared), and re-queue the same snapshot generator —
    /// per frame. Same shape as `avatarNegative` (F15). Cleared only if
    /// the snapshot is explicitly invalidated.
    @ObservationIgnored private var mapNegative: Set<String> = []

    /// Returns the cached map snapshot `NSImage` for `(lat, lng)`. On
    /// miss, schedules a detached load through `MapSnapshotCache` and
    /// returns nil; the coalesced `revision` bump wakes observers once
    /// the snapshot lands.
    func mapImage(lat: Double, lng: Double) -> NSImage? {
        let key = "\(lat),\(lng)"
        if let hit = mapCache.object(forKey: key as NSString) { return hit }
        if mapNegative.contains(key) { return nil }
        if mapInflight.contains(key) { return nil }
        mapInflight.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = await MapSnapshotCache.shared.snapshot(lat: lat, lng: lng)
            await self?.storeMap(key: key, image: img)
        }
        return nil
    }

    private func storeMap(key: String, image: NSImage?) {
        mapInflight.remove(key)
        guard let image else {
            // MKMapSnapshotter failed (offline, invalid coord, etc).
            // Remember so we don't re-fire the snapshotter on every
            // body eval.
            mapNegative.insert(key)
            return
        }
        let cost = Int(image.size.width * image.size.height * 4)
        mapCache.setObject(image, forKey: key as NSString, cost: cost)
        // Map snapshots ride the image revision — no observer reads
        // a dedicated map revision and the map cache landings are
        // rare enough that piggybacking on imageRevision is fine.
        scheduleBump(.image)
    }
}
