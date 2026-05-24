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
    var syncing: Bool = false
    var syncedConversations: Int = 0
    var contactNames: [String: String] = [:]
    /// Sum of `unread` across all chats. Driven by ChatListViewModel so
    /// MenuBarExtra can flip between the idle (template) and active
    /// (red-dot) menubar glyphs without subscribing to the chat list.
    var totalUnread: Int = 0
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

    private var eventTask: Task<Void, Never>?
    private var syncWatchdog: Task<Void, Never>?

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
            break
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
