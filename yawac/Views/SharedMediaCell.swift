import AppKit
import SwiftUI

/// Square thumbnail cell used by the SHARED MEDIA grid in
/// `ChatInfoView`. Renders image / sticker stills via NSImage and
/// extracts a video first-frame via the existing
/// `VideoThumbnailView.generateThumb` async helper. Click opens the
/// underlying file in the system default app.
struct SharedMediaCell: View {
    let item: ChatMediaViewModel.MediaItem
    var onTap: ((String, String?) -> Void)? = nil
    @State private var image: NSImage?

    private var badgeText: String {
        switch item.kind {
        case "video":   return "VID"
        case "sticker": return "STK"
        default:        return "IMG"
        }
    }

    var body: some View {
        Button(action: open) {
            GeometryReader { geo in
                ZStack {
                    Theme.surfaceAlt
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.width)
                            .clipped()
                    } else {
                        Image(systemName: placeholderIcon)
                            .scaledIcon(18)
                            .foregroundStyle(Theme.textFaint)
                    }
                    if item.kind == "video", image != nil {
                        Image(systemName: "play.fill")
                            .scaledIcon(18, weight: .bold)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    VStack {
                        HStack {
                            Text(badgeText)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(0.4)
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Color.black.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: 3)
                                )
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(6)
                }
                .frame(width: geo.size.width, height: geo.size.width)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.timestamp.formatted(date: .abbreviated, time: .shortened))
        .task(id: "\(item.id)|\(item.path ?? "")") {
            await load()
        }
    }

    private var placeholderIcon: String {
        switch item.kind {
        case "video":   return "play.rectangle"
        case "sticker": return "face.smiling"
        default:        return "photo"
        }
    }

    private func load() async {
        guard let path = item.path, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            image = nil
            return
        }
        if item.kind == "video" {
            image = await VideoThumbnailView.generateThumb(path: path)
        } else {
            image = NSImage(contentsOfFile: path)
        }
    }

    private func open() {
        if let onTap {
            onTap(item.id, item.path)
            return
        }
        guard let path = item.path,
              FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

/// Row-style cell used by the FILES list in `ChatInfoView`.
struct SharedFileRow: View {
    let item: ChatMediaViewModel.FileItem
    var onTap: ((String, String?) -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .scaledIcon(16)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName)
                        .scaledUI(13, weight: .medium)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if let size = formattedSize {
                            Text(size)
                                .scaledMono(10.5)
                                .foregroundStyle(Theme.textFaint)
                        }
                        Text(item.timestamp.formatted(date: .abbreviated, time: .omitted))
                            .scaledMono(10.5)
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer()
                if item.path != nil {
                    Image(systemName: "arrow.up.right.square")
                        .scaledIcon(11)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                hovering ? Theme.surfaceAlt.opacity(0.6) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(item.path == nil && onTap == nil)
    }

    private var formattedSize: String? {
        guard let path = item.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func open() {
        if let onTap {
            onTap(item.id, item.path)
            return
        }
        guard let path = item.path,
              FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
