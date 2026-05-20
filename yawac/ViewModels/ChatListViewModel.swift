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
        if let rows = try? context.fetch(descriptor) {
            self.chats = rows.map {
                Chat(jid: $0.jid, name: $0.name,
                     lastMessage: "",
                     lastTimestamp: Int64($0.lastTimestamp.timeIntervalSince1970),
                     unread: $0.unread)
            }
        }
    }

    func ingest(_ message: BridgeMessage) {
        // Skip protocol/system noise — no UI value
        if message.kind == "protocol" || message.kind == "system" { return }

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

        if alreadySeen { return }

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
            case "protocol", "system": preview = ""  // hide
            default:         preview = "[\(message.kind)]"
            }
        }

        let now = message.timestamp
        if let idx = chats.firstIndex(where: { $0.jid == message.chatJID }) {
            var c = chats[idx]
            c.lastMessage = preview
            c.lastTimestamp = now
            if !message.fromMe { c.unread += 1 }
            chats[idx] = c
            upsertPersisted(c)
        } else {
            let c = Chat(
                jid: message.chatJID,
                name: message.chatJID,
                lastMessage: preview,
                lastTimestamp: now,
                unread: message.fromMe ? 0 : 1)
            chats.append(c)
            upsertPersisted(c)
        }
        sortChats()

        if !message.fromMe, !NSApp.isActive, !preview.isEmpty {
            let title = chats.first(where: { $0.jid == message.chatJID })?.name ?? message.chatJID
            NotificationService.notify(title: title, body: preview, chatJID: message.chatJID)
        }
    }

    private func persistMessage(_ m: BridgeMessage) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id,
            chatJID: m.chatJID,
            senderJID: m.senderJID,
            fromMe: m.fromMe,
            timestamp: Date(timeIntervalSince1970: TimeInterval(m.timestamp)),
            kind: m.kind,
            text: m.text,
            mediaPath: m.media?.filePath,
            mediaCaption: m.media?.caption,
            mediaFileName: m.media?.fileName,
            mediaRefJSON: m.media?.ref?.json)
        context.insert(row)
        try? context.save()
    }

    func markRead(_ jid: String) {
        guard let i = chats.firstIndex(where: { $0.jid == jid }) else { return }
        chats[i].unread = 0
        upsertPersisted(chats[i])
    }

    func mergeGroups(_ gs: [BridgeGroupModel]) {
        for g in gs where !chats.contains(where: { $0.jid == g.jid }) {
            chats.append(Chat(
                jid: g.jid,
                name: g.name.isEmpty ? g.jid : g.name,
                lastMessage: g.topic,
                lastTimestamp: 0,
                unread: 0))
            upsertPersisted(chats[chats.count - 1])
        }
        sortChats()
    }

    func mergeContacts(_ cs: [BridgeContact]) {
        for c in cs where !chats.contains(where: { $0.jid == c.jid }) {
            let chat = Chat(
                jid: c.jid,
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

    private func upsertPersisted(_ c: Chat) {
        guard let context else { return }
        let jid = c.jid
        let descriptor = FetchDescriptor<PersistedChat>(
            predicate: #Predicate { $0.jid == jid })
        if let existing = try? context.fetch(descriptor).first {
            existing.name = c.name
            existing.lastTimestamp = Date(timeIntervalSince1970: TimeInterval(c.lastTimestamp))
            existing.unread = c.unread
        } else {
            let row = PersistedChat(
                jid: c.jid,
                name: c.name,
                lastTimestamp: Date(timeIntervalSince1970: TimeInterval(c.lastTimestamp)),
                unread: c.unread)
            context.insert(row)
        }
        try? context.save()
    }
}
