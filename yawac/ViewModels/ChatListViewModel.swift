import AppKit
import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class ChatListViewModel {
    var chats: [Chat] = [] {
        didSet { pushUnreadToSession() }
    }
    /// True while the cold-start bootstrap (`runBootstrap`) is in flight.
    /// Observable so the sidebar can show a `ProgressView` and any
    /// auto-selection (e.g. `lastSelectedChatJID` restore) can wait until
    /// `chats` is populated. Flips to `false` once the background snapshot
    /// has been committed on MainActor.
    private(set) var bootstrapping: Bool = true
    private let client: WAClient?
    private let context: ModelContext?
    /// Weak link back to the global session so the menubar icon can
    /// reflect the chats' aggregate unread count without subscribing
    /// to vm.chats directly from app-level scope.
    @ObservationIgnored weak var session: SessionViewModel?

    init(client: WAClient?, context: ModelContext? = nil, bootstrap: Bool = true) {
        self.client = client
        self.context = context
        // F5: defer the SwiftData fetch + raw SQLite scan that
        // `loadChats` performs to a background Task so the cold-start
        // MainActor is not blocked before the first sidebar paint. The
        // sidebar renders a ProgressView while `bootstrapping == true`.
        if bootstrap {
            Task { [weak self] in await self?.runBootstrap() }
        }
    }

    /// Per-event chat-row work coalescer. `.message` bursts (history
    /// sync, offline queue drain, group activity) hit `ingest` dozens
    /// of times in a single runloop turn — each one used to invoke
    /// `sortChats()` (O(n log n) on every chat) and `upsertPersisted`
    /// (SwiftData fetch + write) synchronously. A 77-message burst →
    /// 154 SwiftData ops + 77 sorts on the main actor in <5s, which
    /// stalled HID delivery and drove the kernel wake-rate violation.
    ///
    /// Now `ingest` marks the chat JID dirty and arms a single 80ms
    /// debounce task. The flush sorts once and persists the dirty
    /// rows together. Persisted message rows continue to be written
    /// per-event so no history is lost on crash.
    @ObservationIgnored private var dirtyChatJIDs: Set<String> = []
    @ObservationIgnored private var pendingFlush: Task<Void, Never>?

    private func markChatDirty(_ jid: String) {
        dirtyChatJIDs.insert(jid)
        if pendingFlush != nil { return }
        pendingFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.pendingFlush = nil
            self.flushDirtyChats()
        }
    }

    private func flushDirtyChats() {
        guard !dirtyChatJIDs.isEmpty else { return }
        sortChats()
        let snapshot = dirtyChatJIDs
        dirtyChatJIDs.removeAll(keepingCapacity: true)
        for jid in snapshot {
            if let c = chats.first(where: { $0.jid == jid }) {
                upsertPersisted(c, preview: c.lastMessage, save: false)
            }
        }
        try? context?.save()
    }

    private func pushUnreadToSession() {
        let now = Date()
        let total = chats.reduce(0) { acc, c in
            let muted = (c.mutedUntil.map { $0 > now }) ?? false
            return muted ? acc : acc + c.unread
        }
        // Only write on change — chats mutates per-element in merge loops,
        // and every redundant assign invalidates the menubar observers.
        if session?.totalUnread != total { session?.totalUnread = total }
    }

    // MARK: - Delete tombstones

    /// Persistent map of deleted-chat JID → deletion time (unix seconds).
    /// A deleted *chat* is still a *contact* in the address book and its
    /// history may be re-delivered by a later history sync, so without this
    /// `mergeContacts`/`ingest` would re-add it. A tombstoned chat resurfaces
    /// only when a message *newer than the deletion* arrives (matching
    /// WhatsApp) or when the user explicitly starts the chat again.
    private var tombstoneKey: String {
        let url = context?.container.configurations.first?.url
        if url == nil || url == AppPaths.messageStoreURL { return "yawac.deletedChats" }
        return "yawac.deletedChats.\(url!.path)"
    }
    private var deletedChats: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: tombstoneKey)
                as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: tombstoneKey) }
    }
    private func tombstone(_ jid: String) {
        var d = deletedChats; d[jid] = Date().timeIntervalSince1970; deletedChats = d
    }
    private func untombstone(_ jid: String) {
        var d = deletedChats
        guard d[jid] != nil else { return }
        d.removeValue(forKey: jid); deletedChats = d
    }
    private func isTombstoned(_ jid: String) -> Bool { deletedChats[jid] != nil }
    /// True when a message at `timestamp` (unix seconds) should keep the chat
    /// suppressed (it's an old replay of a deleted conversation).
    private func suppressedByTombstone(_ jid: String, messageTS: Int64) -> Bool {
        guard let deletedAt = deletedChats[jid] else { return false }
        return Double(messageTS) <= deletedAt
    }

    // MARK: - F5: cold-start bootstrap (off MainActor)

    /// Cached sidebar values read after storage preparation.
    private struct ChatListBootstrap: Sendable { let chats: [Chat] }

    /// Read summaries off-main; message and identifier repairs belong to storage.
    nonisolated private static func buildBootstrap(
        container: ModelContainer,
        tombstones: Set<String>
    ) -> ChatListBootstrap {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedChat>(
            sortBy: [SortDescriptor(\.lastTimestamp, order: .reverse)])
        guard let rows = try? context.fetch(descriptor) else {
            return ChatListBootstrap(chats: [])
        }

        let keepers = Dictionary(rows.map { ($0.jid, $0) }, uniquingKeysWith: { first, _ in first })

        // Derive a fresh per-chat (lastTimestamp, lastMessageText) from
        // raw SQLite — going through SwiftData materialises every row
        // and freezes main on chats with thousands of messages.
        // `latestMessagePerChat` opens its own read-only connection,
        // safe to call off MainActor.
        var latestByChat: [String: (ts: Date, text: String)] = [:]
        for row in SQLiteDedupe.latestMessagePerChat(at: container.configurations.first!.url) {
            // SwiftData stores Date as Apple-epoch seconds; convert.
            let date = Date(timeIntervalSinceReferenceDate: row.timestampAppleEpoch)
            // Mirror previewText(for:) for deletions — otherwise the raw text
            // of a revoked / locally-deleted message resurfaces on every
            // launch, overriding the correctly-tombstoned PersistedChat row.
            let preview: String
            if row.revoked {
                preview = "🚫 message deleted"
            } else if row.locallyDeleted {
                preview = "🚫 you deleted this"
            } else if let t = row.text, !t.isEmpty {
                preview = t
            } else {
                switch row.kind {
                case "image":    preview = "📷 Photo"
                case "video":    preview = "🎥 Video"
                case "audio":    preview = "🎤 Audio"
                case "document": preview = "📄 Document"
                case "sticker":  preview = "Sticker"
                case "location": preview = "📍 Location"
                case "poll":     preview = "📊 Poll"
                default:         preview = "[\(row.kind)]"
                }
            }
            latestByChat[row.chatJID] = (date, preview)
        }

        // Mention resolution is deferred to the MainActor apply phase
        // (`session.displayName` is MainActor-isolated). The raw preview
        // is carried as-is in `Chat.lastMessage` here and resolved in
        // place before the snapshot is committed.
        let messageBearing = SQLiteDedupe.chatJIDsWithAnyMessage(at: container.configurations.first!.url)
        let chats: [Chat] = keepers.values
            .map { row -> Chat in
                let derived = latestByChat[row.jid]
                // F122/F123: derived (latest previewable message row) is
                // authoritative for preview AND sort position — the
                // PersistedChat cache can hold system-message text and a
                // system-bumped lastTimestamp from before the preview
                // gates. A chat whose rows are all system/protocol
                // (derived nil but message-bearing) sinks to the bottom:
                // only real messages float a chat.
                let systemRowsOnly = derived == nil && messageBearing.contains(row.jid)
                let ts = derived?.ts.timeIntervalSince1970
                    ?? (systemRowsOnly ? 0 : row.lastTimestamp.timeIntervalSince1970)
                let rawPreview = derived?.text
                    ?? (systemRowsOnly ? "" : row.lastMessageText ?? "")
                return Chat(
                    jid: row.jid, name: row.name,
                    lastMessage: rawPreview,
                    lastTimestamp: Int64(ts.isFinite ? ts : 0),
                    unread: row.unread,
                    bellEnabled: row.bellEnabled,
                    folderIDs: row.folderIDs,
                    isCommunityParent: row.isCommunityParent,
                    communityParentJID: row.communityParentJID,
                    isDefaultSubGroup: row.isDefaultSubGroup,
                    pinnedAt: row.pinnedAt,
                    archivedAt: row.archivedAt,
                    mutedUntil: row.mutedUntil,
                    groupDescription: row.groupDescription)
            }
            .filter { !tombstones.contains($0.jid) }
            .sorted(by: Self.chatOrder)

        return ChatListBootstrap(
            chats: chats)
    }

    /// Build off-main, resolve names, and publish the cached sidebar.
    func runBootstrap() async {
        guard let container = context?.container else {
            bootstrapping = false
            return
        }
        // Snapshot inputs MainActor-side so the detached Task sees
        // value-typed sendables only.
        let tombstones = Set(deletedChats.keys)
        let client = self.client
        let snap = await Task.detached(priority: .userInitiated) {
            ChatListViewModel.buildBootstrap(
                container: container,
                tombstones: tombstones)
        }.value

        // Resolve mentions on MainActor — `session?.displayName(for:)` is
        // MainActor-isolated. Doing this here also keeps the resolver
        // current with whatever names arrived during the bootstrap
        // window.
        let resolved: [Chat] = snap.chats.map { c in
            var c = c
            c.lastMessage = resolveMentionsText(c.lastMessage) { [weak session] jid in
                session?.displayName(for: jid) ?? jid
            }
            return c
        }

        // Race guard: messages that ingested while the bootstrap was
        // building (history-sync, offline-queue drain) added rows to
        // `self.chats` first. Merge by jid — bootstrap wins for chats
        // not yet seen post-init; ingest-created rows survive.
        if self.chats.isEmpty {
            self.chats = resolved
        } else {
            let bootstrapByJID = Dictionary(resolved.map { ($0.jid, $0) },
                                            uniquingKeysWith: { first, _ in first })
            let existingJIDs = Set(self.chats.map { $0.jid })
            let newcomers = resolved.filter { !existingJIDs.contains($0.jid) }
            // For chats that exist both pre- and post-bootstrap (rare:
            // the row was created by an in-flight ingest), keep the
            // ingest version — it's newer.
            self.chats = self.chats + newcomers
            // Carry through pinned/archived/muted/group metadata for any
            // matching ingest-side row that lacked it (ingest creates
            // bare rows).
            for i in self.chats.indices {
                if let bootstrap = bootstrapByJID[self.chats[i].jid],
                   self.chats[i].lastTimestamp < bootstrap.lastTimestamp {
                    // Bootstrap strictly newer than the ingest-created row
                    // → adopt it. At equality the ingest version wins:
                    // ingest arrived after the bootstrap fetch, so it's
                    // the more recent state in wall-clock terms even if
                    // its `lastTimestamp` matches the bootstrap's.
                    self.chats[i] = bootstrap
                }
            }
            self.chats.sort(by: Self.chatOrder)
        }
        bootstrapping = false

    }

    /// Total ordering for the sidebar. Pinned chats float to the
    /// top (newest pin first), unpinned fall back to recency.
    private static func chatOrder(_ a: Chat, _ b: Chat) -> Bool {
        switch (a.pinnedAt, b.pinnedAt) {
        case let (l?, r?): return l > r
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):
            if a.lastTimestamp != b.lastTimestamp {
                return a.lastTimestamp > b.lastTimestamp
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func accepts(_ message: BridgeMessage) -> Bool {
        // F35: drop protocol-only carriers, but allow synthetic
        // kind="system" rows with a body text through (the bridge now
        // emits these for encryption-key changes + disappearing-timer
        // changes so the user sees what's happening in the chat).
        if message.kind == "protocol" { return false }
        if message.kind == "system",
           (message.text ?? "").isEmpty { return false }
        let chatJID = JIDNormalize.canonical(message.chatJID, client: client)

        // Deleted-chat handling: a message older-or-equal to the deletion is a
        // history-sync replay of the cleared conversation — drop it so the chat
        // stays deleted. A newer message means the conversation is alive again,
        // so lift the tombstone and ingest normally (WhatsApp behavior).
        // Tombstone semantics run synchronously here so a tombstone touched
        // mid-coalesce window still suppresses replays correctly.
        if suppressedByTombstone(chatJID, messageTS: message.timestamp) { return false }
        untombstone(chatJID)

        return true
    }

    func applyCommittedMessages(_ batch: [BridgeMessage], outcomes: [MessageWriter.WriteOutcome], previews: [MessageWriter.ChatPreview] = []) {
        if let session, session.fullSync.inFlight {
            let dupes = outcomes.count(where: \.alreadySeen)
            session.bumpFullSyncCounts(fresh: outcomes.count - dupes, dupe: dupes)
        }
        var working = chats
        var positions = Dictionary(working.enumerated().map { ($1.jid, $0) }, uniquingKeysWith: { first, _ in first })
        for (message, outcome) in zip(batch, outcomes) {
            applyChatRowUpdate(chats: &working, idxByJID: &positions, message: message,
                               canonJID: outcome.canonicalChatJID, alreadySeen: outcome.alreadySeen)
        }
        for preview in previews {
            guard let i = positions[preview.jid] else { continue }
            working[i].lastMessage = resolveMentionsText(preview.text) { [weak session] jid in
                session?.displayName(for: jid) ?? jid
            }
            working[i].lastTimestamp = preview.timestamp
            markChatDirty(preview.jid)
        }
        chats = working
    }

    /// MainActor commit step after the background writer persists a
    /// batch. Updates the in-memory `chats` array (preview / unread /
    /// push-name resolve / broadcast resolve) and fires the inbound
    /// notification. Iterating in batch order means the last message
    /// for a given chat wins on preview / lastTimestamp, matching the
    /// pre-F3 per-event behavior.
    /// F37: takes a shadow `chats` array + a jid → index cache so the
    /// per-outcome loop in `ingest`'s flush can apply 1000+ updates
    /// off the published `self.chats` and publish the shadow back
    /// once. Eliminates both the O(#chats) `firstIndex(where:)` per
    /// outcome AND the 1000+ @Observable publishes that re-rendered
    /// the sidebar mid-history-sync.
    private func applyChatRowUpdate(chats: inout [Chat],
                                    idxByJID: inout [String: Int],
                                    message: BridgeMessage,
                                    canonJID: String,
                                    alreadySeen: Bool) {
        // F53: never let a system / protocol envelope advance the chat
        // preview or timestamp. The bridge emits these for encryption-key
        // changes, disappearing-timer changes, group meta-events etc.
        // with a non-empty `text` payload ("Encryption key with
        // X@lid changed."), so the previous order — text check first,
        // kind switch second — let those strings replace the real last
        // message in the sidebar. The chat row still persists to history
        // via the writer pipeline; only the preview is skipped here.
        if message.kind == "system" || message.kind == "protocol" {
            return
        }
        let chatJID = canonJID
        let rawPreview: String
        if let text = message.text, !text.isEmpty {
            rawPreview = text
        } else {
            switch message.kind {
            case "image":    rawPreview = "📷 Photo"
            case "video":    rawPreview = "🎥 Video"
            case "audio":    rawPreview = "🎤 Audio"
            case "document": rawPreview = "📄 Document"
            case "sticker":  rawPreview = "Sticker"
            case "location": rawPreview = "📍 Location"
            case "poll":     rawPreview = "📊 \(message.poll?.question ?? "Poll")"
            default:         rawPreview = "[\(message.kind)]"
            }
        }
        let preview = resolveMentionsText(rawPreview) { [weak session] jid in
            session?.displayName(for: jid) ?? jid
        }

        let now = message.timestamp
        // F37: use cached idx when present; fall back to firstIndex
        // only on miss + memoize. Shadow `chats` is mutated in place;
        // the caller publishes back to `self.chats` once after the
        // batch.
        let cachedIdx: Int?
        if let i = idxByJID[chatJID] {
            cachedIdx = i
        } else if let i = chats.firstIndex(where: { $0.jid == chatJID }) {
            idxByJID[chatJID] = i
            cachedIdx = i
        } else {
            cachedIdx = nil
        }
        if let idx = cachedIdx {
            var c = chats[idx]
            let advancesTip = now >= c.lastTimestamp
            if advancesTip {
                c.lastMessage = preview
                c.lastTimestamp = now
            }
            // F31: only bump unread for messages that advance the chat
            // tip (genuine new arrival). Backfill replays from F30
            // multi-round HistorySync ingest are older than the current
            // tip and would otherwise inflate unread by every historical
            // message pulled — observed counts in the thousands after a
            // single full-sync run even though the user had read those
            // messages on the phone weeks ago.
            if !alreadySeen, !message.fromMe, advancesTip { c.unread += 1 }
            let looksLikePhonePlaceholder: Bool = {
                guard c.name.hasPrefix("+") else { return c.name == c.jid }
                return c.name.dropFirst().allSatisfy(\.isNumber)
            }()
            if !message.fromMe,
               let push = message.senderPushName, !push.isEmpty,
               looksLikePhonePlaceholder,
               !chatJID.hasSuffix("@broadcast") {
                c.name = push
            }
            if chatJID.hasSuffix("@broadcast"),
               let resolved = session?.displayName(for: chatJID),
               c.name != resolved {
                c.name = resolved
            }
            chats[idx] = c
        } else {
            let initialName: String
            if chatJID.hasSuffix("@broadcast"),
               let resolved = session?.displayName(for: chatJID), !resolved.isEmpty {
                initialName = resolved
            } else {
                initialName = chatJID
            }
            // F31: brand-new chat row. Only mark unread=1 if the
            // message is fresh (within ~5 min of now). Otherwise it's a
            // backfill replay from F30 deep sync — don't inflate.
            let nowSeconds = Int64(Date().timeIntervalSince1970)
            let isFresh = (nowSeconds - now) < 300
            let unread = (!alreadySeen && !message.fromMe && isFresh) ? 1 : 0
            let c = Chat(
                jid: chatJID,
                name: initialName,
                lastMessage: preview,
                lastTimestamp: now,
                unread: unread)
            chats.append(c)
            // F37: memoize the new row in the per-flush cache.
            idxByJID[chatJID] = chats.count - 1
        }
        markChatDirty(chatJID)

        if !AppPaths.isRunningTests, !alreadySeen, !message.fromMe, !NSApp.isActive, !preview.isEmpty {
            let title = chats.first(where: { $0.jid == chatJID })?.name ?? chatJID
            // Group chats: surface sender name as subtitle so recipients can
            // tell who said what without opening the chat. 1:1 chats: title
            // already names the sender — skip subtitle.
            let subtitle: String? = {
                guard chatJID.hasSuffix("@g.us") else { return nil }
                if let s = session?.displayName(for: message.senderJID), !s.isEmpty {
                    return s
                }
                if let push = message.senderPushName, !push.isEmpty {
                    return push
                }
                return nil
            }()
            if isMutedForNotification(chatJID: chatJID, message: message) {
                // Suppressed by mute (unless mention pierces).
            } else {
                // F73-F74: per-chat bell gate. Default to true when the
                // row hasn't been resolved yet so we don't accidentally
                // silence chats during cold-start.
                let bell = chats.first(where: { $0.jid == chatJID })?.bellEnabled ?? true
                NotificationService.notify(
                    title: title,
                    body: preview,
                    chatJID: chatJID,
                    subtitle: subtitle,
                    resolveMentions: { [weak session] jid in session?.displayName(for: jid) ?? jid },
                    bellEnabled: bell)
            }
        }
    }

    func markRead(_ jid: String) {
        guard let i = chats.firstIndex(where: { $0.jid == jid }) else { return }
        chats[i].unread = 0
        upsertPersisted(chats[i])
    }

    /// Decrement a chat's unread count by 1 (clamped at 0). Called by
    /// `ConversationViewModel` when a visible message satisfies the
    /// dwell threshold and gets marked read.
    func decrementUnread(_ jid: String, by n: Int = 1) {
        guard let i = chats.firstIndex(where: { $0.jid == jid }) else { return }
        chats[i].unread = max(0, chats[i].unread - n)
        upsertPersisted(chats[i])
    }

    /// Insert a placeholder chat for a JID that isn't yet known locally
    /// (typically because the user just searched for an unknown phone
    /// number and tapped the "Start chat" suggestion). Idempotent: if a
    /// row for `jid` already exists, returns its id without touching it.
    @discardableResult
    func upsertStubChat(jid: String, displayName: String) -> Chat.ID {
        if let existing = chats.first(where: { $0.jid == jid }) {
            return existing.id
        }
        // Explicit re-open of a previously deleted chat clears its tombstone.
        untombstone(jid)
        let chat = Chat(
            jid: jid,
            name: displayName,
            lastMessage: "",
            lastTimestamp: Int64(Date().timeIntervalSince1970),
            unread: 0)
        chats.append(chat)
        sortChats()
        upsertPersisted(chat)
        return chat.id
    }

    /// Persists every incoming reaction so the conversation view can hydrate
    /// the chip strip when it later opens (or re-opens) the chat. Live
    /// reactions arrive once via the global event stream — without this,
    /// closing/reopening a chat would drop all of them.
    func notifyReaction(_ r: BridgeReaction) {
        // Notify only when somebody reacts to OUR message (`targetFromMe`)
        // and the window isn't focused. Skip self-reactions and clears.
        guard !AppPaths.isRunningTests, !r.emoji.isEmpty,
              r.targetFromMe,
              r.senderJID != "me",
              !NSApp.isActive else { return }
        let canonChat = JIDNormalize.canonical(r.chatJID, client: client)
        let chatName = chats.first(where: { $0.jid == canonChat })?.name ?? canonChat
        let reactSubtitle: String? = {
            guard canonChat.hasSuffix("@g.us") else { return nil }
            let s = session?.displayName(for: r.senderJID) ?? ""
            return s.isEmpty ? nil : s
        }()
        if isMuted(canonChat, now: Date()) {
            // Reaction notifications suppressed for muted chats.
        } else {
            // F73-F74: per-chat bell gate (see message notification above).
            let bell = chats.first(where: { $0.jid == canonChat })?.bellEnabled ?? true
            NotificationService.notify(
                title: chatName,
                body: "\(r.emoji) reacted to your message",
                chatJID: canonChat,
                subtitle: reactSubtitle,
                resolveMentions: { [weak session] jid in session?.displayName(for: jid) ?? jid },
                bellEnabled: bell)
        }
    }

    func mergeGroups(_ gs: [BridgeGroupModel]) {
        var idxByJID = Dictionary(uniqueKeysWithValues: chats.enumerated().map { ($1.jid, $0) })
        for g in gs {
            let jid = JIDNormalize.canonical(g.jid, client: client)
            let parentJID: String? = {
                guard let p = g.linkedParentJID, !p.isEmpty,
                      p.hasSuffix("@g.us") else { return nil }
                return p
            }()
            let amAdmin = isCurrentUserAdmin(group: g)
            if let idx = idxByJID[jid] {
                // Refresh community fields on existing chats so a previously
                // synced regular-group row gets promoted to a community
                // parent / sub-group if whatsmeow now reports it that way.
                var c = chats[idx]
                c.isCommunityParent = g.isParent
                c.communityParentJID = parentJID
                c.isDefaultSubGroup = g.isDefaultSubGroup
                c.joinApprovalMode = g.joinApprovalMode
                c.amAdmin = amAdmin
                c.ephemeralExpirationSeconds = g.ephemeralExpirationSeconds
                c.isAnnounce = g.isAnnounce
                c.isLocked = g.isLocked
                c.isAllMemberAdd = g.isAllMemberAdd
                if c.name == jid && !g.name.isEmpty { c.name = g.name }
                if c.lastTimestamp == 0 && g.created > 0 {
                    c.lastTimestamp = g.created
                }
                chats[idx] = c
                upsertPersisted(c, save: false)
                continue
            }
            if isTombstoned(jid) { continue }
            var fresh = Chat(
                jid: jid,
                name: g.name.isEmpty ? jid : g.name,
                lastMessage: g.topic,
                lastTimestamp: max(0, g.created),
                unread: 0,
                isCommunityParent: g.isParent,
                communityParentJID: parentJID,
                isDefaultSubGroup: g.isDefaultSubGroup)
            fresh.joinApprovalMode = g.joinApprovalMode
            fresh.amAdmin = amAdmin
            fresh.ephemeralExpirationSeconds = g.ephemeralExpirationSeconds
            fresh.isAnnounce = g.isAnnounce
            fresh.isLocked = g.isLocked
            fresh.isAllMemberAdd = g.isAllMemberAdd
            chats.append(fresh)
            idxByJID[jid] = chats.count - 1
            upsertPersisted(chats[chats.count - 1], save: false)
        }
        try? context?.save()
        sortChats()
    }

    /// Apply a live JoinedGroup notification. Unlike the periodic group-list
    /// snapshot, this carries the time this account was added, so a newly
    /// joined old group sorts at the join event rather than its creation date.
    func mergeJoinedGroup(_ group: BridgeGroupModel, at date: Date) {
        let jid = JIDNormalize.canonical(group.jid, client: client)
        untombstone(jid)
        mergeGroups([group])
        guard let idx = chats.firstIndex(where: { $0.jid == jid }) else { return }
        let timestamp = Int64(date.timeIntervalSince1970)
        guard timestamp > chats[idx].lastTimestamp else { return }
        chats[idx].lastTimestamp = timestamp
        upsertPersisted(chats[idx])
        sortChats()
    }

    /// Preserve history-sync conversation metadata for groups whose newest
    /// item is a non-renderable system stub (for example "added you"). The
    /// group snapshot may already have supplied its much older creation date,
    /// so advance the row whenever the history envelope is newer. A rendered
    /// message arriving afterward remains authoritative for the preview.
    func applyHistoryConversation(chatJID: String, name: String, at date: Date) {
        guard chatJID.hasSuffix("@g.us") else { return }
        guard let idx = chats.firstIndex(where: { $0.jid == chatJID }) else {
            let chat = Chat(
                jid: chatJID,
                name: name.isEmpty ? chatJID : name,
                lastMessage: "",
                lastTimestamp: Int64(date.timeIntervalSince1970),
                unread: 0)
            chats.append(chat)
            upsertPersisted(chat)
            sortChats()
            return
        }
        let timestamp = Int64(date.timeIntervalSince1970)
        guard timestamp > chats[idx].lastTimestamp else { return }
        if !name.isEmpty { chats[idx].name = name }
        chats[idx].lastTimestamp = timestamp
        upsertPersisted(chats[idx])
        sortChats()
    }

    /// True when the paired account participates in `group` as an admin
    /// or super-admin. Matches the inspector's gate (see
    /// `ChatInfoView.isCurrentUserAdmin`) so badge visibility and admin
    /// affordances stay in lockstep.
    private func isCurrentUserAdmin(group g: BridgeGroupModel) -> Bool {
        let rawOwn = client?.ownJID ?? ""
        guard !rawOwn.isEmpty else { return false }
        return g.participants.contains { p in
            guard p.isAdmin || p.isSuper else { return false }
            return JIDNormalize.same(p.jid, rawOwn, client: client)
        }
    }

    func mergeContacts(_ cs: [BridgeContact]) {
        var known = Set(chats.map(\.jid))
        for c in cs {
            let jid = JIDNormalize.bare(c.jid)
            if known.contains(jid) { continue }
            if isTombstoned(jid) { continue }
            let chat = Chat(
                jid: jid,
                name: c.name,
                lastMessage: "",
                lastTimestamp: 0,
                unread: 0)
            chats.append(chat)
            known.insert(jid)
            upsertPersisted(chat, save: false)
        }
        try? context?.save()
        sortChats()
    }

    private func sortChats() {
        chats.sort(by: Self.chatOrder)
    }

    func resolveNames(_ cs: [BridgeContact]) {
        let byJID = Dictionary(cs.map { ($0.jid, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        for i in chats.indices {
            if let resolved = byJID[chats[i].jid], chats[i].name != resolved {
                chats[i].name = resolved
                upsertPersisted(chats[i], save: false)
            }
        }
        try? context?.save()
    }

    private func upsertPersisted(_ c: Chat, preview: String? = nil, save: Bool = true) {
        guard let context else { return }
        let jid = c.jid
        let descriptor = FetchDescriptor<PersistedChat>(
            predicate: #Predicate { $0.jid == jid })
        if let existing = try? context.fetch(descriptor).first {
            existing.name = c.name
            existing.lastTimestamp = Date(timeIntervalSince1970: TimeInterval(c.lastTimestamp))
            existing.unread = c.unread
            existing.communityParentJID = c.communityParentJID
            existing.isCommunityParent = c.isCommunityParent
            existing.isDefaultSubGroup = c.isDefaultSubGroup
            existing.pinnedAt = c.pinnedAt
            existing.archivedAt = c.archivedAt
            existing.mutedUntil = c.mutedUntil
            existing.bellEnabled = c.bellEnabled
            existing.folderIDs = c.folderIDs
            existing.groupDescription = c.groupDescription
            if let preview { existing.lastMessageText = preview }
        } else {
            let row = PersistedChat(
                jid: c.jid,
                name: c.name,
                lastMessageText: preview,
                lastTimestamp: Date(timeIntervalSince1970: TimeInterval(c.lastTimestamp)),
                unread: c.unread,
                communityParentJID: c.communityParentJID,
                isCommunityParent: c.isCommunityParent,
                isDefaultSubGroup: c.isDefaultSubGroup,
                pinnedAt: c.pinnedAt,
                archivedAt: c.archivedAt,
                mutedUntil: c.mutedUntil,
                groupDescription: c.groupDescription)
            row.bellEnabled = c.bellEnabled
            row.folderIDs = c.folderIDs
            context.insert(row)
        }
        if save { try? context.save() }
    }

    /// Toggle pin state for `chat`. Sends an appstate patch (the
    /// server fans out to peer devices) and mutates the row eagerly;
    /// peer-device echoes converge via `applyIncomingChatPin`.
    func pinChat(_ chat: Chat, pinned: Bool) {
        guard let client else { return }
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try client.pinChat(chatJID: chat.jid, pinned: pinned)
                }.value
                self.applyLocalPin(chatJID: chat.jid,
                                   pinnedAt: pinned ? Date() : nil)
            } catch {
                NSLog("[yawac/pinChat] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    func applyIncomingChatPin(chatJID: String, pinned: Bool, at: Date) {
        applyLocalPin(chatJID: chatJID, pinnedAt: pinned ? at : nil)
    }

    /// Cold-start sync: ask the bridge which of our known chats are
    /// pinned according to whatsmeow's local appstate store, then
    /// reconcile any mismatches. whatsmeow doesn't re-emit events.Pin
    /// for already-synced patches, so without this the sidebar starts
    /// up with stale state for any chat pinned before our last save.
    func reconcilePinsWithStore() {
        guard let client else { return }
        let jids = chats.map(\.jid)
        Task { @MainActor in
            let pinned: Set<String>
            do {
                pinned = try await Task.detached(priority: .utility) {
                    Set(try client.listPinnedChats(jids: jids))
                }.value
            } catch {
                NSLog("[yawac/pin-reconcile] failed: %@", String(describing: error))
                return
            }
            var changed = false
            let now = Date()
            for i in chats.indices {
                let isPinned = pinned.contains(chats[i].jid)
                let wasPinned = chats[i].pinnedAt != nil
                if isPinned == wasPinned { continue }
                chats[i].pinnedAt = isPinned ? (chats[i].pinnedAt ?? now) : nil
                upsertPersisted(chats[i], save: false)
                changed = true
            }
            if changed { try? context?.save(); sortChats() }
        }
    }

    /// Collapse `@lid` chats that now resolve (via whatsmeow's LID map) to a
    /// phone JID we already have a chat for — the WhatsApp LID/PN duality that
    /// surfaces the same person as two rows. The startup dedupe only catches
    /// mappings known at load time; this re-runs it live once a mapping has
    /// been learned (e.g. after a block resolves one, or on reconnect/sync).
    /// Merges unread/last/name into the phone chat, reparents the LID chat's
    /// messages, and drops the LID row. No-op when no resolvable dups exist.
    func reconcileLIDDuplicates() {
        guard let client else { return }
        let pnJIDs = Set(chats.filter { $0.jid.hasSuffix("@s.whatsapp.net") }.map(\.jid))
        var pairs: [(lid: String, pn: String)] = []
        for c in chats where c.jid.hasSuffix("@lid") {
            let pn = client.resolveLIDToPN(c.jid)
            if pn != c.jid, pn.hasSuffix("@s.whatsapp.net"), pnJIDs.contains(pn) {
                pairs.append((lid: c.jid, pn: pn))
            }
        }
        guard !pairs.isEmpty else { return }
        guard let writer = session?.messageWriter else { return }
        Task {
            do {
                try await writer.mergeChats(pairs)
                chats.removeAll { chat in pairs.contains { $0.lid == chat.jid || $0.pn == chat.jid } }
                await runBootstrap()
            } catch { session?.persistenceError = error.localizedDescription }
        }
    }

    private func applyLocalPin(chatJID: String, pinnedAt: Date?) {
        if let idx = chats.firstIndex(where: { $0.jid == chatJID }) {
            chats[idx].pinnedAt = pinnedAt
            upsertPersisted(chats[idx])
        } else if let context {
            let descriptor = FetchDescriptor<PersistedChat>(
                predicate: #Predicate { $0.jid == chatJID })
            if let row = try? context.fetch(descriptor).first {
                row.pinnedAt = pinnedAt
                try? context.save()
            }
        }
        sortChats()
    }

    // MARK: - Mute

    /// Sentinel "Always" mute end. Matches whatsmeow's MutedForever
    /// (year 9999, UTC) to the second; treat any `mutedUntil > now + 100y`
    /// as "Always" in the UI label.
    static let muteForever = Date(timeIntervalSinceReferenceDate: 253_402_300_799)

    /// True when `chatJID`'s `mutedUntil` is in the future relative to `now`.
    /// `now` injectable for deterministic tests.
    func isMuted(_ chatJID: String, now: Date = Date()) -> Bool {
        guard let c = chats.first(where: { $0.jid == chatJID }),
              let until = c.mutedUntil else { return false }
        return until > now
    }

    /// Notification-gate predicate. Returns true when an inbound event
    /// should NOT trigger a banner.
    ///
    /// Suppression rules:
    /// - Not muted → false.
    /// - Muted, not in a group → true.
    /// - Muted, in a group, message body contains `@<ownPhoneDigits>` →
    ///   false (direct mention pierces mute).
    /// - Muted, in a group, otherwise → true.
    func isMutedForNotification(
        chatJID: String,
        message: BridgeMessage,
        ownPhoneDigits: String? = nil
    ) -> Bool {
        guard isMuted(chatJID, now: Date()) else { return false }
        let isGroup = chatJID.hasSuffix("@g.us")
        guard isGroup else { return true }
        let digits = ownPhoneDigits ?? session?.ownPhoneDigits ?? ""
        guard !digits.isEmpty else { return true }
        let body = message.text ?? ""
        return !body.contains("@\(digits)")
    }

    /// Local optimistic apply for a mute toggle initiated by this device.
    /// `mutedUntil == nil` = unmute.
    func applyLocalMute(chatJID: String, mutedUntil: Date?) {
        if let idx = chats.firstIndex(where: { $0.jid == chatJID }) {
            chats[idx].mutedUntil = mutedUntil
            upsertPersisted(chats[idx])
        } else if let context {
            let descriptor = FetchDescriptor<PersistedChat>(
                predicate: #Predicate { $0.jid == chatJID })
            if let row = try? context.fetch(descriptor).first {
                row.mutedUntil = mutedUntil
                try? context.save()
            }
        }
        sortChats()
    }

    /// Apply a mute change that arrived via `events.Mute`. Last-event-wins
    /// for this state — `mutedUntil` is a state value (end-of-mute), not
    /// an operation timestamp, so no time-based reconciliation against it.
    func applyIncomingMute(chatJID: String, mutedUntil: Date?, at _: Date) {
        applyLocalMute(chatJID: chatJID, mutedUntil: mutedUntil)
    }

    /// Issues the bridge mute call + optimistic local apply.
    /// `until == nil` unmutes.
    func muteChat(_ chat: Chat, until: Date?) {
        guard let client else { return }
        let muteMs: Int64 = until.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try client.muteChat(chatJID: chat.jid,
                                        mute: until != nil,
                                        mutedUntilMs: muteMs)
                }.value
                self.applyLocalMute(chatJID: chat.jid, mutedUntil: until)
            } catch {
                NSLog("[yawac/muteChat] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    /// F74: flip the per-chat bell. Local-only state — phone does not
    /// see this preference. Persists via the existing `upsertPersisted`
    /// round-trip (which copies `bellEnabled` from Chat → PersistedChat).
    func setBellEnabled(chatJID: String, enabled: Bool) {
        guard let idx = chats.firstIndex(where: { $0.jid == chatJID }) else { return }
        chats[idx].bellEnabled = enabled
        upsertPersisted(chats[idx])
    }

    /// F91 hotfix: re-read PersistedChat.folderIDs into the in-memory
    /// chats[] cache after rail mutations. `jid == nil` refreshes every
    /// chat (used after deleteFolder which scrubs all memberships).
    func refreshFolderIDs(for jid: String?) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedChat>()
        let persisted = (try? context.fetch(descriptor)) ?? []
        let byJID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.jid, $0.folderIDs) })
        if let jid {
            if let idx = chats.firstIndex(where: { $0.jid == jid }),
               let folderIDs = byJID[jid] {
                chats[idx].folderIDs = folderIDs
            }
        } else {
            for i in chats.indices {
                if let folderIDs = byJID[chats[i].jid] {
                    chats[i].folderIDs = folderIDs
                }
            }
        }
    }

    /// Cold-start reconcile: pull whatsmeow's local muted-chats list
    /// and align our rows. whatsmeow doesn't re-emit events.Mute for
    /// already-synced patches on reconnect.
    func reconcileMutedWithStore() {
        guard let client else { return }
        let jids = chats.map(\.jid)
        Task { @MainActor in
            let entries: [(jid: String, mutedUntilMs: Int64)]
            do {
                entries = try await Task.detached(priority: .utility) {
                    try client.listMutedChats(jids: jids)
                }.value
            } catch {
                NSLog("[yawac/mute-reconcile] failed: %@",
                      String(describing: error))
                return
            }
            let byJID = Dictionary(entries.map { ($0.jid, $0.mutedUntilMs) },
                                   uniquingKeysWith: { first, _ in first })
            var changed = false
            for i in chats.indices {
                let serverMs = byJID[chats[i].jid] ?? 0
                let serverUntil: Date? = serverMs == 0
                    ? nil
                    : Date(timeIntervalSince1970: TimeInterval(serverMs) / 1000)
                if chats[i].mutedUntil == serverUntil { continue }
                chats[i].mutedUntil = serverUntil
                upsertPersisted(chats[i], save: false)
                changed = true
            }
            if changed { try? context?.save(); sortChats() }
        }
    }

    // MARK: - Group info (name + description)

    /// Issues `SetGroupName` to the bridge + optimistic local apply.
    func setGroupName(_ chat: Chat, to name: String) {
        guard let client else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try client.setGroupName(chatJID: chat.jid, name: trimmed)
                }.value
                self.applyLocalGroupInfo(chatJID: chat.jid,
                                        name: trimmed,
                                        description: nil)
            } catch {
                NSLog("[yawac/setGroupName] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    /// Issues `SetGroupDescription` to the bridge + optimistic local apply.
    /// Empty string clears the description on the server and stores nil
    /// locally.
    func setGroupDescription(_ chat: Chat, to description: String) {
        guard let client else { return }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try client.setGroupDescription(chatJID: chat.jid,
                                                   description: trimmed)
                }.value
                self.applyLocalGroupInfo(chatJID: chat.jid,
                                        name: nil,
                                        description: trimmed)
            } catch {
                NSLog("[yawac/setGroupDescription] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    /// Updates the `chats[]` entry and persists. `name == nil` leaves
    /// name untouched. `description == nil` leaves description
    /// untouched. Empty `description` ("" from an explicit clear) stores
    /// `nil` locally so the placeholder renders.
    func applyLocalGroupInfo(chatJID: String, name: String?, description: String?) {
        if let idx = chats.firstIndex(where: { $0.jid == chatJID }) {
            if let n = name, !n.isEmpty {
                chats[idx].name = n
            }
            if let d = description {
                chats[idx].groupDescription = d.isEmpty ? nil : d
            }
            upsertPersisted(chats[idx])
        } else if let context {
            let descriptor = FetchDescriptor<PersistedChat>(
                predicate: #Predicate { $0.jid == chatJID })
            if let row = try? context.fetch(descriptor).first {
                if let n = name, !n.isEmpty { row.name = n }
                if let d = description {
                    row.groupDescription = d.isEmpty ? nil : d
                }
                try? context.save()
            }
        }
        // Keep the session-level contactNames in sync so every surface
        // that reads names via `session.displayName(for:)` — chat header,
        // notifications, mention chips — sees the new name without a
        // separate reconcile.
        if let n = name, !n.isEmpty {
            session?.setContactNameOverride(jid: chatJID, name: n)
        }
    }

    /// Event-path equivalent. Last-event-wins (state values, not
    /// operation timestamps — same pattern as mute).
    func applyIncomingGroupInfo(chatJID: String,
                                name: String?,
                                description: String?,
                                at _: Date) {
        applyLocalGroupInfo(chatJID: chatJID,
                            name: name, description: description)
    }

    /// Apply a live `joinApprovalModeChanged` event onto the in-memory
    /// `Chat.joinApprovalMode` flag so the sidebar admin-chip gate flips
    /// without waiting for the next `mergeGroups`. Runtime-only —
    /// `joinApprovalMode` is not persisted (a fresh ListGroups on the
    /// next connect repopulates it).
    func applyIncomingJoinApprovalMode(chatJID: String, on: Bool) {
        guard let idx = chats.firstIndex(where: { $0.jid == chatJID }) else {
            return
        }
        chats[idx].joinApprovalMode = on
    }

    /// Apply a live `ephemeralTimerChanged` event (or an optimistic local
    /// edit) onto `Chat.ephemeralExpirationSeconds` so the inspector
    /// picker and any future composer banner reflect the new timer
    /// without waiting for the next `mergeGroups`. Runtime-only — the
    /// field is not persisted (a fresh ListGroups on the next connect
    /// repopulates it for groups; 1:1 chats hydrate only via this event).
    func applyEphemeralTimer(chatJID: String, seconds: Int32) {
        guard let idx = chats.firstIndex(where: { $0.jid == chatJID }) else {
            return
        }
        chats[idx].ephemeralExpirationSeconds = seconds
    }

    /// Apply a live "Only admins can send messages" flip (or an optimistic
    /// local toggle from the group-admin inspector row) onto `Chat.isAnnounce`
    /// so the inspector reflects the new state without waiting for the next
    /// `mergeGroups`. Runtime-only — the field is not persisted (a fresh
    /// ListGroups on the next connect repopulates it).
    func applyGroupAnnounce(chatJID: String, on: Bool) {
        guard let idx = chats.firstIndex(where: { $0.jid == chatJID }) else {
            return
        }
        chats[idx].isAnnounce = on
    }

    /// Apply a live "Only admins can edit group info" flip (or an optimistic
    /// local toggle from the group-admin inspector row) onto `Chat.isLocked`
    /// so the inspector reflects the new state without waiting for the next
    /// `mergeGroups`. Runtime-only — the field is not persisted (a fresh
    /// ListGroups on the next connect repopulates it).
    func applyGroupLocked(chatJID: String, on: Bool) {
        guard let idx = chats.firstIndex(where: { $0.jid == chatJID }) else {
            return
        }
        chats[idx].isLocked = on
    }

    /// Apply a live "Any member can add new members" flip (or an optimistic
    /// local toggle from the group-admin inspector row) onto
    /// `Chat.isAllMemberAdd` so the inspector reflects the new state without
    /// waiting for the next `mergeGroups`. Runtime-only — the field is not
    /// persisted (a fresh ListGroups on the next connect repopulates it).
    /// `true` means whatsmeow's "all_member_add"; `false` is "admin_add".
    func applyGroupMemberAddMode(chatJID: String, allMembersCanAdd: Bool) {
        guard let idx = chats.firstIndex(where: { $0.jid == chatJID }) else {
            return
        }
        chats[idx].isAllMemberAdd = allMembersCanAdd
    }

    /// Pending join-request count to render in the sidebar chip for
    /// `chat`. Returns `nil` when the user is not an admin or there is
    /// nothing to show. Centralises the (amAdmin && count > 0) gate so
    /// `ChatListView` stays declarative.
    func pendingRequestsChip(for chat: Chat) -> Int? {
        guard chat.amAdmin else { return nil }
        guard let n = session?.joinRequestStore.counts[chat.jid],
              n > 0 else { return nil }
        return n
    }

    // MARK: - Group participants

    /// Snapshot of the latest GroupParticipantsChanged event seen, plus a
    /// monotonic tick that observers can watch via `.onChange`. The Chat
    /// model has no roster cache today — this is purely a notification
    /// sentinel so the open inspector reloads from the server.
    struct GroupParticipantsChange: Equatable {
        let chatJID: String
        let action: String  // add | remove | promote | demote
        let jids: [String]
        let at: Date
    }

    var groupParticipantsTick: Int = 0
    private(set) var lastParticipantsChange: GroupParticipantsChange? = nil

    /// Read-only accessor for collaborators that need to call bridge methods
    /// directly (e.g. ChatSearchViewModel for invite-link preview).
    var clientRef: WAClient? { client }

    // MARK: - Invite link preview

    enum InviteLinkPreviewState: Equatable {
        case loading(code: String)
        case ready(BridgeGroupModel, code: String)
        case joining(code: String)
        case pending(code: String, joinedJID: String)
        case error(message: String)

        static func == (lhs: InviteLinkPreviewState,
                        rhs: InviteLinkPreviewState) -> Bool {
            switch (lhs, rhs) {
            case (.loading(let a), .loading(let b)): return a == b
            case (.ready(let a, let b), .ready(let c, let d)):
                return a.jid == c.jid && b == d
            case (.joining(let a), .joining(let b)): return a == b
            case (.pending(let a, let b), .pending(let c, let d)):
                return a == c && b == d
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    var inviteLinkPreview: InviteLinkPreviewState? = nil

    func applyGroupParticipantsChange(chatJID: String,
                                      action: String,
                                      jids: [String],
                                      at: Date) {
        lastParticipantsChange = GroupParticipantsChange(
            chatJID: chatJID, action: action, jids: jids, at: at)
        groupParticipantsTick &+= 1
    }

    // MARK: - Archive / delete / contact

    /// Latest persisted message metadata for `chatJID`, used to anchor the
    /// archive/delete app-state patch. Returns zero values when unknown.
    private func lastMessageMeta(_ chatJID: String) -> (id: String, ts: Int64, fromMe: Bool) {
        guard let context else { return ("", 0, false) }
        var d = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == chatJID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        d.fetchLimit = 1
        guard let row = try? context.fetch(d).first else { return ("", 0, false) }
        return (row.id, Int64(row.timestamp.timeIntervalSince1970), row.fromMe)
    }

    /// Toggle archive state. Sends the app-state patch (server fans out to
    /// peer devices) and updates the row on success; peer echoes converge
    /// via `applyIncomingArchive`.
    func archiveChat(_ chat: Chat, archived: Bool) {
        guard let client else { return }
        let last = lastMessageMeta(chat.jid)
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try client.archiveChat(
                        chatJID: chat.jid, archived: archived,
                        lastTS: last.ts, lastMsgID: last.id,
                        fromMe: last.fromMe)
                }.value
                self.applyLocalArchive(chatJID: chat.jid, archivedAt: archived ? Date() : nil)
            } catch {
                NSLog("[yawac/archiveChat] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    func applyIncomingArchive(chatJID: String, archived: Bool) {
        applyLocalArchive(chatJID: chatJID, archivedAt: archived ? Date() : nil)
    }

    private func applyLocalArchive(chatJID: String, archivedAt: Date?) {
        // whatsmeow's BuildArchive auto-unpins on archive, so mirror that
        // locally — otherwise an archived chat keeps a stale pinnedAt and
        // briefly re-floats to the Pinned section on unarchive.
        if let idx = chats.firstIndex(where: { $0.jid == chatJID }) {
            chats[idx].archivedAt = archivedAt
            if archivedAt != nil { chats[idx].pinnedAt = nil }
            upsertPersisted(chats[idx])
        } else if let context {
            let descriptor = FetchDescriptor<PersistedChat>(
                predicate: #Predicate { $0.jid == chatJID })
            if let row = try? context.fetch(descriptor).first {
                row.archivedAt = archivedAt
                if archivedAt != nil { row.pinnedAt = nil }
                try? context.save()
            }
        }
        sortChats()
    }

    /// Delete a chat locally and on every device. Sends the DeleteChat
    /// app-state patch, then removes the local rows.
    func deleteChat(_ chat: Chat) {
        let last = lastMessageMeta(chat.jid)
        if let client {
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try client.deleteChat(
                            chatJID: chat.jid, lastTS: last.ts,
                            lastMsgID: last.id, fromMe: last.fromMe)
                    }.value
                } catch {
                    NSLog("[yawac/deleteChat] failed jid=%@ err=%@",
                          chat.jid, String(describing: error))
                }
            }
        }
        removeChatLocally(chat.jid)
        session?.deletedChatJID = chat.jid
    }

    func applyIncomingDelete(chatJID: String) {
        removeChatLocally(chatJID)
        session?.deletedChatJID = chatJID
    }

    func hideDeletedChat(_ jid: String) {
        tombstone(jid)
        dirtyChatJIDs.remove(jid)
        chats.removeAll { $0.jid == jid }
        session?.deletedChatJID = jid
    }

    private func removeChatLocally(_ chatJID: String) {
        hideDeletedChat(chatJID)
        guard let session else { return }
        session.purgeChat(chatJID)
    }

    /// Save a contact name (synced to the phone). Updates the local name on
    /// success; peer echoes converge via `applyIncomingContact`.
    func addContact(_ chat: Chat, fullName: String, firstName: String) {
        guard let client, !fullName.isEmpty else { return }
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try client.setContactName(
                        jid: chat.jid, fullName: fullName,
                        firstName: firstName)
                }.value
                self.applyIncomingContact(jid: chat.jid, fullName: fullName)
            } catch {
                NSLog("[yawac/addContact] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    func applyIncomingContact(jid: String, fullName: String) {
        guard !fullName.isEmpty else { return }
        let bare = JIDNormalize.bare(jid)
        session?.contactNames[bare] = fullName
        session?.markSavedContact(bare)
        if let idx = chats.firstIndex(where: { $0.jid == bare }) {
            chats[idx].name = fullName
            upsertPersisted(chats[idx])
            sortChats()
        }
    }

    /// F91: pure folder-selection filter applied BEFORE bucket logic
    /// (pinned / archived header / sections). `.all` and `.custom` hide
    /// archived chats — the rail's Archived sentinel is now their only
    /// surface. `.archived` shows them flat.
    nonisolated static func chatsFor(selection: FolderSelection,
                                     allChats: [Chat]) -> [Chat] {
        switch selection {
        case .all:
            return allChats.filter { $0.archivedAt == nil }
        case .archived:
            return allChats.filter { $0.archivedAt != nil }
        case .custom(let id):
            return allChats.filter {
                $0.archivedAt == nil && $0.folderIDs.contains(id)
            }
        }
    }
}
