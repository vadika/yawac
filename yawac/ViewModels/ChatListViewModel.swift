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
        let now = message.timestamp
        if let idx = chats.firstIndex(where: { $0.jid == message.chatJID }) {
            var c = chats[idx]
            c.lastMessage = message.text ?? "[\(message.kind)]"
            c.lastTimestamp = now
            if !message.fromMe { c.unread += 1 }
            chats[idx] = c
            upsertPersisted(c)
        } else {
            let c = Chat(
                jid: message.chatJID,
                name: message.chatJID,
                lastMessage: message.text ?? "[\(message.kind)]",
                lastTimestamp: now,
                unread: message.fromMe ? 0 : 1)
            chats.append(c)
            upsertPersisted(c)
        }
        chats.sort { $0.lastTimestamp > $1.lastTimestamp }
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
                lastTimestamp: g.created,
                unread: 0))
            upsertPersisted(chats[chats.count - 1])
        }
        chats.sort { $0.lastTimestamp > $1.lastTimestamp }
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
