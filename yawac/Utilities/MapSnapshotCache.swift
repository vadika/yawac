import AppKit
import MapKit

/// Renders + disk-caches a 220×120 @2x map snapshot for a coord.
/// On-disk path: ~/Library/Caches/<bundle>/MapSnapshots/<lat>_<lng>_<zoom>.png
@MainActor
final class MapSnapshotCache {
    static let shared = MapSnapshotCache()
    private init() {}

    private var memory: [String: NSImage] = [:]

    func snapshot(lat: Double, lng: Double,
                  zoom: CLLocationDistance = 1000) async -> NSImage? {
        let key = "\(String(format: "%.6f", lat))_\(String(format: "%.6f", lng))_\(Int(zoom))"
        if let cached = memory[key] { return cached }
        if let disk = readDisk(key: key) {
            memory[key] = disk
            return disk
        }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            latitudinalMeters: zoom, longitudinalMeters: zoom)
        options.size = NSSize(width: 220, height: 120)
        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snap = try await snapshotter.start()
            let composed = composePin(on: snap.image)
            memory[key] = composed
            writeDisk(key: key, image: composed)
            return composed
        } catch {
            return nil
        }
    }

    private func composePin(on base: NSImage) -> NSImage {
        let img = NSImage(size: base.size)
        img.lockFocus()
        base.draw(at: .zero, from: .zero,
                  operation: .copy, fraction: 1.0)
        let pin = NSImage(systemSymbolName: "mappin.and.ellipse",
                          accessibilityDescription: nil)
        let pinSize: CGFloat = 24
        let pinRect = NSRect(
            x: (base.size.width - pinSize) / 2,
            y: (base.size.height - pinSize) / 2,
            width: pinSize, height: pinSize)
        pin?.draw(in: pinRect)
        img.unlockFocus()
        return img
    }

    private var diskRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "yawac"
        return caches
            .appendingPathComponent(bundle)
            .appendingPathComponent("MapSnapshots", isDirectory: true)
    }

    private func readDisk(key: String) -> NSImage? {
        let url = diskRoot.appendingPathComponent("\(key).png")
        return NSImage(contentsOf: url)
    }

    private func writeDisk(key: String, image: NSImage) {
        do {
            try FileManager.default.createDirectory(
                at: diskRoot, withIntermediateDirectories: true)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { return }
            try png.write(to: diskRoot.appendingPathComponent("\(key).png"))
        } catch {
            // Best-effort cache; ignore.
        }
    }
}
