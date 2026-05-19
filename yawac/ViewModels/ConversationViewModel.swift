import Foundation
import Observation

@Observable @MainActor
final class ConversationViewModel {
    let chatJID: String
    var messages: [UIMessage] = []
    var draft: String = ""
    var peerTyping: Bool = false
    let client: WAClient

    init(chatJID: String, client: WAClient) {
        self.chatJID = chatJID
        self.client = client
    }

    func sendDraft() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        do {
            let res = try client.sendText(chatJID, body)
            messages.append(UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .text(body)))
        } catch {
            messages.append(UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID,
                senderJID: "system",
                fromMe: false,
                timestamp: .now,
                body: .system("send failed: \(error.localizedDescription)")))
        }
    }

    func ingest(_ b: BridgeMessage) {
        guard b.chatJID == chatJID else { return }
        messages.append(UIMessage(b))
    }

    func setTyping(_ typing: Bool) {
        try? client.sendTyping(chatJID, typing)
    }
}
