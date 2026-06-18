import AppIntents
import Foundation

/// F97: "Mark WhatsApp Chat Read" Shortcut. Routes through the
/// existing `ChatListViewModel.markRead(_:)` which handles bridge
/// IQ + persisted-row updates + receipt fan-out.
struct MarkWhatsAppChatRead: AppIntent {
    static var title: LocalizedStringResource = "Mark WhatsApp Chat as Read"
    static var description = IntentDescription("Marks all unread messages in a WhatsApp chat as read.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Chat", description: "Phone number or contact name")
    var chat: String

    @Dependency private var session: SessionViewModel

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard session.client != nil else { throw ChatResolveError.notPaired }
        guard let chatList = session.chatList else { throw ChatResolveError.notPaired }
        let target = try ChatResolver.resolveChat(chat, in: chatList.chats)
        chatList.markRead(target.jid)
        return .result(value: "Marked \(target.name) as read")
    }
}
