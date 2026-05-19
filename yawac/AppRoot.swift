import SwiftUI

struct AppRoot: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView().controlSize(.large)
            case .needsPair:
                LoginView()
            case .ready:
                ContentView()
            case .error(let msg):
                Text("Error: \(msg)").foregroundStyle(.red)
            }
        }
        .task { await session.boot() }
    }
}
