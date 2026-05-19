import Foundation
import Observation

@Observable @MainActor
final class SessionViewModel {
    enum State {
        case loading
        case needsPair
        case ready
        case error(String)
    }
    var state: State = .loading

    func boot() async {
        state = .needsPair
    }
}
