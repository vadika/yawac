import SwiftUI

/// Memory hits paint immediately; a cold result updates only this view.
struct ResourceThumbnail<Content: View>: View {
    enum Source: Hashable {
        case image(String)
        case video(String)
        case map(Double, Double)
    }
    let source: Source
    @ViewBuilder let content: (NSImage?) -> Content
    @State private var loadedSource: Source?
    @State private var loadedImage: NSImage?

    private var cached: NSImage? {
        let cache = ThumbnailCache.shared
        switch source {
        case .image(let path): return cache.image(forPath: path)
        case .video(let path): return cache.videoImage(forPath: path)
        case .map(let lat, let lng): return cache.mapImage(lat: lat, lng: lng)
        }
    }

    var body: some View {
        content(cached ?? (loadedSource == source ? loadedImage : nil))
            .task(id: source) {
                let cache = ThumbnailCache.shared
                let result: NSImage?
                switch source {
                case .image(let path): result = await cache.loadImage(path: path)
                case .video(let path): result = await cache.loadVideo(path: path)
                case .map(let lat, let lng): result = await cache.loadMap(lat: lat, lng: lng)
                }
                guard !Task.isCancelled else { return }
                loadedSource = source
                loadedImage = result
            }
    }
}
