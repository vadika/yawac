import Foundation
import Bridge

@MainActor
final class WAClient {
    enum Event {
        case qr(String)
        case pairSuccess
        case connected
        case disconnected
        case loggedOut(reason: String)
        case message(BridgeMessage)
        case receipt(BridgeReceipt)
        case presence(jid: String, online: Bool, lastSeen: Int64)
        case chatPresence(chat: String, sender: String, typing: Bool)
        case historySync(conversations: Int)
        case unknown(kind: String, payload: String)
    }

    enum WAError: Error {
        case bridgeFailure(String)
    }

    private let go: BridgeClient
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

    func downloadMedia(_ refJSON: String, to outPath: String) throws -> String {
        var err: NSError?
        let out = go.downloadMedia(refJSON, outPath: outPath, error: &err)
        if let err { throw err }
        return out
    }

    func fetchProfilePicture(jid: String, outPath: String) throws -> String {
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

    func listContacts() throws -> [BridgeContact] {
        var err: NSError?
        let json = go.listContacts(&err)
        if let err { throw err }
        return try JSONDecoder().decode([BridgeContact].self, from: Data(json.utf8))
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
        default:
            break
        }
        return .unknown(kind: kind, payload: payload)
    }
}
