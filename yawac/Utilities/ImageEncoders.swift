import AppKit

/// Small JPEG-encode helpers reused by avatar-edit code paths
/// (settings own-avatar, plus the existing group-photo crop sheet
/// which has its own bespoke render). Keep the API tiny — anything
/// fancier (cropping, masking) belongs in its own sheet view.
enum ImageEncoders {

    /// Encode an NSImage to JPEG bytes, scaled to fit `maxSize` on
    /// the longest side, at quality 0.8. Returns nil if the image is
    /// degenerate (zero-sized) or AppKit fails to produce a TIFF rep.
    static func encodeJPEG(_ image: NSImage, maxSize: CGFloat = 640) -> Data? {
        let originalSize = image.size
        guard originalSize.width > 0 && originalSize.height > 0 else { return nil }
        let scale = min(1, maxSize / max(originalSize.width, originalSize.height))
        let target = NSSize(width: originalSize.width * scale,
                            height: originalSize.height * scale)
        let scaled = NSImage(size: target)
        scaled.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero, operation: .copy, fraction: 1.0)
        scaled.unlockFocus()
        guard let tiff = scaled.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
