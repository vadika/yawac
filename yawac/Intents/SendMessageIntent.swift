import AppIntents
import Foundation

/// F97: "Send WhatsApp Message" Shortcut. Resolves the chat input
/// (phone or contact name) and invokes the existing
/// `WAClient.sendText` via the live `SessionViewModel`. App must be
/// running (or will be launched) because the bridge holds live state.
struct SendWhatsAppMessage: AppIntent {
    static var title: LocalizedStringResource = "Send WhatsApp Message"
    static var description = IntentDescription("Sends a WhatsApp message via yawac to a chat looked up by phone number or contact name.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Chat", description: "Phone number or contact name")
    var chat: String

    @Parameter(title: "Message")
    var body: String

    @Dependency private var session: SessionViewModel

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let client = session.client else { throw ChatResolveError.notPaired }
        let chats = session.chatList?.chats ?? []
        let target = try ChatResolver.resolveChat(chat, in: chats)
        let result = try await Task.detached(priority: .userInitiated) {
            [client, jid = target.jid, body = self.body] in
            try client.sendText(jid, body)
        }.value
        return .result(value: "Sent message \(result.messageID)")
    }
}
