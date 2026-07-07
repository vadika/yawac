import SwiftUI

struct ChatListView: View {
    @Environment(ChatListViewModel.self) private var vm
    @Environment(ChatSearchViewModel.self) private var search
    @FocusState private var searchFocused: Bool
    @Environment(SessionViewModel.self) private var session
    // F91 — kept for compilation; .archivedHeader Row case is now dead
    // (archived chats are shown via the Archived rail sentinel, not inline).
    @State private var archivedExpanded = false
    @State private var globalSenders: [(jid: String, name: String)] = []
    @State private var pendingDelete: Chat?
    @State private var pendingBlock: Chat?
    @State private var contactEditing: Chat?
    @State private var showingNewGroup = false
    @State private var showingNewCommunity = false
    @Binding var selection: Chat.ID?

    // F91 — folder rail state
    @State private var folderRail: FolderRailViewModel?
    @State private var showNewFolderSheet: Bool = false
    @State private var renamingFolder: PersistedFolder?
    @State private var folderPendingDelete: PersistedFolder?
    @State private var newFolderInsertIndex: Int = 0
    @State private var renameDraft: String = ""
    @AppStorage("yawac.selectedFolderID") private var selectedFolderIDRaw: String = ""
    @AppStorage("yawac.kindScope") private var kindScopeRaw: String = KindScope.all.rawValue
    @Environment(\.modelContext) private var modelContext

    /// F46 — memoized `displayRows()` output. Body re-evals during a
    /// splitter drag fire at gesture-event rate; recomputing the O(C)
    /// filter/sort/group pass per frame pegged main on 1.5k-chat
    /// accounts. The state is rebuilt only when one of the inputs in
    /// `rebuildDisplayRows()` actually changes (see the `.onChange`
    /// wires at the bottom of `body`).
    @State private var cachedRows: [Row] = []

    private enum Row: Hashable, Identifiable {
        case section(id: String, label: String, count: Int)
        case chat(Chat, indent: CGFloat)
        case suggestion(PhoneSuggestion)
        case archivedHeader(count: Int)
        case messageSection(count: Int)
        case messageFilterChips
        case messageHit(hit: MessageIndex.Hit, chatName: String)
        case invitePreview
        var id: String {
            switch self {
            case .section(let id, _, _): return "sec:" + id
            case .chat(let c, let i):    return "row:\(c.jid)#\(Int(i))"
            case .suggestion(let s):     return "sug:" + s.jid
            case .archivedHeader:        return "sec:archived-header"
            case .messageSection:        return "sec:messages"
            case .messageFilterChips:    return "sec:messages-filters"
            case .messageHit(let h, _):  return "mhit:\(h.messageID)"
            case .invitePreview:         return "sec:invite-preview"
            }
        }

        /// F46 — fixed per-variant heights so `LazyVStack` doesn't
        /// measure each visible row's intrinsic size on every layout
        /// pass. During a sidebar splitter drag this measurement
        /// dominated the main thread on large chat lists. All variants
        /// already use `.lineLimit(1)` (or `.lineLimit(2)` for message
        /// hits) so clipping risk is bounded.
        var fixedHeight: CGFloat {
            switch self {
            case .chat:              return 60   // avatar 36 + 2 lines + vpad 9*2
            case .suggestion:        return 56
            case .messageHit:        return 60   // 2-line snippet
            case .section:           return 36   // .top 14 + label + .bottom 4
            case .archivedHeader:    return 36
            case .messageSection:    return 36
            case .messageFilterChips: return 44
            case .invitePreview:     return 56
            }
        }
    }

    /// Builds the flat display list in a single pass over `vm.chats`.
    /// Replaces a previous version that called `filter` 3+ times plus
    /// `subGroups(for:)` once per community parent — O(C×N) on every
    /// body re-evaluation, which made scope switches stall for several
    /// seconds on large accounts.
    ///
    /// F46 — renamed from `displayRows()` and now called only from
    /// `.onChange` handlers / `.task`. Body reads `cachedRows` instead,
    /// so splitter drags (which re-eval body at gesture-event rate)
    /// no longer trigger this O(C) pass per frame.
    private func rebuildDisplayRows() -> [Row] {
        // F91 — filter chats through the active folder selection first.
        let selection = folderRail?.selection ?? .all
        let allChatsSource = search.query.isEmpty ? vm.chats : search.filteredChats
        let railFiltered = ChatListViewModel.chatsFor(
            selection: selection,
            allChats: allChatsSource)
        // F91 v4 — layer kind filter on top of rail selection.
        // `.all` passes everything through; other cases filter.
        let kind = KindScope(rawValue: kindScopeRaw) ?? .all
        let visibleChats = railFiltered.filter { kind.matches($0) }

        // F91 — archived sentinel: flat sorted list, no sections/pinned/groups.
        if selection == .archived {
            var out: [Row] = []
            if !search.query.isEmpty
                && (!search.messageHits.isEmpty
                    || !search.filters.isEmpty
                    || search.globalChatFilter != nil) {
                out.append(.messageSection(count: search.messageHits.count))
                out.append(.messageFilterChips)
                let nameLookup = Dictionary(vm.chats.map { ($0.jid, $0.name) },
                                            uniquingKeysWith: { first, _ in first })
                for hit in search.messageHits {
                    let name = nameLookup[hit.chatJID] ?? hit.chatJID
                    out.append(.messageHit(hit: hit, chatName: name))
                }
            } else {
                let sorted = visibleChats.sorted { $0.lastTimestamp > $1.lastTimestamp }
                for c in sorted { out.append(.chat(c, indent: 0)) }
            }
            return out
        }

        var out: [Row] = []
        if vm.inviteLinkPreview != nil {
            out.append(.invitePreview)
        }
        if let s = search.suggestion {
            out.append(.suggestion(s))
        }

        var communities: [Chat] = []
        var standaloneGroups: [Chat] = []
        var directChats: [Chat] = []
        var subsByParent: [String: [Chat]] = [:]
        var pinned: [Chat] = []

        // F91 — visibleChats already excludes archived chats (chatsFor
        // filters them out for .all and .custom). No inline archived
        // section is rendered; the Archived rail sentinel owns that view.
        for c in visibleChats {
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

        // Pinned floats above everything (and across folder buckets).
        if !pinned.isEmpty {
            out.append(.section(id: "pinned", label: "Pinned",
                                count: pinned.count))
            for p in pinned {
                out.append(.chat(p, indent: 0))
                // A pinned community parent should still expose its
                // joined sub-groups under it — otherwise users lose
                // every channel in the community the moment they pin
                // the parent.
                if p.isCommunityParent {
                    for sub in subsByParent[p.jid] ?? [] {
                        out.append(.chat(sub, indent: 16))
                    }
                }
            }
        }

        // F91 — .all and .custom both use the timeline-sorted single list.
        // F50: All scope renders one timeline-sorted list (matches the
        // native WhatsApp client) instead of segregating by type.
        var interleaved: [Chat] = []
        interleaved.reserveCapacity(communities.count
                                     + standaloneGroups.count
                                     + directChats.count)
        interleaved.append(contentsOf: communities)
        interleaved.append(contentsOf: standaloneGroups)
        interleaved.append(contentsOf: directChats)
        // The source array is already sorted by recency
        // (sortChats() runs after every ingest flush); preserve that
        // ordering when merging the three buckets.
        interleaved.sort { $0.lastTimestamp > $1.lastTimestamp }
        if !interleaved.isEmpty {
            out.append(.section(id: "chats", label: "Chats",
                                count: interleaved.count))
            for c in interleaved {
                out.append(.chat(c, indent: 0))
                if c.isCommunityParent {
                    for sub in subsByParent[c.jid] ?? [] {
                        out.append(.chat(sub, indent: 16))
                    }
                }
            }
        }

        if !search.query.isEmpty
            && (!search.messageHits.isEmpty
                || !search.filters.isEmpty
                || search.globalChatFilter != nil) {
            out.append(.messageSection(count: search.messageHits.count))
            out.append(.messageFilterChips)
            let nameLookup = Dictionary(vm.chats.map { ($0.jid, $0.name) },
                                        uniquingKeysWith: { first, _ in first })
            for hit in search.messageHits {
                let name = nameLookup[hit.chatJID] ?? hit.chatJID
                out.append(.messageHit(hit: hit, chatName: name))
            }
        }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            if let rail = folderRail {
                FolderRail(vm: rail) { event in
                    switch event {
                    case .rename(let f):
                        renamingFolder = f
                    case .delete(let f):
                        folderPendingDelete = f
                    case .newFolder(let idx):
                        newFolderInsertIndex = idx
                        showNewFolderSheet = true
                    }
                }
                Divider()
            }
            chatListContent
        }
        .task {
            if folderRail == nil {
                let rail = FolderRailViewModel(context: modelContext, chatList: vm)
                rail.loadFolders()
                let knownIDs = Set(rail.folders.map(\.id))
                rail.selection = FolderSelection.resolved(
                    storageValue: selectedFolderIDRaw,
                    knownIDs: knownIDs)
                folderRail = rail
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(isPresented: $showNewFolderSheet) { name in
                folderRail?.createFolder(name: name, atIndex: newFolderInsertIndex)
            }
        }
        .alert("Rename folder",
               isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } })) {
            TextField("Folder name", text: $renameDraft)
            Button("Save") {
                if let f = renamingFolder {
                    folderRail?.renameFolder(id: f.id, to: renameDraft)
                }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        } message: {
            Text("Enter a new name for the folder.")
        }
        .alert("Delete folder",
               isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { if !$0 { folderPendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let f = folderPendingDelete {
                    folderRail?.deleteFolder(id: f.id)
                }
                folderPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { folderPendingDelete = nil }
        } message: {
            Text("\"\(folderPendingDelete?.name ?? "")\" will be removed from the rail. Chats stay in your chat list.")
        }
        .onChange(of: renamingFolder?.id) { _, _ in
            renameDraft = renamingFolder?.name ?? ""
        }
    }

    private var chatListContent: some View {
        VStack(spacing: 0) {
            // ─── Title-bar gutter. 64pt matches the right pane's chat
            // header so the two columns share a single seam; traffic
            // lights overlay the leading area, the "+" menu floats
            // on the trailing edge alongside the system sidebar toggle.
            WindowDragHandle()
                .frame(height: 64)
                .overlay(alignment: .topTrailing) {
                    Menu {
                        Button("New group…") { showingNewGroup = true }
                        Button("New community…") { showingNewCommunity = true }
                    } label: {
                        Image(systemName: "plus.circle")
                            .scaledIcon(15, weight: .medium)
                            .foregroundStyle(Theme.textFaint)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.top, 8)
                    .padding(.trailing, 48)
                    .help("New group or community")
                }

            IndexingChip()
                .padding(.bottom, 2)

            // ─── Real search field. ⌘K focuses; empty query restores full list.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .scaledIcon(11, weight: .medium)
                    .foregroundStyle(Theme.textFaint)
                TextField("Search", text: Bindable(search).query)
                    .textFieldStyle(.plain)
                    .scaledUI(12.5)
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
                        .scaledMono(10.5)
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

            // ─── Kind scope row (All / Direct / Groups / Communities).
            // Tap to apply; tap "All" or the already-selected segment
            // to reset to All. Orthogonal to the folder rail selection.
            HStack(spacing: 4) {
                ForEach(KindScope.allCases) { k in
                    Button {
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) {
                            // Tapping the active non-all segment resets to all;
                            // tapping all always selects all.
                            if k == .all || kindScopeRaw == k.rawValue {
                                kindScopeRaw = KindScope.all.rawValue
                            } else {
                                kindScopeRaw = k.rawValue
                            }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: k.icon)
                                .scaledIcon(14, weight: .regular)
                            Text(k.label)
                                .scaledUI(10, weight: .medium)
                                .opacity(0.85)
                        }
                        .foregroundStyle(kindScopeRaw == k.rawValue ? Theme.accentText : Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            kindScopeRaw == k.rawValue ? Theme.accentSoft : Color.clear,
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
            // F5: while the cold-start bootstrap is in flight and we
            // have nothing to draw, render a ProgressView in place of
            // the empty list so the sidebar doesn't look "stuck on
            // blank". The flag flips to `false` the moment the
            // off-MainActor snapshot lands and `chats` is published.
            if vm.bootstrapping && vm.chats.isEmpty {
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(cachedRows) { row in
                        switch row {
                        case .section(_, let label, let count):
                            sectionLabel(label, count: count)
                        case .chat(let chat, let indent):
                            chatRowButton(chat, indent: indent)
                        case .suggestion(let s):
                            suggestionRowButton(s)
                        case .archivedHeader(let count):
                            archivedHeaderRow(count: count)
                        case .messageSection(let count):
                            sectionLabel("Messages", count: count)
                        case .messageFilterChips:
                            messageFilterChipsRow()
                        case .messageHit(let hit, let chatName):
                            messageHitRowButton(hit: hit, chatName: chatName)
                        case .invitePreview:
                            if let state = vm.inviteLinkPreview {
                                InvitePreviewRow(state: state) { code in
                                    Task { @MainActor in await joinPreview(code: code) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            }  // end else (bootstrap branch)
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
        .sheet(isPresented: $showingNewGroup) {
            if let client = vm.clientRef {
                NewGroupSheet(
                    model: NewGroupSheetModel(createGroup: { name, jids in
                        try client.createGroup(name: name, participantJIDs: jids)
                    }),
                    contacts: contactsForPicker,
                    onCreated: { newJID in
                        mergeNewlyCreatedChat(jid: newJID, client: client)
                    }
                )
            }
        }
        .sheet(isPresented: $showingNewCommunity) {
            if let client = vm.clientRef {
                NewCommunitySheet(
                    model: NewCommunitySheetModel(createCommunity: { name in
                        try client.createCommunity(name: name)
                    }),
                    onCreated: { newJID in
                        mergeNewlyCreatedChat(jid: newJID, client: client)
                    }
                )
            }
        }
        // Keep active search results in sync with any chat-list mutation —
        // adds/removes (count), and in-place updates (e.g. lastMessage flip
        // to a tombstone after a delete) which leave count unchanged.
        .onChange(of: vm.chats) { _, _ in
            if !search.query.isEmpty { search.refresh() }
            cachedRows = rebuildDisplayRows()
            folderRail?.refreshBadges(chats: vm.chats)
        }
        // F46 — rebuild the memoized row list when any input to
        // `rebuildDisplayRows()` changes. Body itself no longer calls
        // the O(C) builder, so splitter drags stay cheap.
        .task { cachedRows = rebuildDisplayRows() }
        .onChange(of: vm.inviteLinkPreview) { _, _ in
            cachedRows = rebuildDisplayRows()
        }
        .onChange(of: search.query) { _, _ in
            cachedRows = rebuildDisplayRows()
        }
        .onChange(of: search.filteredChats) { _, _ in
            cachedRows = rebuildDisplayRows()
        }
        .onChange(of: search.suggestion) { _, _ in
            cachedRows = rebuildDisplayRows()
        }
        .onChange(of: search.messageHits) { _, _ in
            cachedRows = rebuildDisplayRows()
        }
        .onChange(of: search.filters) { _, _ in
            cachedRows = rebuildDisplayRows()
        }
        .onChange(of: search.globalChatFilter) { _, _ in
            cachedRows = rebuildDisplayRows()
        }
        // F91 — persist folder selection and rebuild rows when rail selection changes.
        .onChange(of: folderRail?.selection) { _, newValue in
            if let s = newValue {
                selectedFolderIDRaw = s.storageValue
                cachedRows = rebuildDisplayRows()
            }
        }
        // F91 v3 — rebuild when kind scope filter changes.
        .onChange(of: kindScopeRaw) { _, _ in cachedRows = rebuildDisplayRows() }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .scaledUI(11, weight: .semibold)
                .tracking(0.4)
                .foregroundStyle(Theme.textFaint)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            Text("\(count)")
                .scaledMono(10.5)
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
                    .scaledIcon(12)
                    .foregroundStyle(Theme.textFaint)
                Text("Archived")
                    .scaledUI(13, weight: .medium)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text("\(count)")
                    .scaledMono(10.5)
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
                Image(systemName: archivedExpanded ? "chevron.down" : "chevron.right")
                    .scaledIcon(10, weight: .semibold)
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
            if chat.unread > 0 {
                Button("Mark as read") { vm.markRead(chat.jid) }
            }
            Button(chat.pinnedAt != nil ? "Unpin chat" : "Pin chat") {
                vm.pinChat(chat, pinned: chat.pinnedAt == nil)
            }
            if let until = chat.mutedUntil, until > Date() {
                Button("Unmute") { vm.muteChat(chat, until: nil) }
            } else {
                Menu("Mute") {
                    Button("Mute for 8 hours") {
                        vm.muteChat(chat, until: Date().addingTimeInterval(8 * 3600))
                    }
                    Button("Mute for 1 week") {
                        vm.muteChat(chat, until: Date().addingTimeInterval(7 * 86400))
                    }
                    Button("Mute always") {
                        vm.muteChat(chat, until: ChatListViewModel.muteForever)
                    }
                }
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
            if let rail = folderRail {
                Menu("Add to folder…") {
                    ForEach(rail.folders, id: \.id) { f in
                        Button {
                            if chat.folderIDs.contains(f.id) {
                                rail.removeChat(jid: chat.jid, fromFolderID: f.id)
                            } else {
                                rail.addChat(jid: chat.jid, toFolderID: f.id)
                            }
                        } label: {
                            if chat.folderIDs.contains(f.id) {
                                Label(f.name, systemImage: "checkmark")
                            } else {
                                Text(f.name)
                            }
                        }
                    }
                    if !rail.folders.isEmpty {
                        Divider()
                    }
                    Button("New folder…") {
                        newFolderInsertIndex = rail.folders.count
                        showNewFolderSheet = true
                    }
                }
            }
            Divider()
            Button("Delete chat…", role: .destructive) { pendingDelete = chat }
        }
        .draggable(ChatJIDTransfer(jid: chat.jid)) {
            // Drag preview: just the row body at half opacity.
            chatRowBody(chat, indent: 0)
                .frame(width: 240)
                .opacity(0.75)
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
                    .scaledIcon(22)
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 32, height: 32)
                    .background(Theme.accentSoft,
                                in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.displayPhone)
                        .scaledUI(13, weight: .medium)
                        .foregroundStyle(Theme.text)
                    Text("Start new chat")
                        .scaledUI(11)
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
    private func messageFilterChipsRow() -> some View {
        let chatsList = vm.chats.map { (jid: $0.jid, name: $0.name) }
        SearchFilterChips(
            filters: Bindable(search).filters,
            availableSenders: globalSenders,
            showChatChip: true,
            availableChats: chatsList,
            chatJID: Bindable(search).globalChatFilter
        )
        .task { globalSenders = await search.knownGlobalSendersAsync() }
    }

    @ViewBuilder
    private func messageHitRowButton(hit: MessageIndex.Hit, chatName: String) -> some View {
        Button {
            session.requestJumpToMessage(chatJID: hit.chatJID, messageID: hit.messageID)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(chatName)
                        .scaledUI(12, weight: .semibold)
                        .foregroundStyle(Theme.text)
                    if !hit.sender.isEmpty {
                        Text("·").foregroundStyle(Theme.textFaint)
                        Text(hit.sender)
                            .scaledUI(12)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 4)
                    Text(formatHitDate(hit.timestamp))
                        .scaledMono(10)
                        .foregroundStyle(Theme.textFaint)
                }
                // Strips ⟦…⟧ snippet markers for v1; bold-around-hit rendering
                // is deferred to a polish task.
                Text(resolveMentionsText(
                    hit.snippet
                        .replacingOccurrences(of: "⟦", with: "")
                        .replacingOccurrences(of: "⟧", with: "")) {
                    session.displayName(for: $0)
                })
                    .scaledUI(11)
                    .lineLimit(2)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static let hitDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    private func formatHitDate(_ ts: Int64) -> String {
        // ZTIMESTAMP is Apple-epoch seconds.
        let d = Date(timeIntervalSinceReferenceDate: TimeInterval(ts))
        return Self.hitDateFmt.string(from: d)
    }

    /// Contact list passed to the participant picker in `NewGroupSheet`.
    /// Mirrors the dedup pattern used by `ChatInfoView` when populating
    /// add-participants: walk `session.contactNames`, prefer the PN form
    /// over `@lid` when both are known, and drop self.
    private var contactsForPicker: [BridgeContact] {
        guard let client = vm.clientRef else { return [] }
        let selfKey = JIDNormalize.canonical(client.ownJID, client: client)
        var byKey: [String: BridgeContact] = [:]
        for (jid, name) in session.contactNames {
            let key = JIDNormalize.canonical(jid, client: client)
            if key == selfKey { continue }
            if let existing = byKey[key] {
                if existing.jid.hasSuffix("@lid"), !key.hasSuffix("@lid") {
                    byKey[key] = BridgeContact(
                        jid: key, name: name,
                        pushName: nil, fullName: nil, businessName: nil)
                }
                continue
            }
            byKey[key] = BridgeContact(
                jid: key, name: name,
                pushName: nil, fullName: nil, businessName: nil)
        }
        return Array(byKey.values)
    }

    /// Newly-created groups don't arrive via an inbound event yet
    /// (whatsmeow's JoinedGroup isn't wired into WAClient.Event),
    /// so explicitly fetch the new chat's info and merge it into
    /// ChatListViewModel, then queue selection. Mirrors joinPreview.
    @MainActor
    private func mergeNewlyCreatedChat(jid: String, client: WAClient) {
        Task {
            if let info = try? client.getGroupInfo(jid: jid) {
                vm.mergeGroups([info])
            }
            session.requestSelectChat(jid)
        }
    }

    @MainActor
    private func joinPreview(code: String) async {
        guard let client = vm.clientRef else { return }
        vm.inviteLinkPreview = .joining(code: code)
        do {
            let joinedJID = try client.joinGroupViaLink(code: code)
            // Probe to distinguish "joined" from "pending approval".
            if let info = try? client.getGroupInfo(jid: joinedJID) {
                vm.mergeGroups([info])
                vm.inviteLinkPreview = nil
                search.clear()
                session.requestSelectChat(joinedJID)
            } else {
                vm.inviteLinkPreview = .pending(code: code, joinedJID: joinedJID)
            }
        } catch {
            vm.inviteLinkPreview = .error(message: error.localizedDescription)
        }
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
                    // Self-chat surface: append " (You)" to the row name
                    // so the paired account's own DM is unambiguous in
                    // the sidebar. Surgical render-site override (not in
                    // `displayName`) because that helper feeds mentions
                    // + notifications too, where the suffix would read
                    // wrong.
                    Text(chat.name + (session.isSelfChat(chat.jid) ? " (You)" : ""))
                        .scaledUI(14, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(isSelected ? Theme.text : Theme.text)
                        .lineLimit(1)
                        .tracking(-0.1)
                    if session.isBlocked(chat.jid) {
                        Image(systemName: "nosign")
                            .scaledIcon(10, weight: .semibold)
                            .foregroundStyle(Theme.textFaint)
                            .help("Blocked")
                    }
                    Spacer(minLength: 0)
                    if chat.pinnedAt != nil {
                        Image(systemName: "pin.fill")
                            .scaledIcon(9, weight: .semibold)
                            .foregroundStyle(Theme.textFaint)
                            .rotationEffect(.degrees(35))
                            .help("Pinned")
                    }
                    if let until = chat.mutedUntil, until > Date() {
                        Image(systemName: "bell.slash.fill")
                            .scaledIcon(10)
                            .foregroundStyle(Theme.textFaint)
                            .help("Muted")
                    }
                    Text(chat.lastTimestampShort)
                        .scaledMono(11)
                        .foregroundStyle(isSelected ? Theme.accentText : Theme.textFaint)
                        .monospacedDigit()
                        .opacity(0.85)
                }
                HStack(alignment: .center, spacing: 6) {
                    Text(chat.lastMessage)
                        .scaledUI(13)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Pending join-request chip — admin-gated via the VM
                    // helper so non-admins never see the badge even when
                    // the store happens to hold a count (e.g. stale entry
                    // after demote).
                    if let pending = vm.pendingRequestsChip(for: chat) {
                        Button {
                            selection = chat.id
                            session.pendingChatInfoSection = .pendingRequests
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "checkmark.circle")
                                    .scaledIcon(10, weight: .semibold)
                                Text("\(pending)")
                                    .scaledMono(10.5, weight: .semibold)
                                    .monospacedDigit()
                            }
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 5)
                            .frame(minHeight: 18)
                            .background(Theme.accent.opacity(0.25), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("\(pending) pending request\(pending == 1 ? "" : "s") — tap to review")
                    }
                    if chat.unread > 0 {
                        let muted = (chat.mutedUntil.map { $0 > Date() }) ?? false
                        Text("\(chat.unread)")
                            .scaledMono(10.5, weight: .semibold)
                            .foregroundStyle(muted ? Theme.textMuted : Color.white)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(muted ? Theme.surfaceAlt : Theme.accent,
                                        in: Capsule())
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

/// F91 v4 — 4-button kind filter. Added `.all` as the default no-filter
/// state. Orthogonal to the folder rail selection; applied on top of
/// `chatsFor` output. File-scoped so tests can import and exercise
/// `matches(_:)` directly.
enum KindScope: String, CaseIterable, Identifiable {
    case all, direct, groups, communities
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all:         return "bubble.left.and.bubble.right.fill"
        case .direct:      return "person.fill"
        case .groups:      return "person.3.fill"
        case .communities: return "building.2.fill"
        }
    }
    var label: String {
        switch self {
        case .all:         return "All"
        case .direct:      return "Direct"
        case .groups:      return "Groups"
        case .communities: return "Communities"
        }
    }
    /// Pure: returns true iff the chat matches this kind.
    /// `.all` matches every chat.
    func matches(_ chat: Chat) -> Bool {
        switch self {
        case .all:         return true
        case .direct:      return !chat.isGroup && !chat.isCommunityParent
        case .groups:      return chat.isGroup && !chat.isCommunityParent
        case .communities: return chat.isCommunityParent
        }
    }
}

private struct InvitePreviewRow: View {
    let state: ChatListViewModel.InviteLinkPreviewState
    var onJoin: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .scaledIcon(13)
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledUI(12.5, weight: .medium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .scaledUI(11)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
            }
            Spacer()
            if case .loading = state { ProgressView().controlSize(.small) }
            if case .joining = state { ProgressView().controlSize(.small) }
            if case .ready(_, let code) = state {
                Button("Join") { onJoin(code) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.surface)
    }

    private var title: String {
        switch state {
        case .loading: return "Resolving invite link…"
        case .ready(let g, _): return "Join group: \(g.name)"
        case .joining: return "Joining…"
        case .pending: return "Request sent"
        case .error: return "Couldn't resolve link"
        }
    }
    private var subtitle: String {
        switch state {
        case .ready(let g, _):
            return g.topic.isEmpty ? g.jid : g.topic
        case .pending: return "Waiting for admin approval"
        case .error(let m): return m
        default: return ""
        }
    }
    private var detailColor: Color {
        if case .error = state { return Color.red.opacity(0.9) }
        return Theme.textMuted
    }
}

extension Chat {
    /// Compact "HH:mm" or locale-equivalent / "Mon" / "12 May" / "12 May 24"
    /// style string for the row's right-aligned mono timestamp. Mirrors
    /// WhatsApp/iMessage behavior; honors the system 12/24-hour preference
    /// and current locale.
    fileprivate static let weekdayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
    fileprivate static let monthDayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()
    fileprivate static let monthDayYearFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yy"
        return f
    }()

    var lastTimestampShort: String {
        let date = Date(timeIntervalSince1970: TimeInterval(lastTimestamp))
        guard lastTimestamp > 0 else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(date) {
            return Self.yesterdayFmt.localizedString(from: DateComponents(day: -1))
        }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? Int.max
        let f: DateFormatter
        if days < 7 {
            f = Self.weekdayFmt
        } else if days < 180 {
            f = Self.monthDayFmt
        } else {
            f = Self.monthDayYearFmt
        }
        return f.string(from: date)
    }

    fileprivate static let yesterdayFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()
}
