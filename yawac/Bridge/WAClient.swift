import Foundation
import Bridge

struct PhoneCheckResult: Decodable, Equatable {
    let jid: String
    let registered: Bool
    let businessName: String?
    let pushName: String?
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case jid, registered
        case businessName = "business_name"
        case pushName = "push_name"
        case fullName = "full_name"
    }
}

protocol PhoneValidating: AnyObject {
    var ownJID: String { get }
    /// Synchronous — call from off-main via `Task.detached`.
    func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult
}

@MainActor
final class WAClient: PhoneValidating {
    enum Event {
        case qr(String)
        case pairSuccess
        case connected
        case disconnected
        case loggedOut(reason: String)
        case message(BridgeMessage)
        case receipt(BridgeReceipt)
        case reaction(BridgeReaction)
        case pollVote(chatJID: String, pollMessageID: String, voterJID: String, optionHashes: [String])
        case presence(jid: String, online: Bool, lastSeen: Int64)
        case chatPresence(chat: String, sender: String, typing: Bool)
        case historySync(conversations: Int)
        case mediaRetry(messageID: String, ok: Bool, newDirectPath: String?, error: String?)
        case messageEdited(chatJID: String, messageID: String, newText: String, timestamp: Int64)
        case messageRevoked(chatJID: String, messageID: String, revokedBy: String, timestamp: Int64)
        case messageLocallyDeleted(chatJID: String, messageID: String, timestamp: Int64)
        case messageStarred(chatJID: String, messageID: String, senderJID: String, fromMe: Bool, starred: Bool, timestamp: Int64)
        case chatPinned(chatJID: String, pinned: Bool, timestamp: Int64)
        case messagePinned(chatJID: String, targetMessageID: String, senderJID: String, pinned: Bool, timestamp: Int64)
        case unknown(kind: String, payload: String)
    }

    enum WAError: Error {
        case bridgeFailure(String)
    }

    // gomobile-generated BridgeClient is thread-safe (the Go side serializes
    // calls internally). Marking nonisolated(unsafe) so blocking I/O (media
    // downloads, profile picture fetches) can run off MainActor without
    // pinning the UI.
    nonisolated(unsafe) private let go: BridgeClient
    private let bus = WAEventBus()
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var pump: Task<Void, Never>?

    init(dbPath: String) throws {
        var err: NSError?
        guard let client = BridgeNewClient(dbPath, &err) else {
            throw err ?? NSError(domain: "yawac", code: -1)
        }
        self.go = client
        client.setEventSink(bus)
        startPump()
    }

    func eventStream() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            self.subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.subscribers.removeValue(forKey: id)
                }
            }
        }
    }

    deinit {
        // Cannot touch @MainActor-isolated state from deinit. Close the Go
        // client directly; the pump task will end when the event stream
        // closes (or when the process exits).
        go.close()
    }

    var isLoggedIn: Bool { go.isLoggedIn() }
    /// Bare JID of the paired account, empty when not paired.
    var ownJID: String { go.ownJID() }

    func connect() throws { try go.connect() }
    func logout() throws { try go.logout() }

    func sendText(_ chatJID: String, _ body: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendText(chatJID, body: body, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendImage(_ chatJID: String, path: String, caption: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendImage(chatJID, filePath: path, caption: caption, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendVideo(_ chatJID: String, path: String, caption: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendVideo(chatJID, filePath: path, caption: caption, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendAudio(_ chatJID: String, path: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendAudio(chatJID, filePath: path, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendVoiceNote(_ chatJID: String,
                       path: String,
                       duration: Int32,
                       waveform: Data) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendVoiceNote(chatJID,
                                    filePath: path,
                                    durationSec: duration,
                                    waveformB64: waveform.base64EncodedString(),
                                    error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendDocument(_ chatJID: String, path: String, caption: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendDocument(chatJID, filePath: path, caption: caption, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendReaction(chatJID: String,
                      targetMsgID: String,
                      targetSenderJID: String,
                      targetFromMe: Bool,
                      emoji: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendReaction(
            chatJID,
            targetMsgID: targetMsgID,
            targetSenderJID: targetSenderJID,
            targetFromMe: targetFromMe,
            emoji: emoji,
            error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendTextReply(_ chatJID: String, _ body: String,
                       quotedID: String, quotedSenderJID: String,
                       quotedFromMe: Bool, quotedKind: String,
                       quotedSnippet: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendTextReply(
            chatJID, body: body,
            quotedID: quotedID, quotedSenderJID: quotedSenderJID,
            quotedFromMe: quotedFromMe, quotedKind: quotedKind,
            quotedSnippet: quotedSnippet, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func editText(_ chatJID: String, _ msgID: String, _ newBody: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.editText(chatJID, msgID: msgID, newBody: newBody, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func revokeMessage(_ chatJID: String, _ msgID: String,
                       _ targetSenderJID: String, _ targetFromMe: Bool) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.revokeMessage(chatJID, msgID: msgID,
                                    targetSenderJID: targetSenderJID,
                                    targetFromMe: targetFromMe, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func starMessage(chatJID: String,
                     targetMsgID: String,
                     targetSenderJID: String,
                     targetFromMe: Bool,
                     starred: Bool) throws {
        try go.starMessage(chatJID,
                           targetMsgID: targetMsgID,
                           targetSenderJID: targetSenderJID,
                           targetFromMe: targetFromMe,
                           starred: starred)
    }

    func pinChat(chatJID: String, pinned: Bool) throws {
        try go.pinChat(chatJID, pinned: pinned)
    }

    func pinMessageInChat(chatJID: String,
                          targetMsgID: String,
                          targetSenderJID: String,
                          targetFromMe: Bool,
                          pinned: Bool) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.pinMessage(inChat: chatJID,
                                 targetMsgID: targetMsgID,
                                 targetSenderJID: targetSenderJID,
                                 targetFromMe: targetFromMe,
                                 pin: pinned,
                                 error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    /// Returns the subset of `jids` that whatsmeow's local appstate
    /// store currently marks as pinned. Used to reconcile the sidebar
    /// at startup since events.Pin isn't re-emitted on reconnect.
    func listPinnedChats(jids: [String]) throws -> [String] {
        let jidsJSON = (try? JSONEncoder().encode(jids))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var err: NSError?
        let json = go.listPinnedChats(jidsJSON, error: &err)
        if let err { throw err }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    func sendPollVote(chatJID: String,
                      pollMsgID: String,
                      pollSenderJID: String,
                      pollFromMe: Bool,
                      optionHashes: [String],
                      pollOptions: [BridgePollOption]) throws -> BridgeSendResult {
        let hashesJSON = (try? JSONEncoder().encode(optionHashes))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let optionsJSON = (try? JSONEncoder().encode(pollOptions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var err: NSError?
        let json = go.sendPollVote(
            chatJID,
            pollMsgID: pollMsgID,
            pollSenderJID: pollSenderJID,
            pollFromMe: pollFromMe,
            selectedHashesJSON: hashesJSON,
            pollOptionsJSON: optionsJSON,
            error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    nonisolated func downloadMedia(_ refJSON: String, to outPath: String) throws -> String {
        var err: NSError?
        let out = go.downloadMedia(refJSON, outPath: outPath, error: &err)
        if let err { throw err }
        return out
    }

    /// Last-resort download that bypasses whatsmeow's hash + HMAC checks.
    /// Use only when the strict download fails with integrity errors and the
    /// user has opted in.
    nonisolated func downloadMediaForce(_ refJSON: String, to outPath: String) throws -> String {
        var err: NSError?
        let out = go.downloadMediaForce(refJSON, outPath: outPath, error: &err)
        if let err { throw err }
        return out
    }

    nonisolated func requestMediaRetry(chatJID: String, senderJID: String, msgID: String, fromMe: Bool, refJSON: String) throws {
        try go.requestMediaRetry(chatJID, senderJID: senderJID, msgID: msgID, fromMe: fromMe, refJSON: refJSON)
    }

    /// Resolves an `@lid` JID to its bare `@s.whatsapp.net` form via
    /// whatsmeow's local LID map. Returns the input unchanged when no
    /// mapping is known (mapping is learned from group/sender events).
    nonisolated func resolveLIDToPN(_ jid: String) -> String {
        var err: NSError?
        let result = go.resolveLID(toPN: jid, error: &err)
        if err != nil || result.isEmpty { return jid }
        return result
    }

    nonisolated func requestOlderHistory(chatJID: String,
                                         oldestMsgID: String,
                                         oldestSenderJID: String,
                                         oldestFromMe: Bool,
                                         oldestTimestampSec: Int64,
                                         count: Int) throws {
        try go.requestOlderHistory(
            chatJID,
            oldestMsgID: oldestMsgID,
            oldestSenderJID: oldestSenderJID,
            oldestFromMe: oldestFromMe,
            oldestTimestampSec: oldestTimestampSec,
            count: count)
    }

    /// Sends a `read` receipt for `messageIDs`. `senderJID` is the bare
    /// JID of the message author (chat peer for 1:1, participant for groups).
    nonisolated func markRead(chatJID: String, senderJID: String, messageIDs: [String]) throws {
        guard !messageIDs.isEmpty else { return }
        let idsJSON = (try? JSONEncoder().encode(messageIDs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try go.markRead(chatJID, senderJID: senderJID, msgIDsJSON: idsJSON)
    }

    nonisolated func fetchProfilePicture(jid: String, outPath: String) throws -> String {
        var err: NSError?
        let result = go.fetchProfilePicture(jid, outPath: outPath, error: &err)
        if let err { throw err }
        return result
    }

    func listGroups() throws -> [BridgeGroupModel] {
        var err: NSError?
        let json = go.listGroups(&err)
        if let err { throw err }
        return try JSONDecoder().decode([BridgeGroupModel].self, from: Data(json.utf8))
    }

    func getGroupInfo(jid: String) throws -> BridgeGroupModel {
        var err: NSError?
        let json = go.getGroupInfo(jid, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeGroupModel.self, from: Data(json.utf8))
    }

    func listContacts() throws -> [BridgeContact] {
        var err: NSError?
        let json = go.listContacts(&err)
        if let err { throw err }
        return try JSONDecoder().decode([BridgeContact].self, from: Data(json.utf8))
    }

    func getUserInfo(jid: String) throws -> BridgeUserInfo {
        var err: NSError?
        let json = go.getUserInfo(jid, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeUserInfo.self, from: Data(json.utf8))
    }

    nonisolated func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult {
        var err: NSError?
        let json = go.check(onWhatsApp: phone, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(PhoneCheckResult.self, from: Data(json.utf8))
    }

    func createGroup(name: String, participantJIDs: [String]) throws -> String {
        let jids = try JSONEncoder().encode(participantJIDs)
        let jidsString = String(data: jids, encoding: .utf8) ?? "[]"
        var err: NSError?
        let out = go.createGroup(name, participantJIDs: jidsString, error: &err)
        if let err { throw err }
        return out
    }

    func sendTyping(_ chatJID: String, _ typing: Bool) throws {
        try go.sendTyping(chatJID, typing: typing)
    }

    func subscribePresence(_ jid: String) throws {
        try go.subscribePresence(jid)
    }

    func sendPresence(available: Bool) throws {
        try go.sendPresence(available)
    }

    private func startPump() {
        let stream = bus.stream
        pump = Task { @MainActor [weak self] in
            for await tuple in stream {
                guard let self else { return }
                let evt = WAClient.decode(kind: tuple.kind, payload: tuple.payload)
                for cont in self.subscribers.values {
                    cont.yield(evt)
                }
            }
            // stream ended (deinit case)
            guard let self else { return }
            for cont in self.subscribers.values { cont.finish() }
            self.subscribers.removeAll()
        }
    }

    static func decode(kind: String, payload: String) -> Event {
        let data = Data(payload.utf8)
        let dec = JSONDecoder()
        switch kind {
        case "QR":
            return .qr((try? dec.decode(BridgeQR.self, from: data))?.code ?? "")
        case "PairSuccess":   return .pairSuccess
        case "Connected":     return .connected
        case "Disconnected":  return .disconnected
        case "LoggedOut":
            struct R: Codable { let reason: String }
            return .loggedOut(reason: (try? dec.decode(R.self, from: data))?.reason ?? "")
        case "Message":
            if let m = try? dec.decode(BridgeMessage.self, from: data) {
                return .message(m)
            }
        case "Receipt":
            if let r = try? dec.decode(BridgeReceipt.self, from: data) {
                return .receipt(r)
            }
        case "Reaction":
            if let r = try? dec.decode(BridgeReaction.self, from: data) {
                return .reaction(r)
            }
        case "PollVote":
            struct PV: Codable {
                let chatJID: String
                let pollMessageID: String
                let voterJID: String
                let optionHashes: [String]
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case pollMessageID = "poll_message_id"
                    case voterJID = "voter_jid"
                    case optionHashes = "option_hashes"
                    case timestamp
                }
            }
            if let pv = try? dec.decode(PV.self, from: data) {
                return .pollVote(chatJID: pv.chatJID,
                                 pollMessageID: pv.pollMessageID,
                                 voterJID: pv.voterJID,
                                 optionHashes: pv.optionHashes)
            }
        case "Presence":
            struct P: Codable {
                let from: String; let unavailable: Bool; let lastSeen: Int64
                enum CodingKeys: String, CodingKey { case from, unavailable, lastSeen = "last_seen" }
            }
            if let p = try? dec.decode(P.self, from: data) {
                return .presence(jid: p.from, online: !p.unavailable, lastSeen: p.lastSeen)
            }
        case "ChatPresence":
            struct CP: Codable { let chat: String; let sender: String; let state: String }
            if let p = try? dec.decode(CP.self, from: data) {
                return .chatPresence(chat: p.chat, sender: p.sender, typing: p.state == "composing")
            }
        case "HistorySync":
            struct H: Codable { let conversations: Int }
            if let h = try? dec.decode(H.self, from: data) {
                return .historySync(conversations: h.conversations)
            }
        case "MediaRetry":
            struct R: Codable {
                let messageID: String
                let ok: Bool
                let directPath: String?
                let error: String?
                enum CodingKeys: String, CodingKey {
                    case messageID = "message_id"
                    case ok
                    case directPath = "direct_path"
                    case error
                }
            }
            if let r = try? dec.decode(R.self, from: data) {
                return .mediaRetry(messageID: r.messageID, ok: r.ok, newDirectPath: r.directPath, error: r.error)
            }
        case "MessageEdited":
            struct E: Codable {
                let chatJID: String; let messageID: String
                let newText: String; let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case messageID = "message_id"
                    case newText = "new_text"
                    case timestamp
                }
            }
            if let e = try? dec.decode(E.self, from: data) {
                return .messageEdited(chatJID: e.chatJID, messageID: e.messageID,
                                      newText: e.newText, timestamp: e.timestamp)
            }
        case "MessageRevoked":
            struct R: Codable {
                let chatJID: String; let messageID: String
                let revokedBy: String; let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case messageID = "message_id"
                    case revokedBy = "revoked_by"
                    case timestamp
                }
            }
            if let r = try? dec.decode(R.self, from: data) {
                return .messageRevoked(chatJID: r.chatJID, messageID: r.messageID,
                                       revokedBy: r.revokedBy, timestamp: r.timestamp)
            }
        case "MessageLocallyDeleted":
            struct L: Codable {
                let chatJID: String; let messageID: String
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case messageID = "message_id"
                    case timestamp
                }
            }
            if let l = try? dec.decode(L.self, from: data) {
                return .messageLocallyDeleted(chatJID: l.chatJID, messageID: l.messageID,
                                              timestamp: l.timestamp)
            }
        case "MessageStarred":
            struct S: Codable {
                let chatJID: String; let messageID: String
                let senderJID: String; let fromMe: Bool
                let starred: Bool; let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case messageID = "message_id"
                    case senderJID = "sender_jid"
                    case fromMe = "from_me"
                    case starred, timestamp
                }
            }
            if let s = try? dec.decode(S.self, from: data) {
                return .messageStarred(chatJID: s.chatJID, messageID: s.messageID,
                                       senderJID: s.senderJID, fromMe: s.fromMe,
                                       starred: s.starred, timestamp: s.timestamp)
            }
        case "ChatPinned":
            struct P: Codable {
                let chatJID: String; let pinned: Bool; let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case pinned, timestamp
                }
            }
            if let p = try? dec.decode(P.self, from: data) {
                return .chatPinned(chatJID: p.chatJID, pinned: p.pinned, timestamp: p.timestamp)
            }
        case "MessagePinned":
            struct MP: Codable {
                let chatJID: String; let targetMessageID: String
                let senderJID: String; let pinned: Bool; let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case targetMessageID = "target_message_id"
                    case senderJID = "sender_jid"
                    case pinned, timestamp
                }
            }
            if let p = try? dec.decode(MP.self, from: data) {
                return .messagePinned(chatJID: p.chatJID,
                                      targetMessageID: p.targetMessageID,
                                      senderJID: p.senderJID,
                                      pinned: p.pinned,
                                      timestamp: p.timestamp)
            }
        default:
            break
        }
        return .unknown(kind: kind, payload: payload)
    }
}
