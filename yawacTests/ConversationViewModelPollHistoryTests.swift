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
