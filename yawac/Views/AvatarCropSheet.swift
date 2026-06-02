import SwiftUI
import AppKit

/// Modal sheet that lets the user pan + zoom an image inside a circular
/// mask, then exports the masked rectangle as a 640×640 JPEG.
struct AvatarCropSheet: View {
    let original: NSImage
    var onApply: (Data) -> Void
    var onCancel: () -> Void

    @State private var zoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    private let cropSize: CGFloat = 240

    var body: some View {
        VStack(spacing: 14) {
            Text("Crop photo")
                .scaledUI(13, weight: .semibold)
                .foregroundStyle(Theme.text)
            cropArea
            Slider(value: $zoom, in: 1.0...3.0)
                .frame(width: cropSize)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                Button("Apply") {
                    if let data = render() { onApply(data) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    @ViewBuilder
    private var cropArea: some View {
        ZStack {
            Image(nsImage: original)
                .resizable()
                .scaledToFill()
                .scaleEffect(zoom)
                .offset(pan)
                .frame(width: cropSize, height: cropSize)
                .clipped()
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            pan = CGSize(
                                width: dragStart.width + v.translation.width,
                                height: dragStart.height + v.translation.height)
                        }
                        .onEnded { _ in dragStart = pan }
                )
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
                .frame(width: cropSize, height: cropSize)
                .allowsHitTesting(false)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Renders the on-screen cropped area into a 640×640 JPEG.
    private func render() -> Data? {
        let outSize: CGFloat = 640
        let scale = outSize / cropSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(outSize), pixelsHigh: Int(outSize),
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: outSize, height: outSize).fill()
        let imgSize = original.size
        let drawW = imgSize.width * scale * zoom
        let drawH = imgSize.height * scale * zoom
        let originX = (outSize - drawW) / 2 + pan.width * scale
        // NSImage origin is bottom-left; SwiftUI top-left. Invert the Y pan.
        let originY = (outSize - drawH) / 2 - pan.height * scale
        original.draw(
            in: NSRect(x: originX, y: originY, width: drawW, height: drawH),
            from: .zero, operation: .copy, fraction: 1.0)
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: 0.85])
    }
}
