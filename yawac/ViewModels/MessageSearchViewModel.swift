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
    var filters: MessageIndex.SearchFilters = .init() {
        didSet { if oldValue != filters { onQueryChanged() } }
    }
    var chatScope: String? = nil {
        didSet { if oldValue != chatScope { onQueryChanged() } }
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

    func runInChat(jid: String, query: String,
                   filters: MessageIndex.SearchFilters = .init()) async {
        let hits = await Task.detached(priority: .userInitiated) { [index] in
            index.searchInChat(jid: jid, query: query, filters: filters)
        }.value
        inChatHits = hits
    }

    private func onQueryChanged() {
        debounceTask?.cancel()
        let q = query
        let qEmpty = q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let scopeEmpty = (chatScope ?? "").isEmpty
        if qEmpty && filters.isEmpty && scopeEmpty {
            globalHits = []
            return
        }
        let f = filters
        let scope = chatScope
        debounceTask = Task { [weak self, debounceMs, index] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self, !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                index.searchGlobal(query: q, filters: f, chatJID: scope)
            }.value
            guard !Task.isCancelled else { return }
            self.globalHits = hits
        }
    }
}
