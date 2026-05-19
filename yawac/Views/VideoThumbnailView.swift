import AVFoundation
import SwiftUI

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
            self.thumb = await Self.generateThumb(path: path)
        }
    }

    static func generateThumb(path: String) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            if #available(macOS 13.0, *) {
                let cgImage = try await generator.image(at: time).image
                return NSImage(cgImage: cgImage, size: .zero)
            } else {
                var actualTime = CMTime.zero
                let cgImage = try generator.copyCGImage(at: time, actualTime: &actualTime)
                return NSImage(cgImage: cgImage, size: .zero)
            }
        } catch {
            return nil
        }
    }
}
