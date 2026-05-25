import Foundation
import Observation

/// In-memory, per-session cache of translation results keyed by
/// `surfaceID` (one message can have multiple translatable surfaces:
/// body text, media caption, poll question, poll options).
@Observable @MainActor
final class TranslationStore {
    struct Entry: Equatable {
        let original: String
        let translated: String
        let sourceLang: String
        var showingTranslated: Bool
    }

    private(set) var byMessageID: [String: Entry] = [:]
    private(set) var inFlight: Set<String> = []

    func entry(for id: String) -> Entry? {
        byMessageID[id]
    }

    /// Returns `true` and reserves the slot when `id` is not already
    /// being translated. Returns `false` if a translation is in flight.
    func startInFlight(_ id: String) -> Bool {
        guard !inFlight.contains(id) else { return false }
        inFlight.insert(id)
        return true
    }

    func finish(_ id: String, with entry: Entry) {
        inFlight.remove(id)
        byMessageID[id] = entry
    }

    func fail(_ id: String) {
        inFlight.remove(id)
    }

    func toggle(_ id: String) {
        guard var entry = byMessageID[id] else { return }
        entry.showingTranslated.toggle()
        byMessageID[id] = entry
    }
}
