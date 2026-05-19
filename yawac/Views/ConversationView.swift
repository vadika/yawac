import SwiftUI

struct ConversationView: View {
    let chatJID: String
    @Environment(SessionViewModel.self) private var session
    @State private var vm: ConversationViewModel?

    var body: some View {
        Group {
            if let vm {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(vm.messages) { msg in
                                    MessageRow(message: msg).id(msg.id)
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
        .navigationTitle(chatJID)
        .task(id: chatJID) {
            guard let client = session.client else { return }
            let vm = ConversationViewModel(chatJID: chatJID, client: client)
            self.vm = vm
            let stream = client.eventStream()
            for await event in stream {
                switch event {
                case .message(let m):
                    vm.ingest(m)
                case .chatPresence(let chat, _, let typing) where chat == chatJID:
                    vm.peerTyping = typing
                default:
                    break
                }
            }
        }
    }
}
