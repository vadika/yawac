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

/// Shared decoded images and shared loads; views own delivery of each result.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    nonisolated static let imageBubbleMaxPixelExternal = 720
    nonisolated static let videoThumbMaxPixelExternal = 720
    nonisolated static let avatarMaxPixelExternal = 200
    nonisolated static func decode(data: Data, maxPixel: Int) -> NSImage? {
        decodedImage(fromData: data, maxPixel: maxPixel)
    }

    private let images = ThumbnailCache.cache(count: 1024, megabytes: 256)
    private let videos = ThumbnailCache.cache(count: 1024, megabytes: 128)
    private let avatars = ThumbnailCache.cache(count: 4096, megabytes: 64)
    private let maps = ThumbnailCache.cache(count: 64, megabytes: 32)
    private var imageLoads: [String: Task<NSImage?, Never>] = [:]
    private var videoLoads: [String: Task<NSImage?, Never>] = [:]
    private var avatarLoads: [String: (id: UUID, task: Task<NSImage?, Never>)] = [:]
    private var mapLoads: [String: (id: UUID, task: Task<NSImage?, Never>)] = [:]
    private var avatarNegative: Set<String> = []
    private var mapNegative: Set<String> = []
    private let imageLoader: @Sendable (String) async -> NSImage?

    init(imageLoader: @Sendable @escaping (String) async -> NSImage? = { path in
        await Task.detached(priority: .userInitiated) {
            decodedImage(fromFile: path, maxPixel: 720)
        }.value
    }) { self.imageLoader = imageLoader }

    private static func cache(count: Int, megabytes: Int) -> NSCache<NSString, NSImage> {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = count
        cache.totalCostLimit = megabytes * 1024 * 1024
        return cache
    }
    private func store(_ image: NSImage?, key: String, in cache: NSCache<NSString, NSImage>) {
        guard let image else { return }
        cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
    }

    // Pure memory lookups are safe during SwiftUI body evaluation.
    func image(forPath path: String) -> NSImage? { images.object(forKey: path as NSString) }
    func videoImage(forPath path: String) -> NSImage? { videos.object(forKey: path as NSString) }
    func avatarImage(forCacheKey key: String) -> NSImage? { avatars.object(forKey: key as NSString) }
    func mapImage(lat: Double, lng: Double) -> NSImage? { maps.object(forKey: "\(lat),\(lng)" as NSString) }

    func loadImage(path: String) async -> NSImage? {
        if let image = image(forPath: path) { return image }
        if let task = imageLoads[path] { return await task.value }
        let task = Task {
            let image = await imageLoader(path)
            store(image, key: path, in: images)
            imageLoads[path] = nil
            return image
        }
        imageLoads[path] = task
        return await task.value
    }

    func loadVideo(path: String) async -> NSImage? {
        if let image = videoImage(forPath: path) { return image }
        if let task = videoLoads[path] { return await task.value }
        let task = Task {
            let image = await Task.detached(priority: .userInitiated) {
                await VideoThumbnailView.generateThumb(path: path)
            }.value
            store(image, key: path, in: videos)
            videoLoads[path] = nil
            return image
        }
        videoLoads[path] = task
        return await task.value
    }

    func loadAvatar(key: String, fetcher: @escaping @Sendable () async -> URL?) async -> NSImage? {
        if let image = avatarImage(forCacheKey: key) { return image }
        if avatarNegative.contains(key) { return nil }
        if let load = avatarLoads[key] { return await load.task.value }
        let id = UUID()
        let task = Task {
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                if let url = AvatarCache.cachedURL(for: key),
                   let image = decodedImage(fromFile: url.path, maxPixel: 200) { return image }
                guard let url = await fetcher() else { return nil as NSImage? }
                return decodedImage(fromFile: url.path, maxPixel: 200)
            }.value
            guard avatarLoads[key]?.id == id else { return nil as NSImage? }
            avatarLoads[key] = nil
            if image == nil { avatarNegative.insert(key) }
            store(image, key: key, in: avatars)
            return image
        }
        avatarLoads[key] = (id, task)
        return await task.value
    }

    func invalidateAvatar(forCacheKey key: String) {
        avatars.removeObject(forKey: key as NSString)
        avatarNegative.remove(key)
        avatarLoads[key] = nil // Old completions cannot populate this generation.
    }

    func loadMap(lat: Double, lng: Double) async -> NSImage? {
        let key = "\(lat),\(lng)"
        if let image = mapImage(lat: lat, lng: lng) { return image }
        if mapNegative.contains(key) { return nil }
        if let load = mapLoads[key] { return await load.task.value }
        let id = UUID()
        let task = Task {
            let image = await MapSnapshotCache.shared.snapshot(lat: lat, lng: lng)
            guard mapLoads[key]?.id == id else { return nil as NSImage? }
            mapLoads[key] = nil
            if image == nil { mapNegative.insert(key) }
            store(image, key: key, in: maps)
            return image
        }
        mapLoads[key] = (id, task)
        return await task.value
    }

    func invalidateMap(lat: Double, lng: Double) {
        let key = "\(lat),\(lng)"
        maps.removeObject(forKey: key as NSString)
        mapNegative.remove(key)
        mapLoads[key] = nil
    }

    func preheat(_ pairs: [String: PreheatImage]) {
        for (key, holder) in pairs where image(forPath: key) == nil { store(holder.image, key: key, in: images) }
    }
    func preheatVideo(_ pairs: [String: PreheatImage]) {
        for (key, holder) in pairs where videoImage(forPath: key) == nil { store(holder.image, key: key, in: videos) }
    }
    func preheatAvatar(_ pairs: [String: PreheatImage]) {
        for (key, holder) in pairs where avatarImage(forCacheKey: key) == nil { store(holder.image, key: key, in: avatars) }
    }
}
