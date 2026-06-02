import Foundation
import Observation

@Observable @MainActor
final class AddParticipantsPanelModel {
    private(set) var chips: [BridgeContact] = []
    var query: String = "" {
        didSet { onQueryChanged() }
    }
    private(set) var suggestions: [BridgeContact] = []
    private(set) var phoneCandidate: PhoneCheckResult? = nil
    private(set) var validating: Bool = false
    var inFlight: Bool = false
    private(set) var result: AddResult? = nil

    /// Exposed for tests so they don't have to sleep the production
    /// debounce window.
    var debounceMs: Int = 250

    struct AddResult: Equatable {
        struct Row: Equatable {
            enum Kind: Equatable { case ok, pending(inviteCode: String), failed(code: Int) }
            let jid: String
            let displayName: String
            let kind: Kind
        }
        let rows: [Row]
    }

    private let existingParticipantJIDs: Set<String>
    private let allContacts: [BridgeContact]
    private let validator: PhoneValidating
    private var debounceTask: Task<Void, Never>? = nil

    init(existingParticipantJIDs: Set<String>,
         allContacts: [BridgeContact],
         validator: PhoneValidating) {
        self.existingParticipantJIDs = existingParticipantJIDs
        self.allContacts = allContacts
        self.validator = validator
        refreshSuggestions()
    }

    func addChip(_ c: BridgeContact) {
        guard !chips.contains(where: { $0.jid == c.jid }) else { return }
        chips.append(c)
        refreshSuggestions()
    }

    func removeChip(_ jid: String) {
        chips.removeAll { $0.jid == jid }
        refreshSuggestions()
    }

    func addPhoneCandidate() {
        guard let r = phoneCandidate else { return }
        let displayName: String = {
            if let n = r.businessName, !n.isEmpty { return n }
            if let n = r.fullName, !n.isEmpty { return n }
            if let n = r.pushName, !n.isEmpty { return n }
            return r.jid
        }()
        addChip(BridgeContact(jid: r.jid, name: displayName,
                              pushName: r.pushName, fullName: r.fullName,
                              businessName: r.businessName))
        query = ""
        phoneCandidate = nil
    }

    /// Apply the bridge response: drop chips for successful rows, keep
    /// the originally-attempted ones for failures, and surface a result
    /// strip with one row per attempt.
    func applyResult(_ response: [BridgeParticipantModel]) {
        var rows: [AddResult.Row] = []
        var successJIDs = Set<String>()
        for r in response {
            let name = chips.first(where: { $0.jid == r.jid })?.name ?? r.jid
            if let code = r.errorCode, code != 0 {
                if let invite = r.inviteCode, !invite.isEmpty {
                    rows.append(.init(jid: r.jid, displayName: name,
                                      kind: .pending(inviteCode: invite)))
                } else {
                    rows.append(.init(jid: r.jid, displayName: name,
                                      kind: .failed(code: code)))
                }
            } else {
                rows.append(.init(jid: r.jid, displayName: name, kind: .ok))
                successJIDs.insert(r.jid)
            }
        }
        chips.removeAll { successJIDs.contains($0.jid) }
        result = AddResult(rows: rows)
    }

    func dismissResult() { result = nil }

    private func onQueryChanged() {
        debounceTask?.cancel()
        refreshSuggestions()
        let q = query
        let looksLikePhone = Self.looksLikePhone(q)
        if !looksLikePhone {
            phoneCandidate = nil
            validating = false
            return
        }
        debounceTask = Task { @MainActor [weak self, debounceMs] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self, !Task.isCancelled else { return }
            self.runValidation(q)
        }
    }

    private func runValidation(_ q: String) {
        guard !validator.ownJID.isEmpty else { phoneCandidate = nil; return }
        let digits = Self.digitsOnly(q)
        guard !digits.isEmpty else { phoneCandidate = nil; return }
        validating = true
        // WAClient.checkOnWhatsApp is nonisolated (Go bridge call) — safe to
        // call from the main actor. Calling it as a local capture of the
        // validator avoids any actor-hop back through the @MainActor WAClient
        // if this is ever refactored to run off-main.
        let v = self.validator
        defer { validating = false }
        do {
            let r = try v.checkOnWhatsApp(digits)
            guard r.registered else { phoneCandidate = nil; return }
            phoneCandidate = r
        } catch {
            phoneCandidate = nil
        }
    }

    private func refreshSuggestions() {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
                              .lowercased()
        let chipJIDs = Set(chips.map(\.jid))
        suggestions = allContacts.filter { c in
            if existingParticipantJIDs.contains(c.jid) { return false }
            if chipJIDs.contains(c.jid) { return false }
            if normalized.isEmpty { return true }
            return c.name.localizedCaseInsensitiveContains(normalized)
                || c.fullName?.localizedCaseInsensitiveContains(normalized) == true
        }
    }

    static func looksLikePhone(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let digits = digitsOnly(trimmed)
        let allowed = CharacterSet(charactersIn: "+-() ")
                       .union(.decimalDigits).union(.whitespaces)
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return false
        }
        return trimmed.hasPrefix("+") ? digits.count >= 6 : digits.count >= 7
    }

    static func digitsOnly(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }
}
