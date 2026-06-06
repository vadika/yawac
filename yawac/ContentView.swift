import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(\.modelContext) private var modelContext
    @State private var chatList: ChatListViewModel?
    @State private var chatSearch: ChatSearchViewModel?
    /// Last selected chat JID, persisted across launches.
    @AppStorage("yawac.lastSelectedChatJID") private var lastSelectedChatJID: String = ""

    /// Sidebar selection is driven through `session.nav` so the
    /// navigation stack (BackBar) and the NavigationSplitView detail
    /// pane share one source of truth. A sidebar tap writes here →
    /// `openRootChat` → trail resets to depth 0. Reads return the top
    /// of the stack so the row stays highlighted while drilled in.
    private var selectedChat: Binding<Chat.ID?> {
        Binding(
            get: { session.nav.currentJID },
            set: { new in
                guard let new else {
                    session.nav.clear()
                    return
                }
                session.openRootChat(new)
            }
        )
    }

    /// App-wide connection/sync banner state. ContentView only renders
    /// once paired (`state == .ready` — AppRoot owns the pairing screens),
    /// so this is driven purely by the runtime connection health and the
    /// history-sync flag. Surfaced regardless of whether a chat is open.
    private var bannerState: SyncState {
        switch session.connection {
        case .offline:    return .offline
        case .connecting: return .connecting
        case .online:     return session.syncing ? .syncing : .idle
        }
    }

    var body: some View {
        NavigationSplitView {
            if let chatList, let chatSearch {
                ChatListView(selection: selectedChat)
                    .environment(chatList)
                    .environment(chatSearch)
            } else {
                ProgressView()
            }
        } detail: {
            if let id = session.nav.currentJID {
                ConversationView(chatJID: id)
            } else {
                Text("Select a chat")
                    .scaledUI(14)
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
        .overlay(alignment: .top) {
            if bannerState != .idle {
                SyncBanner(state: bannerState)
                    .padding(.top, 14)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: bannerState)
        .onChange(of: session.nav.currentJID) { _, new in
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
                // Treat the community→default-sub redirect as an openRoot
                // so the BackBar doesn't pop up over the announcements
                // pane the user thinks they tapped into directly.
                session.openRootChat(defaultSub.jid)
            }
        }
        .onChange(of: session.pendingChatSelection) { _, new in
            guard let new else { return }
            // openRoot path — search jump, newly-joined / newly-created
            // chat, Account → self-chat. Resets the trail.
            session.openRootChat(new)
            session.pendingChatSelection = nil
        }
        .onChange(of: session.pendingDrillSelection) { _, new in
            guard let new else { return }
            // Drill-in path — reply-privately (group → DM with sender).
            // Pushes onto the stack so back-pop returns to the group.
            session.drillIntoChat(new)
            session.pendingDrillSelection = nil
        }
        .onChange(of: session.deletedChatJID) { _, jid in
            guard let jid else { return }
            session.nav.removeChat(jid: jid)
            session.deletedChatJID = nil
        }
        .task {
            guard let client = session.client else { return }
            let vm = ChatListViewModel(client: client, context: modelContext)
            vm.session = session
            session.chatList = vm
            session.modelContext = modelContext
            self.chatList = vm
            self.chatSearch = ChatSearchViewModel(listVM: vm, validator: client)
            // Restore last-opened chat if it's in our chats list. Goes
            // through openRoot so the trail starts at depth 0 (no stale
            // BackBar from whatever the previous session was looking at).
            if !lastSelectedChatJID.isEmpty,
               vm.chats.contains(where: { $0.jid == lastSelectedChatJID }) {
                session.openRootChat(lastSelectedChatJID)
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
                case .connected:
                    // Reconnect (initial or auto/forced) — re-reconcile
                    // appstate-backed UI that may have changed while we
                    // were dark. The offline message queue is redelivered
                    // by the server as normal .message events.
                    vm.reconcilePinsWithStore()
                    vm.reconcileMutedWithStore()
                    vm.reconcileLIDDuplicates()
                    session.loadBlocklist()
                case .historySync:
                    if !UserDefaults.standard.bool(forKey: "historyBackfillCompleted") {
                        UserDefaults.standard.set(true, forKey: "historyBackfillCompleted")
                    }
                    let cs = (try? client.listContacts()) ?? []
                    vm.resolveNames(cs)
                    vm.mergeContacts(cs)
                    session.ingestContacts(cs)
                    vm.reconcilePinsWithStore()
                    vm.reconcileMutedWithStore()
                    vm.reconcileLIDDuplicates()
                    session.loadBlocklist()
                case .messageEdited(let chatJID, let messageID, let newText, let ts):
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingEdit(chatJID: canonical, messageID: messageID,
                                         newText: newText, at: when)
                    session.currentConversation?.applyIncomingEdit(
                        chatJID: chatJID, messageID: messageID, newText: newText, at: when)
                case .messageRevoked(let chatJID, let messageID, let revokedBy, let ts):
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingRevoke(chatJID: canonical, messageID: messageID,
                                           revokedBy: revokedBy, at: when)
                    session.currentConversation?.applyIncomingRevoke(
                        chatJID: chatJID, messageID: messageID, revokedBy: revokedBy, at: when)
                case .messageLocallyDeleted(let chatJID, let messageID, _):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingLocalDelete(chatJID: canonical, messageID: messageID)
                    session.currentConversation?.applyIncomingLocalDelete(
                        chatJID: chatJID, messageID: messageID)
                case .messageStarred(let chatJID, let messageID, _, _, let starred, let ts):
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingStar(chatJID: canonical, messageID: messageID,
                                         starred: starred, at: when)
                    session.currentConversation?.applyIncomingStar(
                        chatJID: chatJID, messageID: messageID,
                        starred: starred, at: when)
                case .chatPinned(let chatJID, let pinned, let ts):
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingChatPin(chatJID: canonical,
                                            pinned: pinned, at: when)
                case .chatMuted(let chatJID, let mutedUntilMs, let ts):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    let mutedUntil: Date? = mutedUntilMs == 0
                        ? nil
                        : Date(timeIntervalSince1970: TimeInterval(mutedUntilMs) / 1000)
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    vm.applyIncomingMute(chatJID: canonical,
                                         mutedUntil: mutedUntil,
                                         at: when)
                case .groupInfoChanged(let chatJID, let name, let description, let ts):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    vm.applyIncomingGroupInfo(
                        chatJID: canonical,
                        name:        name.isEmpty        ? nil : name,
                        description: description.isEmpty ? nil : description,
                        at: when)
                case .messagePinned(let chatJID, let targetID, _, let pinned, let ts):
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingMessagePin(chatJID: canonical,
                                               targetMessageID: targetID,
                                               pinned: pinned, at: when)
                    session.currentConversation?.applyIncomingMessagePin(
                        chatJID: chatJID, targetMessageID: targetID,
                        pinned: pinned, at: when)
                case .chatArchived(let chatJID, let archived, _):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingArchive(chatJID: canonical, archived: archived)
                case .chatDeleted(let chatJID, _):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingDelete(chatJID: canonical)
                case .contactUpdated(let jid, let fullName, _):
                    let canonical = JIDNormalize.canonical(jid, client: client)
                    vm.applyIncomingContact(jid: canonical, fullName: fullName)
                case .blocklistChanged(let action, let changes):
                    session.applyBlocklistChange(action: action, changes: changes)
                case .groupParticipantsChanged(let chatJID, let action, _, let jids, let ts):
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyGroupParticipantsChange(
                        chatJID: canonical, action: action, jids: jids, at: when)
                case .joinApprovalModeChanged(let chatJID, let on, _, _):
                    // SessionViewModel already routes this event to refresh /
                    // clear `JoinRequestStore`. Mirror the flag into `Chat`
                    // so the sidebar chip gate flips in lockstep with the
                    // store update.
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingJoinApprovalMode(chatJID: canonical, on: on)
                case .groupAnnounceChanged(let chatJID, let on, _, _):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyGroupAnnounce(chatJID: canonical, on: on)
                case .groupLockedChanged(let chatJID, let on, _, _):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyGroupLocked(chatJID: canonical, on: on)
                case .groupMemberAddModeChanged(let chatJID, let allMembersCanAdd, _, _):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyGroupMemberAddMode(chatJID: canonical,
                                               allMembersCanAdd: allMembersCanAdd)
                case .ephemeralTimerChanged(let chatJID, let seconds, _, _):
                    // Server-side timer change (either side of a 1:1 or a
                    // group admin). Refresh the in-memory Chat row so the
                    // inspector picker and any composer banner reflect it.
                    // 1:1 chats hydrate their timer only on the first
                    // EphemeralSetting event — whatsmeow doesn't expose
                    // a cold-read API for 1:1 ephemeral state.
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyEphemeralTimer(chatJID: canonical, seconds: seconds)
                default:
                    break
                }
            }
        }
    }
}
