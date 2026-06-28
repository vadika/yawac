import Foundation
import os
import Bridge

private let evtPerfLog = Logger(subsystem: "dev.vadikas.yawac.yawac",
                                category: "perf")

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
        case historySync(syncType: String,
                         conversations: Int,
                         progress: Int,
                         chunkOrder: Int,
                         chunkMessages: Int)
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
        case groupMemberAddModeChanged(chatJID: String,
                                       allMembersCanAdd: Bool,
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
        /// PUSH_NAME chunk from HistorySync. Each entry's JID is the
        /// exact form whatsmeow received (often `@lid`), so the Swift
        /// side can key `contactNames` at that form directly without
        /// depending on the local LID→PN map.
        case pushNames(names: [(jid: String, name: String)])
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

    // F65: per-method invocation counters for the Diagnostics panel.
    // Used to track which bridge methods fire too often (suspected
    // cause of phone-side battery drain via repeated IQ traffic).
    // nonisolated(unsafe) + NSLock so nonisolated methods can bump
    // from off-MainActor without main-thread hops.
    nonisolated(unsafe) private var _callCounts: [String: Int] = [:]
    nonisolated(unsafe) private var _callCountsStartedAt: Date = Date()
    nonisolated private let callCountsLock = NSLock()

    nonisolated private func bump(_ name: String) {
        callCountsLock.lock()
        _callCounts[name, default: 0] += 1
        callCountsLock.unlock()
    }

    nonisolated func callCountsSnapshot() -> [String: Int] {
        callCountsLock.lock(); defer { callCountsLock.unlock() }
        return _callCounts
    }

    /// Start of the current measurement window — the timestamp of the
    /// last `resetCallCounts()` call, or process start if never reset.
    /// Surfaced in the Diagnostics JSON so bug reports include the
    /// window the counters cover.
    nonisolated func callCountsStartedAt() -> Date {
        callCountsLock.lock(); defer { callCountsLock.unlock() }
        return _callCountsStartedAt
    }

    nonisolated func resetCallCounts() {
        callCountsLock.lock()
        _callCounts.removeAll()
        _callCountsStartedAt = Date()
        callCountsLock.unlock()
    }

    // MARK: - Event pump (off-main)
    //
    // Subscribers are read+written from the detached pump Task as well as
    // from `eventStream()` / continuation termination callbacks (which may
    // be on any actor). Protected by `subscribersQueue`;
    // AsyncStream.Continuation.yield is safe to call from any thread.
    private let subscribersQueue = DispatchQueue(
        label: "yawac.WAClient.subscribers")
    nonisolated(unsafe) private var _subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    // F100: replay buffer for events that arrive at the pump BEFORE any
    // Swift subscriber registers. Bridge starts dispatching as soon as
    // websocket auth completes (~0.5s after WAClient.init), but
    // ContentView.task subscribes only AFTER ChatListViewModel cold-start
    // bootstrap + groups/contacts refresh (~1-2s). The race silently
    // dropped every offline-drain message announced before the first
    // subscriber. Protected by subscribersQueue.
    nonisolated(unsafe) private var _pendingEvents: [Event] = []
    // pump Task is write-once in startPump (from MainActor init) and never
    // read back — nothing observes it for cancellation or deinit cleanup.
    // nonisolated(unsafe) is justified by that invariant.
    nonisolated(unsafe) private var pump: Task<Void, Never>?

    nonisolated private func withSubscribers<R>(_ body: ([UUID: AsyncStream<Event>.Continuation]) -> R) -> R {
        subscribersQueue.sync { body(_subscribers) }
    }

    nonisolated private func mutateSubscribers<R>(_ body: (inout [UUID: AsyncStream<Event>.Continuation]) -> R) -> R {
        subscribersQueue.sync { body(&_subscribers) }
    }

    nonisolated func dispatchSynthetic(_ event: Event) {
        // F87: yawac-side synthesized events (e.g. own outbound sends that
        // whatsmeow does not echo). Routed through the same subscriber fan-
        // out as real bridge events so ChatListViewModel + ConversationView
        // observers update via their existing .onChange paths.
        let snapshot: [AsyncStream<Event>.Continuation] = self.withSubscribers { subs in
            Array(subs.values)
        }
        for cont in snapshot { cont.yield(event) }
    }

    init(dbPath: String) throws {
        var err: NSError?
        guard let client = BridgeNewClient(dbPath, &err) else {
            throw err ?? NSError(domain: "yawac", code: -1)
        }
        self.go = client
        client.setEventSink(bus)
        startPump()
    }

    nonisolated func eventStream() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            // F100: register under lock + drain replay buffer atomically.
            // Buffered events were captured by the pump while no subscriber
            // existed. Yield them OUTSIDE the lock to avoid the
            // onTermination reentrancy deadlock the pump comment calls out.
            let backlog: [Event] = self.mutateSubscribers { subs in
                subs[id] = continuation
                let p = self._pendingEvents
                self._pendingEvents.removeAll(keepingCapacity: false)
                return p
            }
            for e in backlog { continuation.yield(e) }
            continuation.onTermination = { [weak self] _ in
                self?.mutateSubscribers { subs in
                    subs.removeValue(forKey: id)
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
    /// Own push name as known to whatsmeow's local store. Empty before
    /// pairing or before app-state has settled.
    var ownPushName: String { go.ownPushName() }

    func connect() throws {
        bump("connect")
        try go.connect()
    }
    func logout() throws {
        bump("logout")
        try go.logout()
    }

    /// Encode @-mention JIDs as a JSON-string param for the Go bridge.
    /// gomobile silently drops methods whose signatures contain `[]string`,
    /// so the bridge accepts a JSON array string instead. Returns "" for
    /// empty input — the Go side treats "" as "no mentions".
    nonisolated private func encodeMentionsJSON(_ mentionedJIDs: [String]) -> String {
        guard !mentionedJIDs.isEmpty else { return "" }
        // JSONEncoder on [String] cannot fail in practice; on the off-chance,
        // fall through to empty so the bridge takes the no-mentions branch.
        return Self.jsonArrayString(mentionedJIDs, empty: "")
    }

    /// JSON-encode `value` to a string for the Go bridge. gomobile cannot
    /// pass `[]string` natively, so every array-typed param goes over the
    /// wire as a JSON string. Encoding `[String]` / `[Codable]` cannot fail
    /// in practice; `empty` is returned on the off-chance.
    nonisolated private static func jsonArrayString<T: Encodable>(_ value: T, empty: String = "[]") -> String {
        (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) } ?? empty
    }

    /// Decode a UTF-8 JSON string returned by the gomobile bridge.
    /// Folds the `JSONDecoder().decode(_:from: Data(json.utf8))` triple
    /// that every send-call wrapper otherwise spelled out.
    nonisolated private static func decodeJSON<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // Nonisolated to match sendTextReply — the CGo round-trip blocks
    // for ~50-200ms and used to peg MainActor, leaving the composer
    // text "stuck" in the input until the call returned. Callable from
    // a detached task so the UI runloop keeps painting.
    nonisolated func sendText(_ chatJID: String, _ body: String,
                              mentionedJIDs: [String] = [],
                              ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendText")
        var err: NSError?
        let json = go.sendText(chatJID, body: body,
                               mentionedJIDsJSON: encodeMentionsJSON(mentionedJIDs),
                               ephemeralSec: ephemeralSeconds,
                               error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func sendImage(_ chatJID: String, path: String, caption: String,
                   ephemeralSeconds: Int32 = 0,
                   viewOnce: Bool = false) throws -> BridgeSendResult {
        bump("sendImage")
        var err: NSError?
        let json = go.sendImage(chatJID, filePath: path, caption: caption,
                                ephemeralSec: ephemeralSeconds,
                                viewOnce: viewOnce,
                                error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func sendVideo(_ chatJID: String, path: String, caption: String,
                   ephemeralSeconds: Int32 = 0,
                   viewOnce: Bool = false) throws -> BridgeSendResult {
        bump("sendVideo")
        var err: NSError?
        let json = go.sendVideo(chatJID, filePath: path, caption: caption,
                                ephemeralSec: ephemeralSeconds,
                                viewOnce: viewOnce,
                                error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func sendAudio(_ chatJID: String, path: String,
                   ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendAudio")
        var err: NSError?
        let json = go.sendAudio(chatJID, filePath: path,
                                ephemeralSec: ephemeralSeconds,
                                error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func sendVoiceNote(_ chatJID: String,
                       path: String,
                       duration: Int32,
                       waveform: Data,
                       ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendVoiceNote")
        var err: NSError?
        let json = go.sendVoiceNote(chatJID,
                                    filePath: path,
                                    durationSec: duration,
                                    waveformB64: waveform.base64EncodedString(),
                                    ephemeralSec: ephemeralSeconds,
                                    error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func sendDocument(_ chatJID: String, path: String, caption: String,
                      ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendDocument")
        var err: NSError?
        let json = go.sendDocument(chatJID, filePath: path, caption: caption,
                                   ephemeralSec: ephemeralSeconds,
                                   error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    nonisolated func sendLocation(chatJID: String,
                                  latitude: Double,
                                  longitude: Double,
                                  name: String,
                                  address: String,
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendLocation")
        var err: NSError?
        let json = go.sendLocation(chatJID,
                                   lat: latitude,
                                   lng: longitude,
                                   name: name,
                                   address: address,
                                   ephemeralSec: ephemeralSeconds,
                                   error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    nonisolated func sendContact(chatJID: String,
                                 vcard: String,
                                 displayName: String,
                                 ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendContact")
        var err: NSError?
        let json = go.sendContact(chatJID,
                                  vcard: vcard,
                                  displayName: displayName,
                                  ephemeralSec: ephemeralSeconds,
                                  error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    /// Sends a multi-vCard ContactsArrayMessage. The vcards array is
    /// JSON-encoded into a single string because gomobile cannot bridge
    /// `[]string` natively — the Go side reads `vcardsJSON` and
    /// unmarshals (mirrors `createGroup`'s `participantJIDsJSON`).
    nonisolated func sendContacts(chatJID: String,
                                  displayName: String,
                                  vcards: [String],
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendContacts")
        let vcardsJSON = Self.jsonArrayString(vcards)
        var err: NSError?
        let json = go.sendContactsArray(chatJID,
                                        displayName: displayName,
                                        vcardsJSON: vcardsJSON,
                                        ephemeralSec: ephemeralSeconds,
                                        error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    nonisolated func setDisappearingTimer(chatJID: String, seconds: Int32) throws {
        bump("setDisappearingTimer")
        try go.setDisappearingTimer(chatJID, seconds: seconds)
    }

    nonisolated func sendReaction(chatJID: String,
                                  targetMsgID: String,
                                  targetSenderJID: String,
                                  targetFromMe: Bool,
                                  emoji: String,
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendReaction")
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
        return try Self.decodeJSON(json)
    }

    nonisolated func sendTextReply(_ chatJID: String, _ body: String,
                                   quotedID: String, quotedSenderJID: String,
                                   quotedFromMe: Bool, quotedKind: String,
                                   quotedSnippet: String,
                                   mentionedJIDs: [String] = [],
                                   ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendTextReply")
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
        return try Self.decodeJSON(json)
    }

    nonisolated func forwardText(_ chatJID: String, text: String,
                                 ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("forwardText")
        var err: NSError?
        let json = go.forwardText(chatJID, text: text,
                                  ephemeralSec: ephemeralSeconds,
                                  error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    nonisolated func forwardMedia(_ chatJID: String, refJSON: String,
                                  caption: String, fileName: String,
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("forwardMedia")
        var err: NSError?
        let json = go.forwardMedia(chatJID, refJSON: refJSON,
                                   caption: caption, fileName: fileName,
                                   ephemeralSec: ephemeralSeconds,
                                   error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    nonisolated func editText(_ chatJID: String, _ msgID: String, _ newBody: String,
                              mentionedJIDs: [String] = [],
                              ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("editText")
        var err: NSError?
        let json = go.editText(chatJID, msgID: msgID, newBody: newBody,
                               mentionedJIDsJSON: encodeMentionsJSON(mentionedJIDs),
                               ephemeralSec: ephemeralSeconds,
                               error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func revokeMessage(_ chatJID: String, _ msgID: String,
                       _ targetSenderJID: String, _ targetFromMe: Bool) throws -> BridgeSendResult {
        bump("revokeMessage")
        var err: NSError?
        let json = go.revokeMessage(chatJID, msgID: msgID,
                                    targetSenderJID: targetSenderJID,
                                    targetFromMe: targetFromMe, error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func starMessage(chatJID: String,
                     targetMsgID: String,
                     targetSenderJID: String,
                     targetFromMe: Bool,
                     starred: Bool) throws {
        bump("starMessage")
        try go.starMessage(chatJID,
                           targetMsgID: targetMsgID,
                           targetSenderJID: targetSenderJID,
                           targetFromMe: targetFromMe,
                           starred: starred)
    }

    func pinChat(chatJID: String, pinned: Bool) throws {
        bump("pinChat")
        try go.pinChat(chatJID, pinned: pinned)
    }

    func muteChat(chatJID: String, mute: Bool, mutedUntilMs: Int64) throws {
        bump("muteChat")
        try go.muteChat(chatJID, mute: mute, mutedUntilUnixMs: mutedUntilMs)
    }

    func pinMessageInChat(chatJID: String,
                          targetMsgID: String,
                          targetSenderJID: String,
                          targetFromMe: Bool,
                          pinned: Bool) throws -> BridgeSendResult {
        bump("pinMessageInChat")
        var err: NSError?
        let json = go.pinMessage(inChat: chatJID,
                                 targetMsgID: targetMsgID,
                                 targetSenderJID: targetSenderJID,
                                 targetFromMe: targetFromMe,
                                 pin: pinned,
                                 error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func archiveChat(chatJID: String, archived: Bool,
                     lastTS: Int64, lastMsgID: String, fromMe: Bool) throws {
        bump("archiveChat")
        try go.archiveChat(chatJID, archived: archived,
                           lastTS: lastTS, lastMsgID: lastMsgID, fromMe: fromMe)
    }

    func setGroupName(chatJID: String, name: String) throws {
        bump("setGroupName")
        try go.setGroupName(chatJID, name: name)
    }

    func setGroupDescription(chatJID: String, description: String) throws {
        bump("setGroupDescription")
        try go.setGroupDescription(chatJID, description: description)
    }

    func deleteChat(chatJID: String, lastTS: Int64,
                    lastMsgID: String, fromMe: Bool) throws {
        bump("deleteChat")
        try go.deleteChat(chatJID, lastTS: lastTS, lastMsgID: lastMsgID, fromMe: fromMe)
    }

    func setContactName(jid: String, fullName: String, firstName: String) throws {
        bump("setContactName")
        try go.setContactName(jid, fullName: fullName, firstName: firstName)
    }

    nonisolated func setBlocked(jid: String, blocked: Bool) throws {
        bump("setBlocked")
        try go.setBlocked(jid, blocked: blocked)
    }

    nonisolated func listBlocked() throws -> [String] {
        bump("listBlocked")
        var err: NSError?
        let json = go.listBlocked(&err)
        if let err { throw err }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    /// Lists every device paired to the account — phone (`deviceID = 0`)
    /// plus all companions. Backed by whatsmeow's `GetUserDevices` against
    /// the bare own JID. nonisolated so the LinkedDevicesSheet can dispatch
    /// the IQ off the main actor.
    nonisolated func listLinkedDevices() throws -> [BridgeLinkedDevice] {
        bump("listLinkedDevices")
        var err: NSError?
        let json = go.listLinkedDevices(&err)
        if let err { throw err }
        return (try? JSONDecoder().decode([BridgeLinkedDevice].self,
                                          from: Data(json.utf8))) ?? []
    }

    /// Returns the paired account's current privacy settings. First call
    /// after connect can block briefly on an IQ round trip while
    /// whatsmeow's in-memory cache fills; subsequent calls are cached.
    /// nonisolated so PrivacySettingsSheet can dispatch off the main
    /// actor.
    nonisolated func getPrivacySettings() throws -> BridgePrivacySettings {
        bump("getPrivacySettings")
        var err: NSError?
        let json = go.getPrivacySettings(&err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    /// Updates one privacy knob. `name` is the wire PrivacySettingType
    /// ("last", "profile", "status", "readreceipts", "groupadd"). `value`
    /// is "all" / "contacts" / "contact_blacklist" / "none" — but
    /// readreceipts only accepts "all" / "none" (whatsmeow rejects the
    /// others server-side, so the UI must not offer them).
    nonisolated func setPrivacySetting(name: String, value: String) throws {
        bump("setPrivacySetting")
        try go.setPrivacySetting(name, value: value)
    }

    /// Returns the subset of `jids` that whatsmeow's local appstate
    /// store currently marks as pinned. Used to reconcile the sidebar
    /// at startup since events.Pin isn't re-emitted on reconnect.
    func listPinnedChats(jids: [String]) throws -> [String] {
        bump("listPinnedChats")
        let jidsJSON = Self.jsonArrayString(jids)
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
        bump("listMutedChats")
        let jidsJSON = Self.jsonArrayString(jids)
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
        bump("sendPollCreation")
        let optsJSON = Self.jsonArrayString(options)
        var err: NSError?
        let json = go.sendPollCreation(
            chatJID,
            question: question,
            optionsJSON: optsJSON,
            selectableCount: Int32(selectableCount),
            ephemeralSec: ephemeralSeconds,
            error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    nonisolated func sendPollVote(chatJID: String,
                                  pollMsgID: String,
                                  pollSenderJID: String,
                                  pollFromMe: Bool,
                                  optionHashes: [String],
                                  pollOptions: [BridgePollOption],
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendPollVote")
        let hashesJSON = Self.jsonArrayString(optionHashes)
        let optionsJSON = Self.jsonArrayString(pollOptions)
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
        return try Self.decodeJSON(json)
    }

    nonisolated func downloadMedia(_ refJSON: String, to outPath: String) throws -> String {
        bump("downloadMedia")
        var err: NSError?
        let out = go.downloadMedia(refJSON, outPath: outPath, error: &err)
        if let err { throw err }
        return out
    }

    /// Last-resort download that bypasses whatsmeow's hash + HMAC checks.
    /// Use only when the strict download fails with integrity errors and the
    /// user has opted in.
    nonisolated func downloadMediaForce(_ refJSON: String, to outPath: String) throws -> String {
        bump("downloadMediaForce")
        var err: NSError?
        let out = go.downloadMediaForce(refJSON, outPath: outPath, error: &err)
        if let err { throw err }
        return out
    }

    nonisolated func requestMediaRetry(chatJID: String, senderJID: String, msgID: String, fromMe: Bool, refJSON: String) throws {
        bump("requestMediaRetry")
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
        bump("requestOlderHistory")
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
        bump("requestFullHistorySync")
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
        bump("markRead")
        let idsJSON = Self.jsonArrayString(messageIDs)
        try go.markRead(chatJID, senderJID: senderJID, msgIDsJSON: idsJSON)
    }

    nonisolated func fetchProfilePicture(jid: String, outPath: String) throws -> String {
        bump("fetchProfilePicture")
        var err: NSError?
        let result = go.fetchProfilePicture(jid, outPath: outPath, error: &err)
        if let err { throw err }
        return result
    }

    // Nonisolated to match listContacts — scheduleHistorySyncReconcile
    // runs the CGo round-trip + JSON decode off MainActor during the
    // burst of HistorySync events at initial sync.
    nonisolated func listGroups() throws -> [BridgeGroupModel] {
        bump("listGroups")
        var err: NSError?
        let json = go.listGroups(&err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func getGroupInfo(jid: String) throws -> BridgeGroupModel {
        bump("getGroupInfo")
        var err: NSError?
        let json = go.getGroupInfo(jid, error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    /// Returns every sub-group linked under `parentJID` (a community
    /// parent), joined or not. Cheap directory listing.
    func listSubGroups(parentJID: String) throws -> [BridgeSubGroup] {
        bump("listSubGroups")
        var err: NSError?
        let json = go.listSubGroups(parentJID, error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    /// Best-effort community-member self-join: fetches the sub-group's
    /// invite link and joins via the returned code. Returns the joined
    /// JID. Throws the bridge error (forbidden / not-in-community)
    /// verbatim when the server rejects the call.
    func joinSubGroup(subJID: String) throws -> String {
        bump("joinSubGroup")
        var err: NSError?
        let result = go.joinSubGroup(subJID, error: &err)
        if let err { throw err }
        return result
    }

    // Nonisolated so `SessionViewModel.scheduleHistorySyncReconcile`
    // (F19) can run the CGo round-trip + array marshal off MainActor
    // during the burst of HistorySync events at initial sync.
    nonisolated func listContacts() throws -> [BridgeContact] {
        bump("listContacts")
        var err: NSError?
        let json = go.listContacts(&err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    nonisolated func getUserInfo(jid: String) throws -> BridgeUserInfo {
        bump("getUserInfo")
        var err: NSError?
        let json = go.getUserInfo(jid, error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    nonisolated func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult {
        bump("checkOnWhatsApp")
        var err: NSError?
        let json = go.check(onWhatsApp: phone, error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    /// Nonisolated so `NewGroupSheetModel` can call it from a detached task
    /// — the bridge call is synchronous and a multi-second create round-trip
    /// must not block the main actor.
    nonisolated func createGroup(name: String, participantJIDs: [String]) throws -> String {
        bump("createGroup")
        let jidsString = Self.jsonArrayString(participantJIDs)
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
        bump("createCommunity")
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
        bump("createSubGroup")
        let jidsString = Self.jsonArrayString(participantJIDs)
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
        bump("linkSubGroup")
        try go.linkSubGroup(parentJID, subJIDStr: subJID)
    }

    /// Detaches a child from its parent community. Swift gates against
    /// isDefaultSubGroup; server accepts the IQ even on the default
    /// sub-group but it breaks the community.
    nonisolated func unlinkSubGroup(parentJID: String, subJID: String) throws {
        bump("unlinkSubGroup")
        try go.unlinkSubGroup(parentJID, subJIDStr: subJID)
    }

    /// Returns the pending join-request queue for `chatJID`. Empty array
    /// when the queue is empty or approval-mode is off (the two are
    /// indistinguishable at this layer — consult
    /// `BridgeGroupModel.joinApprovalMode` for the mode flag).
    /// Nonisolated so `JoinRequestStore` can drive it from a detached
    /// task without hopping back to the main actor for every group.
    nonisolated func getGroupJoinRequests(chatJID: String) throws -> [BridgeJoinRequest] {
        bump("getGroupJoinRequests")
        var err: NSError?
        let json = go.getGroupJoinRequests(chatJID, error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
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
        bump("updateGroupJoinRequests")
        let jidsString = Self.jsonArrayString(jids)
        var err: NSError?
        let json = go.updateGroupJoinRequests(chatJID,
                                              action: action,
                                              participantJIDsJSON: jidsString,
                                              error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    /// Flips the require-admin-approval gate on a group on or off.
    /// Admin only.
    nonisolated func setGroupJoinApprovalMode(chatJID: String, on: Bool) throws {
        bump("setGroupJoinApprovalMode")
        try go.setGroupJoinApprovalMode(chatJID, on: on)
    }

    /// Toggles announcement-mode on a group. When on, only admins may post.
    /// Admin only.
    nonisolated func setGroupAnnounce(chatJID: String, on: Bool) throws {
        bump("setGroupAnnounce")
        try go.setGroupAnnounce(chatJID, on: on)
    }

    /// Toggles edit-locked-mode on a group. When on, only admins may edit
    /// group info (name / description / icon).
    /// Admin only.
    nonisolated func setGroupLocked(chatJID: String, on: Bool) throws {
        bump("setGroupLocked")
        try go.setGroupLocked(chatJID, on: on)
    }

    /// Toggles who can add new participants. `allMembersCanAdd == true`
    /// flips whatsmeow's "all_member_add" mode; false restores the
    /// default "admin_add". Admin only — server returns 403 otherwise.
    nonisolated func setGroupMemberAddMode(chatJID: String,
                                           allMembersCanAdd: Bool) throws {
        bump("setGroupMemberAddMode")
        try go.setGroupMemberAddMode(chatJID, allMembersCanAdd: allMembersCanAdd)
    }

    nonisolated func leaveGroup(jid: String) throws {
        bump("leaveGroup")
        try go.leaveGroup(jid)
    }

    func sendTyping(_ chatJID: String, _ typing: Bool) throws {
        bump("sendTyping")
        try go.sendTyping(chatJID, typing: typing)
    }

    func subscribePresence(_ jid: String) throws {
        bump("subscribePresence")
        try go.subscribePresence(jid)
    }

    func sendPresence(available: Bool) throws {
        bump("sendPresence")
        try go.sendPresence(available)
    }

    /// Forces a clean socket cycle on the Go side. nonisolated so the
    /// blocking gomobile call runs off the main actor.
    nonisolated func forceReconnect() {
        bump("forceReconnect")
        try? go.reconnect()
    }

    /// Current websocket state per whatsmeow. Stale-true after sleep —
    /// see bridge IsConnected doc. nonisolated for off-main calls.
    nonisolated var connected: Bool {
        go.isConnected()
    }

    nonisolated private func startPump() {
        let stream = bus.stream
        // Detached, off main actor. Each Go event decodes here and yields
        // to subscriber continuations on a background thread. Subscribers
        // hop to whatever actor they need inside their own `for await`.
        // Eliminates per-event main-thread wakes that the original pump
        // (Task { @MainActor }) generated during history-sync / message
        // bursts (kernel flagged yawac at ~792 wakes/sec).
        pump = Task.detached(priority: .userInitiated) { [weak self] in
            var perKindCount: [String: Int] = [:]
            var windowStart = CFAbsoluteTimeGetCurrent()
            for await tuple in stream {
                guard let self else { return }
                perKindCount[tuple.kind, default: 0] += 1
                let now = CFAbsoluteTimeGetCurrent()
                if now - windowStart >= 5.0 {
                    let total = perKindCount.values.reduce(0, +)
                    let perSec = Double(total) / (now - windowStart)
                    let breakdown = perKindCount
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: " ")
                    evtPerfLog.log("eventPump total=\(total, privacy: .public) rate=\(perSec, format: .fixed(precision: 1), privacy: .public)/s [\(breakdown, privacy: .public)]")
                    perKindCount.removeAll(keepingCapacity: true)
                    windowStart = now
                }
                let evt = WAClient.decode(kind: tuple.kind, payload: tuple.payload)
                // Snapshot continuations under the lock; yield outside it.
                // `cont.yield` itself is non-blocking, but a previously
                // finished continuation's `onTermination` callback fires
                // synchronously and re-enters `subscribersQueue.sync` via
                // `mutateSubscribers` — yielding while holding the lock
                // would deadlock that path.
                // F100: always buffer (cap 1000) so any LATE subscriber
                // (e.g. ChatListViewModel registers ~1s after SessionViewModel
                // — events that fired in the gap would otherwise be missed)
                // can drain the backlog on registration. Existing subs get
                // the live yield as before; no dupes. Closes issue #6 for the
                // late-subscriber-missed-offline-drain failure mode.
                let snapshot: [AsyncStream<Event>.Continuation] = self.mutateSubscribers { subs in
                    self._pendingEvents.append(evt)
                    if self._pendingEvents.count > 1000 {
                        self._pendingEvents.removeFirst(self._pendingEvents.count - 1000)
                    }
                    return Array(subs.values)
                }
                for cont in snapshot { cont.yield(evt) }
            }
            // stream ended (deinit case). Drain + clear under the lock,
            // finish the continuations outside it for the same reentrancy
            // reason as the per-event fan-out above.
            guard let self else { return }
            let toFinish: [AsyncStream<Event>.Continuation] = self.mutateSubscribers { subs in
                let conts = Array(subs.values)
                subs.removeAll()
                return conts
            }
            for cont in toFinish { cont.finish() }
        }
    }

    func updateGroupParticipants(chatJID: String,
                                 action: String,
                                 participantJIDs: [String])
        throws -> [BridgeParticipantModel] {
        bump("updateGroupParticipants")
        let jidsString = Self.jsonArrayString(participantJIDs)
        var err: NSError?
        let json = go.updateGroupParticipants(chatJID,
                                              action: action,
                                              participantJIDsJSON: jidsString,
                                              error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func setGroupPhoto(chatJID: String, jpeg: Data) throws -> String {
        bump("setGroupPhoto")
        var err: NSError?
        let pictureID = go.setGroupPhoto(chatJID, jpeg: jpeg, error: &err)
        if let err { throw err }
        return pictureID
    }

    nonisolated func removeGroupPhoto(chatJID: String) throws {
        bump("removeGroupPhoto")
        try go.removeGroupPhoto(chatJID)
    }

    nonisolated func setSelfAvatar(jpegBytes: Data) throws {
        bump("setSelfAvatar")
        try go.setSelfAvatar(jpegBytes)
    }

    nonisolated func removeSelfAvatar() throws {
        bump("removeSelfAvatar")
        try go.removeSelfAvatar()
    }

    nonisolated func setSelfAbout(_ message: String) throws {
        bump("setSelfAbout")
        try go.setSelfAbout(message)
    }

    nonisolated func setSelfPushName(_ name: String) throws {
        bump("setSelfPushName")
        try go.setSelfPushName(name)
    }

    func getGroupInviteLink(chatJID: String, reset: Bool) throws -> String {
        bump("getGroupInviteLink")
        var err: NSError?
        let link = go.getGroupInviteLink(chatJID, reset: reset, error: &err)
        if let err { throw err }
        return link
    }

    func groupInfoFromLink(code: String) throws -> BridgeGroupModel {
        bump("groupInfoFromLink")
        var err: NSError?
        let json = go.groupInfo(fromLink: code, error: &err)
        if let err { throw err }
        return try Self.decodeJSON(json)
    }

    func joinGroupViaLink(code: String) throws -> String {
        bump("joinGroupViaLink")
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
            struct H: Codable {
                let conversations: Int
                let syncType: String?
                let progress: Int?
                let chunkOrder: Int?
                let chunkMessages: Int?
                enum CodingKeys: String, CodingKey {
                    case conversations
                    case syncType = "sync_type"
                    case progress
                    case chunkOrder = "chunk_order"
                    case chunkMessages = "chunk_messages"
                }
            }
            if let h = try? dec.decode(H.self, from: data) {
                return .historySync(syncType: h.syncType ?? "",
                                    conversations: h.conversations,
                                    progress: h.progress ?? 0,
                                    chunkOrder: h.chunkOrder ?? 0,
                                    chunkMessages: h.chunkMessages ?? 0)
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
        case "GroupMemberAddModeChanged":
            struct M: Codable {
                let chatJID: String
                let allMembersCanAdd: Bool
                let actorJID: String?
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case allMembersCanAdd = "all_members_can_add"
                    case actorJID = "actor_jid"
                    case timestamp
                }
            }
            if let m = try? dec.decode(M.self, from: data) {
                return .groupMemberAddModeChanged(
                    chatJID: m.chatJID,
                    allMembersCanAdd: m.allMembersCanAdd,
                    actorJID: m.actorJID ?? "",
                    timestamp: m.timestamp)
            }
        case "push_names":
            struct Entry: Codable { let jid: String; let name: String }
            struct Batch: Codable { let names: [Entry] }
            if let b = try? dec.decode(Batch.self, from: data) {
                return .pushNames(names: b.names.map { ($0.jid, $0.name) })
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
