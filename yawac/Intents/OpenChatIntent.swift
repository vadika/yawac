import AppIntents
import Foundation

/// F97: "Open WhatsApp Chat" Shortcut. Resolves chat input, drives
/// the session navigator + brings the main window forward. Goes
/// through `SessionViewModel.openRootChat` so the existing
/// BackBar / sidebar selection logic is honored.
struct OpenWhatsAppChat: AppIntent {
    static var title: LocalizedStringResource = "Open WhatsApp Chat"
    static var description = IntentDescription("Opens a WhatsApp chat in yawac by phone number or contact name.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Chat", description: "Phone number or contact name")
    var chat: String

    @Dependency private var session: SessionViewModel

    @MainActor
    func perform() async throws -> some IntentResult {
        guard session.client != nil else { throw ChatResolveError.notPaired }
        let chats = session.chatList?.chats ?? []
        let target = try ChatResolver.resolveChat(chat, in: chats)
        session.openRootChat(target.jid)
        WindowToggler.bringToFront()
        return .result()
    }
}
