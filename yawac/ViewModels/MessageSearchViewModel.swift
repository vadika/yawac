import Foundation
import Observation

/// Debounced async wrapper over `MessageIndex`. Holds the current query
/// and result arrays for both surfaces. The global path is debounced on
/// `query` assignment; the in-chat path is one-shot per call (the find
/// bar's own state owns debouncing — see ConversationViewModel).
@Observable @MainActor
final class MessageSearchViewModel {

    var query: String = "" {
        didSet { onQueryChanged() }
    }
    private(set) var globalHits: [MessageIndex.Hit] = []
    private(set) var inChatHits: [MessageIndex.Hit] = []

    private let index: MessageIndex
    private let debounceMs: Int
    private var debounceTask: Task<Void, Never>?

    init(index: MessageIndex = .shared, debounceMs: Int = 120) {
        self.index = index
        self.debounceMs = debounceMs
    }

    func clear() {
        debounceTask?.cancel()
        query = ""
        globalHits = []
        inChatHits = []
    }

    func runInChat(jid: String, query: String) async {
        let hits = await Task.detached(priority: .userInitiated) { [index] in
            index.searchInChat(jid: jid, query: query)
        }.value
        inChatHits = hits
    }

    private func onQueryChanged() {
        debounceTask?.cancel()
        let q = query
        if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            globalHits = []
            return
        }
        debounceTask = Task { [weak self, debounceMs, index] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self, !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                index.searchGlobal(query: q)
            }.value
            guard !Task.isCancelled else { return }
            self.globalHits = hits
        }
    }
}
