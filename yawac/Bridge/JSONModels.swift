import Foundation

struct BridgeMessage: Codable, Identifiable {
    let id: String
    let chatJID: String
    let senderJID: String
    let fromMe: Bool
    let timestamp: Int64
    let kind: String
    let text: String?
    let media: BridgeMedia?
    let quotedID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case chatJID = "chat_jid"
        case senderJID = "sender_jid"
        case fromMe = "from_me"
        case timestamp, kind, text, media
        case quotedID = "quoted_id"
    }
}

struct BridgeMedia: Codable {
    let mimeType: String
    let caption: String?
    let filePath: String?
    let width: Int?
    let height: Int?
    let duration: Int?
    let sizeBytes: Int64?
    let ref: BridgeMediaRef?

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case caption
        case filePath = "file_path"
        case width, height, duration
        case sizeBytes = "size_bytes"
        case ref
    }
}

struct BridgeMediaRef: Codable {
    let kind: String
    let url: String
    let directPath: String
    let mediaKey: Data
    let fileEncSHA256: Data
    let fileSHA256: Data
    let fileLength: UInt64
    let mimetype: String

    enum CodingKeys: String, CodingKey {
        case kind, url
        case directPath = "direct_path"
        case mediaKey = "media_key"
        case fileEncSHA256 = "file_enc_sha256"
        case fileSHA256 = "file_sha256"
        case fileLength = "file_length"
        case mimetype
    }
}

extension BridgeMediaRef {
    var json: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct BridgeReceipt: Codable {
    let chatJID: String
    let senderJID: String
    let messageIDs: [String]
    let status: String
    let timestamp: Int64

    enum CodingKeys: String, CodingKey {
        case chatJID = "chat_jid"
        case senderJID = "sender_jid"
        case messageIDs = "message_ids"
        case status, timestamp
    }
}

struct BridgeQR: Codable { let code: String }

struct BridgeSendResult: Codable {
    let messageID: String
    let timestamp: Int64
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case timestamp
    }
}

struct BridgeGroupModel: Codable, Identifiable {
    var id: String { jid }
    let jid: String
    let name: String
    let topic: String
    let ownerJID: String
    let created: Int64
    let participants: [BridgeParticipantModel]
    enum CodingKeys: String, CodingKey {
        case jid, name, topic
        case ownerJID = "owner_jid"
        case created, participants
    }
}

struct BridgeParticipantModel: Codable {
    let jid: String
    let isAdmin: Bool
    let isSuper: Bool
    enum CodingKeys: String, CodingKey {
        case jid
        case isAdmin = "is_admin"
        case isSuper = "is_super_admin"
    }
}

struct BridgeReaction: Codable {
    let chatJID: String
    let targetMessageID: String
    let targetFromMe: Bool
    let senderJID: String
    let emoji: String
    let timestamp: Int64

    enum CodingKeys: String, CodingKey {
        case chatJID = "chat_jid"
        case targetMessageID = "target_message_id"
        case targetFromMe = "target_from_me"
        case senderJID = "sender_jid"
        case emoji, timestamp
    }
}

struct BridgeContact: Codable, Identifiable {
    var id: String { jid }
    let jid: String
    let name: String
    let pushName: String?
    let fullName: String?
    let businessName: String?

    enum CodingKeys: String, CodingKey {
        case jid, name
        case pushName = "push_name"
        case fullName = "full_name"
        case businessName = "business_name"
    }
}
