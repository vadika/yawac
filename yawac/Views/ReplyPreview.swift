import AppKit
import SwiftUI

/// Compact 44pt bar that sits between the message list and the
/// composer pill while a reply is staged. Replaces the older
/// full-width "Replying to" banner, which leaked raw JIDs and took
/// up too much vertical space.
struct ReplyPreview: View {
    let author: String
    let text: String
    let mediaKind: String?
    let mediaThumbnailPath: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.accent)
                .frame(width: 2.5)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .scaledIcon(10, weight: .medium)
                        .foregroundStyle(Theme.accentText)
                    Text("Replying to")
                        .foregroundStyle(Theme.accentText)
                    Text(author)
                        .foregroundStyle(Theme.text)
                }
                .scaledUI(12, weight: .semibold)
                .tracking(-0.1)

                HStack(spacing: 6) {
                    if let kind = mediaKind {
                        MediaBadge(kind: kind)
                    }
                    Text(displaySnippet)
                        .scaledUI(13)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let path = mediaThumbnailPath {
                ReplyThumb(path: path, kind: mediaKind ?? "")
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            CancelButton(action: onCancel)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(height: 44)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var displaySnippet: String {
        if !text.isEmpty { return text }
        switch mediaKind {
        case "image":    return "Photo"
        case "video":    return "Video"
        case "audio":    return "Voice message"
        case "document": return "Document"
        case "sticker":  return "Sticker"
        default:         return "—"
        }
    }
}

private struct MediaBadge: View {
    let kind: String

    private var icon: String {
        switch kind {
        case "video":    return "play.fill"
        case "audio":    return "mic.fill"
        case "document": return "doc"
        case "sticker":  return "face.smiling"
        default:         return "photo"
        }
    }

    private var label: String {
        switch kind {
        case "video":    return "Video"
        case "audio":    return "Voice"
        case "document": return "Document"
        case "sticker":  return "Sticker"
        default:         return "Photo"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .scaledIcon(9)
            Text(label)
                .scaledMono(11)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(Theme.textMuted)
    }
}

private struct ReplyThumb: View {
    let path: String
    let kind: String

    var body: some View {
        // Shared in-memory cache + coalesced revision bump: no
        // per-instance @State / .task means staged-reply previews don't
        // flash the placeholder on a disk hit (F12).
        let cache = ThumbnailCache.shared
        let _ = cache.revision
        let img: NSImage? = kind == "video"
            ? cache.videoImage(forPath: path)
            : cache.image(forPath: path)
        ZStack {
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.surfaceAlt
            }
            if kind == "video" {
                Image(systemName: "play.fill")
                    .scaledIcon(10, weight: .bold)
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            }
        }
    }
}

private struct CancelButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .scaledIcon(10, weight: .medium)
                .foregroundStyle(hovering ? Theme.text : Theme.textFaint)
                .frame(width: 24, height: 24)
                .background(
                    hovering ? Theme.surfaceAlt : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Cancel reply")
    }
}
