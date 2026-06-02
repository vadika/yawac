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
    /// Runtime-only: server-synced "approve new members" flag. Mirrors
    /// `BridgeGroupModel.joinApprovalMode`. Populated by `mergeGroups`
    /// and live `joinApprovalModeChanged` events. Not persisted — a
    /// fresh ListGroups on connect repopulates it.
    var joinApprovalMode: Bool = false
    /// Runtime-only: whether the paired account is an admin (or super
    /// admin) of this group. Populated by `mergeGroups` against the
    /// `BridgeGroupModel.participants` roster. Not persisted.
    var amAdmin: Bool = false
    var id: String { jid }
}

// JIDNormalize moved to yawac/Utilities/JIDNormalize.swift — keeps Chat.swift
// focused on the `Chat` model.
