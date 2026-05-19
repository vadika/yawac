import SwiftUI

struct MessageRow: View {
    let message: UIMessage
    let status: UIMessage.Status?

    init(message: UIMessage, status: UIMessage.Status? = nil) {
        self.message = message
        self.status = status
    }

    private var isGroupChat: Bool { message.chatJID.hasSuffix("@g.us") }

    private var senderDisplay: String {
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
                if !message.fromMe && isGroupChat {
                    Text(senderDisplay)
                        .font(.caption).bold()
                        .foregroundStyle(.tint)
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
            if !message.fromMe { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        switch message.body {
        case .text(let s):
            Text(s).textSelection(.enabled)
        case .media(let kind, let caption, let path):
            mediaView(kind: kind, caption: caption, path: path)
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
    private func mediaView(kind: String, caption: String?, path: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if kind == "image",
               let path,
               let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 240)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                Label(kind, systemImage: iconName(for: kind))
                    .foregroundStyle(.secondary)
            }
            if let caption, !caption.isEmpty {
                Text(caption)
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
