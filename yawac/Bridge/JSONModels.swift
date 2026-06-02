import Foundation

struct BridgeMessage: Codable, Identifiable {
    let id: String
    let chatJID: String
    let senderJID: String
    let senderPushName: String?
    let fromMe: Bool
    let timestamp: Int64
    let kind: String
    let text: String?
    let media: BridgeMedia?
    let poll: BridgePoll?
    let quoted: Quoted?
    let isForwarded: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case chatJID = "chat_jid"
        case senderJID = "sender_jid"
        case senderPushName = "sender_push_name"
        case fromMe = "from_me"
        case timestamp, kind, text, media, poll, quoted
        case isForwarded = "is_forwarded"
    }

    struct Quoted: Codable, Hashable, Equatable {
        let messageID: String
        let senderJID: String
        let fromMe: Bool
        let kind: String
        let snippet: String

        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case senderJID = "sender_jid"
            case fromMe = "from_me"
            case kind, snippet
        }
    }
}

struct BridgePoll: Codable, Hashable {
    let question: String
    let options: [BridgePollOption]
    let selectableCount: Int

    enum CodingKeys: String, CodingKey {
        case question, options
        case selectableCount = "selectable_count"
    }
}

struct BridgePollOption: Codable, Hashable {
    let name: String
    let hash: String
}

extension BridgePoll {
    var json: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct BridgeMedia: Codable {
    let mimeType: String
    let caption: String?
    let fileName: String?
    let filePath: String?
    let width: Int?
    let height: Int?
    let duration: Int?
    let sizeBytes: Int64?
    let ref: BridgeMediaRef?

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case caption
        case fileName = "file_name"
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

struct BridgeSendPollResult: Codable {
    let messageID: String
    let timestamp: Int64
    let poll: BridgePoll

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case timestamp, poll
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
    let isParent: Bool
    let linkedParentJID: String?
    let isDefaultSubGroup: Bool
    // `var` (not `let`) so admin UIs can optimistically flip the flag
    // without re-building the whole struct. The decoder still treats
    // missing/false payloads as `false`.
    var joinApprovalMode: Bool

    enum CodingKeys: String, CodingKey {
        case jid, name, topic
        case ownerJID = "owner_jid"
        case created, participants
        case isParent = "is_parent"
        case linkedParentJID = "linked_parent_jid"
        case isDefaultSubGroup = "is_default_sub_group"
        case joinApprovalMode = "join_approval_mode"
    }

    init(jid: String, name: String, topic: String, ownerJID: String,
         created: Int64, participants: [BridgeParticipantModel],
         isParent: Bool = false, linkedParentJID: String? = nil,
         isDefaultSubGroup: Bool = false,
         joinApprovalMode: Bool = false) {
        self.jid = jid
        self.name = name
        self.topic = topic
        self.ownerJID = ownerJID
        self.created = created
        self.participants = participants
        self.isParent = isParent
        self.linkedParentJID = linkedParentJID
        self.isDefaultSubGroup = isDefaultSubGroup
        self.joinApprovalMode = joinApprovalMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jid = try c.decode(String.self, forKey: .jid)
        name = try c.decode(String.self, forKey: .name)
        topic = try c.decode(String.self, forKey: .topic)
        ownerJID = try c.decode(String.self, forKey: .ownerJID)
        created = try c.decode(Int64.self, forKey: .created)
        participants = try c.decode([BridgeParticipantModel].self, forKey: .participants)
        isParent = try c.decodeIfPresent(Bool.self, forKey: .isParent) ?? false
        let linked = try c.decodeIfPresent(String.self, forKey: .linkedParentJID)
        // Treat empty strings or non-`@g.us` zero JIDs as no parent.
        if let l = linked, !l.isEmpty, l.hasSuffix("@g.us") {
            linkedParentJID = l
        } else {
            linkedParentJID = nil
        }
        isDefaultSubGroup = try c.decodeIfPresent(Bool.self, forKey: .isDefaultSubGroup) ?? false
        joinApprovalMode = try c.decodeIfPresent(Bool.self, forKey: .joinApprovalMode) ?? false
    }
}

struct BridgeParticipantModel: Codable {
    let jid: String
    let isAdmin: Bool
    let isSuper: Bool
    let errorCode: Int?
    let inviteCode: String?
    let inviteExpiry: Int64?

    enum CodingKeys: String, CodingKey {
        case jid
        case isAdmin = "is_admin"
        case isSuper = "is_super_admin"
        case errorCode = "error_code"
        case inviteCode = "invite_code"
        case inviteExpiry = "invite_expiry"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jid = try c.decode(String.self, forKey: .jid)
        isAdmin = try c.decode(Bool.self, forKey: .isAdmin)
        isSuper = try c.decode(Bool.self, forKey: .isSuper)
        errorCode = try c.decodeIfPresent(Int.self, forKey: .errorCode)
        inviteCode = try c.decodeIfPresent(String.self, forKey: .inviteCode)
        inviteExpiry = try c.decodeIfPresent(Int64.self, forKey: .inviteExpiry)
    }

    init(jid: String, isAdmin: Bool, isSuper: Bool,
         errorCode: Int? = nil, inviteCode: String? = nil,
         inviteExpiry: Int64? = nil) {
        self.jid = jid
        self.isAdmin = isAdmin
        self.isSuper = isSuper
        self.errorCode = errorCode
        self.inviteCode = inviteCode
        self.inviteExpiry = inviteExpiry
    }
}

/// Lightweight community sub-group entry — name + JID + default flag.
/// Used by the ChatInfoView parent inspector to render every group
/// linked under a community, joined or not.
struct BridgeSubGroup: Codable {
    let jid: String
    let name: String
    let isDefaultSubGroup: Bool
    enum CodingKeys: String, CodingKey {
        case jid, name
        case isDefaultSubGroup = "is_default_sub_group"
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

struct BridgeUserInfo: Codable {
    let jid: String
    let status: String?
}

struct BridgeJoinRequest: Decodable, Hashable {
    let jid: String
    let requestedAt: Int64

    enum CodingKeys: String, CodingKey {
        case jid
        case requestedAt = "requested_at"
    }
}

struct BridgeJoinRequestResult: Decodable, Hashable {
    let jid: String
    let errorCode: Int?

    enum CodingKeys: String, CodingKey {
        case jid
        case errorCode = "error_code"
    }
}
