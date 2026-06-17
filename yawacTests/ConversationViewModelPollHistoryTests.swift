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
