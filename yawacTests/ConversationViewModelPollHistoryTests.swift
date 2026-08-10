import XCTest
import SwiftData
@testable import yawac

/// Covers the historical-poll-vote consumer path (F90):
///   1. `ConversationViewModel.applyPollVote` correctly keys an
///      own-vote against `client.ownJID` so `mySelections(for:)`
///      returns the user's selected option hashes — the in-memory
///      branch fired by `ConversationView.event` when the chat is
///      open during the bridge sweep.
///   2. `ConversationViewModel.buildHistorySnapshot` hydrates
///      `pollVotes` from `PersistedPollVote` rows for visible poll
///      IDs — the cold-open branch fired when the chat was closed
///      during the sweep and the user opens it later.
@MainActor
final class ConversationViewModelPollHistoryTests: XCTestCase {

    private let ownJID = "11234567890@s.whatsapp.net"
    private let chatJID = "5550200@s.whatsapp.net"
    private let pollID = "POLL_MSG_1"

    // MARK: applyPollVote round-trip

    func testApplyPollVoteOwnSelectionSurfaces() async throws {
        let stub = try StubPollHistoryClient.make(ownJID: ownJID)
        let vm = ConversationViewModel(chatJID: chatJID, client: stub)

        vm.applyPollVote(pollMessageID: pollID,
                         voterJID: ownJID,
                         optionHashes: ["h1", "h2"])

        XCTAssertEqual(vm.mySelections(for: pollID), Set(["h1", "h2"]))
    }

    func testApplyPollVotePeerSelectionDoesNotSurfaceAsOwn() async throws {
        let stub = try StubPollHistoryClient.make(ownJID: ownJID)
        let vm = ConversationViewModel(chatJID: chatJID, client: stub)

        vm.applyPollVote(pollMessageID: pollID,
                         voterJID: "5550300@s.whatsapp.net",
                         optionHashes: ["h1"])

        XCTAssertEqual(vm.mySelections(for: pollID), Set())
    }

    func testApplyPollVoteReplacesPriorSelections() async throws {
        let stub = try StubPollHistoryClient.make(ownJID: ownJID)
        let vm = ConversationViewModel(chatJID: chatJID, client: stub)

        vm.applyPollVote(pollMessageID: pollID,
                         voterJID: ownJID,
                         optionHashes: ["h1"])
        vm.applyPollVote(pollMessageID: pollID,
                         voterJID: ownJID,
                         optionHashes: ["h2"])

        XCTAssertEqual(vm.mySelections(for: pollID), Set(["h2"]))
    }

    // MARK: buildHistorySnapshot hydration

    func testBuildHistorySnapshotHydratesOwnPollVote() async throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        let pollTimestamp = Date(timeIntervalSince1970: 1_729_000_000)
        context.insert(PersistedMessage(
            id: pollID,
            chatJID: chatJID,
            senderJID: chatJID,
            fromMe: false,
            timestamp: pollTimestamp,
            kind: "poll",
            text: "Lunch?"))
        context.insert(PersistedPollVote(
            chatJID: chatJID,
            pollMessageID: pollID,
            voterJID: ownJID,
            optionHashesJSON: "[\"h1\",\"h2\"]",
            timestamp: pollTimestamp.addingTimeInterval(60)))
        try context.save()

        let snap = await Task.detached { [chatJID, container] in
            ConversationViewModel.buildHistorySnapshot(
                chatJID: chatJID,
                container: container,
                canonicalize: { $0 },
                limit: 100)
        }.value

        XCTAssertTrue(
            snap.pollVotes[pollID]?["h1"]?.contains(ownJID) == true,
            "own vote on h1 should hydrate from PersistedPollVote")
        XCTAssertTrue(
            snap.pollVotes[pollID]?["h2"]?.contains(ownJID) == true,
            "own vote on h2 should hydrate from PersistedPollVote")
    }

    func testBuildHistorySnapshotIgnoresVotesForOffWindowPolls() async throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        // No PersistedMessage row for "ORPHAN_POLL" — vote should not
        // be hydrated since the snapshot only seeds for visible polls.
        context.insert(PersistedPollVote(
            chatJID: chatJID,
            pollMessageID: "ORPHAN_POLL",
            voterJID: ownJID,
            optionHashesJSON: "[\"h1\"]",
            timestamp: Date(timeIntervalSince1970: 1_729_000_000)))
        try context.save()

        let snap = await Task.detached { [chatJID, container] in
            ConversationViewModel.buildHistorySnapshot(
                chatJID: chatJID,
                container: container,
                canonicalize: { $0 },
                limit: 100)
        }.value

        XCTAssertNil(snap.pollVotes["ORPHAN_POLL"])
    }

    // MARK: keyset history pagination

    func testHistorySnapshotAndEarlierPagesStayBounded() async throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let jid = "pagination-(UUID().uuidString)@s.whatsapp.net"
        let base = Date(timeIntervalSince1970: 1_730_000_000)
        for index in 0..<8 {
            context.insert(PersistedMessage(
                id: "m\(index)", chatJID: jid, senderJID: jid,
                fromMe: false,
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                kind: "text", text: "message \(index)"))
        }
        try context.save()

        let first = await Task.detached { [container] in
            ConversationViewModel.buildHistorySnapshot(
                chatJID: jid, container: container,
                canonicalize: { $0 }, limit: 3)
        }.value

        XCTAssertEqual(first.messages.map(\.id), ["m5", "m6", "m7"])
        XCTAssertTrue(first.hasMoreStoredHistory)
        let firstCursor = try XCTUnwrap(first.olderCursor)

        let second = await Task.detached { [container] in
            ConversationViewModel.buildEarlierSnapshot(
                chatJID: jid, container: container,
                cursor: firstCursor, limit: 3)
        }.value
        XCTAssertEqual(second.messages.map(\.id), ["m2", "m3", "m4"])
        XCTAssertTrue(second.hasMoreStoredHistory)
        let secondCursor = try XCTUnwrap(second.olderCursor)

        let third = await Task.detached { [container] in
            ConversationViewModel.buildEarlierSnapshot(
                chatJID: jid, container: container,
                cursor: secondCursor, limit: 3)
        }.value
        XCTAssertEqual(third.messages.map(\.id), ["m0", "m1"])
        XCTAssertFalse(third.hasMoreStoredHistory)
    }

    func testHistoryCursorBreaksTimestampTiesWithoutGaps() async throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let jid = "pagination-tie-(UUID().uuidString)@s.whatsapp.net"
        let timestamp = Date(timeIntervalSince1970: 1_730_000_000)
        for index in 0..<6 {
            context.insert(PersistedMessage(
                id: "m\(index)", chatJID: jid, senderJID: jid,
                fromMe: false, timestamp: timestamp,
                kind: "text", text: "message \(index)"))
        }
        try context.save()

        let first = await Task.detached { [container] in
            ConversationViewModel.buildHistorySnapshot(
                chatJID: jid, container: container,
                canonicalize: { $0 }, limit: 2)
        }.value
        let firstCursor = try XCTUnwrap(first.olderCursor)
        let second = await Task.detached { [container] in
            ConversationViewModel.buildEarlierSnapshot(
                chatJID: jid, container: container,
                cursor: firstCursor, limit: 2)
        }.value
        let secondCursor = try XCTUnwrap(second.olderCursor)
        let third = await Task.detached { [container] in
            ConversationViewModel.buildEarlierSnapshot(
                chatJID: jid, container: container,
                cursor: secondCursor, limit: 2)
        }.value

        let allIDs = first.messages.map(\.id)
            + second.messages.map(\.id)
            + third.messages.map(\.id)
        XCTAssertEqual(Set(allIDs), Set((0..<6).map { "m\($0)" }))
        XCTAssertEqual(allIDs.count, 6)
        XCTAssertFalse(third.hasMoreStoredHistory)
    }

    // MARK: shared-media background snapshot

    func testChatMediaSnapshotAppliesLimitsButKeepsFullCounts() async throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let jid = "media-(UUID().uuidString)@s.whatsapp.net"
        let base = Date(timeIntervalSince1970: 1_740_000_000)

        for index in 0..<5 {
            let row = PersistedMessage(
                id: "image-\(index)", chatJID: jid, senderJID: jid,
                fromMe: false,
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                kind: "image")
            if index == 4 { row.starredAt = base.addingTimeInterval(20) }
            context.insert(row)
        }
        let document = PersistedMessage(
            id: "document", chatJID: jid, senderJID: jid,
            fromMe: false, timestamp: base.addingTimeInterval(10),
            kind: "document", mediaFileName: "report.pdf")
        document.starredAt = base.addingTimeInterval(21)
        context.insert(document)
        let revoked = PersistedMessage(
            id: "revoked", chatJID: jid, senderJID: jid,
            fromMe: false, timestamp: base.addingTimeInterval(30),
            kind: "image")
        revoked.revokedAt = base.addingTimeInterval(31)
        context.insert(revoked)
        try context.save()

        let snapshot = await Task.detached { [container] in
            ChatMediaViewModel.buildSnapshot(
                chatJID: jid, container: container, limit: 2)
        }.value

        XCTAssertEqual(snapshot.media.map(\.id), ["image-4", "image-3"])
        XCTAssertEqual(snapshot.mediaTotal, 5)
        XCTAssertEqual(snapshot.files.map(\.id), ["document"])
        XCTAssertEqual(snapshot.filesTotal, 1)
        XCTAssertEqual(snapshot.starred.map(\.id), ["document", "image-4"])
        XCTAssertEqual(snapshot.starredTotal, 2)
        XCTAssertEqual(snapshot.starred.first?.snippet, "report.pdf")
    }

    // MARK: sender mapping prewarm

    func testHistorySnapshotPrewarmsUniqueBareSenders() async throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let jid = "prewarm-(UUID().uuidString)@g.us"
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let senders = [
            "12345:1@lid", "12345:2@lid",
            "358400929611:7@s.whatsapp.net",
        ]
        for (index, sender) in senders.enumerated() {
            context.insert(PersistedMessage(
                id: "sender-\(index)", chatJID: jid, senderJID: sender,
                fromMe: false,
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                kind: "text", text: "message"))
        }
        try context.save()
        let recorder = JIDPrewarmRecorder()

        _ = await Task.detached { [container] in
            ConversationViewModel.buildHistorySnapshot(
                chatJID: jid, container: container,
                canonicalize: { $0 },
                prewarmJIDs: { recorder.record($0) },
                limit: 10)
        }.value

        XCTAssertEqual(recorder.values, Set([
            "12345@lid", "358400929611@s.whatsapp.net",
        ]))
    }

    // MARK: helpers

    private static func makeInMemoryContainer() throws -> ModelContainer {
        // Mirrors the app's ModelContainer construction in yawacApp.swift
        // (the four `@Model` types this app declares). isStoredInMemoryOnly
        // keeps each test hermetic — no on-disk store, no inter-test leak.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: PersistedMessage.self,
            PersistedChat.self,
            PersistedReaction.self,
            PersistedPollVote.self,
            configurations: config)
    }
}

private final class JIDPrewarmRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<String> = []

    func record(_ jids: [String]) {
        lock.lock()
        storage.formUnion(jids)
        lock.unlock()
    }

    var values: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Minimal WAClient subclass that overrides `ownJID` so the tests can
/// drive `mySelections(for:)` lookups against a stable identity. Same
/// pattern as `StubSelfChatClient` in `SessionViewModelSelfChatTests`.
@MainActor
final class StubPollHistoryClient: WAClient {
    private let stubOwnJID: String

    override var ownJID: String { stubOwnJID }

    init(dbPath: String, ownJID: String) throws {
        self.stubOwnJID = ownJID
        try super.init(dbPath: dbPath)
    }

    static func make(ownJID: String) throws -> StubPollHistoryClient {
        let dir = NSTemporaryDirectory()
            .appending("yawac-pollhistory-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return try StubPollHistoryClient(dbPath: dir + "/state.db",
                                         ownJID: ownJID)
    }
}
