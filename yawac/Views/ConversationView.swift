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
                                            onCastVote: { hashes, options in
                                                vm.castVote(messageID: msg.id,
                                                            hashes: hashes,
                                                            options: options,
                                                            pollSenderJID: msg.senderJID,
                                                            pollFromMe: msg.fromMe)
                                            },
                                            mentionResolver: { jid in session.displayName(for: jid) }
                                        ).id(msg.id)
                                    }
                                }
                            }
                            .padding()
                        }
                        .onChange(of: vm.messages.count) { _, _ in
                            if let last = vm.messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
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
            let vm = ConversationViewModel(chatJID: chatJID, client: client, context: modelContext)
            vm.loadHistory()
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
                case .receipt(let r) where r.chatJID == chatJID:
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
}
