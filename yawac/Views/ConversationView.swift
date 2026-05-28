import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private enum TimelineItem {
    case dateHeader(Date)
    case message(UIMessage)
}

private struct DateSeparator: View {
    let date: Date
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                .font(Theme.ui(11.5, weight: .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textFaint)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .padding(.vertical, 14)
    }
}

struct ConversationView: View {
    let chatJID: String
    @Environment(SessionViewModel.self) private var session
    @Environment(\.modelContext) private var modelContext
    @State private var vm: ConversationViewModel?
    @State private var didInitialScroll = false
    @State private var lastSeenCount = 0
    @State private var showInfo = false
    @State private var atBottom = true
    @State private var showForwardPicker = false
    @State private var pendingDelete: Chat?
    @State private var pendingBlock: Chat?
    @State private var contactEditing: Chat?

    @ViewBuilder
    private var inspectorPane: some View {
        ChatInfoView(
            chatJID: chatJID,
            onClose: { showInfo = false },
            onJumpToMessage: jumpToMessage,
            messageRevision: messageRevisionToken,
            mediaPathResolver: resolveMediaPath
        )
    }

    /// Cheap change-token that bumps when the message list, downloaded paths,
    /// or starred set changes — drives the inspector's media/files refresh.
    /// Extracted from the call site so the Swift type-checker doesn't choke on
    /// the chained-optional arithmetic (Release-config compile timeout).
    private var messageRevisionToken: Int {
        guard let vm else { return 0 }
        let starred = vm.messages.reduce(0) { $0 + ($1.starredAt != nil ? 1 : 0) }
        return vm.messages.count + vm.localPaths.count + starred
    }

    private func resolveMediaPath(_ id: String) -> String? {
        vm?.localPaths[id]
    }

    private func jumpToMessage(_ id: String) {
        vm?.jumpToQuoted(id: id)
    }

    /// Walks messages in chronological order, prepending a `.dateHeader`
    /// whenever the day changes.
    private func timeline() -> [TimelineItem] {
        guard let vm else { return [] }
        let cal = Calendar.current
        var out: [TimelineItem] = []
        var lastDay: DateComponents?
        for m in vm.messages {
            let day = cal.dateComponents([.year, .month, .day], from: m.timestamp)
            if day != lastDay {
                if let header = cal.date(from: day) {
                    out.append(.dateHeader(header))
                }
                lastDay = day
            }
            out.append(.message(m))
        }
        return out
    }

    /// Returns the optional dot color + label for the status segment of
    /// the header. nil → nothing rendered.
    ///
    /// - Typing wins over online state.
    /// - Online → green dot + "online".
    /// - Offline with non-zero lastSeen → grey dot + "last seen <relative>".
    /// - Offline with hidden lastSeen → nothing (matches WhatsApp's UX of
    ///   not labelling peers as "offline" when they hide last-seen privacy).
    /// - Groups: skip — presence isn't published per-group.
    private func headerStatus(isGroup: Bool) -> (Color?, String)? {
        if isGroup { return nil }
        if vm?.peerTyping == true {
            return (Theme.onlineDot, "typing…")
        }
        guard let p = session.presence(for: chatJID) else { return nil }
        if p.online {
            return (Theme.onlineDot, "online")
        }
        if p.lastSeen > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(p.lastSeen))
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            return (Theme.textFaint, "last seen \(fmt.localizedString(for: date, relativeTo: Date()))")
        }
        return nil
    }

    /// Replaces the composer while forwarding: selection count + actions.
    @ViewBuilder
    private func forwardBar(_ vm: ConversationViewModel) -> some View {
        HStack(spacing: 14) {
            Button("Cancel") { vm.cancelForward() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Text("\(vm.forwardSelection.count) selected")
                .font(Theme.ui(13))
                .foregroundStyle(Theme.text)
            Spacer()
            Button("Forward") { showForwardPicker = true }
                .buttonStyle(.plain)
                .foregroundStyle(vm.forwardSelection.isEmpty ? Theme.textFaint : Theme.accent)
                .disabled(vm.forwardSelection.isEmpty)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// Custom header bar replaces SwiftUI's titlebar so we can apply
    /// Graphite tokens directly (the OS title bar is hidden via
    /// .windowStyle(.hiddenTitleBar) on the WindowGroup).
    @ViewBuilder
    private var headerBar: some View {
        let name = session.displayName(for: chatJID)
        let isGroup = chatJID.hasSuffix("@g.us")
        HStack(spacing: 14) {
            AvatarView(jid: chatJID, name: name, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.ui(16, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.titleColor)
                    .lineLimit(1)
                if let (dotColor, label) = headerStatus(isGroup: isGroup) {
                    HStack(spacing: 5) {
                        if let dotColor {
                            Circle().fill(dotColor).frame(width: 6, height: 6)
                        }
                        Text(label)
                            .font(Theme.ui(12.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            Spacer()
            chatActionsMenu
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(showInfo ? Theme.accent : Theme.textMuted)
                    .padding(7)
                    .background(showInfo ? Theme.accentSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Chat info")
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .frame(height: 64)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        // Window-drag layer behind the row so any non-interactive
        // pixel on the header strip drags the window. Interactive
        // children (avatar tap, info button) win because they sit
        // above this in the ZStack-derived hit order.
        .background(WindowDragHandle())
    }

    /// The header `⋯` actions menu for the current chat. Extracted from
    /// `headerBar` to keep that expression small enough for the Swift
    /// type-checker under Release optimization.
    @ViewBuilder
    private var chatActionsMenu: some View {
        if let chat = session.chatList?.chats.first(where: { $0.jid == chatJID }) {
            let isDirect = !chat.isGroup && !chat.isCommunityParent
            Menu {
                Button(chat.pinnedAt != nil ? "Unpin chat" : "Pin chat") {
                    session.chatList?.pinChat(chat, pinned: chat.pinnedAt == nil)
                }
                Button(chat.archivedAt != nil ? "Unarchive" : "Archive") {
                    session.chatList?.archiveChat(chat, archived: chat.archivedAt == nil)
                }
                if isDirect {
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
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.textMuted)
                    .padding(7)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Chat actions")
        }
    }

    @ViewBuilder
    private func pinnedBanner(_ vm: ConversationViewModel) -> some View {
        if let m = vm.pinnedBannerMessage {
            Button {
                vm.jumpToQuoted(id: m.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .rotationEffect(.degrees(35))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pinned message")
                            .font(Theme.ui(10.5, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(Theme.textFaint)
                        Text(Self.pinSnippet(m))
                            .font(Theme.ui(12.5))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        vm.pinMessage(m, pinned: false)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Unpin")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.surfaceAlt)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var blockedBanner: some View {
        if session.isBlocked(chatJID) {
            HStack(spacing: 10) {
                Image(systemName: "nosign")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                Text("You blocked this contact")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Unblock") { session.setBlocked(chatJID, blocked: false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.surfaceAlt)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
        }
    }

    private static func pinSnippet(_ m: UIMessage) -> String {
        switch m.body {
        case .text(let t): return t
        case .media(let kind, let caption, let fileName, _):
            if let c = caption, !c.isEmpty { return c }
            if let n = fileName, !n.isEmpty { return n }
            switch kind {
            case "image":    return "Photo"
            case "video":    return "Video"
            case "audio":    return "Voice note"
            case "document": return "Document"
            case "sticker":  return "Sticker"
            default:         return kind
            }
        case .poll(let q, _, _): return q
        case .system(let s):     return s
        }
    }

    private var coreView: some View {
        Group {
            if let vm {
                VStack(spacing: 0) {
                    headerBar
                    pinnedBanner(vm)
                    blockedBanner
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                if !vm.olderUnavailable {
                                    HStack {
                                        Spacer()
                                        Button {
                                            vm.requestOlderHistory()
                                        } label: {
                                            if vm.loadingOlder {
                                                HStack(spacing: 4) {
                                                    ProgressView().controlSize(.small)
                                                    Text("Loading earlier messages…")
                                                }
                                            } else {
                                                Text("Load earlier messages")
                                            }
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(vm.loadingOlder)
                                        .padding(.vertical, 6)
                                        Spacer()
                                    }
                                }
                                ForEach(Array(timeline().enumerated()), id: \.offset) { _, item in
                                    switch item {
                                    case .dateHeader(let date):
                                        DateSeparator(date: date)
                                    case .message(let msg):
                                        MessageRow(
                                            message: msg,
                                            status: vm.receiptStatus[msg.id],
                                            senderName: session.displayName(for: msg.senderJID),
                                            localPath: vm.localPaths[msg.id],
                                            reactions: vm.reactions(for: msg.id),
                                            reactors: vm.reactors(for: msg.id),
                                            downloadError: vm.downloadErrors[msg.id],
                                            onRetryDownload: vm.retryHandler(for: msg),
                                            voteCounts: vm.voteCounts(for: msg.id),
                                            votersByOption: vm.voters(for: msg.id),
                                            mySelections: vm.mySelections(for: msg.id),
                                            onCastVote: { hashes, options in
                                                vm.castVote(messageID: msg.id,
                                                            hashes: hashes,
                                                            options: options,
                                                            pollSenderJID: msg.senderJID,
                                                            pollFromMe: msg.fromMe)
                                            },
                                            myReaction: vm.myReaction(for: msg.id),
                                            onReact: { emoji in
                                                vm.sendReaction(messageID: msg.id,
                                                                targetSenderJID: msg.senderJID,
                                                                targetFromMe: msg.fromMe,
                                                                emoji: emoji)
                                            },
                                            mentionResolver: { jid in session.displayName(for: jid) },
                                            onOpenChat: { jid in
                                                session.requestSelectChat(jid)
                                            },
                                            onReply: { m in vm.startReply(to: m) },
                                            onEdit: { m in vm.startEdit(m) },
                                            onDeleteForEveryone: { m in Task { await vm.deleteForEveryone(m) } },
                                            onDeleteForMe: { m in vm.deleteForMe(m) },
                                            onStar: { m in vm.starMessage(m, starred: m.starredAt == nil) },
                                            onPin: { m in vm.pinMessage(m, pinned: m.pinnedAt == nil) },
                                            onForward: { m in vm.beginForward(m) },
                                            onJumpToQuoted: { id in vm.jumpToQuoted(id: id) },
                                            isHighlighted: vm.highlightedID == msg.id,
                                            selecting: vm.forwardSelecting,
                                            selected: vm.forwardSelection.contains(msg.id),
                                            selectable: vm.canForward(msg),
                                            onToggleSelect: { vm.toggleForward(msg.id) }
                                        )
                                        .id(msg.id)
                                        .modifier(BottomVisibilityTracker(
                                            isLast: msg.id == vm.messages.last?.id,
                                            atBottom: $atBottom))
                                        .modifier(ViewportReadModifier(
                                            messageID: msg.id, vm: vm))
                                    }
                                }
                            }
                            .padding(.horizontal, 26)
                            .padding(.vertical, 8)
                        }
                        .background(Theme.bg)
                        .overlay(alignment: .bottomTrailing) {
                            if !atBottom, let last = vm.messages.last {
                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .frame(width: 36, height: 36)
                                        .background(.regularMaterial, in: Circle())
                                        .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                                        .shadow(radius: 3, y: 1)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 14)
                                .padding(.bottom, 12)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                            }
                        }
                        .onChange(of: vm.messages.count) { _, newCount in
                            // First population: anchor to initialAnchorID
                            // (first-unread, or latest if all read).
                            // Subsequent growth: auto-scroll only if user
                            // hasn't scrolled away (we just always follow
                            // for now since we don't track scroll offset).
                            if !didInitialScroll {
                                let anchor = vm.initialAnchorID ?? vm.messages.last?.id
                                guard let anchor else { return }
                                let position: UnitPoint =
                                    anchor == vm.messages.last?.id ? .bottom : .top
                                DispatchQueue.main.async {
                                    proxy.scrollTo(anchor, anchor: position)
                                    didInitialScroll = true
                                    lastSeenCount = newCount
                                }
                            } else if newCount > lastSeenCount, let last = vm.messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                                lastSeenCount = newCount
                            }
                        }
                        .onChange(of: vm.pendingScrollToID) { _, id in
                            guard let id else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                            vm.didFinishScroll(to: id)
                            vm.pendingScrollToID = nil
                        }
                    }
                    if vm.peerTyping {
                        HStack(spacing: 8) {
                            HStack(spacing: 3) {
                                ForEach(0..<3) { _ in
                                    Circle().fill(Theme.textMuted.opacity(0.6))
                                        .frame(width: 5, height: 5)
                                }
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Theme.otherBubble,
                                        in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                                    .stroke(Theme.otherBorder, lineWidth: 1)
                            )
                            Text("typing…")
                                .font(Theme.ui(12))
                                .foregroundStyle(Theme.textFaint)
                            Spacer()
                        }
                        .padding(.horizontal, 26).padding(.bottom, 4)
                    }
                    if vm.forwardSelecting {
                        forwardBar(vm)
                    } else {
                        ComposerView(vm: vm)
                    }
                }
                .background(Theme.bg)
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .inspector(isPresented: $showInfo) {
            inspectorPane
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        // Drives the window title (visible in the Window menu + dock
        // context menu + screen readers even with the title bar hidden).
        // SwiftUI's navigationTitle takes a plain String — no AttributedString
        // overload — so we use U+1D432 MATHEMATICAL BOLD SMALL Y which the
        // system font renders bold even in unstyled contexts (Window menu,
        // Dock context menu, screen readers).
        .navigationTitle("𝐲 - \(session.displayName(for: chatJID))")
        .sheet(isPresented: $showForwardPicker) {
            if let vm {
                ForwardPickerView(messageCount: vm.forwardSelection.count) { jid in
                    showForwardPicker = false
                    Task { await vm.executeForward(to: jid,
                                                   senderName: { session.displayName(for: $0) }) }
                }
                .environment(session)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let vm else { return false }
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in vm.stageAttachment(at: url) }
                    }
                }
            }
            return true
        }
        .onDisappear {
            session.currentConversation = nil
        }
        .task(id: chatJID) {
            guard let client = session.client else { return }
            // Reset scroll bookkeeping for the new chat. atBottom starts
            // false — the BottomVisibilityTracker on the last row flips it
            // true via .onAppear once that row enters the viewport. If
            // we anchor to first-unread (above bottom), the last row
            // never appears, atBottom stays false, and the chevron is
            // free to show as expected.
            didInitialScroll = false
            atBottom = false
            lastSeenCount = 0
            self.vm?.cancelForward()
            let vm = ConversationViewModel(chatJID: chatJID, client: client, context: modelContext)
            vm.loadHistory()
            // Don't bulk-clear unread on chat open — let
            // ViewportReadModifier dwell-mark each visible row instead
            // (WhatsApp semantics: receipts fire only after the user
            // has actually looked at a row).
            // Background-refresh poll tallies if any poll is in view. The
            // primary phone's response carries the current pollUpdates
            // bundle so tallies for polls created during this companion's
            // connected window (which had no embedded votes when first
            // observed) become visible without manual user action.
            if vm.messages.contains(where: { msg in
                if case .poll = msg.body { return true } else { return false }
            }) {
                vm.refreshPollTallies()
            }
            self.vm = vm
            session.currentConversation = vm
            vm.chatList = session.chatList
            vm.replayPendingForLoadedRows()
            try? client.subscribePresence(chatJID)
            let stream = client.eventStream()
            for await event in stream {
                switch event {
                case .message(let m):
                    session.ingestPushName(jid: m.senderJID, name: m.senderPushName)
                    vm.ingest(m)
                case .chatPresence(let chat, _, let typing) where JIDNormalize.canonical(chat, client: client) == chatJID:
                    vm.peerTyping = typing
                case .receipt(let r) where Self.receiptMatches(r.chatJID, chat: chatJID, client: client):
                    vm.applyReceipt(r)
                case .reaction(let r) where JIDNormalize.canonical(r.chatJID, client: client) == chatJID:
                    vm.applyReaction(r)
                case .pollVote(let chat, let pmid, let voter, let hashes) where JIDNormalize.canonical(chat, client: client) == chatJID:
                    vm.applyPollVote(pollMessageID: pmid, voterJID: voter, optionHashes: hashes)
                case .mediaRetry(let mid, let ok, let newPath, let err):
                    vm.applyMediaRetry(messageID: mid, ok: ok, newDirectPath: newPath, error: err)
                default:
                    break
                }
            }
        }
    }

    var body: some View {
        coreView
            .confirmationDialog(
                "Delete chat with \(pendingDelete?.name ?? "")?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { chat in
                Button("Delete", role: .destructive) {
                    session.chatList?.deleteChat(chat); pendingDelete = nil
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
                    session.chatList?.addContact(chat, fullName: full, firstName: first)
                }
            }
    }

    /// Receipt match that avoids a synchronous gomobile FFI call on every
    /// receipt event. Fast-paths the common case (already-canonical PN JID)
    /// by comparing `bare()` first, only paying for `canonical()` (which
    /// crosses into Go for LID→PN resolution) when the receipt is in
    /// `@lid` form.
    static func receiptMatches(_ receiptJID: String, chat: String, client: WAClient) -> Bool {
        let bare = JIDNormalize.bare(receiptJID)
        if bare == chat { return true }
        guard bare.hasSuffix("@lid") else { return false }
        return JIDNormalize.canonical(receiptJID, client: client) == chat
    }
}

/// 2s viewport-dwell read marker. WhatsApp's read-receipt semantics
/// aren't "chat opened" — it's "the user actually looked at the row".
/// Attach to every MessageRow; the modifier bails for outbound rows
/// and for ids that aren't tracked as unread, so the cost on read
/// messages is nil.
private struct ViewportReadModifier: ViewModifier {
    let messageID: String
    let vm: ConversationViewModel
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard vm.unreadInboundIDs.contains(messageID) else { return }
                task?.cancel()
                task = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if Task.isCancelled { return }
                    guard NSApp.isActive else { return }
                    vm.markVisibleAsRead(messageID: messageID)
                }
            }
            .onDisappear {
                task?.cancel()
                task = nil
            }
    }
}

/// Tracks the on-screen visibility of the chat's last row to drive the
/// floating "scroll to latest" button. The lazy stack instantiates and
/// disposes rows as they enter/leave the viewport, so this fires on the
/// exact moment the user scrolls away from (or back to) the bottom.
private struct BottomVisibilityTracker: ViewModifier {
    let isLast: Bool
    @Binding var atBottom: Bool

    func body(content: Content) -> some View {
        if isLast {
            content
                .onAppear { atBottom = true }
                .onDisappear { atBottom = false }
        } else {
            content
        }
    }
}
