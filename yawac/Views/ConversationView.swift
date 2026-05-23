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
        HStack {
            VStack { Divider() }
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            VStack { Divider() }
        }
        .padding(.vertical, 4)
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

    var body: some View {
        Group {
            if let vm {
                VStack(spacing: 0) {
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
                                            }
                                        ).id(msg.id)
                                    }
                                }
                            }
                            .padding()
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
                    }
                    if vm.peerTyping {
                        Text("typing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    Divider()
                    ComposerView(vm: vm)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(session.displayName(for: chatJID))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("Chat info")
            }
        }
        .inspector(isPresented: $showInfo) {
            ChatInfoView(chatJID: chatJID)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
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
        .task(id: chatJID) {
            guard let client = session.client else { return }
            // Reset scroll bookkeeping for the new chat.
            didInitialScroll = false
            lastSeenCount = 0
            let vm = ConversationViewModel(chatJID: chatJID, client: client, context: modelContext)
            vm.loadHistory()
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
            try? client.subscribePresence(chatJID)
            let stream = client.eventStream()
            for await event in stream {
                switch event {
                case .message(let m):
                    session.ingestPushName(jid: m.senderJID, name: m.senderPushName)
                    vm.ingest(m)
                case .chatPresence(let chat, _, let typing) where chat == chatJID:
                    vm.peerTyping = typing
                case .receipt(let r) where Self.receiptMatches(r.chatJID, chat: chatJID, client: client):
                    vm.applyReceipt(r)
                case .reaction(let r) where r.chatJID == chatJID:
                    vm.applyReaction(r)
                case .pollVote(let chat, let pmid, let voter, let hashes) where chat == chatJID:
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
