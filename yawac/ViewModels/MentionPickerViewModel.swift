import Foundation
import Observation

/// Composer-side picker state for @-mention autocomplete. Owns the
/// candidate list, the substring being typed after `@`, and the keyboard
/// selection cursor. Composer reacts by reading `isActive` / `filtered`
/// and calling `commitSelected()` / `cancel()` from keypress handlers.
@Observable @MainActor
final class MentionPickerViewModel {

    /// Sentinel JID for the synthetic `@everyone` row — `*` makes it
    /// impossible to confuse with a real WhatsApp JID. Consumers use
    /// this to detect "expand to all participants" at send time.
    static let everyoneSentinelJID = "*all*"

    enum Candidate: Equatable {
        case everyone
        case participant(jid: String, displayName: String)

        var jid: String {
            switch self {
            case .everyone: return MentionPickerViewModel.everyoneSentinelJID
            case .participant(let jid, _): return jid
            }
        }

        /// User-facing label inserted into the composer body (without
        /// the leading `@`). For `everyone` this is literally "everyone".
        var label: String {
            switch self {
            case .everyone: return "everyone"
            case .participant(_, let n): return n
            }
        }
    }

    private(set) var candidates: [Candidate] = []
    private(set) var filtered: [Candidate] = []
    private(set) var selectedIdx: Int = 0
    private(set) var triggerRange: Range<String.Index>?
    private(set) var isActive: Bool = false
    private var includeEveryone: Bool = false

    func setCandidates(_ items: [Candidate], includeEveryone: Bool) {
        self.includeEveryone = includeEveryone
        let sorted = items.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        self.candidates = (includeEveryone ? [.everyone] : []) + sorted
    }

    /// Update picker state from the composer's current text. Cursor is
    /// assumed at `text.endIndex` (TextField doesn't expose live cursor
    /// position on macOS without subclassing NSTextView).
    func update(text: String) {
        var atIdx: String.Index? = nil
        var i = text.endIndex
        while i > text.startIndex {
            let prev = text.index(before: i)
            let c = text[prev]
            if c == "@" {
                let okLeft = (prev == text.startIndex)
                    || text[text.index(before: prev)].isWhitespace
                if okLeft { atIdx = prev }
                break
            }
            if c.isWhitespace {
                break
            }
            i = prev
        }
        guard let at = atIdx else {
            cancel()
            return
        }
        let afterAt = text.index(after: at)
        if let _ = text[afterAt..<text.endIndex].firstIndex(where: { $0.isWhitespace }) {
            cancel()
            return
        }
        let query = String(text[afterAt..<text.endIndex])
        triggerRange = at..<text.endIndex
        isActive = true
        applyFilter(query: query)
    }

    private func applyFilter(query: String) {
        let q = query.lowercased()
        let digits = q.filter(\.isNumber)
        filtered = candidates.filter { c in
            switch c {
            case .everyone:
                if q.isEmpty { return true }
                // Match only the literal keywords so a single-letter prefix
                // like "a" doesn't shove `everyone` ahead of real names.
                return q == "all" || q == "every" || q == "everyone"
            case .participant(let jid, let name):
                if q.isEmpty { return true }
                if name.localizedCaseInsensitiveContains(query) { return true }
                if !digits.isEmpty, jid.filter(\.isNumber).contains(digits) { return true }
                return false
            }
        }
        selectedIdx = 0
    }

    func move(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let n = filtered.count
        selectedIdx = ((selectedIdx + delta) % n + n) % n
    }

    /// Returns the candidate at `selectedIdx` and closes the picker.
    /// `nil` when filtered is empty.
    func commitSelected() -> Candidate? {
        guard !filtered.isEmpty,
              filtered.indices.contains(selectedIdx) else {
            cancel()
            return nil
        }
        let pick = filtered[selectedIdx]
        cancel()
        return pick
    }

    func cancel() {
        isActive = false
        triggerRange = nil
        filtered = []
        selectedIdx = 0
    }
}
