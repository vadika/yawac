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
            case .chats:       return "Direct"
            case .groups:      return "Groups"
            case .communities: return "Channels"
            }
        }
        var icon: String {
            switch self {
            case .all:         return "tray"
            case .chats:       return "person"
            case .groups:      return "person.2"
            case .communities: return "building.2"
            }
        }
        var count: Int? { nil } // populated by ChatListView via VM
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

    private func count(for s: Scope) -> Int {
        switch s {
        case .all:         return vm.chats.count
        case .chats:       return directChats.count
        case .groups:      return standaloneGroups.count
        case .communities: return communities.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ─── Title row: wordmark (traffic lights are owned by the
            // OS-supplied titlebar, sitting just above this view).
            HStack {
                Spacer()
                Text("yawac")
                    .font(Theme.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .tracking(-0.2)
            }
            .frame(height: 44)
            .padding(.horizontal, 16)

            // ─── Search (visual hint — real search is system-level).
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                Text("Search")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Text("⌘K")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // ─── Tabs (custom pill-style, matching design).
            HStack(spacing: 4) {
                ForEach(Scope.allCases) { s in
                    Button {
                        scopeRaw = s.rawValue
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: s.icon)
                                .font(.system(size: 14, weight: .regular))
                            Text(s.label)
                                .font(Theme.ui(10, weight: .medium))
                                .opacity(0.85)
                        }
                        .foregroundStyle(scope == s ? Theme.accentText : Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            scope == s ? Theme.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // ─── List with sectioned chats.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if scope == .all || scope == .communities, !communities.isEmpty {
                        sectionLabel("Channels", count: communities.count)
                        ForEach(communities, id: \.jid) { parent in
                            chatRowButton(parent)
                            ForEach(subGroups(for: parent.jid), id: \.jid) { sub in
                                chatRowButton(sub, indent: 16)
                            }
                        }
                    }
                    if scope == .all || scope == .groups, !standaloneGroups.isEmpty {
                        sectionLabel("Groups", count: standaloneGroups.count)
                        ForEach(standaloneGroups, id: \.jid) { g in
                            chatRowButton(g)
                        }
                    }
                    if scope == .all || scope == .chats, !directChats.isEmpty {
                        sectionLabel("Direct", count: directChats.count)
                        ForEach(directChats, id: \.jid) { c in
                            chatRowButton(c)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.sidebarBg)
    }

    @ViewBuilder
    private func sectionLabel(_ text: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(Theme.ui(11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.textFaint)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            Text("\(count)")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint.opacity(0.85))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func chatRowButton(_ chat: Chat, indent: CGFloat = 0) -> some View {
        Button {
            selection = chat.id
        } label: {
            chatRowBody(chat, indent: indent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func chatRowBody(_ chat: Chat, indent: CGFloat) -> some View {
        let isSelected = (selection == chat.id)
        HStack(alignment: .top, spacing: 11) {
            if indent > 0 { Color.clear.frame(width: indent) }
            AvatarView(jid: chat.jid, name: chat.name, size: 36)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat.name)
                        .font(Theme.ui(14, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.text : Theme.text)
                        .lineLimit(1)
                        .tracking(-0.1)
                    Spacer(minLength: 0)
                    Text(chat.lastTimestampShort)
                        .font(Theme.mono(11))
                        .foregroundStyle(isSelected ? Theme.accentText : Theme.textFaint)
                        .monospacedDigit()
                        .opacity(0.85)
                }
                HStack(alignment: .center, spacing: 6) {
                    Text(chat.lastMessage)
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if chat.unread > 0 {
                        Text("\(chat.unread)")
                            .font(Theme.mono(10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Theme.accent, in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            (isSelected ? Theme.accentSoft : Color.clear),
            in: RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 2)
                    .padding(.vertical, 8)
            }
        }
        .contentShape(Rectangle())
    }
}

private extension Chat {
    /// Compact "HH:mm" / "Mon" / "12 May" style string for the row's
    /// right-aligned mono timestamp. Mirrors WhatsApp/iMessage behavior.
    var lastTimestampShort: String {
        let date = Date(timeIntervalSince1970: TimeInterval(lastTimestamp))
        guard lastTimestamp > 0 else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            return "Yest"
        } else if let days = cal.dateComponents([.day], from: date, to: Date()).day,
                  days < 7 {
            f.dateFormat = "EEE"
        } else {
            f.dateFormat = "d MMM"
        }
        return f.string(from: date)
    }
}
