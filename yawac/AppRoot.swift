import SwiftUI

struct AppRoot: View {
    @Environment(SessionViewModel.self) private var session
    // Read at the view level (not the App struct) so a change from the
    // separate Settings window reactively re-applies to this live window.
    @AppStorage(UIScaleStep.storageKey) private var scaleStepRaw = UIScaleStep.default.rawValue

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView().controlSize(.large).tint(Theme.accent)
            case .needsPair:
                LoginView()
            case .ready:
                ContentView()
            case .error(let msg):
                Text("Error: \(msg)")
                    .scaledUI(13)
                    .foregroundStyle(Color.red.opacity(0.85))
            }
        }
        .onOpenURL { url in
            if !session.handleWhatsAppURL(url) {
                session.urlOpenError = "This WhatsApp link is invalid or isn’t supported."
            }
            WindowToggler.bringToFront()
        }
        .environment(\.openURL, OpenURLAction { url in
            session.handleWhatsAppURL(url) ? .handled : .systemAction
        })
        .alert("Couldn’t open link", isPresented: Binding(
            get: { session.urlOpenError != nil },
            set: { if !$0 { session.urlOpenError = nil } })) {
                Button("OK") { session.urlOpenError = nil }
            } message: { Text(session.urlOpenError ?? "") }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.uiScaleFactor, UIScaleStep.from(scaleStepRaw).scaleFactor)
        // Sync state is surfaced inside ConversationView via the
        // floating SyncBanner overlay — no top strip pushing content.
        .task {
            NotificationRouter.shared.session = session
            if !AppPaths.isRunningTests { await session.boot() }
        }
    }
}
