import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(\.modelContext) private var modelContext
    @State private var chatList: ChatListViewModel?
    @State private var chatSearch: ChatSearchViewModel?
    @State private var selectedChat: Chat.ID?
    /// Last selected chat JID, persisted across launches.
    @AppStorage("yawac.lastSelectedChatJID") private var lastSelectedChatJID: String = ""

    var body: some View {
        NavigationSplitView {
            if let chatList, let chatSearch {
                ChatListView(selection: $selectedChat)
                    .environment(chatList)
                    .environment(chatSearch)
            } else {
                ProgressView()
            }
        } detail: {
            if let id = selectedChat {
                ConversationView(chatJID: id)
            } else {
                Text("Select a chat")
                    .font(Theme.ui(14))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Drop NavigationSplitView's auto-injected sidebar-toggle icon
        // (the lone "split-pane" button). The title bar itself stays so
        // traffic lights still render.
        .toolbar(removing: .sidebarToggle)
        .onChange(of: selectedChat) { _, new in
            guard let new else { return }
            lastSelectedChatJID = new
            // markRead intentionally NOT called here. ConversationView's
            // .task calls it AFTER loadHistory snapshots unread so the
            // initial scroll anchor (first-unread vs. bottom) is computed
            // against fresh data on every open, regardless of SwiftUI's
            // .onChange / .task evaluation order on cold start.
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
            vm.session = session
            session.chatList = vm
            self.chatList = vm
            self.chatSearch = ChatSearchViewModel(listVM: vm, validator: client)
            // Restore last-opened chat if it's in our chats list.
            if !lastSelectedChatJID.isEmpty,
               vm.chats.contains(where: { $0.jid == lastSelectedChatJID }) {
                selectedChat = lastSelectedChatJID
            }
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
                    // Incoming peer message → peer is online right now.
                    // Compensates for whatsmeow not delivering initial
                    // presence state to companion devices.
                    if !m.fromMe, !m.chatJID.hasSuffix("@g.us") {
                        session.markOnline(jid: m.chatJID)
                    }
                    vm.ingest(m)
                case .reaction(let r):
                    vm.persistReaction(r)
                    if r.senderJID != "me", !r.chatJID.hasSuffix("@g.us") {
                        session.markOnline(jid: r.chatJID)
                    }
                case .chatPresence(let chat, _, let typing):
                    // Typing in a direct chat is a strong online signal.
                    if typing, !chat.hasSuffix("@g.us") {
                        session.markOnline(jid: chat)
                    }
                case .presence(let jid, let online, let lastSeen):
                    session.ingestPresence(jid: jid, online: online, lastSeen: lastSeen)
                case .historySync:
                    let cs = (try? client.listContacts()) ?? []
                    vm.resolveNames(cs)
                    vm.mergeContacts(cs)
                    session.ingestContacts(cs)
                case .messageEdited(let chatJID, let messageID, let newText, let ts):
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    session.currentConversation?.applyIncomingEdit(
                        chatJID: chatJID, messageID: messageID, newText: newText, at: when)
                case .messageRevoked(let chatJID, let messageID, let revokedBy, let ts):
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    session.currentConversation?.applyIncomingRevoke(
                        chatJID: chatJID, messageID: messageID, revokedBy: revokedBy, at: when)
                default:
                    break
                }
            }
        }
    }
}
