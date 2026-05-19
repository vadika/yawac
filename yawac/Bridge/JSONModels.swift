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

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case caption
        case filePath = "file_path"
        case width, height, duration
        case sizeBytes = "size_bytes"
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
