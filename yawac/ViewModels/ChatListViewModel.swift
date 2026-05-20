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

        // One-time cleanup: collapse rows whose jid only differs by the
        // device suffix `:<n>@server`. Keep the row with the newest
        // lastTimestamp; sum unread; delete the rest. Persisted in DB.
        var keepers: [String: PersistedChat] = [:]
        var toDelete: [PersistedChat] = []
        for r in rows {
            let bare = JIDNormalize.bare(r.jid)
            if let existing = keepers[bare] {
                if r.lastTimestamp > existing.lastTimestamp {
                    existing.lastTimestamp = r.lastTimestamp
                    existing.lastMessageText = r.lastMessageText ?? existing.lastMessageText
                    if !r.name.isEmpty { existing.name = r.name }
                }
                existing.unread += r.unread
                toDelete.append(r)
            } else if r.jid != bare {
                // Same jid will rebind under canonical key; delete this
                // device-suffixed row and re-create canonical.
                let canon = PersistedChat(
                    jid: bare,
                    name: r.name,
                    lastMessageText: r.lastMessageText,
                    lastTimestamp: r.lastTimestamp,
                    unread: r.unread)
                context.insert(canon)
                keepers[bare] = canon
                toDelete.append(r)
            } else {
                keepers[bare] = r
            }
        }
        for r in toDelete { context.delete(r) }
        if !toDelete.isEmpty { try? context.save() }

        self.chats = keepers.values
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
            .map {
                Chat(jid: $0.jid, name: $0.name,
                     lastMessage: $0.lastMessageText ?? "",
                     lastTimestamp: Int64($0.lastTimestamp.timeIntervalSince1970),
                     unread: $0.unread)
            }
    }

    func ingest(_ message: BridgeMessage) {
        // Skip protocol/system noise — no UI value
        if message.kind == "protocol" || message.kind == "system" { return }
        let chatJID = JIDNormalize.bare(message.chatJID)

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
            chatJID: JIDNormalize.bare(m.chatJID),
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

    func mergeGroups(_ gs: [BridgeGroupModel]) {
        for g in gs {
            let jid = JIDNormalize.bare(g.jid)
            if chats.contains(where: { $0.jid == jid }) { continue }
            chats.append(Chat(
                jid: jid,
                name: g.name.isEmpty ? jid : g.name,
                lastMessage: g.topic,
                lastTimestamp: 0,
                unread: 0))
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
            if let preview { existing.lastMessageText = preview }
        } else {
            let row = PersistedChat(
                jid: c.jid,
                name: c.name,
                lastMessageText: preview,
                lastTimestamp: Date(timeIntervalSince1970: TimeInterval(c.lastTimestamp)),
                unread: c.unread)
            context.insert(row)
        }
        try? context.save()
    }
}
