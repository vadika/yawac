import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ConversationView: View {
    let chatJID: String
    @Environment(SessionViewModel.self) private var session
    @Environment(\.modelContext) private var modelContext
    @State private var vm: ConversationViewModel?

    var body: some View {
        Group {
            if let vm {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(vm.messages) { msg in
                                    MessageRow(
                                        message: msg,
                                        status: vm.receiptStatus[msg.id],
                                        senderName: session.displayName(for: msg.senderJID),
                                        localPath: vm.localPaths[msg.id]
                                    ).id(msg.id)
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
                        Task { @MainActor in await vm.sendImage(at: url) }
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
                    vm.ingest(m)
                case .chatPresence(let chat, _, let typing) where chat == chatJID:
                    vm.peerTyping = typing
                case .receipt(let r) where r.chatJID == chatJID:
                    vm.applyReceipt(r)
                default:
                    break
                }
            }
        }
    }
}
