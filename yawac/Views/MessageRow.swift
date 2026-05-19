import SwiftUI

struct MessageRow: View {
    let message: UIMessage

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 60) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
                bodyView
                Text(message.timestamp, style: .time)
                    .font(.caption2).foregroundStyle(.secondary)
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
}
