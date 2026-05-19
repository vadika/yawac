import SwiftUI

struct ContentView: View {
    @Environment(SessionViewModel.self) private var session
    @State private var chatList: ChatListViewModel?
    @State private var selectedChat: Chat.ID?

    var body: some View {
        NavigationSplitView {
            if let chatList {
                ChatListView(selection: $selectedChat)
                    .environment(chatList)
            } else {
                ProgressView()
            }
        } detail: {
            if let id = selectedChat {
                ConversationView(chatJID: id)
            } else {
                Text("Select a chat").foregroundStyle(.secondary)
            }
        }
        .task {
            guard let client = session.client else { return }
            let vm = ChatListViewModel(client: client)
            self.chatList = vm
            for await event in client.events {
                if case .message(let m) = event { vm.ingest(m) }
            }
        }
    }
}
