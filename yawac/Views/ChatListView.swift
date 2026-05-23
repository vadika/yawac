import SwiftUI

struct ChatListView: View {
    @Environment(ChatListViewModel.self) private var vm
    @Binding var selection: Chat.ID?
    @AppStorage("yawac.chatListScope") private var scopeRaw: String = Scope.all.rawValue

    enum Scope: String, CaseIterable, Identifiable {
        case all, chats, groups, communities
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:         return "All"
            case .chats:       return "Chats"
            case .groups:      return "Groups"
            case .communities: return "Communities"
            }
        }
        var icon: String {
            switch self {
            case .all:         return "tray.full"
            case .chats:       return "person"
            case .groups:      return "person.3"
            case .communities: return "building.2"
            }
        }
    }

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .all }

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
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { scope },
                set: { scopeRaw = $0.rawValue }
            )) {
                ForEach(Scope.allCases) { s in
                    Image(systemName: s.icon).tag(s)
                        .help(s.label)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            List(selection: $selection) {
                if scope == .all || scope == .communities {
                    if !communities.isEmpty {
                        Section("Communities") {
                            ForEach(communities, id: \.jid) { parent in
                                chatRow(parent).tag(parent.id)
                                ForEach(subGroups(for: parent.jid), id: \.jid) { sub in
                                    chatRow(sub, indent: 16).tag(sub.id)
                                }
                            }
                        }
                    }
                }
                if scope == .all || scope == .groups {
                    if !standaloneGroups.isEmpty {
                        Section("Groups") {
                            ForEach(standaloneGroups, id: \.jid) { g in
                                chatRow(g).tag(g.id)
                            }
                        }
                    }
                }
                if scope == .all || scope == .chats {
                    if !directChats.isEmpty {
                        Section("Chats") {
                            ForEach(directChats, id: \.jid) { c in
                                chatRow(c).tag(c.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func chatRow(_ chat: Chat, indent: CGFloat = 0) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if indent > 0 {
                Color.clear.frame(width: indent)
            }
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
