import Foundation
import Observation

@Observable @MainActor
final class ChatSearchViewModel {
    var query: String = "" {
        didSet { onQueryChanged() }
    }
    private(set) var filteredChats: [Chat] = []
    private(set) var suggestion: PhoneSuggestion? = nil
    private(set) var validating: Bool = false

    private weak var listVM: ChatListViewModel?
    private let validator: PhoneValidating
    private var debounceTask: Task<Void, Never>? = nil

    /// Debounce interval before running the filter / firing bridge validation.
    /// Exposed for tests so they don't have to sleep 500ms.
    var debounceMs: Int = 500

    init(listVM: ChatListViewModel, validator: PhoneValidating) {
        self.listVM = listVM
        self.validator = validator
        self.filteredChats = listVM.chats
    }

    func clear() {
        debounceTask?.cancel()
        query = ""
        suggestion = nil
        validating = false
        filteredChats = listVM?.chats ?? []
    }

    private func onQueryChanged() {
        debounceTask?.cancel()
        let q = query
        if q.isEmpty {
            filteredChats = listVM?.chats ?? []
            suggestion = nil
            validating = false
            return
        }
        debounceTask = Task { [weak self, debounceMs] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self, !Task.isCancelled else { return }
            await self.runFilter(q)
        }
    }

    private func runFilter(_ q: String) async {
        // Implemented in Task 6.
        filteredChats = listVM?.chats ?? []
    }
}
