import Foundation
import SwiftData

@Model
final class PersistedMessage {
    @Attribute(.unique) var id: String
    var chatJID: String
    var senderJID: String
    var fromMe: Bool
    var timestamp: Date
    var kind: String
    var text: String?
    var mediaPath: String?
    var mediaCaption: String?
    var mediaFileName: String?
    var mediaRefJSON: String?
    var pollJSON: String?
    // View-once envelope (Sticker / Image / Video).
    var isViewOnce: Bool = false
    var viewOnceLocked: Bool = false
    var viewOnceRevealedAt: Date? = nil
    // Location (live + static). `locationIsLive` flips the kind to
    // "location_live"; `locationSequence` is the live-update sequence
    // emitted by WhatsApp's CDN-less live-location protocol.
    var locationLat: Double? = nil
    var locationLng: Double? = nil
    var locationName: String? = nil
    var locationAddress: String? = nil
    var locationIsLive: Bool = false
    var locationSequence: Int64? = nil
    // Contact card (vCard payload + parsed display name).
    var contactVCard: String? = nil
    var contactDisplayName: String? = nil
    // Delivery state for fromMe messages: "sent" | "delivered" | "read" | "played".
    // Defaulted so existing rows migrate lightweight.
    var deliveryStatus: String = "sent"
    // Push name (the name the sender set on their phone) captured at
    // message receive time. Persisted so cold-start can rebuild the
    // contactNames map without waiting for a live message to re-arrive.
    var senderPushName: String? = nil
    // Quoted-message snapshot (captured at receive time so the strip
    // still renders even if the original row is later deleted).
    var quotedMessageID: String? = nil
    var quotedSenderJID: String? = nil
    var quotedFromMe: Bool = false
    var quotedTextSnippet: String? = nil
    var quotedKind: String? = nil

    // Edit / revoke / local-delete lifecycle.
    var editedAt: Date? = nil
    var revokedAt: Date? = nil
    var revokedBy: String? = nil
    var locallyDeleted: Bool = false

    // App-state bookmarks. Defaulted so existing rows migrate lightweight.
    var starredAt: Date? = nil
    // In-chat pin (WhatsApp's pinInChat protocol). nil = unpinned.
    var pinnedAt: Date? = nil
    // Set when the message carried ContextInfo.IsForwarded (inbound) or we
    // sent it as a forward (outbound). Drives the "Forwarded" tag.
    var isForwarded: Bool = false

    /// Set when one full download + MediaRetry cycle has already failed
    /// with a plaintext-SHA mismatch or unrecoverable 4xx. WhatsApp ages
    /// out old media from its CDN; once we hit this state for a given
    /// message the bytes are gone server-side and no client-side retry
    /// can recover them. We persist the flag so relaunches don't hammer
    /// the server with the same hopeless downloads.
    var mediaExpired: Bool = false

    init(id: String, chatJID: String, senderJID: String, fromMe: Bool,
         timestamp: Date, kind: String, text: String? = nil,
         mediaPath: String? = nil, mediaCaption: String? = nil,
         mediaFileName: String? = nil,
         mediaRefJSON: String? = nil,
         pollJSON: String? = nil,
         isViewOnce: Bool = false,
         viewOnceLocked: Bool = false,
         viewOnceRevealedAt: Date? = nil,
         locationLat: Double? = nil,
         locationLng: Double? = nil,
         locationName: String? = nil,
         locationAddress: String? = nil,
         locationIsLive: Bool = false,
         locationSequence: Int64? = nil,
         contactVCard: String? = nil,
         contactDisplayName: String? = nil,
         deliveryStatus: String = "sent",
         senderPushName: String? = nil,
         quotedMessageID: String? = nil,
         quotedSenderJID: String? = nil,
         quotedFromMe: Bool = false,
         quotedTextSnippet: String? = nil,
         quotedKind: String? = nil,
         editedAt: Date? = nil,
         revokedAt: Date? = nil,
         revokedBy: String? = nil,
         locallyDeleted: Bool = false,
         starredAt: Date? = nil,
         pinnedAt: Date? = nil,
         isForwarded: Bool = false) {
        self.id = id
        self.chatJID = chatJID
        self.senderJID = senderJID
        self.fromMe = fromMe
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.mediaPath = mediaPath
        self.mediaCaption = mediaCaption
        self.mediaFileName = mediaFileName
        self.mediaRefJSON = mediaRefJSON
        self.pollJSON = pollJSON
        self.isViewOnce = isViewOnce
        self.viewOnceLocked = viewOnceLocked
        self.viewOnceRevealedAt = viewOnceRevealedAt
        self.locationLat = locationLat
        self.locationLng = locationLng
        self.locationName = locationName
        self.locationAddress = locationAddress
        self.locationIsLive = locationIsLive
        self.locationSequence = locationSequence
        self.contactVCard = contactVCard
        self.contactDisplayName = contactDisplayName
        self.deliveryStatus = deliveryStatus
        self.senderPushName = senderPushName
        self.quotedMessageID = quotedMessageID
        self.quotedSenderJID = quotedSenderJID
        self.quotedFromMe = quotedFromMe
        self.quotedTextSnippet = quotedTextSnippet
        self.quotedKind = quotedKind
        self.editedAt = editedAt
        self.revokedAt = revokedAt
        self.revokedBy = revokedBy
        self.locallyDeleted = locallyDeleted
        self.starredAt = starredAt
        self.pinnedAt = pinnedAt
        self.isForwarded = isForwarded
    }
}

@Model
final class PersistedReaction {
    /// Composite key as a single string `<messageID>|<senderJID>` so we can
    /// upsert via SwiftData's @Attribute(.unique) without combining two
    /// columns.
    @Attribute(.unique) var compositeKey: String
    var chatJID: String
    var targetMessageID: String
    var senderJID: String
    var emoji: String
    var timestamp: Date

    init(chatJID: String, targetMessageID: String,
         senderJID: String, emoji: String, timestamp: Date) {
        self.compositeKey = "\(targetMessageID)|\(senderJID)"
        self.chatJID = chatJID
        self.targetMessageID = targetMessageID
        self.senderJID = senderJID
        self.emoji = emoji
        self.timestamp = timestamp
    }
}

/// Last known vote from a voter on a specific poll. Composite key
/// `<pollMessageID>|<voterJID>` so a new vote upserts (matches
/// WhatsApp semantics — a voter's latest update replaces priors,
/// for both single- and multi-select polls).
@Model
final class PersistedPollVote {
    @Attribute(.unique) var compositeKey: String
    var chatJID: String
    var pollMessageID: String
    var voterJID: String
    /// JSON array of hex-encoded option hashes (the same hashes
    /// emitted by the bridge from SHA256(optionName)).
    var optionHashesJSON: String
    var timestamp: Date

    init(chatJID: String, pollMessageID: String, voterJID: String,
         optionHashesJSON: String, timestamp: Date) {
        self.compositeKey = "\(pollMessageID)|\(voterJID)"
        self.chatJID = chatJID
        self.pollMessageID = pollMessageID
        self.voterJID = voterJID
        self.optionHashesJSON = optionHashesJSON
        self.timestamp = timestamp
    }
}

@Model
final class PersistedChat {
    @Attribute(.unique) var jid: String
    var name: String
    var lastMessageID: String?
    var lastMessageText: String?
    var lastTimestamp: Date
    var unread: Int
    // Community linkage. Optional / defaulted so existing rows migrate
    // lightweight.
    var communityParentJID: String?
    var isCommunityParent: Bool = false
    var isDefaultSubGroup: Bool = false
    var pinnedAt: Date? = nil
    var archivedAt: Date? = nil
    var mutedUntil: Date? = nil
    var groupDescription: String? = nil
    /// Composer text typed-but-unsent for this chat, persisted so a
    /// restart keeps the draft. Local to this device — WhatsApp drafts
    /// are not synced cross-device.
    var draft: String? = nil

    init(jid: String, name: String,
         lastMessageText: String? = nil,
         lastTimestamp: Date = .distantPast, unread: Int = 0,
         communityParentJID: String? = nil,
         isCommunityParent: Bool = false,
         isDefaultSubGroup: Bool = false,
         pinnedAt: Date? = nil,
         archivedAt: Date? = nil,
         mutedUntil: Date? = nil,
         groupDescription: String? = nil,
         draft: String? = nil) {
        self.jid = jid
        self.name = name
        self.lastMessageText = lastMessageText
        self.lastTimestamp = lastTimestamp
        self.unread = unread
        self.communityParentJID = communityParentJID
        self.isCommunityParent = isCommunityParent
        self.isDefaultSubGroup = isDefaultSubGroup
        self.pinnedAt = pinnedAt
        self.archivedAt = archivedAt
        self.mutedUntil = mutedUntil
        self.groupDescription = groupDescription
        self.draft = draft
    }
}

extension PersistedMessage {
    /// View of the row in the shape `MessageIndex` expects. Empty strings
    /// where the SwiftData column is nil — FTS5 tolerates them.
    var indexFields: MessageIndex.MessageFields {
        MessageIndex.MessageFields(
            messageID: id,
            chatJID:   chatJID,
            timestamp: Int64(timestamp.timeIntervalSinceReferenceDate),
            kind:      kind,
            text:      text ?? "",
            caption:   mediaCaption ?? "",
            quoted:    quotedTextSnippet ?? "",
            sender:    senderPushName ?? "",
            fromMe:    fromMe)
    }
}
