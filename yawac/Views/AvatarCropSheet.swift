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
                    if let data = render() {
                        onApply(data)
                    } else {
                        NSLog("[yawac/avatar-crop] render returned nil — Apply no-op")
                    }
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
        let outSize: Int = 640
        // hasAlpha:true / samplesPerPixel:4 is the reliable form — the
        // 3-sample no-alpha shape can fail NSGraphicsContext init on
        // some color spaces.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outSize, pixelsHigh: outSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else {
            NSLog("[yawac/avatar-crop] bitmap rep init failed")
            return nil
        }
        rep.size = NSSize(width: outSize, height: outSize)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSLog("[yawac/avatar-crop] graphics ctx init failed")
            return nil
        }
        NSGraphicsContext.current = ctx
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: outSize, height: outSize).fill()

        // SwiftUI's preview renders `original` with .scaledToFill() inside
        // a cropSize×cropSize frame, then .scaleEffect(zoom), then .offset(pan).
        // Replicate that math, then upscale by (outSize/cropSize).
        let outSizeF = CGFloat(outSize)
        let scale = outSizeF / cropSize
        let imgSize = original.size
        guard imgSize.width > 0, imgSize.height > 0 else {
            NSLog("[yawac/avatar-crop] image size invalid: %@",
                  NSStringFromSize(imgSize))
            return nil
        }
        // scaledToFill: smaller dimension matches frame, larger overflows.
        let base = max(cropSize / imgSize.width, cropSize / imgSize.height)
        let drawW = imgSize.width * base * zoom * scale
        let drawH = imgSize.height * base * zoom * scale
        let centerX = outSizeF / 2 + pan.width * scale
        // SwiftUI Y grows down, NSImage Y grows up — flip the pan.
        let centerY = outSizeF / 2 - pan.height * scale
        original.draw(
            in: NSRect(x: centerX - drawW / 2,
                       y: centerY - drawH / 2,
                       width: drawW, height: drawH),
            from: .zero, operation: .copy, fraction: 1.0)
        guard let data = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.85]) else {
            NSLog("[yawac/avatar-crop] jpeg encode failed")
            return nil
        }
        NSLog("[yawac/avatar-crop] render ok bytes=%d size=%@",
              data.count, NSStringFromSize(imgSize))
        return data
    }
}
