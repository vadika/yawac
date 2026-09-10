import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(\.modelContext) private var modelContext
    private var chatList: ChatListViewModel? { session.chatList }
    @State private var chatSearch: ChatSearchViewModel?
    /// Last selected chat JID, persisted across launches.
    @AppStorage("yawac.lastSelectedChatJID") private var lastSelectedChatJID: String = ""

    /// Sidebar selection is driven through `session.nav` so the
    /// navigation stack (BackBar) and the NavigationSplitView detail
    /// pane share one source of truth. A sidebar tap writes here →
    /// `openRootChat` → trail resets to depth 0. Reads return the top
    /// of the stack so the row stays highlighted while drilled in.
    /// Sidebar highlight follows the ROOT of the navigation stack —
    /// never the drilled-in chat. When the user is at group A and
    /// drills into member B, the sidebar still shows A highlighted
    /// (a back-pop returns there); the detail pane separately mounts
    /// `ConversationView(chatJID: nav.currentJID)` for B and renders
    /// the BackBar above it.
    private var selectedChat: Binding<Chat.ID?> {
        Binding(
            get: { session.nav.stack.first?.id },
            set: { new in
                guard let new else {
                    session.nav.clear()
                    return
                }
                // Echo guard: if the sidebar is just re-asserting the
                // root that's already on the stack, skip openRoot so we
                // don't truncate a drilled trail.
                if new == session.nav.stack.first?.id { return }
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
                    // Fresh install lands with a 300pt sidebar; macOS
                    // persists user resize in window state thereafter.
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
            } else {
                ProgressView()
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
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
        .alert("Couldn’t save messages", isPresented: Binding(
            get: { session.persistenceError != nil },
            set: { if !$0 { session.persistenceError = nil } })) {
                Button("OK") { session.persistenceError = nil }
            } message: { Text(session.persistenceError ?? "") }
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
        .onChange(of: session.pendingShortcutQuery) { _, newQuery in
            guard let newQuery, let chatSearch else { return }
            chatSearch.query = newQuery
            // Consume: reset so the next shortcut with the same query
            // still triggers the change.
            session.pendingShortcutQuery = nil
        }
        .task {
            guard let client = session.client, let vm = session.chatList else { return }
            self.chatSearch = ChatSearchViewModel(listVM: vm, validator: client)
            if !lastSelectedChatJID.isEmpty,
               vm.chats.contains(where: { $0.jid == lastSelectedChatJID }) {
                session.openRootChat(lastSelectedChatJID)
            }
        }
    }
}
