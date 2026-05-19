import Foundation
import Observation

@Observable @MainActor
final class ChatListViewModel {
    var chats: [Chat] = []
    private let client: WAClient

    init(client: WAClient) { self.client = client }

    func ingest(_ message: BridgeMessage) {
        let now = message.timestamp
        if let idx = chats.firstIndex(where: { $0.jid == message.chatJID }) {
            var c = chats[idx]
            c.lastMessage = message.text ?? "[\(message.kind)]"
            c.lastTimestamp = now
            if !message.fromMe { c.unread += 1 }
            chats[idx] = c
        } else {
            chats.append(Chat(
                jid: message.chatJID,
                name: message.chatJID,  // resolved later via contacts
                lastMessage: message.text ?? "[\(message.kind)]",
                lastTimestamp: now,
                unread: message.fromMe ? 0 : 1
            ))
        }
        chats.sort { $0.lastTimestamp > $1.lastTimestamp }
    }

    func markRead(_ jid: String) {
        guard let i = chats.firstIndex(where: { $0.jid == jid }) else { return }
        chats[i].unread = 0
    }
}
