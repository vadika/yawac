import Foundation
import Observation

@Observable @MainActor
final class SessionViewModel {
    enum State: Equatable {
        case loading
        case needsPair
        case ready
        case error(String)
    }

    var state: State = .loading
    var qrCode: String?
    var client: WAClient?
    /// Back-ref to the chat list VM so views (e.g. ConversationView) can
    /// invoke side-effects like `markRead` without threading it through
    /// every constructor. Set once from ContentView's boot path.
    weak var chatList: ChatListViewModel?
    weak var currentConversation: ConversationViewModel?
    var syncing: Bool = false
    var syncedConversations: Int = 0
    var contactNames: [String: String] = [:]
    /// Sum of `unread` across all chats. Driven by ChatListViewModel so
    /// MenuBarExtra can flip between the idle (template) and active
    /// (red-dot) menubar glyphs without subscribing to the chat list.
    var totalUnread: Int = 0
    /// Set by ChatListViewModel when a chat is deleted so ContentView can
    /// clear the detail selection if that chat was open. Consumed + cleared
    /// by ContentView via `.onChange`.
    var deletedChatJID: String?
    /// JIDs (bare) the user has blocked. Seeded from the server via
    /// `loadBlocklist()` on connect; updated by BlocklistChanged events.
    private(set) var blockedJIDs: Set<String> = []

    enum Connection { case connecting, online, offline }
    /// Runtime socket health, independent of the pairing `state`.
    /// Drives the sync banner alongside `state`.
    private(set) var connection: Connection = .connecting
    /// How long after a disconnect we wait before declaring `.offline`
    /// (whatsmeow is auto-retrying during this window). Var so tests
    /// can shrink it.
    var offlineDelay: Duration = .seconds(8)
    private var offlineWatchdog: Task<Void, Never>?
    private var connectivity: ConnectivityMonitor?
    /// When non-nil, the chat list / detail pane should focus this JID.
    /// Consumed and cleared by `ContentView` via `.onChange`.
    var pendingChatSelection: String?

    /// Per-peer presence. `online == true` → currently connected.
    /// `lastSeen` is seconds-since-epoch when peer went offline; 0 means
    /// peer hasn't shared lastSeen privacy (the most common case).
    struct Presence: Equatable {
        var online: Bool
        var lastSeen: Int64
    }
    var presenceByJID: [String: Presence] = [:]

    func ingestPresence(jid: String, online: Bool, lastSeen: Int64) {
        let key = JIDNormalize.canonical(jid, client: client)
        presenceByJID[key] = Presence(online: online, lastSeen: lastSeen)
    }

    /// Treat peer activity (incoming message, typing) as proof they are
    /// currently online. Whatsmeow only emits `events.Presence` on
    /// transitions and never delivers the *initial* online state to
    /// companion devices, so without this nudge the header would stay
    /// blank until the peer happens to go offline once.
    func markOnline(jid: String) {
        let key = JIDNormalize.canonical(jid, client: client)
        presenceByJID[key] = Presence(online: true, lastSeen: 0)
    }

    func presence(for jid: String) -> Presence? {
        let key = JIDNormalize.canonical(jid, client: client)
        return presenceByJID[key]
    }

    func requestSelectChat(_ jid: String) {
        pendingChatSelection = JIDNormalize.canonical(jid, client: client)
    }

    func ingestContacts(_ cs: [BridgeContact]) {
        for c in cs { contactNames[c.jid] = c.name }
    }

    func ingestGroups(_ gs: [BridgeGroupModel]) {
        for g in gs where !g.name.isEmpty { contactNames[g.jid] = g.name }
    }

    /// Records a sender's push-name (the name they set on their phone)
    /// against their JID. Lower priority than explicit contact names —
    /// only inserted when no other name is known.
    func ingestPushName(jid: String, name: String?) {
        guard let name, !name.isEmpty else { return }
        let key = JIDNormalize.bare(jid)
        if contactNames[key] == nil { contactNames[key] = name }
    }

    func displayName(for jid: String) -> String {
        if jid == "status@broadcast" { return "Status updates" }
        if jid.hasSuffix("@broadcast") { return "Broadcast" }
        // Senders in groups arrive with a `:<device>` suffix that the
        // contact map is keyed without — strip before lookup, then also
        // try the LID→PN canonical form for `@lid` senders.
        let bare = JIDNormalize.bare(jid)
        if let n = contactNames[bare] { return n }
        let canonical = JIDNormalize.canonical(jid, client: client)
        if canonical != bare, let n = contactNames[canonical] { return n }
        if let at = bare.firstIndex(of: "@") {
            return String(bare[..<at])
        }
        return bare
    }

    func isBlocked(_ jid: String) -> Bool {
        blockedJIDs.contains(JIDNormalize.bare(jid))
    }

    /// Refetch the full blocklist from the server (off-main, since the
    /// gomobile IQ blocks) and replace the local set.
    func loadBlocklist() {
        guard let client else { return }
        Task { @MainActor [weak self] in
            do {
                let jids = try await Task.detached { try client.listBlocked() }.value
                self?.blockedJIDs = Set(jids.map { JIDNormalize.bare($0) })
            } catch {
                NSLog("[yawac/blocklist] loadBlocklist failed: %@",
                      String(describing: error))
            }
        }
    }

    /// Block/unblock a user. Updates the local set on success.
    func setBlocked(_ jid: String, blocked: Bool) {
        guard let client else { return }
        let bare = JIDNormalize.bare(jid)
        Task { @MainActor [weak self] in
            do {
                try await Task.detached { try client.setBlocked(jid: bare, blocked: blocked) }.value
                if blocked { self?.blockedJIDs.insert(bare) }
                else { self?.blockedJIDs.remove(bare) }
            } catch {
                NSLog("[yawac/blocklist] setBlocked failed jid=%@ err=%@",
                      bare, String(describing: error))
            }
        }
    }

    /// Apply an inbound BlocklistChanged event. A "modify" action (or an
    /// empty change list) means "re-sync everything".
    func applyBlocklistChange(action: String, changes: [(jid: String, action: String)]) {
        if action == "modify" || changes.isEmpty {
            loadBlocklist()
            return
        }
        for ch in changes {
            let bare = JIDNormalize.bare(ch.jid)
            switch ch.action {
            case "block":   blockedJIDs.insert(bare)
            case "unblock": blockedJIDs.remove(bare)
            default:        break
            }
        }
    }

    private var eventTask: Task<Void, Never>?
    private var syncWatchdog: Task<Void, Never>?

    /// Socket came up (initial connect OR a whatsmeow auto/forced
    /// reconnect — Connected fires every time).
    func markConnected() {
        offlineWatchdog?.cancel()
        offlineWatchdog = nil
        connection = .online
    }

    /// Socket dropped. whatsmeow is already retrying with backoff, so we
    /// show `.connecting` and only escalate to `.offline` if it hasn't
    /// recovered within `offlineDelay`.
    func markDisconnected() {
        connection = .connecting
        offlineWatchdog?.cancel()
        offlineWatchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.offlineDelay)
            guard !Task.isCancelled else { return }
            if self.connection != .online { self.connection = .offline }
        }
    }

    private func armSyncWatchdog() {
        syncWatchdog?.cancel()
        syncWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.syncing = false
        }
    }

    func boot() async {
        do {
            let url = try AppPaths.databaseURL()
            let c = try WAClient(dbPath: url.path)
            self.client = c
            try c.connect()
            self.state = c.isLoggedIn ? .ready : .needsPair
            hydratePushNamesFromStore()
            consumeEvents()
            let monitor = ConnectivityMonitor(
                isReady: { [weak self] in self?.state == .ready },
                isConnected: { [weak self] in self?.client?.connected ?? false },
                reconnect: { [weak self] _ in
                    guard let c = self?.client else { return }
                    // forceReconnect blocks on gomobile (DNS dial) — run
                    // off-main and await so the retry loop serializes.
                    await Task.detached { c.forceReconnect() }.value
                })
            monitor.start()
            self.connectivity = monitor
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Rebuilds the in-memory contactNames map from persisted push names
    /// captured on prior sessions so cold-start renders names instead of
    /// raw user ids — even for chats the user never opens this session.
    private func hydratePushNamesFromStore() {
        for (jid, name) in SQLiteDedupe.sendersWithPushNames() {
            let key = JIDNormalize.bare(jid)
            if contactNames[key] == nil { contactNames[key] = name }
        }
    }

    private func consumeEvents() {
        guard let client else { return }
        eventTask?.cancel()
        let stream = client.eventStream()
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    func logout() async {
        try? client?.logout()
        client = nil
        qrCode = nil
        syncWatchdog?.cancel()
        syncing = false
        syncedConversations = 0
        offlineWatchdog?.cancel()
        offlineWatchdog = nil
        connection = .connecting
        connectivity?.stop()
        connectivity = nil
        state = .loading
        eventTask?.cancel()
        eventTask = nil
        await boot()
    }

    private func handle(_ event: WAClient.Event) {
        switch event {
        case .qr(let code):
            qrCode = code
            state = .needsPair
        case .pairSuccess:
            qrCode = nil
            state = .ready
        case .connected:
            qrCode = nil
            state = .ready
            markConnected()
            syncing = true
            armSyncWatchdog()
            // Publish our own presence as available so whatsmeow honors
            // SubscribePresence(jid) calls — peers don't share presence
            // with companions that look offline. Best-effort: errors
            // here mean we'll just not see online dots.
            try? client?.sendPresence(available: true)
        case .historySync(let n):
            syncedConversations += n
            armSyncWatchdog()
        case .loggedOut:
            state = .needsPair
            syncWatchdog?.cancel()
            syncing = false
        case .disconnected:
            markDisconnected()
        case .message(let m):
            // Capture pushName globally so closed chats also build the
            // contactNames map — otherwise senders are only learned when
            // their chat happens to be open.
            ingestPushName(jid: m.senderJID, name: m.senderPushName)
        case .receipt(let r):
            persistReceipt(r)
        case .pollVote(let chat, let pmid, let voter, let hashes):
            persistPollVote(chatJID: chat, pollMessageID: pmid,
                            voterJID: voter, optionHashes: hashes)
        default:
            break
        }
    }

    /// Off-actor raw SQLite update so the open ConversationView still
    /// gets the live event for in-memory state, while the persisted
    /// column is updated in the background for cold-start hydration.
    private nonisolated func persistReceipt(_ r: BridgeReceipt) {
        Task.detached(priority: .utility) {
            _ = SQLiteDedupe.applyReceiptStatus(
                messageIDs: r.messageIDs, status: r.status)
        }
    }

    private nonisolated func persistPollVote(chatJID: String,
                                             pollMessageID: String,
                                             voterJID: String,
                                             optionHashes: [String]) {
        let json = (try? JSONEncoder().encode(optionHashes))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        Task.detached(priority: .utility) {
            SQLiteDedupe.upsertPollVote(
                chatJID: chatJID,
                pollMessageID: pollMessageID,
                voterJID: voterJID,
                optionHashesJSON: json,
                timestamp: Date())
        }
    }
}
