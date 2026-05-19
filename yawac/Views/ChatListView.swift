import SwiftUI

struct ChatListView: View {
    @Environment(ChatListViewModel.self) private var vm
    @Binding var selection: Chat.ID?

    var body: some View {
        List(vm.chats, selection: $selection) { chat in
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(.gray.opacity(0.3))
                    .frame(width: 40, height: 40)
                    .overlay(Text(String(chat.name.prefix(1))).bold())
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
