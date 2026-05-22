import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(\.modelContext) private var modelContext
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
        .onChange(of: selectedChat) { _, new in
            guard let new else { return }
            chatList?.markRead(new)
            // If user selected a community parent that has a default sub-group,
            // redirect selection to that sub-group so they land in Announcements.
            if let parent = chatList?.chats.first(where: { $0.jid == new && $0.isCommunityParent }),
               let defaultSub = chatList?.chats.first(where: {
                   $0.communityParentJID == parent.jid && $0.isDefaultSubGroup
               }) {
                selectedChat = defaultSub.jid
            }
        }
        .onChange(of: session.pendingChatSelection) { _, new in
            guard let new else { return }
            selectedChat = new
            session.pendingChatSelection = nil
        }
        .task {
            guard let client = session.client else { return }
            let vm = ChatListViewModel(client: client, context: modelContext)
            self.chatList = vm
            let groups = GroupsViewModel(client: client)
            await groups.refresh()
            vm.mergeGroups(groups.groups)
            session.ingestGroups(groups.groups)
            let contacts = (try? client.listContacts()) ?? []
            vm.resolveNames(contacts)
            vm.mergeContacts(contacts)
            session.ingestContacts(contacts)
            let stream = client.eventStream()
            for await event in stream {
                switch event {
                case .message(let m):
                    session.ingestPushName(jid: m.senderJID, name: m.senderPushName)
                    vm.ingest(m)
                case .reaction(let r):
                    vm.persistReaction(r)
                case .historySync:
                    let cs = (try? client.listContacts()) ?? []
                    vm.resolveNames(cs)
                    vm.mergeContacts(cs)
                    session.ingestContacts(cs)
                default:
                    break
                }
            }
        }
    }
}
