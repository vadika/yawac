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
            .background(message.fromMe ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15),
                        in: .rect(cornerRadius: 10))
            if !message.fromMe { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        switch message.body {
        case .text(let s):
            Text(s).textSelection(.enabled)
        case .media(let k, let c, _):
            Text("[\(k)] \(c ?? "")").italic()
        case .system(let s):
            Text(s).font(.caption).foregroundStyle(.secondary)
        }
    }
}
