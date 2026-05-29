import SwiftUI

/// Single-select destination picker for forwarding. A search field over the
/// known chats (filtered locally) + a flat list; tapping a chat calls
/// `onPick(jid)`. Intentionally flat — no scope tabs / community nesting.
struct ForwardPickerView: View {
    let messageCount: Int
    let onPick: (String) -> Void
    @Environment(SessionViewModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pending: Chat?

    private var chats: [Chat] {
        let all = session.chatList?.chats ?? []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Forward to…")
                    .scaledUI(15, weight: .semibold)
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textFaint)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .scaledUI(13)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(chats) { chat in
                        Button {
                            pending = chat
                        } label: {
                            HStack(spacing: 11) {
                                AvatarView(jid: chat.jid, name: chat.name, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chat.name).scaledUI(14, weight: .medium)
                                        .foregroundStyle(Theme.text).lineLimit(1)
                                    if !chat.lastMessage.isEmpty {
                                        Text(chat.lastMessage).scaledUI(12)
                                            .foregroundStyle(Theme.textMuted).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .frame(width: 360, height: 480)
        .background(Theme.sidebarBg)
        .alert("Forward \(messageCount) message\(messageCount == 1 ? "" : "s")?",
               isPresented: Binding(get: { pending != nil },
                                    set: { if !$0 { pending = nil } }),
               presenting: pending) { chat in
            Button("Forward") { onPick(chat.jid) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { chat in
            Text("To \(chat.name)")
        }
    }
}
