import AppKit
import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class ChatListViewModel {
    var chats: [Chat] = []
    private let client: WAClient
    private let context: ModelContext?

    init(client: WAClient, context: ModelContext? = nil) {
        self.client = client
        self.context = context
        loadChats()
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
            let canon = client.resolveLIDToPN(r.jid)
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
        // the actual messages on disk, ignoring the PersistedChat columns
        // which SwiftData sometimes refuses to commit (verified earlier
        // for @lid dedupe). This makes the sidebar order match reality
        // even when upsertPersisted's save was a no-op.
        let msgDescriptor = FetchDescriptor<PersistedMessage>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        var latestByChat: [String: (ts: Date, text: String)] = [:]
        if let allMessages = try? context.fetch(msgDescriptor) {
            for m in allMessages {
                if latestByChat[m.chatJID] != nil { continue }
                let preview: String
                if let t = m.text, !t.isEmpty {
                    preview = t
                } else {
                    switch m.kind {
                    case "image":    preview = "📷 Photo"
                    case "video":    preview = "🎥 Video"
                    case "audio":    preview = "🎤 Audio"
                    case "document": preview = "📄 Document"
                    case "sticker":  preview = "Sticker"
                    case "location": preview = "📍 Location"
                    case "poll":     preview = "📊 Poll"
                    default:         preview = "[\(m.kind)]"
                    }
                }
                latestByChat[m.chatJID] = (m.timestamp, preview)
            }
        }

        self.chats = keepers.values
            .map { row -> Chat in
                let derived = latestByChat[row.jid]
                let ts = max(
                    row.lastTimestamp.timeIntervalSince1970,
                    derived?.ts.timeIntervalSince1970 ?? -.infinity)
                let preview: String = {
                    if let d = derived,
                       d.ts.timeIntervalSince1970 >= row.lastTimestamp.timeIntervalSince1970 {
                        return d.text
                    }
                    return row.lastMessageText ?? ""
                }()
                return Chat(
                    jid: row.jid, name: row.name,
                    lastMessage: preview,
                    lastTimestamp: Int64(ts.isFinite ? ts : 0),
                    unread: row.unread,
                    isCommunityParent: row.isCommunityParent,
                    communityParentJID: row.communityParentJID,
                    isDefaultSubGroup: row.isDefaultSubGroup)
            }
            .sorted { a, b in
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

        let preview: String
        if let text = message.text, !text.isEmpty {
            preview = text
        } else {
            switch message.kind {
            case "image":    preview = "📷 Photo"
            case "video":    preview = "🎥 Video"
            case "audio":    preview = "🎤 Audio"
            case "document": preview = "📄 Document"
            case "sticker":  preview = "Sticker"
            case "location": preview = "📍 Location"
            case "poll":     preview = "📊 \(message.poll?.question ?? "Poll")"
            case "protocol", "system": preview = ""  // hide
            default:         preview = "[\(message.kind)]"
            }
        }

        let now = message.timestamp
        if let idx = chats.firstIndex(where: { $0.jid == chatJID }) {
            var c = chats[idx]
            if now >= c.lastTimestamp {
                c.lastMessage = preview
                c.lastTimestamp = now
            }
            if !alreadySeen, !message.fromMe { c.unread += 1 }
            chats[idx] = c
            upsertPersisted(c, preview: c.lastMessage)
        } else {
            let c = Chat(
                jid: chatJID,
                name: chatJID,
                lastMessage: preview,
                lastTimestamp: now,
                unread: (!alreadySeen && !message.fromMe) ? 1 : 0)
            chats.append(c)
            upsertPersisted(c, preview: preview)
        }
        sortChats()

        if !alreadySeen, !message.fromMe, !NSApp.isActive, !preview.isEmpty {
            let title = chats.first(where: { $0.jid == chatJID })?.name ?? chatJID
            NotificationService.notify(title: title, body: preview, chatJID: chatJID)
        }
    }

    private func persistMessage(_ m: BridgeMessage) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id,
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
            pollJSON: m.poll?.json)
        context.insert(row)
        try? context.save()
    }

    func markRead(_ jid: String) {
        guard let i = chats.firstIndex(where: { $0.jid == jid }) else { return }
        chats[i].unread = 0
        upsertPersisted(chats[i])
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
        NotificationService.notify(
            title: chatName,
            body: "\(r.emoji) reacted to your message",
            chatJID: canonChat)
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

    private func sortChats() {
        chats.sort { a, b in
            if a.lastTimestamp != b.lastTimestamp {
                return a.lastTimestamp > b.lastTimestamp
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
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
                isDefaultSubGroup: c.isDefaultSubGroup)
            context.insert(row)
        }
        try? context.save()
    }
}
