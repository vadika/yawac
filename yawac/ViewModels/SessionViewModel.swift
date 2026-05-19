import Foundation
import Observation

@Observable @MainActor
final class SessionViewModel {
    enum State: Equatable {
        case loading
        case needsPair
        case ready
        case error(String)
    }

    var state: State = .loading
    var qrCode: String?
    var client: WAClient?

    private var eventTask: Task<Void, Never>?

    func boot() async {
        do {
            let url = try AppPaths.databaseURL()
            let c = try WAClient(dbPath: url.path)
            self.client = c
            try c.connect()
            self.state = c.isLoggedIn ? .ready : .needsPair
            consumeEvents()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func consumeEvents() {
        guard let client else { return }
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            for await event in client.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: WAClient.Event) {
        switch event {
        case .qr(let code):
            qrCode = code
            state = .needsPair
        case .pairSuccess, .connected:
            qrCode = nil
            state = .ready
        case .loggedOut:
            state = .needsPair
        case .disconnected:
            break
        default:
            break
        }
    }
}
