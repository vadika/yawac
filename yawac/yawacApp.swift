import SwiftUI

@main
struct YawacApp: App {
    @State private var session = SessionViewModel()

    var body: some Scene {
        WindowGroup("yawac") {
            AppRoot()
                .environment(session)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
