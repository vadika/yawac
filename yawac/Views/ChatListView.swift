import SwiftUI

struct ChatListView: View {
    @Environment(ChatListViewModel.self) private var vm
    @Binding var selection: Chat.ID?

    private var communities: [Chat] {
        vm.chats.filter { $0.isCommunityParent }
    }

    private func subGroups(for parentJID: String) -> [Chat] {
        vm.chats.filter { $0.communityParentJID == parentJID }
    }

    private var standaloneGroups: [Chat] {
        vm.chats.filter { c in
            c.isGroup && !c.isCommunityParent && c.communityParentJID == nil
        }
    }

    private var directChats: [Chat] {
        vm.chats.filter { !$0.isGroup }
    }

    var body: some View {
        List(selection: $selection) {
            if !communities.isEmpty {
                Section("Communities") {
                    ForEach(communities, id: \.jid) { parent in
                        DisclosureGroup {
                            ForEach(subGroups(for: parent.jid), id: \.jid) { sub in
                                chatRow(sub).tag(sub.id)
                            }
                        } label: {
                            chatRow(parent).tag(parent.id)
                        }
                    }
                }
            }
            if !standaloneGroups.isEmpty {
                Section("Groups") {
                    ForEach(standaloneGroups, id: \.jid) { g in
                        chatRow(g).tag(g.id)
                    }
                }
            }
            if !directChats.isEmpty {
                Section("Chats") {
                    ForEach(directChats, id: \.jid) { c in
                        chatRow(c).tag(c.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func chatRow(_ chat: Chat) -> some View {
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
    }
}
