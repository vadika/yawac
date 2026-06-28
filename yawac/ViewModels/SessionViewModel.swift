import AppKit
import Foundation
import Observation
import SwiftData

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
    /// Pending join-request counts per group, surfaced in the chat list
    /// badge and admin panel header. Recreated when the WAClient is built
    /// in `boot()` so the store can fan out queue refreshes via the bridge.
    private(set) var joinRequestStore: JoinRequestStore = JoinRequestStore()
    /// SwiftData context injected from `ContentView.task` once the
    /// environment is in scope. Read by `requestHistoryBackfillIfNeeded`
    /// to find the globally-oldest persisted message before issuing a
    /// one-shot HistorySyncFromOldest IQ on first v0.8.1 boot.
    @ObservationIgnored
    var modelContext: ModelContext?
    /// One-shot gate for the v0.8.1 history backfill — flipped to true on
    /// the first HistorySync arrival (see ContentView, T12) and reset on
    /// logout. UserDefaults-backed (matching `ChatListViewModel.deletedChats`
    /// style) rather than `@AppStorage` because the property-wrapper
    /// requires a SwiftUI view context and doesn't compose with the
    /// `@Observable` macro here.
    private static let historyBackfillCompletedKey = "historyBackfillCompleted"
    var historyBackfillCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.historyBackfillCompletedKey) }
        set { UserDefaults.standard.set(newValue,
                                        forKey: Self.historyBackfillCompletedKey) }
    }

    /// F92: timestamp (Unix seconds) of the last on-reconnect
    /// catch-up history sync. Used to throttle the per-connect 7-day
    /// catch-up so reconnect flapping doesn't hammer the phone.
    private static let lastReconnectCatchupKey = "yawac.lastReconnectCatchupAt"

    var lastReconnectCatchupAt: TimeInterval {
        get { UserDefaults.standard.double(forKey: Self.lastReconnectCatchupKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastReconnectCatchupKey) }
    }

    /// F92 hardening (v0.10.24): dropped from 5 min to 30 s. The
    /// original throttle was set to prevent reconnect-flap from
    /// hammering the phone, but a 30 s window still prevents
    /// hammering in practice while letting a user who launches +
    /// quickly relaunches still re-fire the catch-up. Phone-side
    /// catch-up dedupes anyway (idempotent FULL_HISTORY_SYNC_ON_DEMAND
    /// request IDs collide and the phone discards the second).
    static let reconnectCatchupThrottle: TimeInterval = 30
    /// User-triggered full history sync progress state. Read by the
    /// AccountPanel "Full history sync" row to render a linear
    /// ProgressView + counters while a backfill burst is in flight.
    /// F28.
    struct FullSyncState: Equatable {
        var inFlight: Bool = false
        /// Highest progress value seen during the current burst (phone may
        /// report 100 on every ON_DEMAND chunk; we keep the max).
        var progress: Int = 0
        /// Number of contentful HistorySync chunks observed during the burst.
        var chunks: Int = 0
        /// Sum of per-chunk message counts during the burst.
        var messages: Int = 0
        /// F29: true once `startFullHistorySync` has run at least once
        /// this app session. Lets the idle sublabel distinguish "never
        /// tried" ("Pull older messages from phone") from "tried and
        /// got nothing back" ("Phone replied with no new history").
        var attempted: Bool = false
        /// F39: per-message fresh / dupe counters bumped by
        /// `ChatListViewModel.ingest`'s flush. Lets the AccountPanel
        /// sublabel show "X new / Y already had" so the user can see
        /// the rate of actually-new history vs. phone-side overlap
        /// instead of guessing from the raw `chunks` count.
        var fresh: Int = 0
        var dupe: Int = 0
    }

    /// Observable so the Settings row redraws on each chunk.
    private(set) var fullSync: FullSyncState = .init()

    /// F67: process-lifetime dedupe set for media-retry IQ requests.
    /// Previously `ConversationViewModel.retriesRequested` lived per-CVM
    /// and got wiped on every chat-switch, so the same expired/broken
    /// message issued a fresh `requestMediaRetry` IQ each time the user
    /// re-opened its chat. Counter evidence (875 retries in one session,
    /// ~17 chat-opens × ~50 broken media per chat) confirmed the
    /// pattern. Lives on the session so all CVMs share the same set
    /// for the process's lifetime; persisting across launches would
    /// require SwiftData and isn't worth the complexity yet.
    @ObservationIgnored var mediaRetryAttempted: Set<String> = []

    /// Watchdog cleared 60s after the last chunk arrives.
    @ObservationIgnored private var fullSyncTimeoutTask: Task<Void, Never>?
    /// Throttle for `didBecomeActive` refresh fan-out (30s).
    private var lastForegroundRefresh: Date?
    @ObservationIgnored
    nonisolated(unsafe) private var didBecomeActiveObserver: NSObjectProtocol?
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
    /// F97: Search shortcut payload. SearchMessagesIntent writes the
    /// query string here; ContentView observes and applies to the
    /// existing ChatSearchViewModel. Consumer resets to nil after
    /// applying so re-firing the same query re-triggers the change.
    var pendingShortcutQuery: String? = nil
    /// F98: which ChatInfoView section to scroll to on next mount.
    /// ChatListView writes this when the user taps a sidebar
    /// affordance (e.g. pending-request chip); ChatInfoView observes
    /// + scrolls + clears so re-tapping re-triggers.
    enum PendingChatInfoSection: Equatable { case pendingRequests }
    var pendingChatInfoSection: PendingChatInfoSection? = nil
    /// JIDs (bare) the user has blocked. Seeded from the server via
    /// `loadBlocklist()` on connect; updated by BlocklistChanged events.
    private(set) var blockedJIDs: Set<String> = []

    /// Bare phone-digit prefix of the paired account's JID
    /// (e.g. `"5550100"` for `"5550100@s.whatsapp.net"`). Empty string
    /// when not signed in. Used by the mute notification gate so an
    /// `@<digits>` mention in a muted group still pierces the mute.
    var ownPhoneDigits: String {
        guard let jid = client?.ownJID, let at = jid.firstIndex(of: "@") else {
            return ""
        }
        return String(jid[..<at])
    }

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
    /// `requestSelectChat` writes here for the **openRoot** path (search
    /// jumps, newly-created chat, account self-chat, etc.) — the trail
    /// resets when ContentView assigns it through.
    var pendingChatSelection: String?

    /// Drill-in counterpart of `pendingChatSelection`. Set by the
    /// "Reply privately" affordance (group → DM with sender) so the
    /// destination is layered ON TOP OF the originating chat instead of
    /// replacing the trail. Consumed and cleared by ContentView via
    /// `.onChange`.
    var pendingDrillSelection: String?

    /// Chat navigation stack — backs the BackBar (v0.9.14). The current
    /// chat is `nav.current`; the "Back to {origin}" label reads
    /// `nav.origin`. Sidebar / search-hit selection writes here via
    /// `openRootChat`; in-chat taps (member, participant, reply-privately,
    /// community sub-group, mention popover, quoted author) push via
    /// `drillIntoChat`. ChatNavigation is itself `@Observable` so view
    /// updates propagate naturally; we therefore don't need to mark
    /// `ObservationIgnored` here.
    let nav = ChatNavigation()

    /// Set together with `pendingChatSelection` to request a scroll-to
    /// inside the freshly-opened chat. ConversationView consumes + clears.
    var pendingJumpMessageID: String?

    /// Chat that owns `pendingJumpMessageID`. Only the matching
    /// ConversationView is allowed to consume the message-id, so a
    /// stale CVM (still mounted while the chat swap is in flight)
    /// doesn't drain the jump before the destination chat takes over.
    var pendingJumpChatJID: String?

    /// Reply target carried across a chat switch. Set by the
    /// "Reply privately" affordance in `ConversationView` immediately
    /// after `requestSelectChat(sender)`, then consumed + cleared by the
    /// destination `ConversationViewModel` when its `.task` boots.
    /// Ephemeral UX state — not persisted, not observed for view updates.
    @ObservationIgnored
    var pendingReplyTarget: UIMessage?

    /// One-shot guard so we only force-rebootstrap the FTS Sender
    /// column once per session — after `.connected` has handed the
    /// MessageIndex its canonicalizer + own JID. Bootstrap that ran at
    /// app-init couldn't have used either.
    @ObservationIgnored
    private var didRebootstrapMessageIndex: Bool = false

    /// Coalesces the `.historySync` reconcile fan-out (F19). Initial sync
    /// delivers a burst of HistorySync events; we collapse the burst into
    /// a single 250 ms-debounced flush so we don't run the CGo
    /// `listContacts` round-trip + four reconcile passes per event.
    @ObservationIgnored
    private var historySyncFlush: Task<Void, Never>?

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

    /// Build a `ChatRef` for the navigation stack. Resolves the JID to
    /// its canonical form (LID → PN where possible) and looks up the
    /// display name through `displayName(for:)` so the BackBar never
    /// shows a raw JID (spec §6).
    func chatRef(forJID jid: String) -> ChatRef {
        let canonical = JIDNormalize.canonical(jid, client: client)
        let name = displayName(for: canonical)
        return ChatRef(id: canonical, displayName: name)
    }

    /// Sidebar / search-hit / restore — reset the navigation trail to a
    /// fresh root chat. The BackBar disappears at depth 0.
    func openRootChat(_ jid: String) {
        nav.openRoot(chatRef(forJID: jid))
    }

    /// Drill into `jid` from the current chat (member tap, participant
    /// row, reply-privately, community sub-group, mention popover,
    /// quoted-message author). Pushes onto the stack; back-pop returns
    /// to the originating chat.
    func drillIntoChat(_ jid: String) {
        nav.push(chatRef(forJID: jid))
    }

    /// Open `chatJID` and scroll to message `messageID` after the
    /// chat's history is loaded.
    func requestJumpToMessage(chatJID: String, messageID: String) {
        let canonical = JIDNormalize.canonical(chatJID, client: client)
        pendingChatSelection = canonical
        pendingJumpChatJID = canonical
        pendingJumpMessageID = messageID
    }

    func ingestContacts(_ cs: [BridgeContact]) {
        for c in cs {
            // F48: skip empty names + bare-normalize the key.
            // 1. Empty `c.name` arrives during the first few seconds
            //    after `addContact` — whatsmeow hasn't echoed the
            //    locally-set name back yet. Writing "" here clobbered
            //    the just-set "Boris Tobotras" that `applyIncomingContact`
            //    deposited at `contactNames[bare]`, leaving the
            //    conversation header + inspector pane showing the raw
            //    JID until the next sync cycle.
            // 2. `JIDNormalize.bare` must match the read path in
            //    `displayName(for:)` (line 298) — otherwise a device-
            //    suffixed sender JID and a bare contact key never
            //    collide and the lookup falls through to the prefix.
            let bare = JIDNormalize.bare(c.jid)
            if !c.name.isEmpty {
                contactNames[bare] = c.name
            }
            // A non-empty FullName means a saved address-book contact (vs a
            // push-name-only acquaintance). Drives the "Add to contacts…" vs
            // "Edit name…" menu label.
            if let full = c.fullName, !full.isEmpty {
                savedContactJIDs.insert(bare)
            }
        }
    }

    /// JIDs (bare) that are saved address-book contacts (have a FullName).
    private(set) var savedContactJIDs: Set<String> = []

    func isSavedContact(_ jid: String) -> Bool {
        savedContactJIDs.contains(JIDNormalize.bare(jid))
    }

    /// Mark a JID as a saved contact after a successful add/edit, so the
    /// menu label flips without waiting for the next contact sync.
    func markSavedContact(_ jid: String) {
        savedContactJIDs.insert(JIDNormalize.bare(jid))
    }

    func ingestGroups(_ gs: [BridgeGroupModel]) {
        for g in gs where !g.name.isEmpty { contactNames[g.jid] = g.name }
    }

    /// Overwrites the recorded display name for `jid` (group rename
    /// from inspector / phone). Stronger than `ingestPushName` —
    /// unconditional replacement.
    func setContactNameOverride(jid: String, name: String) {
        guard !name.isEmpty else { return }
        contactNames[JIDNormalize.bare(jid)] = name
    }

    /// Records a sender's push-name (the name they set on their phone)
    /// against their JID. Lower priority than explicit contact names —
    /// only inserted when no other name is known. Mirrors the entry
    /// across every form whatsmeow knows for this person (bare,
    /// canonical PN, reverse-resolved LID) so a 1:1 push-name carried
    /// on `<phone>@s.whatsapp.net` also resolves the same person's
    /// group sender `<lid>@lid` (and vice versa) — without this every
    /// group bubble for a 1:1 contact fell back to the bare LID
    /// digits because the name lived only on the PN key.
    func ingestPushName(jid: String, name: String?) {
        guard let name, !name.isEmpty else { return }
        for key in JIDNormalize.allForms(jid, client: client) {
            if contactNames[key] == nil { contactNames[key] = name }
        }
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
        // F60: protocol-limit fallback. For @lid senders with a known
        // LID→PN mapping but no push-name anywhere (silent group
        // member, no prior interaction with this account — whatsmeow's
        // Contacts row exists but with empty name fields, and the
        // server has no API to fetch push-names for arbitrary JIDs),
        // prefer the PN prefix over the random 15-digit @lid number.
        // "+3725060015" reads as a recognizable phone number; the
        // @lid form looks like garbage.
        let fallbackJID = (canonical != bare) ? canonical : bare
        if let at = fallbackJID.firstIndex(of: "@") {
            let prefix = String(fallbackJID[..<at])
            if fallbackJID.hasSuffix("@s.whatsapp.net"),
               prefix.allSatisfy(\.isNumber) {
                return "+" + prefix
            }
            return prefix
        }
        return fallbackJID
    }

    /// True when `jid` resolves to the paired account's own JID (i.e. the
    /// self-chat at `<ownJID>@s.whatsapp.net`). Uses `JIDNormalize.same` so
    /// device-suffixed / `@lid` variants of the own JID still match. Returns
    /// false before pairing (empty `ownJID`) or when no client is bound.
    func isSelfChat(_ jid: String) -> Bool {
        guard let client else { return false }
        let own = client.ownJID
        guard !own.isEmpty else { return false }
        return JIDNormalize.same(jid, own, client: client)
    }

    /// Fetch the paired account's own About/status from the server.
    /// Mirrors `ChatInfoView.loadUserInfo` — the same `getUserInfo`
    /// path, just keyed by `ownJID`. Returns nil when no client is
    /// bound, the account isn't paired (empty `ownJID`), or the IQ
    /// fails. Runs the bridge call on a detached task so the
    /// multi-second round-trip doesn't block the main actor.
    func fetchSelfInfo() async -> BridgeUserInfo? {
        guard let client else { return nil }
        let own = client.ownJID
        guard !own.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? client.getUserInfo(jid: own)
        }.value
    }

    func isBlocked(_ jid: String) -> Bool {
        let bare = JIDNormalize.bare(jid)
        if blockedJIDs.contains(bare) { return true }
        // blockedJIDs is normalized to phone JIDs (see ListBlocked), so a chat
        // still keyed by @lid must be matched against its PN counterpart —
        // otherwise the banner (which may use the @lid form) disagrees with the
        // sidebar/Settings (PN form).
        if bare.hasSuffix("@lid"), let client {
            let pn = client.resolveLIDToPN(bare)
            if pn != bare { return blockedJIDs.contains(JIDNormalize.bare(pn)) }
        }
        return false
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

    /// Debounced `.historySync` reconcile pass (F19). Initial sync delivers
    /// a burst of HistorySync events; previously each one ran the CGo
    /// `listContacts` round-trip + name resolve + merge + ingest + three
    /// reconcile passes + a blocklist IQ inline on the MainActor
    /// event-stream consumer. Coalesce the burst into one flush after a
    /// 250 ms quiet period, and lift the bridge call off MainActor so the
    /// marshal/unmarshal of a potentially large contacts array doesn't
    /// block UI updates.
    func scheduleHistorySyncReconcile(client: WAClient,
                                      vm: ChatListViewModel) {
        if historySyncFlush != nil { return }
        // F37: during a user-triggered full-history sync, the
        // 250-ms-debounced reconcile (6 passes over 1033 chats +
        // SwiftData upserts per pass) was firing repeatedly — a major
        // main-thread chew that survived the F37/F37v2 sidebar fix.
        // Stretch the debounce to 5 s during sync so reconcile fires
        // a handful of times instead of dozens.
        let debounceMs: UInt64 = fullSync.inFlight ? 5000 : 250
        historySyncFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self else { return }
            self.historySyncFlush = nil
            // CGo bridge call off MainActor — listContacts marshals a
            // potentially large array.
            let contacts = await Task.detached(priority: .userInitiated) {
                () -> [BridgeContact] in
                (try? client.listContacts()) ?? []
            }.value
            // Groups list lands incomplete on initial app-state sync; re-fetch
            // during the coalesced reconcile so JID-stubbed chats get their
            // real names + community flags.
            let groups = await Task.detached(priority: .userInitiated) {
                () -> [BridgeGroupModel] in
                (try? client.listGroups()) ?? []
            }.value
            vm.resolveNames(contacts)
            vm.mergeContacts(contacts)
            self.ingestContacts(contacts)
            vm.mergeGroups(groups)
            self.ingestGroups(groups)
            vm.reconcilePinsWithStore()
            vm.reconcileMutedWithStore()
            vm.reconcileLIDDuplicates()
            self.loadBlocklist()
        }
    }

    /// Block/unblock a user. The bridge sends the change as a fire-and-forget
    /// IQ; we update the local set optimistically and let the inbound
    /// BlocklistChanged event (and connect/settings refreshes) reconcile with
    /// the server. We deliberately do NOT eagerly re-fetch here — the server
    /// applies the change asynchronously, so a quick GET would race it and
    /// make the banner flicker off→on.
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

    init() {
        // App foreground → opportunistic refresh of admin approval queues,
        // throttled to one fan-out per 30s so a rapid window-cycle doesn't
        // hammer the bridge.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let now = Date()
                if let last = self.lastForegroundRefresh,
                   now.timeIntervalSince(last) < 30 { return }
                self.lastForegroundRefresh = now
                await self.refreshAllAdminApprovalGroups()
            }
        }
    }

    deinit {
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func boot() async {
        do {
            let url = try AppPaths.databaseURL()
            let c = try WAClient(dbPath: url.path)
            self.client = c
            // Rebind the join-request store now that the bridge client exists.
            // The fetch closure is immutable on the store, so we swap the instance.
            self.joinRequestStore = JoinRequestStore { chatJID in
                try c.getGroupJoinRequests(chatJID: chatJID)
            }
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
        // Re-arm the v0.8.1 one-shot history backfill so the next pairing
        // session re-runs it against whatever state the new account has.
        historyBackfillCompleted = false
        lastReconnectCatchupAt = 0  // F92: reset catch-up throttle on logout
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
            // Cache the paired account's own push name + bare JID on
            // the FTS index. Push name fills `sender` for own-outbound
            // rows (whatsmeow never sets senderPushName on fromMe =
            // true); bare JID fills `sender_jid` so the Sender filter
            // is stable across push-name changes. Canonicalizer
            // collapses LID / PN siblings of the same contact into one
            // chip entry.
            if let client {
                MessageIndex.shared.setOwnPushName(client.ownPushName)
                MessageIndex.shared.setCanonicalizer { jid in
                    JIDNormalize.canonical(jid, client: client)
                }
                MessageIndex.shared.setOwnBareJID(client.ownJID)
                // The app-init bootstrap walked before any of the
                // setters above existed — own outbound rows ended up
                // with empty / device-suffixed sender_jid and LID /
                // PN siblings of the same contact got separate ids.
                // Rebuild once per session now that the setters are
                // primed, but only when the inputs that feed the FTS
                // row contents (ownJID, ownPushName, canonicalizer
                // version) have actually changed since the last
                // bootstrap — otherwise every reconnect would drop +
                // repopulate the whole table for no reason.
                if !didRebootstrapMessageIndex {
                    didRebootstrapMessageIndex = true
                    Task.detached(priority: .utility) {
                        await MessageIndex.shared
                            .rebootstrapIfFingerprintChanged()
                    }
                }
            }
            // Publish our own presence as available so whatsmeow honors
            // SubscribePresence(jid) calls — peers don't share presence
            // with companions that look offline. Best-effort: errors
            // here mean we'll just not see online dots.
            try? client?.sendPresence(available: true)
            // Seed pending join-request counts for every admin approval
            // group so the chat-list badge is correct as soon as the
            // sidebar renders post-connect.
            Task { await self.refreshAllAdminApprovalGroups() }
            // v0.8.1 one-shot history backfill against the globally-oldest
            // persisted message. No-op once the flag is set; see T12 for
            // where the flag flips on first HistorySync arrival.
            Task { await self.requestHistoryBackfillIfNeeded() }
            // F92: on every connect after the one-shot deep sync, fire
            // a 7-day catch-up so messages the phone read while yawac
            // was offline (which WhatsApp clears from the offline buffer)
            // still flow in via direct history-sync request. Throttled.
            Task { await self.requestReconnectCatchupSyncIfNeeded() }
        case .joinApprovalModeChanged(let chatJID, let on, _, _):
            if on {
                Task { await self.joinRequestStore.refresh(chatJID: chatJID) }
            } else {
                self.joinRequestStore.clear(chatJID: chatJID)
            }
        case .historySync(let syncType, let n, let progress, _, let chunkMessages):
            // F92 hardening (v0.10.24): trace ON_DEMAND chunks so we
            // can see whether the phone responded to the catch-up
            // request. ON_DEMAND chunks are the type-6 FULL_HISTORY_
            // SYNC_ON_DEMAND response (also fired by user-tap Full
            // sync). Both paths share this code, both want visibility.
            if syncType == "ON_DEMAND" {
                NSLog("[yawac/catchup] received ON_DEMAND chunk progress=%d chunkMessages=%d conversations=%d",
                      progress, chunkMessages, n)
            }
            syncedConversations += n
            armSyncWatchdog()
            if fullSync.inFlight {
                // Only count chunks that actually carry conversation messages.
                // PUSH_NAME / INITIAL_STATUS_V3 / NON_BLOCKING_DATA arrive
                // alongside but shouldn't bump the counters. Same gate F26
                // uses for the one-shot UserDefaults flag.
                let contentful: Set<String> = [
                    "INITIAL_BOOTSTRAP", "RECENT", "FULL", "ON_DEMAND",
                ]
                if contentful.contains(syncType) {
                    fullSync.progress = max(fullSync.progress, progress)
                    fullSync.chunks += 1
                    fullSync.messages += chunkMessages
                    armFullSyncTimeout()  // re-arm silence window
                    // F29: removed the `progress >= 100` auto-clear.
                    // Phone reports progress=100 on every ON_DEMAND chunk
                    // (and on intermediate RECENT chunks too), so the
                    // 60s silence-timeout is the only honest signal that
                    // the burst is over. Auto-clearing on >=100 made the
                    // second tap "blink" — phone replied with a single
                    // progress=100 chunk and the row went back to idle
                    // before SwiftUI even animated the ProgressView in.
                }
            }
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

    /// User-triggered full history sync. Belt-and-suspenders:
    /// 1. Fire the account-wide FULL_HISTORY_SYNC_ON_DEMAND (type 6,
    ///    F27 path) — works only on first pair / first session;
    ///    phone silently drops repeats.
    /// 2. Run a multi-round per-chat fan-out: each round snapshots the
    ///    current oldest persisted message per chat, fires type-5
    ///    HISTORY_SYNC_ON_DEMAND (count=200) for every chat with a
    ///    100 ms throttle, waits ~30 s for chunks to land + the
    ///    F3 batched writer to commit them, then samples again. If
    ///    any chat got deeper, loop. Caps at 10 rounds so a stuck
    ///    sync never spins forever.
    /// F28, F29 (idle-sublabel + diagnostics), F30 (fan-out),
    /// F30v2 (multi-round recursion).
    /// F39: bumps fresh / dupe per-message counts on `fullSync`.
    /// Public so `ChatListViewModel.ingest`'s flush can drive it.
    @MainActor
    func bumpFullSyncCounts(fresh: Int, dupe: Int) {
        guard fullSync.inFlight else { return }
        fullSync.fresh += fresh
        fullSync.dupe += dupe
    }

    @MainActor
    func startFullHistorySync() {
        guard !fullSync.inFlight else { return }
        NSLog("[yawac/backfill] startFullHistorySync — user tap")
        historyBackfillCompleted = false
        fullSync = FullSyncState(inFlight: true, attempted: true)
        armFullSyncTimeout()
        // Type-6 first. Cheap, sometimes works.
        Task { await self.requestHistoryBackfillIfNeeded() }
        // Then run the recursive deep backfill.
        Task { await self.runDeepBackfill() }
    }

    /// Recursive per-chat fan-out: repeatedly snapshot oldest message
    /// per chat, fan out type-5 backfills, wait, sample again. Exit
    /// when no chat got deeper or when the max round count is hit.
    /// F30v2.
    @MainActor
    private func runDeepBackfill() async {
        // F39: bumped 10 → 30. The exit gate is "round produced no
        // deeper messages anywhere", and the at-floor pruning below
        // shrinks the per-round work as chats reach their floor, so
        // the higher cap costs almost nothing on healthy syncs and
        // lets one tap dig further into deep histories. Worst-case
        // wall clock: 30 × 60 s = 30 min if phone keeps shipping.
        let maxRounds = 30
        // F30v5: 60s. The previous 30s wasn't long enough for the F3
        // batched MessageWriter to commit all incoming HistorySync
        // messages before we re-sampled oldestTimestampPerChat. Late
        // arrivals landed AFTER the sample and the round-over-round
        // comparison declared `deeper=0` prematurely. SQLITE_BUSY
        // contention with whatsmeow's secret-key store amplifies this.
        let perRoundWaitSec: UInt64 = 60
        // F39: per-chat consecutive "did not deepen" counter. After
        // `atFloorThreshold` consecutive rounds with no deeper rows
        // for a chat, we mark it at-floor and skip it in subsequent
        // rounds. The systematic-debugging investigation showed
        // that 150/152 chats returned no-deeper in round 1 but we
        // kept hammering all 152 every round, wasting peer-message
        // sends and looking like "refetch" to the user.
        let atFloorThreshold = 2
        var stableRoundsByJID: [String: Int] = [:]
        var atFloor: Set<String> = []
        for round in 1...maxRounds {
            let before = await oldestTimestampPerChat()
            // F39: bump per-request count when the residual deepening
            // set is small. Once at-floor pruning has narrowed
            // fan-out to ≤5 chats, 200 msgs/request bottlenecks the
            // long tail — those stragglers (typically one big
            // group) need more history per round-trip to converge
            // within maxRounds. Phone may silently truncate above
            // some server-side ceiling; honoring it ≈2.5× depth /
            // round on the remaining chat(s).
            let remaining = before.count - atFloor.count
            let countPerChat = remaining <= 5 ? 500 : 200
            NSLog("[yawac/backfill] deep-backfill round=%d chats=%d at_floor=%d count_per_chat=%d",
                  round, before.count, atFloor.count, countPerChat)
            await fanOutPerChatBackfill(countPerChat: countPerChat,
                                        throttleMs: 100,
                                        excludeJIDs: atFloor)
            try? await Task.sleep(for: .seconds(perRoundWaitSec))
            let after = await oldestTimestampPerChat()
            var deeperCount = 0
            for (jid, beforeTS) in before {
                if atFloor.contains(jid) { continue }
                if let afterTS = after[jid], afterTS < beforeTS {
                    deeperCount += 1
                    stableRoundsByJID[jid] = 0
                } else {
                    let next = (stableRoundsByJID[jid] ?? 0) + 1
                    stableRoundsByJID[jid] = next
                    if next >= atFloorThreshold {
                        atFloor.insert(jid)
                    }
                }
            }
            NSLog("[yawac/backfill] deep-backfill round=%d deeper=%d/%d new_at_floor=%d",
                  round, deeperCount, before.count, atFloor.count)
            if deeperCount == 0 {
                NSLog("[yawac/backfill] deep-backfill exit — phone has no more history")
                break
            }
        }
        NSLog("[yawac/backfill] deep-backfill complete")
        fullSync.inFlight = false
        fullSyncTimeoutTask?.cancel()
    }

    /// Sample current oldest-message timestamp per chat. Returns
    /// `[chatJID: epochSeconds]`. Used by `runDeepBackfill` to detect
    /// whether a fan-out round actually added deeper history.
    /// F37: was @MainActor and ran 1033 SwiftData fetches on the main
    /// thread (a 30-s sample during full-history sync showed this and
    /// fanOutPerChatBackfill at ~60% of main-thread time, the
    /// dominant beachball source). Now runs detached with its own
    /// background ModelContext.
    private func oldestTimestampPerChat() async -> [String: Int64] {
        guard let container = modelContext?.container else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            () -> [String: Int64] in
            let ctx = ModelContext(container)
            let chatDescriptor = FetchDescriptor<PersistedChat>()
            guard let chats = try? ctx.fetch(chatDescriptor) else { return [:] }
            var out: [String: Int64] = [:]
            out.reserveCapacity(chats.count)
            for chat in chats {
                let jid = chat.jid
                var d = FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.chatJID == jid },
                    sortBy: [SortDescriptor(\.timestamp, order: .forward)])
                d.fetchLimit = 1
                if let oldest = (try? ctx.fetch(d))?.first {
                    out[jid] = Int64(oldest.timestamp.timeIntervalSince1970)
                }
            }
            return out
        }.value
    }

    /// F30: iterates every PersistedChat that has at least one
    /// persisted message and asks the phone for `countPerChat` older
    /// messages anchored at that chat's oldest known message. Sequential
    /// with a 100 ms throttle to avoid tripping WhatsApp's peer-message
    /// rate limiter. Each response arrives asynchronously as a
    /// HistorySync of SyncType=ON_DEMAND; the existing handler bumps
    /// fullSync.chunks + .messages.
    /// F37: was @MainActor and ran 1033 SwiftData fetches inline,
    /// pinning the main thread for the full duration of the fan-out.
    /// Now resolves per-chat anchors in a detached Task with its own
    /// background ModelContext, then walks the result list back on
    /// MainActor only to fire the (already fire-and-forget) peer
    /// sends + the throttle sleep.
    /// F39: `excludeJIDs` skips chats marked at-floor by the
    /// `runDeepBackfill` heuristic so we stop hammering them.
    private func fanOutPerChatBackfill(countPerChat: Int,
                                       throttleMs: UInt64,
                                       excludeJIDs: Set<String> = []) async {
        guard let client else { return }
        guard let container = modelContext?.container else { return }
        struct Anchor: Sendable {
            let jid: String
            let msgID: String
            let senderJID: String
            let fromMe: Bool
            let tsUnix: Int64
        }
        let anchors: [Anchor] = await Task.detached(priority: .userInitiated) {
            () -> [Anchor] in
            let ctx = ModelContext(container)
            let chatDescriptor = FetchDescriptor<PersistedChat>(
                sortBy: [SortDescriptor(\.lastTimestamp, order: .reverse)])
            guard let chats = try? ctx.fetch(chatDescriptor) else { return [] }
            var out: [Anchor] = []
            out.reserveCapacity(chats.count)
            for chat in chats {
                let jid = chat.jid
                if excludeJIDs.contains(jid) { continue }
                var msgDescriptor = FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.chatJID == jid },
                    sortBy: [SortDescriptor(\.timestamp, order: .forward)])
                msgDescriptor.fetchLimit = 1
                guard let oldest = (try? ctx.fetch(msgDescriptor))?.first
                else { continue }
                out.append(Anchor(
                    jid: jid,
                    msgID: oldest.id,
                    senderJID: oldest.senderJID,
                    fromMe: oldest.fromMe,
                    tsUnix: Int64(oldest.timestamp.timeIntervalSince1970)))
            }
            return out
        }.value
        NSLog("[yawac/backfill] fan-out across %d chats count_per_chat=%d throttle_ms=%llu",
              anchors.count, countPerChat, throttleMs)
        var sent = 0
        for a in anchors {
            let jid = a.msgID  // unused; preserve `sent += 1` flow below.
            _ = jid
            // F30v3 fire-and-forget; F37 hoisted anchor fetch off main.
            Task.detached { [client] in
                try? client.requestOlderHistory(
                    chatJID: a.jid,
                    oldestMsgID: a.msgID,
                    oldestSenderJID: a.senderJID,
                    oldestFromMe: a.fromMe,
                    oldestTimestampSec: a.tsUnix,
                    count: countPerChat)
            }
            sent += 1
            try? await Task.sleep(for: .milliseconds(throttleMs))
        }
        NSLog("[yawac/backfill] fan-out complete — sent=%d", sent)
    }

    @MainActor
    private func armFullSyncTimeout() {
        fullSyncTimeoutTask?.cancel()
        fullSyncTimeoutTask = Task { @MainActor [weak self] in
            // F30 timeout: 5 minutes. The fan-out dispatches ~1000+
            // peer messages with a 100 ms throttle (~100 s sequential
            // dispatch alone). Phone batches the replies behind that
            // flood and first-chunk arrival can land near tap+2 min.
            //
            // The Task.isCancelled re-check after the sleep matters:
            // `try?` swallows the CancellationError so cancellation
            // would otherwise fall through and clear inFlight on the
            // very next chunk's armFullSyncTimeout re-arm — racing
            // every fresh chunk back to inFlight=false. Observed live
            // 2026-06-09: second chunk landed 2.5s after first and
            // immediately reported inFlight=false because the
            // first-tap task resumed post-cancel and clobbered the
            // flag.
            try? await Task.sleep(for: .seconds(300))
            guard let self else { return }
            guard !Task.isCancelled else { return }
            // If a chunk arrived during the window it would have
            // cancelled this task and re-armed a fresh one. Reaching
            // here means a full 5 minutes of silence; clear inFlight.
            self.fullSync.inFlight = false
        }
    }

    /// v0.8.1 one-shot history backfill. On the first `.connected` after
    /// upgrade we issue a single HistorySyncFromOldest IQ anchored at the
    /// globally-oldest persisted message, so disappearing messages that
    /// expired off the phone before the user paired this device can still
    /// be replayed via the server-side ephemeral window. The
    /// `historyBackfillCompleted` flag is flipped to true on the first
    /// HistorySync arrival (see ContentView, T12) and reset by `logout()`.
    @MainActor
    func requestHistoryBackfillIfNeeded() async {
        guard !historyBackfillCompleted else { return }
        guard let client else { return }
        // F56: previously this guarded on an existing oldest persisted
        // message and early-returned (flipping the one-shot flag) when
        // no anchor row existed yet — i.e. on every fresh-install
        // pair. The type-6 FULL_HISTORY_SYNC_ON_DEMAND request doesn't
        // use an anchor (bridge sets HistoryFromTimestamp = now +
        // HistoryDurationDays = count), so the anchor fields exist
        // only for source compatibility. Sending the request with
        // empty anchors is harmless and is the ONLY way to pull deep
        // history into a fresh install after the initial bootstrap
        // chunk lands. The previous behavior left fresh users with
        // only whatever messages the INITIAL_BOOTSTRAP shipped.
        let context = modelContext
        var oldestChatJID = ""
        var oldestMsgID = ""
        var oldestFromMe = false
        var oldestTSUnix: Int64 = 0
        if let context {
            var d = FetchDescriptor<PersistedMessage>(
                sortBy: [SortDescriptor(\.timestamp, order: .forward)])
            d.fetchLimit = 1
            if let oldest = (try? context.fetch(d))?.first {
                oldestChatJID = oldest.chatJID
                oldestMsgID = oldest.id
                oldestFromMe = oldest.fromMe
                oldestTSUnix = Int64(oldest.timestamp.timeIntervalSince1970)
            }
        }
        do {
            NSLog("[yawac/backfill] sending FULL_HISTORY_SYNC_ON_DEMAND chat=%@ msg=%@ ts=%lld count=100000",
                  oldestChatJID, oldestMsgID, oldestTSUnix)
            try await Task.detached { [client] in
                try client.requestFullHistorySync(
                    beforeChatJID: oldestChatJID,
                    beforeMsgID: oldestMsgID,
                    beforeFromMe: oldestFromMe,
                    beforeTSUnix: oldestTSUnix,
                    count: 100_000)
            }.value
            NSLog("[yawac/backfill] SendPeerMessage returned ok — waiting for HistorySync chunks")
        } catch {
            NSLog("[yawac/backfill] history backfill request failed: %@",
                  String(describing: error))
            return
        }
        // Flag flipped on first HistorySync arrival — see T12 (ContentView).
    }

    /// F92: on every `.connected` event AFTER the one-shot full history
    /// backfill has already happened, request a small (7-day) catch-up
    /// sync. WhatsApp clears its offline buffer for messages the phone
    /// has already read, so messages missed while yawac was down don't
    /// re-deliver via the normal `.connected` path. This catch-up bypasses
    /// the server-side clearing by asking the phone directly via type-6
    /// FULL_HISTORY_SYNC_ON_DEMAND. Throttled to 5 min so reconnect
    /// flapping doesn't hammer.
    @MainActor
    func requestReconnectCatchupSyncIfNeeded() async {
        guard historyBackfillCompleted else {
            // First-pair flow: let `requestHistoryBackfillIfNeeded` run
            // the full deep sync. Catch-up only kicks in after.
            return
        }
        guard let client else { return }
        let now = Date().timeIntervalSince1970
        let last = lastReconnectCatchupAt
        if now - last < Self.reconnectCatchupThrottle {
            NSLog("[yawac/catchup] skip — last fired %.0fs ago (throttle=%.0fs)",
                  now - last, Self.reconnectCatchupThrottle)
            return
        }
        lastReconnectCatchupAt = now
        NSLog("[yawac/catchup] sending FULL_HISTORY_SYNC_ON_DEMAND count=30 (days)")
        do {
            try await Task.detached { [client] in
                try client.requestFullHistorySync(
                    beforeChatJID: "",
                    beforeMsgID: "",
                    beforeFromMe: false,
                    beforeTSUnix: 0,
                    count: 30)
            }.value
            NSLog("[yawac/catchup] SendPeerMessage ok — waiting for HistorySync chunks")
        } catch {
            NSLog("[yawac/catchup] catch-up sync failed: %@",
                  String(describing: error))
        }
    }

    /// Fan-out refresh of pending join-request queues for every group
    /// where the user is an admin and approval mode is on. Called on
    /// `.connected` and on `didBecomeActive` (throttled).
    ///
    /// The candidate set is derived from the in-memory `chatList.chats`
    /// — `mergeGroups` populates `joinApprovalMode` + `amAdmin` from
    /// the server roster, so by the time `.connected` fires after
    /// `ContentView.task` has run, this set reflects reality.
    @MainActor
    private func refreshAllAdminApprovalGroups() async {
        guard let chats = chatList?.chats else { return }
        let candidates: [String] = chats.compactMap { chat in
            guard chat.isGroup, chat.joinApprovalMode, chat.amAdmin
            else { return nil }
            return chat.jid
        }
        guard !candidates.isEmpty else { return }
        await joinRequestStore.refreshAllAdmin(chatJIDs: candidates)
    }
}
