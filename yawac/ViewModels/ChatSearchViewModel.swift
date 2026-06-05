import Foundation
import Observation

@Observable @MainActor
final class ChatSearchViewModel {
    var query: String = "" {
        didSet { onQueryChanged() }
    }
    /// Filter knobs for the global ⌘K Messages section.
    /// Mutating any field re-runs the existing debounced search.
    var filters: MessageIndex.SearchFilters = .init() {
        didSet { if oldValue != filters { onFiltersChanged() } }
    }
    /// Optional "scope to this chat" knob, kept separate from
    /// `MessageIndex.SearchFilters` so the chip-strip can render a
    /// nameable picker against the chat list without leaking JID
    /// strings into the SQL filter struct.
    var globalChatFilter: String? = nil {
        didSet { if oldValue != globalChatFilter { onFiltersChanged() } }
    }
    private(set) var filteredChats: [Chat] = []
    private(set) var suggestion: PhoneSuggestion? = nil
    private(set) var validating: Bool = false

    private weak var listVM: ChatListViewModel?
    private let validator: PhoneValidating
    private var debounceTask: Task<Void, Never>? = nil
    private(set) var messageHits: [MessageIndex.Hit] = []
    private let messageIndex: MessageIndex
    private var messageTask: Task<Void, Never>? = nil
    private var inviteLinkTask: Task<Void, Never>? = nil

    /// Debounce interval before running the filter / firing bridge validation.
    /// Exposed for tests so they don't have to sleep 500ms.
    var debounceMs: Int = 500

    init(listVM: ChatListViewModel,
         validator: PhoneValidating,
         messageIndex: MessageIndex = .shared) {
        self.listVM = listVM
        self.validator = validator
        self.messageIndex = messageIndex
        self.filteredChats = listVM.chats
    }

    func clear() {
        debounceTask?.cancel()
        messageTask?.cancel()
        inviteLinkTask?.cancel()
        query = ""
        suggestion = nil
        validating = false
        filteredChats = listVM?.chats ?? []
        messageHits = []
        listVM?.inviteLinkPreview = nil
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
            await self.refreshMessages(q)
            await self.maybeResolveInviteLink(q)
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
        filteredChats = matches(for: q)
    }

    private func refreshMessages(_ q: String) async {
        messageTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFilter = !filters.isEmpty
            || !(globalChatFilter ?? "").isEmpty
        if trimmed.count < 2 && !hasFilter {
            messageHits = []
            return
        }
        let idx = messageIndex
        let f = filters
        let chatFilter = globalChatFilter
        messageTask = Task { [weak self] in
            let hits = await Task.detached(priority: .userInitiated) {
                idx.searchGlobal(query: trimmed, filters: f, chatJID: chatFilter)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.messageHits = hits
        }
        await messageTask?.value
    }

    /// Re-runs the global message search when filters change without
    /// touching the chat-name local filter (those are query-driven).
    /// Single-shot — no debounce, since filter changes are user-driven
    /// taps not key strokes.
    private func onFiltersChanged() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            messageHits = []
            return
        }
        Task { @MainActor [weak self] in
            await self?.refreshMessages(q)
        }
    }

    /// Distinct (senderJID, label) pairs indexed globally. JID stable
    /// across push-name changes; label resolves through
    /// SessionViewModel display names when available, falling back to
    /// the indexed push name otherwise.
    var knownGlobalSenders: [(jid: String, name: String)] {
        return messageIndex.distinctSendersGlobal()
    }

    private func maybeResolveInviteLink(_ q: String) async {
        inviteLinkTask?.cancel()
        let code = InviteLink.parseCode(q)
        guard let code else {
            listVM?.inviteLinkPreview = nil
            return
        }
        // Skip resolution if we're not connected — the bridge call would just
        // throw. Preview clears so the user isn't staring at a stale spinner.
        let listVM = self.listVM
        guard let client = listVM?.clientRef, !client.ownJID.isEmpty else {
            listVM?.inviteLinkPreview = .error(
                message: "Sign in to preview invite links.")
            return
        }
        listVM?.inviteLinkPreview = .loading(code: code)
        inviteLinkTask = Task { @MainActor [weak self] in
            do {
                let info = try client.groupInfoFromLink(code: code)
                guard let _ = self, !Task.isCancelled else { return }
                listVM?.inviteLinkPreview = .ready(info, code: code)
            } catch {
                listVM?.inviteLinkPreview = .error(
                    message: error.localizedDescription)
            }
        }
    }

    /// Re-run the current text filter against the latest `listVM.chats`.
    /// Called when the chat list mutates (e.g. a delete) while a search is
    /// active, so removed chats drop out of the results immediately instead
    /// of lingering until the next query change / reload.
    func refresh() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            filteredChats = listVM?.chats ?? []
            return
        }
        filteredChats = matches(for: query)
    }

    private func matches(for q: String) -> [Chat] {
        let normalized = q.trimmingCharacters(in: .whitespacesAndNewlines)
                           .lowercased()
        let digits = Self.digitsOnly(q)
        let source = listVM?.chats ?? []
        return source.filter { chat in
            if chat.name.localizedCaseInsensitiveContains(normalized) {
                return true
            }
            if !digits.isEmpty, Self.digitsOnly(chat.jid).contains(digits) {
                return true
            }
            return false
        }
    }

    static func digitsOnly(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }
}
