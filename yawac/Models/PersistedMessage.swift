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

    init(id: String, chatJID: String, senderJID: String, fromMe: Bool,
         timestamp: Date, kind: String, text: String? = nil,
         mediaPath: String? = nil, mediaCaption: String? = nil,
         mediaFileName: String? = nil,
         mediaRefJSON: String? = nil,
         pollJSON: String? = nil) {
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

@Model
final class PersistedChat {
    @Attribute(.unique) var jid: String
    var name: String
    var lastMessageID: String?
    var lastMessageText: String?
    var lastTimestamp: Date
    var unread: Int

    init(jid: String, name: String,
         lastMessageText: String? = nil,
         lastTimestamp: Date = .distantPast, unread: Int = 0) {
        self.jid = jid
        self.name = name
        self.lastMessageText = lastMessageText
        self.lastTimestamp = lastTimestamp
        self.unread = unread
    }
}
