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
    weak var session: SessionViewModel?

    init(client: WAClient?, context: ModelContext? = nil) {
        self.client = client
        self.context = context
        // Background message writer. `client` is a `@MainActor`-isolated
        // reference, but `JIDNormalize.canonical` only reads the
        // nonisolated `resolveLIDToPN` / `resolvePNToLID` maps, so the
        // canonicalize closure is safe to invoke from the writer actor.
        if let container = context?.container {
            self.writer = MessageWriter(
                container: container,
                canonicalize: { jid in
                    JIDNormalize.canonical(jid, client: client)
                })
        } else {
            self.writer = nil
        }
        // F5: defer the SwiftData fetch + raw SQLite scan that
        // `loadChats` performs to a background Task so the cold-start
        // MainActor is not blocked before the first sidebar paint. The
        // sidebar renders a ProgressView while `bootstrapping == true`.
        Task { [weak self] in
            await self?.runBootstrap()
        }
    }

    // MARK: - Background message writer (F3)
    //
    // `ingest()` used to do dedupe-fetch + persistMessage (another fetch
    // + insert + save + sync MessageIndex.upsert) on MainActor, per
    // event. The writer moves that work off-main and batches a 50ms
    // coalesce window into one `context.save()`.
    @ObservationIgnored private let writer: MessageWriter?
    @ObservationIgnored private var pendingIngest: [BridgeMessage] = []
    @ObservationIgnored private var pendingIngestFlush: Task<Void, Never>?

    // F20: batched reaction writer — see persistReaction().
    @ObservationIgnored private var pendingReactions: [BridgeReaction] = []
    @ObservationIgnored private var pendingReactionsFlush: Task<Void, Never>?

    // F21: batched message-mutation writer — see enqueueMutation().
    @ObservationIgnored private var pendingMutations: [MessageWriter.MessageMutation] = []
    @ObservationIgnored private var pendingMutationsFlush: Task<Void, Never>?

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
                upsertPersisted(c, preview: c.lastMessage)
            }
        }
    }

    private func pushUnreadToSession() {
        let now = Date()
        let total = chats.reduce(0) { acc, c in
            let muted = (c.mutedUntil.map { $0 > now }) ?? false
            return muted ? acc : acc + c.unread
        }
        session?.totalUnread = total
    }

    // MARK: - Delete tombstones

    /// Persistent map of deleted-chat JID → deletion time (unix seconds).
    /// A deleted *chat* is still a *contact* in the address book and its
    /// history may be re-delivered by a later history sync, so without this
    /// `mergeContacts`/`ingest` would re-add it. A tombstoned chat resurfaces
    /// only when a message *newer than the deletion* arrives (matching
    /// WhatsApp) or when the user explicitly starts the chat again.
    private static let tombstoneKey = "yawac.deletedChats"
    private var deletedChats: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: Self.tombstoneKey)
                as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.tombstoneKey) }
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

    /// Immutable result of `buildBootstrap`. Carries the assembled `Chat`
    /// rows (with **raw** preview text — mention resolution happens on
    /// MainActor in `runBootstrap` because `session.displayName` is
    /// MainActor-isolated) plus the list of `PersistedChat`
    /// `PersistentIdentifier`s the dedupe pass decided to drop and the
    /// list of unique-key rebinds (`id` → `newJID`) the dedupe pass
    /// decided to apply. Both mutations are round-tripped to the main
    /// context in the apply phase because SwiftData refuses to persist
    /// unique-key mutations from a background context in our setup
    /// (see `SQLiteDedupe` rationale).
    private struct ChatListBootstrap: Sendable {
        struct Rebind: Sendable {
            let id: PersistentIdentifier
            let newJID: String
        }
        let chats: [Chat]
        let deleteIDs: [PersistentIdentifier]
        let rebinds: [Rebind]
    }

    /// Off-MainActor bootstrap builder. Owns its own background
    /// `ModelContext` bound to the same `ModelContainer`. Performs the
    /// `PersistedChat` fetch, the in-memory LID→PN dedupe, the
    /// device-suffix dedupe, and the raw-SQLite
    /// `SQLiteDedupe.latestMessagePerChat()` scan — all of which used
    /// to block MainActor before the first sidebar paint. Returns a
    /// value-type snapshot for the apply phase to consume.
    ///
    /// The `lidResolver` / `canonicalize` closures are passed in because
    /// `WAClient` is `@MainActor`-isolated but its
    /// `resolveLIDToPN` / `resolvePNToLID` methods are nonisolated, so
    /// the closures themselves are safe to call from any thread (same
    /// pattern as `MessageWriter`'s canonicalizer).
    nonisolated private static func buildBootstrap(
        container: ModelContainer,
        tombstones: Set<String>,
        lidResolver: @Sendable (String) -> String,
        canonicalize: @Sendable (String) -> String
    ) -> ChatListBootstrap {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedChat>(
            sortBy: [SortDescriptor(\.lastTimestamp, order: .reverse)])
        guard let rows = try? context.fetch(descriptor) else {
            return ChatListBootstrap(chats: [], deleteIDs: [], rebinds: [])
        }

        // In-memory dedupe only: SwiftData refuses to persist deletions of
        // these unique-key rows in our setup (verified — post-exit WAL is
        // empty, rows remain on disk). Instead we filter them at read time
        // so the UI is clean. The hidden @lid rows stay in the DB but are
        // never surfaced. Future writes via ingest still go through
        // JIDNormalize.canonical so new rows land under the PN form.
        let pnJIDs = Set(
            rows
                .filter { $0.jid.hasSuffix("@s.whatsapp.net") }
                .map { $0.jid }
        )
        var hiddenLIDs = Set<String>()
        for r in rows where r.jid.hasSuffix("@lid") {
            let canon = lidResolver(r.jid)
            if canon != r.jid, pnJIDs.contains(canon) {
                hiddenLIDs.insert(r.jid)
            }
        }
        let rowsAfter = rows.filter { !hiddenLIDs.contains($0.jid) }

        // Two-pass cleanup: collapse rows whose canonical jid matches
        // (device-suffix dedupe + LID→PN resolution). First pass prefers
        // canonical-form rows as anchors so we don't accidentally
        // spawn duplicate PersistedChats that violate the unique JID
        // constraint.
        var keepers: [String: PersistedChat] = [:]
        var toDelete: [PersistedChat] = []

        // Pass 1: bind only the rows whose stored jid already IS the
        // canonical form. These become the merge targets for everything
        // else.
        for r in rowsAfter {
            let bare = canonicalize(r.jid)
            if r.jid == bare {
                keepers[bare] = r
            }
        }

        // Pass 2: handle non-canonical (e.g. `@lid` or `:device@server`)
        // rows. Merge into existing canonical anchor if present;
        // otherwise stage a rebind that the MainActor apply phase will
        // persist (SwiftData refuses to persist unique-key rebinds from
        // a background context in our setup — see ChatListBootstrap doc).
        var pendingRebinds: [ChatListBootstrap.Rebind] = []
        for r in rowsAfter {
            let bare = canonicalize(r.jid)
            if r.jid == bare { continue }
            if let anchor = keepers[bare] {
                if r.lastTimestamp > anchor.lastTimestamp {
                    anchor.lastTimestamp = r.lastTimestamp
                    anchor.lastMessageText = r.lastMessageText ?? anchor.lastMessageText
                    if !r.name.isEmpty { anchor.name = r.name }
                }
                anchor.unread += r.unread
                toDelete.append(r)
            } else {
                // No canonical row yet — stage a rebind so this row's
                // unique key flips to `bare` on the main context, then
                // mutate the in-memory background copy so subsequent
                // passes and the `Chat` materialisation below see the
                // canonical jid. The background mutation is intentionally
                // not saved (the apply phase owns persistence).
                pendingRebinds.append(.init(id: r.persistentModelID, newJID: bare))
                r.jid = bare
                keepers[bare] = r
            }
        }

        // Pass 3: secondary merges where a now-rebound row collides with
        // another canonical row that appeared later in pass 1.
        // (Defensive — should be rare since pass 1 ran first.)
        var seen: [String: PersistedChat] = [:]
        for (jid, row) in keepers {
            if let existing = seen[jid], existing !== row {
                if row.lastTimestamp > existing.lastTimestamp {
                    existing.lastTimestamp = row.lastTimestamp
                    existing.lastMessageText = row.lastMessageText ?? existing.lastMessageText
                    if !row.name.isEmpty { existing.name = row.name }
                }
                existing.unread += row.unread
                toDelete.append(row)
            } else {
                seen[jid] = row
            }
        }

        // Intentionally NO `context.save()` on the background context:
        // SwiftData refuses to persist unique-key mutations from a
        // background context in our setup (verified for deletes; the
        // same silent-failure risk applies to rebinds). All persistent
        // mutations — rebinds AND deletes — are round-tripped to the
        // main context in the apply phase.

        // Collect persistent IDs for the rows to delete. Deletes are
        // applied on the main context (see ChatListBootstrap doc).
        let deleteIDs: [PersistentIdentifier] = toDelete.map { $0.persistentModelID }

        keepers = seen

        // Derive a fresh per-chat (lastTimestamp, lastMessageText) from
        // raw SQLite — going through SwiftData materialises every row
        // and freezes main on chats with thousands of messages.
        // `latestMessagePerChat` opens its own read-only connection,
        // safe to call off MainActor.
        var latestByChat: [String: (ts: Date, text: String)] = [:]
        for row in SQLiteDedupe.latestMessagePerChat() {
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
        let chats: [Chat] = keepers.values
            .map { row -> Chat in
                let derived = latestByChat[row.jid]
                let ts = max(
                    row.lastTimestamp.timeIntervalSince1970,
                    derived?.ts.timeIntervalSince1970 ?? -.infinity)
                let rawPreview: String = {
                    if let d = derived,
                       d.ts.timeIntervalSince1970 >= row.lastTimestamp.timeIntervalSince1970 {
                        return d.text
                    }
                    return row.lastMessageText ?? ""
                }()
                return Chat(
                    jid: row.jid, name: row.name,
                    lastMessage: rawPreview,
                    lastTimestamp: Int64(ts.isFinite ? ts : 0),
                    unread: row.unread,
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
            chats: chats, deleteIDs: deleteIDs, rebinds: pendingRebinds)
    }

    /// MainActor cold-start driver. Dispatches the background bootstrap
    /// builder, resolves mentions on the produced rows (uses MainActor-
    /// isolated `session.displayName`), commits `chats` in one shot, and
    /// finally rounds-trips the duplicate-row deletes to the main
    /// `ModelContext`. Sets `bootstrapping = false` once `chats` is
    /// published so the sidebar's ProgressView dismisses.
    private func runBootstrap() async {
        guard let container = context?.container else {
            bootstrapping = false
            return
        }
        // Snapshot inputs MainActor-side so the detached Task sees
        // value-typed sendables only.
        let tombstones = Set(deletedChats.keys)
        let client = self.client
        let lidResolver: @Sendable (String) -> String = { jid in
            client?.resolveLIDToPN(jid) ?? jid
        }
        let canonicalize: @Sendable (String) -> String = { jid in
            JIDNormalize.canonical(jid, client: client)
        }
        let snap = await Task.detached(priority: .userInitiated) {
            ChatListViewModel.buildBootstrap(
                container: container,
                tombstones: tombstones,
                lidResolver: lidResolver,
                canonicalize: canonicalize)
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
            let bootstrapByJID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.jid, $0) })
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

        // Round-trip the unique-key mutations (rebinds + deletes) to the
        // main context. SwiftData's persistence of these mutations is
        // unreliable from a background context in our setup (verified
        // for deletes; same silent-failure risk applies to rebinds —
        // that's why we no longer save the background context). Apply
        // rebinds first so the delete branch doesn't race a row whose
        // canonical sibling hasn't materialised yet.
        if let context = self.context,
           !(snap.rebinds.isEmpty && snap.deleteIDs.isEmpty) {
            var rebound = 0
            for rebind in snap.rebinds {
                if let row = context.model(for: rebind.id) as? PersistedChat {
                    row.jid = rebind.newJID
                    rebound += 1
                }
            }
            var deleted = 0
            for id in snap.deleteIDs {
                if let row = context.model(for: id) as? PersistedChat {
                    context.delete(row)
                    deleted += 1
                }
            }
            var saveErr: String = "ok"
            do { try context.save() } catch { saveErr = String(describing: error) }
            NSLog("[yawac/runBootstrap] rebinds=%d toDelete=%d save=%@",
                  rebound, deleted, saveErr)
        }
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

    func ingest(_ message: BridgeMessage) {
        // Skip protocol/system noise — no UI value
        if message.kind == "protocol" || message.kind == "system" { return }
        let chatJID = JIDNormalize.canonical(message.chatJID, client: client)

        // Deleted-chat handling: a message older-or-equal to the deletion is a
        // history-sync replay of the cleared conversation — drop it so the chat
        // stays deleted. A newer message means the conversation is alive again,
        // so lift the tombstone and ingest normally (WhatsApp behavior).
        // Tombstone semantics run synchronously here so a tombstone touched
        // mid-coalesce window still suppresses replays correctly.
        if suppressedByTombstone(chatJID, messageTS: message.timestamp) { return }
        untombstone(chatJID)

        // Queue the message for batched background persistence. The 50ms
        // coalesce window groups history-sync / offline-queue drains into
        // a single SwiftData save + FTS upsert pass per batch.
        pendingIngest.append(message)
        guard pendingIngestFlush == nil else { return }
        pendingIngestFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            let batch = self.pendingIngest
            self.pendingIngest.removeAll(keepingCapacity: true)
            self.pendingIngestFlush = nil
            guard !batch.isEmpty, let writer = self.writer else { return }
            let outcomes = await writer.enqueue(batch)
            // Re-pair outcomes with their originating BridgeMessage by id so
            // the apply step has access to the full message payload (preview
            // text, sender push name, fromMe, etc.).
            let byID = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
            for outcome in outcomes {
                guard let original = byID[outcome.id] else { continue }
                self.applyChatRowUpdate(
                    message: original,
                    canonJID: outcome.canonicalChatJID,
                    alreadySeen: outcome.alreadySeen)
            }
        }
    }

    /// MainActor commit step after the background writer persists a
    /// batch. Updates the in-memory `chats` array (preview / unread /
    /// push-name resolve / broadcast resolve) and fires the inbound
    /// notification. Iterating in batch order means the last message
    /// for a given chat wins on preview / lastTimestamp, matching the
    /// pre-F3 per-event behavior.
    private func applyChatRowUpdate(message: BridgeMessage,
                                    canonJID: String,
                                    alreadySeen: Bool) {
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
            case "protocol", "system": rawPreview = ""  // hide
            default:         rawPreview = "[\(message.kind)]"
            }
        }
        let preview = resolveMentionsText(rawPreview) { [weak session] jid in
            session?.displayName(for: jid) ?? jid
        }

        let now = message.timestamp
        if let idx = chats.firstIndex(where: { $0.jid == chatJID }) {
            var c = chats[idx]
            if now >= c.lastTimestamp {
                c.lastMessage = preview
                c.lastTimestamp = now
            }
            if !alreadySeen, !message.fromMe { c.unread += 1 }
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
            let c = Chat(
                jid: chatJID,
                name: initialName,
                lastMessage: preview,
                lastTimestamp: now,
                unread: (!alreadySeen && !message.fromMe) ? 1 : 0)
            chats.append(c)
        }
        markChatDirty(chatJID)

        if !alreadySeen, !message.fromMe, !NSApp.isActive, !preview.isEmpty {
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
                NotificationService.notify(
                    title: title,
                    body: preview,
                    chatJID: chatJID,
                    subtitle: subtitle,
                    resolveMentions: { [weak session] jid in session?.displayName(for: jid) ?? jid })
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
    func persistReaction(_ r: BridgeReaction) {
        // F20: SwiftData persistence is batched off-main via MessageWriter
        // with a 50 ms coalesce window. The notification side below stays
        // on MainActor and fires per-event because per-reaction policy
        // (mute, NSApp.isActive, targetFromMe) is naturally per-event.
        if writer != nil {
            pendingReactions.append(r)
            if pendingReactionsFlush == nil {
                pendingReactionsFlush = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self else { return }
                    let batch = self.pendingReactions
                    self.pendingReactions.removeAll(keepingCapacity: true)
                    self.pendingReactionsFlush = nil
                    guard !batch.isEmpty, let writer = self.writer else { return }
                    await writer.enqueueReactions(batch)
                }
            }
        }

        // Notify only when somebody reacts to OUR message (`targetFromMe`)
        // and the window isn't focused. Skip self-reactions and clears.
        guard !r.emoji.isEmpty,
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
            NotificationService.notify(
                title: chatName,
                body: "\(r.emoji) reacted to your message",
                chatJID: canonChat,
                subtitle: reactSubtitle,
                resolveMentions: { [weak session] jid in session?.displayName(for: jid) ?? jid })
        }
    }

    func mergeGroups(_ gs: [BridgeGroupModel]) {
        for g in gs {
            let jid = JIDNormalize.canonical(g.jid, client: client)
            let parentJID: String? = {
                guard let p = g.linkedParentJID, !p.isEmpty,
                      p.hasSuffix("@g.us") else { return nil }
                return p
            }()
            let amAdmin = isCurrentUserAdmin(group: g)
            if let idx = chats.firstIndex(where: { $0.jid == jid }) {
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
                chats[idx] = c
                upsertPersisted(c)
                continue
            }
            if isTombstoned(jid) { continue }
            var fresh = Chat(
                jid: jid,
                name: g.name.isEmpty ? jid : g.name,
                lastMessage: g.topic,
                lastTimestamp: 0,
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
            upsertPersisted(chats[chats.count - 1])
        }
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
        for c in cs {
            let jid = JIDNormalize.bare(c.jid)
            if chats.contains(where: { $0.jid == jid }) { continue }
            if isTombstoned(jid) { continue }
            let chat = Chat(
                jid: jid,
                name: c.name,
                lastMessage: "",
                lastTimestamp: 0,
                unread: 0)
            chats.append(chat)
            upsertPersisted(chat)
        }
        sortChats()
    }

    /// Persist a peer-device delete-for-me sync directly to the
    /// PersistedMessage row, independent of whether the chat is
    /// currently open. Called by the event loop on every inbound
    /// `.messageLocallyDeleted` so the row stays hidden after restart.
    ///
    /// F21: SwiftData persistence is batched off-main via MessageWriter
    /// with a 50 ms coalesce window. The post-batch flush calls
    /// `refreshPreview` for every chat JID that got a row that affects
    /// preview text (delete / revoke / edit) so the sidebar reflects
    /// the new last-message state.
    func applyIncomingLocalDelete(chatJID: String, messageID: String) {
        enqueueMutation(.localDelete(id: messageID, chatJID: chatJID))
    }

    /// Persist a peer-device revoke directly to PersistedMessage row,
    /// regardless of whether the chat is currently open.
    func applyIncomingRevoke(chatJID: String, messageID: String, revokedBy: String, at: Date) {
        enqueueMutation(.revoke(id: messageID, chatJID: chatJID, by: revokedBy, at: at))
    }

    /// Persist a peer-device or peer-participant in-chat pin/unpin
    /// directly to PersistedMessage, regardless of whether the chat
    /// is currently open.
    func applyIncomingMessagePin(chatJID: String, targetMessageID: String,
                                 pinned: Bool, at: Date) {
        enqueueMutation(.messagePin(id: targetMessageID, chatJID: chatJID,
                                    pinned: pinned, at: at))
    }

    /// Persist a peer-device (un)star directly to PersistedMessage,
    /// regardless of whether the chat is currently open. No preview
    /// refresh — starring doesn't change last-message state.
    func applyIncomingStar(chatJID: String, messageID: String,
                           starred: Bool, at: Date) {
        enqueueMutation(.star(id: messageID, chatJID: chatJID,
                              starred: starred, at: at))
    }

    /// Persist a peer-device edit directly to PersistedMessage row,
    /// regardless of whether the chat is currently open.
    func applyIncomingEdit(chatJID: String, messageID: String, newText: String, at: Date) {
        enqueueMutation(.edit(id: messageID, chatJID: chatJID,
                              newText: newText, at: at))
    }

    /// F21: queue a `MessageMutation` for the background writer and arm
    /// a 50 ms flush task. When the batch persists, refresh the sidebar
    /// preview for every chat JID that received a mutation that affects
    /// last-message text (delete / revoke / edit).
    private func enqueueMutation(_ m: MessageWriter.MessageMutation) {
        pendingMutations.append(m)
        guard pendingMutationsFlush == nil else { return }
        pendingMutationsFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            let batch = self.pendingMutations
            self.pendingMutations.removeAll(keepingCapacity: true)
            self.pendingMutationsFlush = nil
            guard !batch.isEmpty, let writer = self.writer else { return }
            await writer.enqueueMutations(batch)
            // Preview refresh runs AFTER the writer commits so the
            // MainActor fetch sees the new revoked / locally-deleted /
            // text fields. star and message-pin don't affect preview
            // text so they don't trigger a refresh.
            var chatsNeedingRefresh: Set<String> = []
            for m in batch {
                switch m {
                case .localDelete(_, let chatJID),
                     .revoke(_, let chatJID, _, _),
                     .edit(_, let chatJID, _, _):
                    chatsNeedingRefresh.insert(chatJID)
                case .messagePin, .star:
                    break
                }
            }
            for jid in chatsNeedingRefresh {
                self.refreshPreview(chatJID: jid)
            }
        }
    }

    /// Re-derive `lastMessage` / `lastTimestamp` for `chatJID` from the
    /// most-recent PersistedMessage row. Honors revoked / locally-deleted
    /// state with a 🚫 prefix. Called by CVM after edit / revoke /
    /// delete-for-me mutations so the sidebar stays in sync.
    func refreshPreview(chatJID: String) {
        guard let context else { return }
        var descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == chatJID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return }
        let preview = Self.previewText(for: row)
        let resolved = resolveMentionsText(preview) { [weak session] jid in
            session?.displayName(for: jid) ?? jid
        }
        guard let idx = chats.firstIndex(where: { $0.jid == chatJID }) else { return }
        var c = chats[idx]
        c.lastMessage = resolved
        c.lastTimestamp = Int64(row.timestamp.timeIntervalSince1970)
        chats[idx] = c
        upsertPersisted(c, preview: c.lastMessage)
        sortChats()
    }

    private static func previewText(for m: PersistedMessage) -> String {
        if m.revokedAt != nil   { return "🚫 message deleted" }
        if m.locallyDeleted     { return "🚫 you deleted this" }
        if let t = m.text, !t.isEmpty { return t }
        switch m.kind {
        case "image":    return "📷 Photo"
        case "video":    return "🎥 Video"
        case "audio":    return "🎤 Audio"
        case "document": return "📄 Document"
        case "sticker":  return "Sticker"
        case "location": return "📍 Location"
        case "poll":     return "📊 Poll"
        case "protocol", "system": return ""
        default:         return "[\(m.kind)]"
        }
    }

    private func sortChats() {
        chats.sort(by: Self.chatOrder)
    }

    func resolveNames(_ cs: [BridgeContact]) {
        let byJID = Dictionary(uniqueKeysWithValues: cs.map { ($0.jid, $0.name) })
        for i in chats.indices {
            if let resolved = byJID[chats[i].jid], chats[i].name != resolved {
                chats[i].name = resolved
                upsertPersisted(chats[i])
            }
        }
    }

    private func upsertPersisted(_ c: Chat, preview: String? = nil) {
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
            context.insert(row)
        }
        try? context.save()
    }

    /// Toggle pin state for `chat`. Sends an appstate patch (the
    /// server fans out to peer devices) and mutates the row eagerly;
    /// peer-device echoes converge via `applyIncomingChatPin`.
    func pinChat(_ chat: Chat, pinned: Bool) {
        guard let client else { return }
        Task { @MainActor in
            do {
                try client.pinChat(chatJID: chat.jid, pinned: pinned)
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
        let pinned: Set<String>
        do {
            pinned = Set(try client.listPinnedChats(jids: jids))
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
            upsertPersisted(chats[i])
            changed = true
        }
        if changed { sortChats() }
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
        for (lid, pn) in pairs {
            guard let li = chats.firstIndex(where: { $0.jid == lid }),
                  let pi = chats.firstIndex(where: { $0.jid == pn }) else { continue }
            let lidChat = chats[li]
            var pnChat = chats[pi]
            pnChat.unread += lidChat.unread
            if lidChat.lastTimestamp > pnChat.lastTimestamp {
                pnChat.lastTimestamp = lidChat.lastTimestamp
                pnChat.lastMessage = lidChat.lastMessage
            }
            // Adopt the LID row's name only if the phone row is still an
            // unresolved placeholder (its jid as the name).
            if pnChat.name == pn, lidChat.name != lid {
                pnChat.name = lidChat.name
            }
            chats[pi] = pnChat
            upsertPersisted(pnChat)
        }
        let lids = Set(pairs.map(\.lid))
        chats.removeAll { lids.contains($0.jid) }
        _ = SQLiteDedupe.mergeLIDChats(pairs)
        sortChats()
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
                try client.muteChat(chatJID: chat.jid,
                                    mute: until != nil,
                                    mutedUntilMs: muteMs)
                self.applyLocalMute(chatJID: chat.jid, mutedUntil: until)
            } catch {
                NSLog("[yawac/muteChat] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    /// Cold-start reconcile: pull whatsmeow's local muted-chats list
    /// and align our rows. whatsmeow doesn't re-emit events.Mute for
    /// already-synced patches on reconnect.
    func reconcileMutedWithStore() {
        guard let client else { return }
        let jids = chats.map(\.jid)
        let entries: [(jid: String, mutedUntilMs: Int64)]
        do {
            entries = try client.listMutedChats(jids: jids)
        } catch {
            NSLog("[yawac/mute-reconcile] failed: %@",
                  String(describing: error))
            return
        }
        let byJID = Dictionary(uniqueKeysWithValues:
            entries.map { ($0.jid, $0.mutedUntilMs) })
        var changed = false
        for i in chats.indices {
            let serverMs = byJID[chats[i].jid] ?? 0
            let serverUntil: Date? = serverMs == 0
                ? nil
                : Date(timeIntervalSince1970: TimeInterval(serverMs) / 1000)
            if chats[i].mutedUntil == serverUntil { continue }
            chats[i].mutedUntil = serverUntil
            upsertPersisted(chats[i])
            changed = true
        }
        if changed { sortChats() }
    }

    // MARK: - Group info (name + description)

    /// Issues `SetGroupName` to the bridge + optimistic local apply.
    func setGroupName(_ chat: Chat, to name: String) {
        guard let client else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            do {
                try client.setGroupName(chatJID: chat.jid, name: trimmed)
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
                try client.setGroupDescription(chatJID: chat.jid,
                                               description: trimmed)
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
                try client.archiveChat(chatJID: chat.jid, archived: archived,
                                       lastTS: last.ts, lastMsgID: last.id, fromMe: last.fromMe)
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
                    try client.deleteChat(chatJID: chat.jid, lastTS: last.ts,
                                          lastMsgID: last.id, fromMe: last.fromMe)
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

    private func removeChatLocally(_ chatJID: String) {
        tombstone(chatJID)
        chats.removeAll { $0.jid == chatJID }
        if let context {
            let msgs = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.chatJID == chatJID })
            if let rows = try? context.fetch(msgs) {
                for r in rows { context.delete(r) }
            }
            let chatDesc = FetchDescriptor<PersistedChat>(
                predicate: #Predicate { $0.jid == chatJID })
            if let row = try? context.fetch(chatDesc).first {
                context.delete(row)
            }
            try? context.save()
        }
        // SwiftData delete of unique-key rows is unreliable here, so purge
        // directly so the chat doesn't resurrect on next launch.
        _ = SQLiteDedupe.purgeChat(jid: chatJID)
    }

    /// Save a contact name (synced to the phone). Updates the local name on
    /// success; peer echoes converge via `applyIncomingContact`.
    func addContact(_ chat: Chat, fullName: String, firstName: String) {
        guard let client, !fullName.isEmpty else { return }
        Task { @MainActor in
            do {
                try client.setContactName(jid: chat.jid, fullName: fullName, firstName: firstName)
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
}
