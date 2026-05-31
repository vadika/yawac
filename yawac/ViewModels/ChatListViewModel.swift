import AppKit
import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class ChatListViewModel {
    var chats: [Chat] = [] {
        didSet { pushUnreadToSession() }
    }
    private let client: WAClient?
    private let context: ModelContext?
    /// Weak link back to the global session so the menubar icon can
    /// reflect the chats' aggregate unread count without subscribing
    /// to vm.chats directly from app-level scope.
    weak var session: SessionViewModel?

    init(client: WAClient?, context: ModelContext? = nil) {
        self.client = client
        self.context = context
        loadChats()
    }

    private func pushUnreadToSession() {
        let total = chats.reduce(0) { $0 + $1.unread }
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

    private func loadChats() {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedChat>(
            sortBy: [SortDescriptor(\.lastTimestamp, order: .reverse)])
        guard let rows = try? context.fetch(descriptor) else { return }

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
            let canon = client?.resolveLIDToPN(r.jid) ?? r.jid
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
            let bare = JIDNormalize.canonical(r.jid, client: client)
            if r.jid == bare {
                keepers[bare] = r
            }
        }

        // Pass 2: handle non-canonical (e.g. `@lid` or `:device@server`)
        // rows. Merge into existing canonical anchor if present;
        // otherwise mutate-in-place to adopt the canonical jid.
        for r in rowsAfter {
            let bare = JIDNormalize.canonical(r.jid, client: client)
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
                // No canonical row yet — rebind this one in place so it
                // becomes the anchor. Avoids creating a phantom row that
                // would collide with a yet-to-arrive PN row.
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

        let deleteCount = toDelete.count
        for r in toDelete { context.delete(r) }
        var saveErr: String = "ok"
        if !toDelete.isEmpty {
            do { try context.save() } catch { saveErr = String(describing: error) }
        }
        NSLog("[yawac/loadChats] toDelete=%d save=%@", deleteCount, saveErr)
        keepers = seen

        // Derive a fresh per-chat (lastTimestamp, lastMessageText) from
        // raw SQLite — going through SwiftData materialises every row
        // and freezes main on chats with thousands of messages.
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

        self.chats = keepers.values
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
                let preview = resolveMentionsText(rawPreview) { [weak session] jid in
                    session?.displayName(for: jid) ?? jid
                }
                return Chat(
                    jid: row.jid, name: row.name,
                    lastMessage: preview,
                    lastTimestamp: Int64(ts.isFinite ? ts : 0),
                    unread: row.unread,
                    isCommunityParent: row.isCommunityParent,
                    communityParentJID: row.communityParentJID,
                    isDefaultSubGroup: row.isDefaultSubGroup,
                    pinnedAt: row.pinnedAt,
                    archivedAt: row.archivedAt,
                    mutedUntil: row.mutedUntil)
            }
            .filter { !isTombstoned($0.jid) }
            .sorted(by: Self.chatOrder)
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
        if suppressedByTombstone(chatJID, messageTS: message.timestamp) { return }
        untombstone(chatJID)

        // Dedupe: if this message id is already persisted, this is a replay
        // (e.g. HistorySync redelivering on reconnect). Skip unread/preview
        // bumps so counts don't grow on every restart.
        let alreadySeen: Bool
        if let context {
            let id = message.id
            let descriptor = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.id == id })
            alreadySeen = (try? context.fetch(descriptor).first) != nil
        } else {
            alreadySeen = false
        }

        // Persist every incoming message so history is available even when the
        // conversation view hasn't been opened yet.
        persistMessage(message)

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
            upsertPersisted(c, preview: c.lastMessage)
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
            upsertPersisted(c, preview: preview)
        }
        sortChats()

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
            NotificationService.notify(
                title: title,
                body: preview,
                chatJID: chatJID,
                subtitle: subtitle,
                resolveMentions: { [weak session] jid in session?.displayName(for: jid) ?? jid })
        }
    }

    private func persistMessage(_ m: BridgeMessage) {
        guard let context else { return }
        let id = m.id

        // Upsert: history-sync replays sometimes deliver fresher media
        // refs than what we first persisted — see ConversationViewModel
        // for the long story. Refresh media fields on an existing row
        // instead of letting @Attribute(.unique) silently drop the new
        // arrival.
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            if let ref = m.media?.ref?.json, ref != existing.mediaRefJSON {
                existing.mediaRefJSON = ref
                existing.mediaExpired = false
            }
            if let p = m.media?.filePath, !p.isEmpty { existing.mediaPath = p }
            if let c = m.media?.caption, !c.isEmpty { existing.mediaCaption = c }
            if let f = m.media?.fileName, !f.isEmpty { existing.mediaFileName = f }
            try? context.save()
            return
        }

        let row = PersistedMessage(
            id: id,
            chatJID: JIDNormalize.canonical(m.chatJID, client: client),
            senderJID: m.senderJID,
            fromMe: m.fromMe,
            timestamp: Date(timeIntervalSince1970: TimeInterval(m.timestamp)),
            kind: m.kind,
            text: m.text,
            mediaPath: m.media?.filePath,
            mediaCaption: m.media?.caption,
            mediaFileName: m.media?.fileName,
            mediaRefJSON: m.media?.ref?.json,
            pollJSON: m.poll?.json,
            quotedMessageID: m.quoted?.messageID,
            quotedSenderJID: m.quoted?.senderJID,
            quotedFromMe: m.quoted?.fromMe ?? false,
            quotedTextSnippet: m.quoted?.snippet,
            quotedKind: m.quoted?.kind)
        context.insert(row)
        try? context.save()
        MessageIndex.shared.upsert(row.indexFields)
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
        guard let context else { return }
        let id = r.targetMessageID
        let sender = r.senderJID
        let descriptor = FetchDescriptor<PersistedReaction>(
            predicate: #Predicate {
                $0.targetMessageID == id && $0.senderJID == sender
            })
        let ts = Date(timeIntervalSince1970: TimeInterval(r.timestamp))
        if r.emoji.isEmpty {
            if let row = try? context.fetch(descriptor).first {
                context.delete(row)
            }
        } else if let existing = try? context.fetch(descriptor).first {
            existing.emoji = r.emoji
            existing.timestamp = ts
            existing.chatJID = JIDNormalize.canonical(r.chatJID, client: client)
        } else {
            let row = PersistedReaction(
                chatJID: JIDNormalize.canonical(r.chatJID, client: client),
                targetMessageID: r.targetMessageID,
                senderJID: r.senderJID,
                emoji: r.emoji,
                timestamp: ts)
            context.insert(row)
        }
        try? context.save()

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
        NotificationService.notify(
            title: chatName,
            body: "\(r.emoji) reacted to your message",
            chatJID: canonChat,
            subtitle: reactSubtitle,
            resolveMentions: { [weak session] jid in session?.displayName(for: jid) ?? jid })
    }

    func mergeGroups(_ gs: [BridgeGroupModel]) {
        for g in gs {
            let jid = JIDNormalize.canonical(g.jid, client: client)
            let parentJID: String? = {
                guard let p = g.linkedParentJID, !p.isEmpty,
                      p.hasSuffix("@g.us") else { return nil }
                return p
            }()
            if let idx = chats.firstIndex(where: { $0.jid == jid }) {
                // Refresh community fields on existing chats so a previously
                // synced regular-group row gets promoted to a community
                // parent / sub-group if whatsmeow now reports it that way.
                var c = chats[idx]
                c.isCommunityParent = g.isParent
                c.communityParentJID = parentJID
                c.isDefaultSubGroup = g.isDefaultSubGroup
                if c.name == jid && !g.name.isEmpty { c.name = g.name }
                chats[idx] = c
                upsertPersisted(c)
                continue
            }
            if isTombstoned(jid) { continue }
            chats.append(Chat(
                jid: jid,
                name: g.name.isEmpty ? jid : g.name,
                lastMessage: g.topic,
                lastTimestamp: 0,
                unread: 0,
                isCommunityParent: g.isParent,
                communityParentJID: parentJID,
                isDefaultSubGroup: g.isDefaultSubGroup))
            upsertPersisted(chats[chats.count - 1])
        }
        sortChats()
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
    func applyIncomingLocalDelete(chatJID: String, messageID: String) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.locallyDeleted = true
            try? context.save()
        }
        refreshPreview(chatJID: chatJID)
    }

    /// Persist a peer-device revoke directly to PersistedMessage row,
    /// regardless of whether the chat is currently open.
    func applyIncomingRevoke(chatJID: String, messageID: String, revokedBy: String, at: Date) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.revokedAt = at
            row.revokedBy = revokedBy
            try? context.save()
        }
        refreshPreview(chatJID: chatJID)
    }

    /// Persist a peer-device or peer-participant in-chat pin/unpin
    /// directly to PersistedMessage, regardless of whether the chat
    /// is currently open.
    func applyIncomingMessagePin(chatJID: String, targetMessageID: String,
                                 pinned: Bool, at: Date) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == targetMessageID })
        if let row = try? context.fetch(descriptor).first {
            row.pinnedAt = pinned ? at : nil
            try? context.save()
        }
    }

    /// Persist a peer-device (un)star directly to PersistedMessage,
    /// regardless of whether the chat is currently open. No preview
    /// refresh — starring doesn't change last-message state.
    func applyIncomingStar(chatJID: String, messageID: String,
                           starred: Bool, at: Date) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.starredAt = starred ? at : nil
            try? context.save()
        }
    }

    /// Persist a peer-device edit directly to PersistedMessage row,
    /// regardless of whether the chat is currently open.
    func applyIncomingEdit(chatJID: String, messageID: String, newText: String, at: Date) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.text = newText
            row.editedAt = at
            try? context.save()
        }
        refreshPreview(chatJID: chatJID)
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
                mutedUntil: c.mutedUntil)
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

    /// Apply a mute change that arrived via `events.Mute`.
    /// LWW: ignore when our local `mutedUntil` is newer than `at`.
    func applyIncomingMute(chatJID: String, mutedUntil: Date?, at: Date) {
        if let existing = chats.first(where: { $0.jid == chatJID })?.mutedUntil,
           existing > at {
            return
        }
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
