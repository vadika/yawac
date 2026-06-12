import Foundation

struct Chat: Identifiable, Hashable {
    let jid: String
    var name: String
    var lastMessage: String
    var lastTimestamp: Int64
    var unread: Int
    var bellEnabled: Bool = true
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
    /// Runtime-only: disappearing-messages timer in seconds (0 = off).
    /// Hydrated from `BridgeGroupModel` on `mergeGroups` and updated by
    /// live `ephemeralTimerChanged` / 1:1 `EphemeralSetting` events.
    /// Not persisted — a fresh ListGroups on connect repopulates it.
    var ephemeralExpirationSeconds: Int32 = 0
    /// Runtime-only: "Only admins can send messages" flag. Mirrors
    /// `BridgeGroupModel.isAnnounce`. Populated by `mergeGroups` and
    /// live admin events. Not persisted — a fresh ListGroups on connect
    /// repopulates it.
    var isAnnounce: Bool = false
    /// Runtime-only: "Only admins can edit group info" flag. Mirrors
    /// `BridgeGroupModel.isLocked`. Populated by `mergeGroups` and live
    /// admin events. Not persisted — a fresh ListGroups on connect
    /// repopulates it.
    var isLocked: Bool = false
    /// Runtime-only: "Any member can add new members" flag (v0.9.8).
    /// Mirrors `BridgeGroupModel.isAllMemberAdd`. Populated by
    /// `mergeGroups` and live `groupMemberAddModeChanged` events.
    /// Not persisted — a fresh ListGroups on connect repopulates it.
    /// `false` (default) means admin_add; `true` means all_member_add.
    var isAllMemberAdd: Bool = false
    var id: String { jid }
}

// JIDNormalize moved to yawac/Utilities/JIDNormalize.swift — keeps Chat.swift
// focused on the `Chat` model.
