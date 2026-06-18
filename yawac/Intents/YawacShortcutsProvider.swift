import AppIntents

/// F97: registers yawac's four Shortcuts in the system-wide
/// Shortcuts.app gallery. macOS picks this up automatically on first
/// launch after install — no UI work required to populate the
/// Shortcuts library.
struct YawacShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendWhatsAppMessage(),
            phrases: ["Send WhatsApp message via \(.applicationName)"],
            shortTitle: "Send Message",
            systemImageName: "paperplane")
        AppShortcut(
            intent: OpenWhatsAppChat(),
            phrases: ["Open WhatsApp chat in \(.applicationName)"],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(
            intent: MarkWhatsAppChatRead(),
            phrases: ["Mark WhatsApp chat read in \(.applicationName)"],
            shortTitle: "Mark Chat Read",
            systemImageName: "checkmark.message")
        AppShortcut(
            intent: SearchWhatsAppMessages(),
            phrases: ["Search WhatsApp messages in \(.applicationName)"],
            shortTitle: "Search Messages",
            systemImageName: "magnifyingglass")
    }
}
