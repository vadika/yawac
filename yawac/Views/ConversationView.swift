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

    /// Derives the banner state from the global session signals.
    /// Sync is shown only while the global syncing flag is set; offline
    /// reflects the connection state. Idle hides the banner entirely.
    private var currentSyncState: SyncState {
        switch session.state {
        case .needsPair, .loading: return .connecting
        case .error: return .offline
        case .ready: return session.syncing ? .syncing : .idle
        }
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

    var body: some View {
        Group {
            if let vm {
                VStack(spacing: 0) {
                    headerBar
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
                                            onJumpToQuoted: { id in vm.jumpToQuoted(id: id) },
                                            isHighlighted: vm.highlightedID == msg.id
                                        )
                                        .id(msg.id)
                                        .modifier(BottomVisibilityTracker(
                                            isLast: msg.id == vm.messages.last?.id,
                                            atBottom: $atBottom))
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
                    ComposerView(vm: vm)
                }
                .background(Theme.bg)
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            let s = currentSyncState
            if s != .idle {
                SyncBanner(state: s)
                    .padding(.top, 78) // clears the 64pt header strip
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: currentSyncState)
        .inspector(isPresented: $showInfo) {
            ChatInfoView(chatJID: chatJID) {
                showInfo = false
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        // Drives the window title (visible in the Window menu + dock
        // context menu + screen readers even with the title bar hidden).
        .navigationTitle("yawac — \(session.displayName(for: chatJID))")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let vm else { return false }
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in await vm.sendAttachment(at: url) }
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
            let vm = ConversationViewModel(chatJID: chatJID, client: client, context: modelContext)
            vm.loadHistory()
            // markRead AFTER loadHistory so the unread snapshot used for
            // the scroll anchor isn't pre-cleared.
            session.chatList?.markRead(chatJID)
            vm.markAllAsRead()
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
