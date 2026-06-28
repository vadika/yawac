import Foundation
import Observation

/// Drives the "send a WhatsApp contact" composer sheet.
///
/// Holds the contact list, the search query, and the set of currently
/// selected JIDs. `buildPayloads()` produces a stable-ordered array of
/// `ContactPayload`s (one per selected contact, in original contacts
/// list order). Each vCard is built via `VCardBuilder.build` so the
/// recipient sees a tappable "Message on WhatsApp" button per card.
@MainActor
@Observable
final class ContactPickerSheetModel {
    let contacts: [BridgeContact]
    var query: String = ""
    var selectedJIDs: Set<String> = []

    init(contacts: [BridgeContact]) {
        self.contacts = contacts
    }

    var canSend: Bool { !selectedJIDs.isEmpty }

    var filtered: [BridgeContact] {
        guard !query.isEmpty else { return contacts }
        let q = query.lowercased()
        return contacts.filter { c in
            c.name.lowercased().contains(q)
                || (c.fullName ?? "").lowercased().contains(q)
        }
    }

    func toggle(_ jid: String) {
        if selectedJIDs.contains(jid) {
            selectedJIDs.remove(jid)
        } else {
            selectedJIDs.insert(jid)
        }
    }

    func isSelected(_ jid: String) -> Bool {
        selectedJIDs.contains(jid)
    }

    /// Build payloads in the original contacts list order (NOT
    /// selection order) so the resulting bubble reads predictably and
    /// the composer chip strip stays stable across re-selections.
    func buildPayloads() -> [ContactPayload] {
        contacts.compactMap { c -> ContactPayload? in
            guard selectedJIDs.contains(c.jid) else { return nil }
            let phoneDigits = String(c.jid.split(separator: "@").first ?? "")
            let phone = "+" + phoneDigits
            return ContactPayload(
                jid: c.jid,
                displayName: c.name,
                phone: phone)
        }
    }
}
