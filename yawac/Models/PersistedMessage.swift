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
    var mediaRefJSON: String?

    init(id: String, chatJID: String, senderJID: String, fromMe: Bool,
         timestamp: Date, kind: String, text: String? = nil,
         mediaPath: String? = nil, mediaCaption: String? = nil,
         mediaRefJSON: String? = nil) {
        self.id = id
        self.chatJID = chatJID
        self.senderJID = senderJID
        self.fromMe = fromMe
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.mediaPath = mediaPath
        self.mediaCaption = mediaCaption
        self.mediaRefJSON = mediaRefJSON
    }
}

@Model
final class PersistedChat {
    @Attribute(.unique) var jid: String
    var name: String
    var lastMessageID: String?
    var lastTimestamp: Date
    var unread: Int

    init(jid: String, name: String,
         lastTimestamp: Date = .distantPast, unread: Int = 0) {
        self.jid = jid
        self.name = name
        self.lastTimestamp = lastTimestamp
        self.unread = unread
    }
}
