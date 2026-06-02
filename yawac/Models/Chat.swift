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
    var groupDescription: String? = nil
    var id: String { jid }
}

// JIDNormalize moved to yawac/Utilities/JIDNormalize.swift — keeps Chat.swift
// focused on the `Chat` model.
