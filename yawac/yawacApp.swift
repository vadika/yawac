import SwiftUI
import SwiftData

@main
struct YawacApp: App {
    @State private var session = SessionViewModel()
    let container: ModelContainer

    init() {
        do {
            self.container = try ModelContainer(for: PersistedMessage.self, PersistedChat.self)
        } catch {
            fatalError("ModelContainer: \(error)")
        }
        Task { await NotificationService.requestAuthorization() }
    }

    var body: some Scene {
        WindowGroup("yawac") {
            AppRoot()
                .environment(session)
                .modelContainer(container)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
