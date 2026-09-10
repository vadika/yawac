import XCTest
import AppKit
@testable import yawac

@MainActor
final class ThumbnailCacheTests: XCTestCase {
    func testSharedLoadSurvivesOneWaiterCancellationAndWarmsMemory() async {
        actor Loader {
            var calls = 0
            let image = NSImage(size: NSSize(width: 10, height: 10))
            func load() async -> NSImage? {
                calls += 1
                try? await Task.sleep(for: .milliseconds(20))
                return image
            }
        }
        let loader = Loader()
        let cache = ThumbnailCache(imageLoader: { _ in await loader.load() })
        XCTAssertNil(cache.image(forPath: "shared"))
        let first = Task { await cache.loadImage(path: "shared") }
        let second = Task { await cache.loadImage(path: "shared") }
        first.cancel()
        let image = await second.value
        _ = await first.value
        XCTAssertNotNil(image)
        XCTAssertTrue(cache.image(forPath: "shared") === image)
        let count = await loader.calls
        XCTAssertEqual(count, 1)
        _ = await cache.loadImage(path: "shared")
        let warmCount = await loader.calls
        XCTAssertEqual(warmCount, 1)
    }

    func testAvatarNegativeCacheCanBeInvalidated() async {
        actor Fetcher {
            var calls = 0
            func fetch() -> URL? { calls += 1; return nil }
        }
        let fetcher = Fetcher()
        let cache = ThumbnailCache()
        let key = UUID().uuidString
        _ = await cache.loadAvatar(key: key) { await fetcher.fetch() }
        _ = await cache.loadAvatar(key: key) { await fetcher.fetch() }
        let before = await fetcher.calls
        XCTAssertEqual(before, 1)
        cache.invalidateAvatar(forCacheKey: key)
        _ = await cache.loadAvatar(key: key) { await fetcher.fetch() }
        let after = await fetcher.calls
        XCTAssertEqual(after, 2)
    }

    func testColdDecodeIsBoundedAndWarmLookupDoesNotDecodeAgain() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: path) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600,
            pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        let cache = ThumbnailCache()
        let start = Date()
        let cold = await cache.loadImage(path: path.path)
        XCTAssertNotNil(cold)
        XCTAssertLessThanOrEqual(cold?.size.width ?? 0, 720)
        for _ in 0..<1000 { XCTAssertTrue(cache.image(forPath: path.path) === cold) }
        print("thumbnail benchmark: 1600x1200 cold decode + 1000 memory hits, \(Date().timeIntervalSince(start)) seconds")
    }
}
