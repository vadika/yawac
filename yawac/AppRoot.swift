import SwiftUI

struct AppRoot: View {
    @Environment(SessionViewModel.self) private var session

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
                    .font(Theme.ui(13))
                    .foregroundStyle(Color.red.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sync state is surfaced inside ConversationView via the
        // floating SyncBanner overlay — no top strip pushing content.
        .task { await session.boot() }
    }
}
