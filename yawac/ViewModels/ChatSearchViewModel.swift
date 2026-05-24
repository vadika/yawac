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
            await self.maybeValidate(q)
        }
    }

    private func maybeValidate(_ q: String) async {
        guard Self.looksLikePhone(q) else {
            suggestion = nil
            return
        }
        let digits = Self.digitsOnly(q)
        // Skip if an existing chat already matches by digits — user
        // already has that conversation.
        if let chats = listVM?.chats,
           chats.contains(where: { Self.digitsOnly($0.jid).contains(digits) }) {
            suggestion = nil
            return
        }
        // Logged out — skip bridge call. Local filter (already run) still works.
        guard !validator.ownJID.isEmpty else {
            suggestion = nil
            return
        }
        validating = true
        let previousSuggestion = suggestion
        suggestion = nil
        let validator = self.validator
        let result: PhoneCheckResult?
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try validator.checkOnWhatsApp(digits)
            }.value
        } catch {
            NSLog("[yawac/search] checkOnWhatsApp failed: %@", String(describing: error))
            if (error as NSError).localizedDescription.contains("rate_limited") {
                // Keep the previous suggestion intact; do not clear.
                suggestion = previousSuggestion
                validating = false
                return
            }
            result = nil
        }
        validating = false
        guard !Task.isCancelled else { return }
        guard let r = result, r.registered else {
            suggestion = nil
            return
        }
        if !validator.ownJID.isEmpty, r.jid == validator.ownJID {
            suggestion = nil
            return
        }
        let bestName: String = {
            if let n = r.businessName, !n.isEmpty { return n }
            if let n = r.fullName, !n.isEmpty { return n }
            if let n = r.pushName, !n.isEmpty { return n }
            return "+" + digits
        }()
        suggestion = PhoneSuggestion(
            jid: r.jid,
            displayPhone: bestName)
    }

    static func looksLikePhone(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let digits = digitsOnly(trimmed)
        let allowed = CharacterSet(charactersIn: "+-() ").union(.decimalDigits)
                                                        .union(.whitespaces)
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return false
        }
        if trimmed.hasPrefix("+") { return digits.count >= 1 }
        return digits.count >= 7
    }

    private func runFilter(_ q: String) async {
        let normalized = q.trimmingCharacters(in: .whitespacesAndNewlines)
                           .lowercased()
        let digits = Self.digitsOnly(q)
        let source = listVM?.chats ?? []
        let matches = source.filter { chat in
            if chat.name.localizedCaseInsensitiveContains(normalized) {
                return true
            }
            if !digits.isEmpty, Self.digitsOnly(chat.jid).contains(digits) {
                return true
            }
            return false
        }
        self.filteredChats = matches
    }

    static func digitsOnly(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }
}
