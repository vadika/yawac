import Foundation

struct Chat: Identifiable, Hashable {
    let jid: String
    var name: String
    var lastMessage: String
    var lastTimestamp: Int64
    var unread: Int
    var isGroup: Bool { jid.hasSuffix("@g.us") }
    // Community linkage (zero/empty for normal chats):
    var isCommunityParent: Bool = false
    var communityParentJID: String? = nil
    var isDefaultSubGroup: Bool = false
    /// Server-synced pin (WhatsApp app-state). nil = unpinned.
    var pinnedAt: Date? = nil
    /// Server-synced archive (WhatsApp app-state). nil = not archived.
    var archivedAt: Date? = nil
    var mutedUntil: Date? = nil
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
    /// Strips a `:<device>` suffix from the user portion of a JID.
    static func bare(_ jid: String) -> String {
        guard let at = jid.firstIndex(of: "@") else { return jid }
        let user = jid[..<at]
        let server = jid[at...]
        if let colon = user.firstIndex(of: ":") {
            return String(user[..<colon]) + String(server)
        }
        return jid
    }

    /// Returns the canonical chat JID: bare + (if `@lid`) resolved to the
    /// PN form via the WAClient's local LID map. Falls back to `bare(jid)`
    /// when no PN mapping is known.
    static func canonical(_ jid: String, client: WAClient?) -> String {
        let stripped = bare(jid)
        guard stripped.hasSuffix("@lid"), let client else { return stripped }
        let resolved = client.resolveLIDToPN(stripped)
        return resolved == stripped ? stripped : bare(resolved)
    }
}
