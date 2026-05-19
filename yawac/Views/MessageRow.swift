import AppKit
import AVKit
import SwiftUI

struct MessageRow: View {
    let message: UIMessage
    let status: UIMessage.Status?
    let senderName: String?
    let localPath: String?
    let reactions: [String]
    let downloadError: String?
    let onRetryDownload: (() -> Void)?

    init(message: UIMessage, status: UIMessage.Status? = nil,
         senderName: String? = nil, localPath: String? = nil,
         reactions: [String] = [],
         downloadError: String? = nil,
         onRetryDownload: (() -> Void)? = nil) {
        self.message = message
        self.status = status
        self.senderName = senderName
        self.localPath = localPath
        self.reactions = reactions
        self.downloadError = downloadError
        self.onRetryDownload = onRetryDownload
    }

    private var isGroupChat: Bool { message.chatJID.hasSuffix("@g.us") }

    private var senderDisplay: String {
        if let senderName, !senderName.isEmpty { return senderName }
        let raw = message.senderJID
        if let at = raw.firstIndex(of: "@") {
            return String(raw[..<at])
        }
        return raw
    }

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 60) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
                VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 4) {
                    if !message.fromMe && isGroupChat {
                        HStack(spacing: 6) {
                            AvatarView(jid: message.senderJID, name: senderDisplay, size: 24)
                            Text(senderDisplay)
                                .font(.caption).bold()
                                .foregroundStyle(.tint)
                        }
                    }
                    bodyView
                    footerView
                }
                .padding(8)
                .background(
                    message.fromMe
                        ? Color.accentColor.opacity(0.2)
                        : Color.gray.opacity(0.15),
                    in: .rect(cornerRadius: 10))
                if !reactions.isEmpty {
                    reactionChips
                }
            }
            if !message.fromMe { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(Array(Set(reactions)), id: \.self) { emoji in
                let count = reactions.filter { $0 == emoji }.count
                HStack(spacing: 2) {
                    Text(emoji).font(.caption)
                    if count > 1 {
                        Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.gray.opacity(0.15), in: .capsule)
            }
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        switch message.body {
        case .text(let s):
            Text(s).textSelection(.enabled)
        case .media(let kind, let caption, let fileName, let path):
            mediaView(kind: kind, caption: caption, fileName: fileName, path: path)
        case .system(let s):
            Text(s).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footerView: some View {
        HStack(spacing: 4) {
            Text(message.timestamp, style: .time)
            if message.fromMe, let status {
                Image(systemName: statusIcon(status))
                    .foregroundStyle(statusColor(status))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func mediaView(kind: String, caption: String?, fileName: String?, path: String?) -> some View {
        let effectivePath = localPath ?? path
        VStack(alignment: .leading, spacing: 4) {
            switch kind {
            case "image":
                imageBubble(path: effectivePath)
            case "sticker":
                stickerBubble(path: effectivePath)
            case "video":
                videoBubble(path: effectivePath)
            case "audio":
                audioBubble(path: effectivePath)
            case "document":
                documentBubble(path: effectivePath, fileName: fileName)
            default:
                Label(kind, systemImage: iconName(for: kind))
                    .foregroundStyle(.secondary)
            }
            if let caption, !caption.isEmpty {
                Text(caption)
            }
        }
    }

    @ViewBuilder
    private func imageBubble(path: String?) -> some View {
        if let p = path, let img = NSImage(contentsOfFile: p) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 320, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 8))
        } else {
            downloadingPlaceholder("photo")
        }
    }

    @ViewBuilder
    private func stickerBubble(path: String?) -> some View {
        if let p = path, let img = NSImage(contentsOfFile: p) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 160, maxHeight: 160)
        } else {
            downloadingPlaceholder("face.smiling")
        }
    }

    @ViewBuilder
    private func videoBubble(path: String?) -> some View {
        if let p = path {
            VideoThumbnailView(path: p)
                .frame(maxWidth: 320, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 8))
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: p))
                }
        } else {
            downloadingPlaceholder("play.rectangle")
        }
    }

    @ViewBuilder
    private func audioBubble(path: String?) -> some View {
        if let p = path {
            AudioPlayerView(path: p)
        } else {
            downloadingPlaceholder("waveform")
        }
    }

    @ViewBuilder
    private func documentBubble(path: String?, fileName: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: downloadError != nil ? "exclamationmark.triangle.fill" : "doc")
                .font(.title2)
                .foregroundStyle(downloadError != nil ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName ?? "Document").font(.callout).bold()
                if path != nil {
                    Text("Tap to open").font(.caption2).foregroundStyle(.secondary)
                } else if let err = downloadError {
                    Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if path == nil, downloadError != nil, let retry = onRetryDownload {
                Spacer()
                Button("Retry", action: retry).buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(6)
        .frame(maxWidth: 320, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture {
            if let p = path {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
            }
        }
    }

    @ViewBuilder
    private func downloadingPlaceholder(_ icon: String) -> some View {
        if let err = downloadError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download failed").font(.caption)
                    Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if let retry = onRetryDownload {
                    Button("Retry", action: retry).buttonStyle(.borderless).font(.caption)
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "image":    return "photo"
        case "audio":    return "waveform"
        case "video":    return "play.rectangle"
        case "sticker":  return "face.smiling"
        default:         return "doc"
        }
    }

    private func statusIcon(_ s: UIMessage.Status) -> String {
        switch s {
        case .sent:      return "checkmark"
        case .delivered: return "checkmark.circle"
        case .read:      return "checkmark.circle.fill"
        case .played:    return "play.circle.fill"
        }
    }

    private func statusColor(_ s: UIMessage.Status) -> Color {
        s == .read || s == .played ? .blue : .secondary
    }
}
