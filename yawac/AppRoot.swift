import SwiftUI

struct AppRoot: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            if session.syncing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Syncing history…")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
            }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await session.boot() }
    }
}
