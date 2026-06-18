import AppIntents
import Foundation

/// F97: "Search WhatsApp Messages" Shortcut. Brings yawac to the
/// front and writes the query through SessionViewModel's transient
/// `pendingShortcutQuery` field; ContentView's `.onChange` observer
/// forwards into the live `ChatSearchViewModel`.
struct SearchWhatsAppMessages: AppIntent {
    static var title: LocalizedStringResource = "Search WhatsApp Messages"
    static var description = IntentDescription("Opens yawac with a search query applied to the global message index.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Query")
    var query: String

    @Dependency private var session: SessionViewModel

    @MainActor
    func perform() async throws -> some IntentResult {
        session.pendingShortcutQuery = query
        WindowToggler.bringToFront()
        return .result()
    }
}
