import Foundation
import Observation

/// Drives the "send a WhatsApp contact" composer sheet.
///
/// Holds the contact list, the search query, and the currently
/// selected JID. `buildPayload()` produces a `ContactPayload` whose
/// vCard is built via `VCardBuilder.build`, carrying the `waid`
/// parameter so the recipient sees a tappable "Message on WhatsApp"
/// button.
@MainActor
@Observable
final class ContactPickerSheetModel {
    let contacts: [BridgeContact]
    var query: String = ""
    var selectedJID: String?

    init(contacts: [BridgeContact]) {
        self.contacts = contacts
    }

    var canSend: Bool { selectedJID != nil }

    var filtered: [BridgeContact] {
        guard !query.isEmpty else { return contacts }
        let q = query.lowercased()
        return contacts.filter { c in
            c.name.lowercased().contains(q)
                || (c.fullName ?? "").lowercased().contains(q)
        }
    }

    func buildPayload() -> ContactPayload? {
        guard let jid = selectedJID,
              let contact = contacts.first(where: { $0.jid == jid }) else {
            return nil
        }
        let phoneDigits = String(jid.split(separator: "@").first ?? "")
        let phone = "+" + phoneDigits
        return ContactPayload(
            jid: jid,
            displayName: contact.name,
            phone: phone,
            vcard: VCardBuilder.build(
                jid: jid,
                name: contact.name,
                phone: phone))
    }
}
