import SwiftUI

struct ChatListView: View {
    @Environment(ChatListViewModel.self) private var vm
    @Environment(ChatSearchViewModel.self) private var search
    @FocusState private var searchFocused: Bool
    @Environment(SessionViewModel.self) private var session
    @State private var archivedExpanded = false
    @State private var pendingDelete: Chat?
    @State private var pendingBlock: Chat?
    @State private var contactEditing: Chat?
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

    private enum Row: Hashable, Identifiable {
        case section(id: String, label: String, count: Int)
        case chat(Chat, indent: CGFloat)
        case suggestion(PhoneSuggestion)
        case archivedHeader(count: Int)
        var id: String {
            switch self {
            case .section(let id, _, _): return "sec:" + id
            case .chat(let c, let i):    return "row:\(c.jid)#\(Int(i))"
            case .suggestion(let s):     return "sug:" + s.jid
            case .archivedHeader:        return "sec:archived-header"
            }
        }
    }

    /// Builds the flat display list in a single pass over `vm.chats`.
    /// Replaces a previous version that called `filter` 3+ times plus
    /// `subGroups(for:)` once per community parent — O(C×N) on every
    /// body re-evaluation, which made scope switches stall for several
    /// seconds on large accounts.
    private func displayRows() -> [Row] {
        let chats = search.query.isEmpty ? vm.chats : search.filteredChats
        var out: [Row] = []
        if let s = search.suggestion {
            out.append(.suggestion(s))
        }

        var communities: [Chat] = []
        var standaloneGroups: [Chat] = []
        var directChats: [Chat] = []
        var subsByParent: [String: [Chat]] = [:]
        var pinned: [Chat] = []
        var archived: [Chat] = []

        for c in chats {
            if search.query.isEmpty, c.archivedAt != nil {
                archived.append(c)
                continue
            }
            if c.pinnedAt != nil {
                pinned.append(c)
                continue
            }
            if c.isCommunityParent {
                communities.append(c)
            } else if let parent = c.communityParentJID, !parent.isEmpty {
                subsByParent[parent, default: []].append(c)
            } else if c.isGroup {
                standaloneGroups.append(c)
            } else {
                directChats.append(c)
            }
        }

        let s = scope

        let archivedVisible: [Chat] = archived.filter { c in
            switch s {
            case .all:         return true
            case .chats:       return !c.isGroup && !c.isCommunityParent
            case .groups:      return c.isGroup && !c.isCommunityParent
            case .communities: return c.isCommunityParent
            }
        }
        if !archivedVisible.isEmpty {
            out.append(.archivedHeader(count: archivedVisible.count))
            if archivedExpanded {
                for a in archivedVisible {
                    out.append(.chat(a, indent: 0))
                }
            }
        }

        // Pinned floats above everything (and across scope buckets).
        // Hide under .communities — pin lives in the home tabs only.
        let pinnedVisible: [Chat] = pinned.filter { c in
            switch s {
            case .all:         return true
            case .chats:       return !c.isGroup && !c.isCommunityParent
            case .groups:      return c.isGroup && !c.isCommunityParent
            case .communities: return c.isCommunityParent
            }
        }
        if !pinnedVisible.isEmpty {
            out.append(.section(id: "pinned", label: "Pinned",
                                count: pinnedVisible.count))
            for p in pinnedVisible {
                out.append(.chat(p, indent: 0))
            }
        }

        if (s == .all || s == .communities) && !communities.isEmpty {
            out.append(.section(id: "channels", label: "Channels",
                                count: communities.count))
            for parent in communities {
                out.append(.chat(parent, indent: 0))
                for sub in subsByParent[parent.jid] ?? [] {
                    out.append(.chat(sub, indent: 16))
                }
            }
        }
        if (s == .all || s == .groups) && !standaloneGroups.isEmpty {
            out.append(.section(id: "groups", label: "Groups",
                                count: standaloneGroups.count))
            for g in standaloneGroups {
                out.append(.chat(g, indent: 0))
            }
        }
        if (s == .all || s == .chats) && !directChats.isEmpty {
            out.append(.section(id: "direct", label: "Direct",
                                count: directChats.count))
            for c in directChats {
                out.append(.chat(c, indent: 0))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            // ─── Title-bar gutter. 64pt matches the right pane's chat
            // header so the two columns share a single seam; traffic
            // lights overlay the leading area.
            WindowDragHandle()
                .frame(height: 64)

            // ─── Real search field. ⌘K focuses; empty query restores full list.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.icon(11, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                TextField("Search", text: Bindable(search).query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.text)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                if search.validating {
                    ProgressView().controlSize(.small)
                } else if !search.query.isEmpty {
                    Button {
                        search.clear()
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("⌘K")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(searchFocused ? Theme.accent : Theme.border,
                            lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .background(
                // Hidden button receives ⌘K and forwards focus to the field.
                Button("") { searchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )

            // ─── Tabs (custom pill-style, matching design).
            HStack(spacing: 4) {
                ForEach(Scope.allCases) { s in
                    Button {
                        // Skip implicit animation — animating the diff
                        // between scopes is what caused multi-second
                        // hangs on large chat lists.
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) {
                            scopeRaw = s.rawValue
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: s.icon)
                                .font(Theme.icon(14, weight: .regular))
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

            // ─── List with sectioned chats. Flat row enum so LazyVStack
            // only diffs one ForEach instead of multiple nested ones.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(displayRows()) { row in
                        switch row {
                        case .section(_, let label, let count):
                            sectionLabel(label, count: count)
                        case .chat(let chat, let indent):
                            chatRowButton(chat, indent: indent)
                        case .suggestion(let s):
                            suggestionRowButton(s)
                        case .archivedHeader(let count):
                            archivedHeaderRow(count: count)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.sidebarBg)
        .ignoresSafeArea(.container, edges: .top)
        .confirmationDialog(
            "Delete chat with \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { chat in
            Button("Delete", role: .destructive) {
                vm.deleteChat(chat); pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This clears the conversation on all your devices.")
        }
        .confirmationDialog(
            "Block \(pendingBlock?.name ?? "")?",
            isPresented: Binding(get: { pendingBlock != nil },
                                 set: { if !$0 { pendingBlock = nil } }),
            presenting: pendingBlock
        ) { chat in
            Button("Block", role: .destructive) {
                session.setBlocked(chat.jid, blocked: true); pendingBlock = nil
            }
            Button("Cancel", role: .cancel) { pendingBlock = nil }
        } message: { _ in
            Text("They won't be able to message you or see when you're online.")
        }
        .sheet(item: $contactEditing) { chat in
            ContactNameSheet(initialName: chat.name == chat.jid ? "" : chat.name) { full, first in
                vm.addContact(chat, fullName: full, firstName: first)
            }
        }
        // Keep active search results in sync when the chat list shrinks
        // (e.g. a delete from within search) — otherwise the stale snapshot
        // keeps showing the removed chat until the query changes.
        .onChange(of: vm.chats.count) { _, _ in
            if !search.query.isEmpty { search.refresh() }
        }
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
    private func archivedHeaderRow(count: Int) -> some View {
        Button { archivedExpanded.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .font(Theme.icon(12))
                    .foregroundStyle(Theme.textFaint)
                Text("Archived")
                    .font(Theme.ui(13, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text("\(count)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
                Image(systemName: archivedExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.icon(10, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func chatRowButton(_ chat: Chat, indent: CGFloat = 0) -> some View {
        Button {
            selection = chat.id
        } label: {
            chatRowBody(chat, indent: indent)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(chat.pinnedAt != nil ? "Unpin chat" : "Pin chat") {
                vm.pinChat(chat, pinned: chat.pinnedAt == nil)
            }
            Button(chat.archivedAt != nil ? "Unarchive" : "Archive") {
                vm.archiveChat(chat, archived: chat.archivedAt == nil)
            }
            if !chat.isGroup && !chat.isCommunityParent {
                Button(session.isSavedContact(chat.jid) ? "Edit name…" : "Add to contacts…") {
                    contactEditing = chat
                }
                if session.isBlocked(chat.jid) {
                    Button("Unblock") { session.setBlocked(chat.jid, blocked: false) }
                } else {
                    Button("Block…") { pendingBlock = chat }
                }
            }
            Divider()
            Button("Delete chat…", role: .destructive) { pendingDelete = chat }
        }
    }

    @ViewBuilder
    private func suggestionRowButton(_ s: PhoneSuggestion) -> some View {
        Button {
            let id = vm.upsertStubChat(jid: s.jid, displayName: s.displayPhone)
            selection = id
            search.clear()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(Theme.icon(22))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 32, height: 32)
                    .background(Theme.accentSoft,
                                in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.displayPhone)
                        .font(Theme.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Start new chat")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
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
                    if session.isBlocked(chat.jid) {
                        Image(systemName: "nosign")
                            .font(Theme.icon(10, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .help("Blocked")
                    }
                    Spacer(minLength: 0)
                    if chat.pinnedAt != nil {
                        Image(systemName: "pin.fill")
                            .font(Theme.icon(9, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .rotationEffect(.degrees(35))
                            .help("Pinned")
                    }
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
