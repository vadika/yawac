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
class WAClient: PhoneValidating, LIDResolving {
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
        case chatMuted(chatJID: String, mutedUntilMs: Int64, timestamp: Int64)
        case groupInfoChanged(chatJID: String, name: String, description: String, timestamp: Int64)
        case groupParticipantsChanged(chatJID: String, action: String,
                                      actorJID: String, jids: [String],
                                      timestamp: Int64)
        case joinApprovalModeChanged(chatJID: String,
                                     on: Bool,
                                     actorJID: String,
                                     timestamp: Int64)
        case groupAnnounceChanged(chatJID: String,
                                  on: Bool,
                                  actorJID: String,
                                  timestamp: Int64)
        case groupLockedChanged(chatJID: String,
                                on: Bool,
                                actorJID: String,
                                timestamp: Int64)
        case ephemeralTimerChanged(chatJID: String,
                                   seconds: Int32,
                                   actorJID: String,
                                   timestamp: Int64)
        case messagePinned(chatJID: String, targetMessageID: String, senderJID: String, pinned: Bool, timestamp: Int64)
        case chatArchived(chatJID: String, archived: Bool, timestamp: Int64)
        case chatDeleted(chatJID: String, timestamp: Int64)
        case contactUpdated(jid: String, fullName: String, firstName: String)
        case blocklistChanged(action: String, changes: [(jid: String, action: String)])
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

    /// Encode @-mention JIDs as a JSON-string param for the Go bridge.
    /// gomobile silently drops methods whose signatures contain `[]string`,
    /// so the bridge accepts a JSON array string instead. Returns "" for
    /// empty input — the Go side treats "" as "no mentions".
    nonisolated private func encodeMentionsJSON(_ mentionedJIDs: [String]) -> String {
        guard !mentionedJIDs.isEmpty else { return "" }
        // JSONEncoder on [String] cannot fail in practice; on the off-chance,
        // fall through to empty so the bridge takes the no-mentions branch.
        return (try? String(data: JSONEncoder().encode(mentionedJIDs), encoding: .utf8)) ?? ""
    }

    func sendText(_ chatJID: String, _ body: String,
                  mentionedJIDs: [String] = [],
                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendText(chatJID, body: body,
                               mentionedJIDsJSON: encodeMentionsJSON(mentionedJIDs),
                               ephemeralSec: ephemeralSeconds,
                               error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendImage(_ chatJID: String, path: String, caption: String,
                   ephemeralSeconds: Int32 = 0,
                   viewOnce: Bool = false) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendImage(chatJID, filePath: path, caption: caption,
                                ephemeralSec: ephemeralSeconds,
                                viewOnce: viewOnce,
                                error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendVideo(_ chatJID: String, path: String, caption: String,
                   ephemeralSeconds: Int32 = 0,
                   viewOnce: Bool = false) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendVideo(chatJID, filePath: path, caption: caption,
                                ephemeralSec: ephemeralSeconds,
                                viewOnce: viewOnce,
                                error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendAudio(_ chatJID: String, path: String,
                   ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendAudio(chatJID, filePath: path,
                                ephemeralSec: ephemeralSeconds,
                                error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendVoiceNote(_ chatJID: String,
                       path: String,
                       duration: Int32,
                       waveform: Data,
                       ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendVoiceNote(chatJID,
                                    filePath: path,
                                    durationSec: duration,
                                    waveformB64: waveform.base64EncodedString(),
                                    ephemeralSec: ephemeralSeconds,
                                    error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func sendDocument(_ chatJID: String, path: String, caption: String,
                      ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendDocument(chatJID, filePath: path, caption: caption,
                                   ephemeralSec: ephemeralSeconds,
                                   error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    nonisolated func sendLocation(chatJID: String,
                                  latitude: Double,
                                  longitude: Double,
                                  name: String,
                                  address: String,
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendLocation(chatJID,
                                   lat: latitude,
                                   lng: longitude,
                                   name: name,
                                   address: address,
                                   ephemeralSec: ephemeralSeconds,
                                   error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    nonisolated func sendContact(chatJID: String,
                                 vcard: String,
                                 displayName: String,
                                 ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendContact(chatJID,
                                  vcard: vcard,
                                  displayName: displayName,
                                  ephemeralSec: ephemeralSeconds,
                                  error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    nonisolated func setDisappearingTimer(chatJID: String, seconds: Int32) throws {
        try go.setDisappearingTimer(chatJID, seconds: seconds)
    }

    nonisolated func sendReaction(chatJID: String,
                                  targetMsgID: String,
                                  targetSenderJID: String,
                                  targetFromMe: Bool,
                                  emoji: String,
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendReaction(
            chatJID,
            targetMsgID: targetMsgID,
            targetSenderJID: targetSenderJID,
            targetFromMe: targetFromMe,
            emoji: emoji,
            ephemeralSec: ephemeralSeconds,
            error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    nonisolated func sendTextReply(_ chatJID: String, _ body: String,
                                   quotedID: String, quotedSenderJID: String,
                                   quotedFromMe: Bool, quotedKind: String,
                                   quotedSnippet: String,
                                   mentionedJIDs: [String] = [],
                                   ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendTextReply(
            chatJID, body: body,
            quotedID: quotedID, quotedSenderJID: quotedSenderJID,
            quotedFromMe: quotedFromMe, quotedKind: quotedKind,
            quotedSnippet: quotedSnippet,
            mentionedJIDsJSON: encodeMentionsJSON(mentionedJIDs),
            ephemeralSec: ephemeralSeconds,
            error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    nonisolated func forwardText(_ chatJID: String, text: String,
                                 ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.forwardText(chatJID, text: text,
                                  ephemeralSec: ephemeralSeconds,
                                  error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    nonisolated func forwardMedia(_ chatJID: String, refJSON: String,
                                  caption: String, fileName: String,
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.forwardMedia(chatJID, refJSON: refJSON,
                                   caption: caption, fileName: fileName,
                                   ephemeralSec: ephemeralSeconds,
                                   error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    nonisolated func editText(_ chatJID: String, _ msgID: String, _ newBody: String,
                              mentionedJIDs: [String] = [],
                              ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.editText(chatJID, msgID: msgID, newBody: newBody,
                               mentionedJIDsJSON: encodeMentionsJSON(mentionedJIDs),
                               ephemeralSec: ephemeralSeconds,
                               error: &err)
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

    func muteChat(chatJID: String, mute: Bool, mutedUntilMs: Int64) throws {
        try go.muteChat(chatJID, mute: mute, mutedUntilUnixMs: mutedUntilMs)
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

    func archiveChat(chatJID: String, archived: Bool,
                     lastTS: Int64, lastMsgID: String, fromMe: Bool) throws {
        try go.archiveChat(chatJID, archived: archived,
                           lastTS: lastTS, lastMsgID: lastMsgID, fromMe: fromMe)
    }

    func setGroupName(chatJID: String, name: String) throws {
        try go.setGroupName(chatJID, name: name)
    }

    func setGroupDescription(chatJID: String, description: String) throws {
        try go.setGroupDescription(chatJID, description: description)
    }

    func deleteChat(chatJID: String, lastTS: Int64,
                    lastMsgID: String, fromMe: Bool) throws {
        try go.deleteChat(chatJID, lastTS: lastTS, lastMsgID: lastMsgID, fromMe: fromMe)
    }

    func setContactName(jid: String, fullName: String, firstName: String) throws {
        try go.setContactName(jid, fullName: fullName, firstName: firstName)
    }

    nonisolated func setBlocked(jid: String, blocked: Bool) throws {
        try go.setBlocked(jid, blocked: blocked)
    }

    nonisolated func listBlocked() throws -> [String] {
        var err: NSError?
        let json = go.listBlocked(&err)
        if let err { throw err }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
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

    /// Returns each input JID that whatsmeow's local appstate store
    /// currently considers muted (only future-dated mutes — already-
    /// expired entries are skipped server-side). Used to reconcile
    /// the sidebar at startup since events.Mute isn't re-emitted on
    /// reconnect.
    func listMutedChats(jids: [String]) throws -> [(jid: String, mutedUntilMs: Int64)] {
        let jidsJSON = (try? JSONEncoder().encode(jids))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var err: NSError?
        let json = go.listMutedChats(jidsJSON, error: &err)
        if let err { throw err }
        struct E: Codable {
            let chatJID: String
            let mutedUntilMs: Int64
            enum CodingKeys: String, CodingKey {
                case chatJID = "chat_jid"
                case mutedUntilMs = "muted_until_ms"
            }
        }
        let decoded = (try? JSONDecoder().decode([E].self, from: Data(json.utf8))) ?? []
        return decoded.map { ($0.chatJID, $0.mutedUntilMs) }
    }

    func sendPollCreation(_ chatJID: String,
                          question: String,
                          options: [String],
                          selectableCount: Int,
                          ephemeralSeconds: Int32 = 0) throws -> BridgeSendPollResult {
        let optsJSON = (try? JSONEncoder().encode(options))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var err: NSError?
        let json = go.sendPollCreation(
            chatJID,
            question: question,
            optionsJSON: optsJSON,
            selectableCount: Int32(selectableCount),
            ephemeralSec: ephemeralSeconds,
            error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendPollResult.self,
                                        from: Data(json.utf8))
    }

    nonisolated func sendPollVote(chatJID: String,
                                  pollMsgID: String,
                                  pollSenderJID: String,
                                  pollFromMe: Bool,
                                  optionHashes: [String],
                                  pollOptions: [BridgePollOption],
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
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
            ephemeralSec: ephemeralSeconds,
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

    /// Reverse direction: resolves a `@s.whatsapp.net` JID to its `@lid`
    /// form via the same local map. Returns the input unchanged when no
    /// mapping is known. Used by JIDNormalize.same to establish identity
    /// equality regardless of which namespace each side happens to be in.
    nonisolated func resolvePNToLID(_ jid: String) -> String {
        var err: NSError?
        let result = go.resolvePN(toLID: jid, error: &err)
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

    nonisolated func requestFullHistorySync(beforeChatJID: String,
                                            beforeMsgID: String,
                                            beforeFromMe: Bool,
                                            beforeTSUnix: Int64,
                                            count: Int32) throws {
        try go.requestFullHistorySync(beforeChatJID,
                                      beforeMsgID: beforeMsgID,
                                      beforeFromMe: beforeFromMe,
                                      beforeTSUnix: beforeTSUnix,
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

    /// Returns every sub-group linked under `parentJID` (a community
    /// parent), joined or not. Cheap directory listing.
    func listSubGroups(parentJID: String) throws -> [BridgeSubGroup] {
        var err: NSError?
        let json = go.listSubGroups(parentJID, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode([BridgeSubGroup].self, from: Data(json.utf8))
    }

    /// Best-effort community-member self-join: fetches the sub-group's
    /// invite link and joins via the returned code. Returns the joined
    /// JID. Throws the bridge error (forbidden / not-in-community)
    /// verbatim when the server rejects the call.
    func joinSubGroup(subJID: String) throws -> String {
        var err: NSError?
        let result = go.joinSubGroup(subJID, error: &err)
        if let err { throw err }
        return result
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

    /// Nonisolated so `NewGroupSheetModel` can call it from a detached task
    /// — the bridge call is synchronous and a multi-second create round-trip
    /// must not block the main actor.
    nonisolated func createGroup(name: String, participantJIDs: [String]) throws -> String {
        let jids = try JSONEncoder().encode(participantJIDs)
        let jidsString = String(data: jids, encoding: .utf8) ?? "[]"
        var err: NSError?
        let out = go.createGroup(name, participantJIDs: jidsString, error: &err)
        if let err { throw err }
        return out
    }

    /// Creates a new community parent group. The server auto-creates the
    /// default announcements sub-group, whose JID arrives via a JoinedGroup
    /// event shortly after. Returns the parent's JID.
    ///
    /// Nonisolated so `NewCommunitySheetModel` can call it from a detached
    /// task — the bridge call is synchronous and the create round-trip must
    /// not block the main actor.
    nonisolated func createCommunity(name: String) throws -> String {
        var err: NSError?
        let out = go.createCommunity(name, error: &err)
        if let err { throw err }
        return out
    }

    /// Creates a new sub-group inside the community parent identified by
    /// `parentJID`. Caller must be admin of the parent (server enforces).
    /// Returns the new sub-group's JID.
    ///
    /// Nonisolated so `NewSubGroupSheetModel` can call it from a detached
    /// task — the bridge call is synchronous and the create round-trip
    /// must not block the main actor.
    nonisolated func createSubGroup(parentJID: String,
                                    name: String,
                                    participantJIDs: [String]) throws -> String {
        let jids = try JSONEncoder().encode(participantJIDs)
        let jidsString = String(data: jids, encoding: .utf8) ?? "[]"
        var err: NSError?
        let out = go.createSubGroup(parentJID,
                                    name: name,
                                    participantJIDsJSON: jidsString,
                                    error: &err)
        if let err { throw err }
        return out
    }

    /// Attaches a child group to a community parent. Both JIDs must be
    /// admin-controlled. Surfaces whatsmeow errors verbatim.
    nonisolated func linkSubGroup(parentJID: String, subJID: String) throws {
        try go.linkSubGroup(parentJID, subJIDStr: subJID)
    }

    /// Detaches a child from its parent community. Swift gates against
    /// isDefaultSubGroup; server accepts the IQ even on the default
    /// sub-group but it breaks the community.
    nonisolated func unlinkSubGroup(parentJID: String, subJID: String) throws {
        try go.unlinkSubGroup(parentJID, subJIDStr: subJID)
    }

    /// Returns the pending join-request queue for `chatJID`. Empty array
    /// when the queue is empty or approval-mode is off (the two are
    /// indistinguishable at this layer — consult
    /// `BridgeGroupModel.joinApprovalMode` for the mode flag).
    /// Nonisolated so `JoinRequestStore` can drive it from a detached
    /// task without hopping back to the main actor for every group.
    nonisolated func getGroupJoinRequests(chatJID: String) throws -> [BridgeJoinRequest] {
        var err: NSError?
        let json = go.getGroupJoinRequests(chatJID, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode([BridgeJoinRequest].self,
                                        from: Data(json.utf8))
    }

    /// Applies "approve" or "reject" to a batch of pending join requests.
    /// Per-row failures populate `errorCode` on the returned rows; the
    /// outer error is reserved for fatal cases (network / unauthorized /
    /// group missing).
    /// Nonisolated so the admin panel can dispatch the bridge call from a
    /// detached task and keep the main actor free while the queue churns.
    nonisolated func updateGroupJoinRequests(chatJID: String,
                                             action: String,
                                             jids: [String]) throws -> [BridgeJoinRequestResult] {
        let encoded = try JSONEncoder().encode(jids)
        let jidsString = String(data: encoded, encoding: .utf8) ?? "[]"
        var err: NSError?
        let json = go.updateGroupJoinRequests(chatJID,
                                              action: action,
                                              participantJIDsJSON: jidsString,
                                              error: &err)
        if let err { throw err }
        return try JSONDecoder().decode([BridgeJoinRequestResult].self,
                                        from: Data(json.utf8))
    }

    /// Flips the require-admin-approval gate on a group on or off.
    /// Admin only.
    nonisolated func setGroupJoinApprovalMode(chatJID: String, on: Bool) throws {
        try go.setGroupJoinApprovalMode(chatJID, on: on)
    }

    /// Toggles announcement-mode on a group. When on, only admins may post.
    /// Admin only.
    nonisolated func setGroupAnnounce(chatJID: String, on: Bool) throws {
        try go.setGroupAnnounce(chatJID, on: on)
    }

    /// Toggles edit-locked-mode on a group. When on, only admins may edit
    /// group info (name / description / icon).
    /// Admin only.
    nonisolated func setGroupLocked(chatJID: String, on: Bool) throws {
        try go.setGroupLocked(chatJID, on: on)
    }

    nonisolated func leaveGroup(jid: String) throws {
        try go.leaveGroup(jid)
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

    /// Forces a clean socket cycle on the Go side. nonisolated so the
    /// blocking gomobile call runs off the main actor.
    nonisolated func forceReconnect() {
        try? go.reconnect()
    }

    /// Current websocket state per whatsmeow. Stale-true after sleep —
    /// see bridge IsConnected doc. nonisolated for off-main calls.
    nonisolated var connected: Bool {
        go.isConnected()
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

    func updateGroupParticipants(chatJID: String,
                                 action: String,
                                 participantJIDs: [String])
        throws -> [BridgeParticipantModel] {
        let jids = try JSONEncoder().encode(participantJIDs)
        let jidsString = String(data: jids, encoding: .utf8) ?? "[]"
        var err: NSError?
        let json = go.updateGroupParticipants(chatJID,
                                              action: action,
                                              participantJIDsJSON: jidsString,
                                              error: &err)
        if let err { throw err }
        return try JSONDecoder().decode([BridgeParticipantModel].self,
                                        from: Data(json.utf8))
    }

    func setGroupPhoto(chatJID: String, jpeg: Data) throws -> String {
        var err: NSError?
        let pictureID = go.setGroupPhoto(chatJID, jpeg: jpeg, error: &err)
        if let err { throw err }
        return pictureID
    }

    nonisolated func removeGroupPhoto(chatJID: String) throws {
        try go.removeGroupPhoto(chatJID)
    }

    func getGroupInviteLink(chatJID: String, reset: Bool) throws -> String {
        var err: NSError?
        let link = go.getGroupInviteLink(chatJID, reset: reset, error: &err)
        if let err { throw err }
        return link
    }

    func groupInfoFromLink(code: String) throws -> BridgeGroupModel {
        var err: NSError?
        let json = go.groupInfo(fromLink: code, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeGroupModel.self,
                                        from: Data(json.utf8))
    }

    func joinGroupViaLink(code: String) throws -> String {
        var err: NSError?
        let jid = go.joinGroup(viaLink: code, error: &err)
        if let err { throw err }
        return jid
    }

    nonisolated static func decode(kind: String, payload: String) -> Event {
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
        case "ChatMuted":
            struct M: Codable {
                let chatJID: String
                let mutedUntilMs: Int64
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case mutedUntilMs = "muted_until_ms"
                    case timestamp
                }
            }
            if let m = try? dec.decode(M.self, from: data) {
                return .chatMuted(chatJID: m.chatJID,
                                  mutedUntilMs: m.mutedUntilMs,
                                  timestamp: m.timestamp)
            }
        case "GroupInfoChanged":
            struct G: Codable {
                let chatJID: String
                let name: String
                let description: String
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case name, description, timestamp
                }
            }
            if let g = try? dec.decode(G.self, from: data) {
                return .groupInfoChanged(chatJID: g.chatJID,
                                         name: g.name,
                                         description: g.description,
                                         timestamp: g.timestamp)
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
        case "ChatArchived":
            struct A: Codable {
                let chatJID: String; let archived: Bool; let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case archived, timestamp
                }
            }
            if let a = try? dec.decode(A.self, from: data) {
                return .chatArchived(chatJID: a.chatJID, archived: a.archived, timestamp: a.timestamp)
            }
        case "ChatDeleted":
            struct D: Codable {
                let chatJID: String; let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case timestamp
                }
            }
            if let d = try? dec.decode(D.self, from: data) {
                return .chatDeleted(chatJID: d.chatJID, timestamp: d.timestamp)
            }
        case "ContactUpdated":
            struct C: Codable {
                let jid: String; let fullName: String; let firstName: String
                enum CodingKeys: String, CodingKey {
                    case jid
                    case fullName = "full_name"
                    case firstName = "first_name"
                }
            }
            if let c = try? dec.decode(C.self, from: data) {
                return .contactUpdated(jid: c.jid, fullName: c.fullName, firstName: c.firstName)
            }
        case "BlocklistChanged":
            struct Ch: Codable { let jid: String; let action: String }
            struct B: Codable { let action: String; let changes: [Ch] }
            if let b = try? dec.decode(B.self, from: data) {
                return .blocklistChanged(action: b.action,
                                         changes: b.changes.map { ($0.jid, $0.action) })
            }
        case "GroupParticipantsChanged":
            struct GP: Codable {
                let chatJID: String
                let action: String
                let actorJID: String?
                let jids: [String]
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case action
                    case actorJID = "actor_jid"
                    case jids, timestamp
                }
            }
            if let g = try? dec.decode(GP.self, from: data) {
                return .groupParticipantsChanged(
                    chatJID: g.chatJID, action: g.action,
                    actorJID: g.actorJID ?? "",
                    jids: g.jids, timestamp: g.timestamp)
            }
        case "JoinApprovalModeChanged":
            struct J: Codable {
                let chatJID: String
                let on: Bool
                let actorJID: String?
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case on
                    case actorJID = "actor_jid"
                    case timestamp
                }
            }
            if let j = try? dec.decode(J.self, from: data) {
                return .joinApprovalModeChanged(chatJID: j.chatJID,
                                                on: j.on,
                                                actorJID: j.actorJID ?? "",
                                                timestamp: j.timestamp)
            }
        case "GroupAnnounceChanged":
            struct A: Codable {
                let chatJID: String
                let on: Bool
                let actorJID: String?
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case on
                    case actorJID = "actor_jid"
                    case timestamp
                }
            }
            if let a = try? dec.decode(A.self, from: data) {
                return .groupAnnounceChanged(chatJID: a.chatJID,
                                             on: a.on,
                                             actorJID: a.actorJID ?? "",
                                             timestamp: a.timestamp)
            }
        case "GroupLockedChanged":
            struct L: Codable {
                let chatJID: String
                let on: Bool
                let actorJID: String?
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case on
                    case actorJID = "actor_jid"
                    case timestamp
                }
            }
            if let l = try? dec.decode(L.self, from: data) {
                return .groupLockedChanged(chatJID: l.chatJID,
                                           on: l.on,
                                           actorJID: l.actorJID ?? "",
                                           timestamp: l.timestamp)
            }
        case "EphemeralTimerChanged":
            struct E: Codable {
                let chatJID: String
                let seconds: Int32
                let actorJID: String?
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case seconds
                    case actorJID = "actor_jid"
                    case timestamp
                }
            }
            if let e = try? dec.decode(E.self, from: data) {
                return .ephemeralTimerChanged(chatJID: e.chatJID,
                                              seconds: e.seconds,
                                              actorJID: e.actorJID ?? "",
                                              timestamp: e.timestamp)
            }
        default:
            break
        }
        return .unknown(kind: kind, payload: payload)
    }
}
