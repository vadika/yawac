import Foundation

enum VCardBuilder {

    /// Build a VCARD 3.0 carrying the WhatsApp-specific `waid`
    /// parameter so the recipient sees a tappable "Message on
    /// WhatsApp" button. `jid` is the WhatsApp JID; we use its
    /// phone prefix as the `waid` value.
    static func build(jid: String, name: String, phone: String) -> String {
        let phoneDigits = phone.trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        let waid = String(jid.split(separator: "@").first ?? "")
        return """
        BEGIN:VCARD
        VERSION:3.0
        FN:\(name)
        TEL;type=CELL;waid=\(waid):+\(phoneDigits)
        END:VCARD
        """
    }

    /// Pull the `waid` value from a TEL line in a vCard. Returns
    /// nil when the vCard doesn't carry the parameter.
    static func parseWAID(_ vcard: String) -> String? {
        for line in vcard.split(separator: "\n") {
            guard line.lowercased().hasPrefix("tel") else { continue }
            let parts = line.split(separator: ";")
            for p in parts {
                if let r = p.range(of: "waid=", options: .caseInsensitive) {
                    let after = p[r.upperBound...]
                    let waid = after.split(separator: ":", maxSplits: 1).first ?? Substring()
                    return String(waid)
                }
            }
        }
        return nil
    }
}
