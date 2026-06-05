import XCTest
@testable import yawac

/// Covers `SessionViewModel.isSelfChat` — the helper that gates the
/// "(You)" suffix on the self-chat in the sidebar and chat header.
///
/// The first case (nil client) exercises the early-return guard with
/// no harness. The remaining cases use a `StubSelfChatClient` that
/// overrides `ownJID` so the helper has a stable identity to compare
/// against, mirroring the `StubBackfillClient` pattern used by
/// `SessionViewModelBackfillTests`.
@MainActor
final class SessionViewModelSelfChatTests: XCTestCase {

    func testSelfChatReturnsFalseWithNilClient() {
        let svm = SessionViewModel()
        XCTAssertFalse(svm.isSelfChat("anyone@s.whatsapp.net"))
    }

    func testSelfChatReturnsFalseWithEmptyOwnJID() throws {
        let svm = SessionViewModel()
        svm.client = try StubSelfChatClient.make(ownJID: "")
        XCTAssertFalse(svm.isSelfChat("anyone@s.whatsapp.net"))
    }

    func testSelfChatReturnsTrueForOwnJID() throws {
        let svm = SessionViewModel()
        svm.client = try StubSelfChatClient.make(
            ownJID: "5550100@s.whatsapp.net")
        XCTAssertTrue(svm.isSelfChat("5550100@s.whatsapp.net"))
    }

    func testSelfChatReturnsFalseForOtherDirectJID() throws {
        let svm = SessionViewModel()
        svm.client = try StubSelfChatClient.make(
            ownJID: "5550100@s.whatsapp.net")
        XCTAssertFalse(svm.isSelfChat("5550200@s.whatsapp.net"))
    }

    func testSelfChatReturnsFalseForGroupJID() throws {
        let svm = SessionViewModel()
        svm.client = try StubSelfChatClient.make(
            ownJID: "5550100@s.whatsapp.net")
        XCTAssertFalse(svm.isSelfChat("12345-67890@g.us"))
    }
}

/// Minimal WAClient subclass that overrides `ownJID` for self-chat
/// identity tests. Goes through `super.init(dbPath:)` over a throwaway
/// temp directory to keep gomobile happy — the actual Go state is not
/// exercised by these tests; only the Swift-side computed property is.
@MainActor
final class StubSelfChatClient: WAClient {
    private let stubOwnJID: String

    override var ownJID: String { stubOwnJID }

    init(dbPath: String, ownJID: String) throws {
        self.stubOwnJID = ownJID
        try super.init(dbPath: dbPath)
    }

    static func make(ownJID: String) throws -> StubSelfChatClient {
        let dir = NSTemporaryDirectory()
            .appending("yawac-selfchat-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return try StubSelfChatClient(dbPath: dir + "/state.db",
                                      ownJID: ownJID)
    }
}
