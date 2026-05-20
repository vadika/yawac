import Foundation

struct Chat: Identifiable, Hashable {
    let jid: String
    var name: String
    var lastMessage: String
    var lastTimestamp: Int64
    var unread: Int
    var isGroup: Bool { jid.hasSuffix("@g.us") }
    var id: String { jid }
}

/// JID normalization — collapses device-suffixed variants
/// (`<user>:<device>@<server>`) to bare `<user>@<server>` so the chat list
/// doesn't show one row per device the contact uses.
///
/// Note: this does NOT bridge between `@s.whatsapp.net` and `@lid` for the
/// same physical person. WhatsApp's privacy-LID feature can surface the same
/// user under both namespaces in different message paths; resolving the
/// mapping requires server-side lookups we don't perform.
enum JIDNormalize {
    static func bare(_ jid: String) -> String {
        guard let at = jid.firstIndex(of: "@") else { return jid }
        let user = jid[..<at]
        let server = jid[at...]
        if let colon = user.firstIndex(of: ":") {
            return String(user[..<colon]) + String(server)
        }
        return jid
    }
}
