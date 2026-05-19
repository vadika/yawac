import SwiftUI

struct ChatListView: View {
    @Environment(ChatListViewModel.self) private var vm
    @Binding var selection: Chat.ID?

    var body: some View {
        List(vm.chats, selection: $selection) { chat in
            HStack(alignment: .top, spacing: 8) {
                AvatarView(jid: chat.jid, name: chat.name, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.name).font(.headline).lineLimit(1)
                    Text(chat.lastMessage).font(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if chat.unread > 0 {
                    Text("\(chat.unread)")
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint, in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            .tag(chat.id)
        }
        .listStyle(.sidebar)
    }
}
