import XCTest
@testable import yawac

@MainActor
final class FakeWAClient: WAClient {
    var cannedPollResult: BridgeSendPollResult?
    var pollError: Error?
    var lastPollQuestion: String?
    var lastPollOptions: [String]?
    var lastPollSelectable: Int?

    static func make() throws -> FakeWAClient {
        let dir = NSTemporaryDirectory().appending("yawac-fake-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return try FakeWAClient(dbPath: dir + "/state.db")
    }

    override func sendPollCreation(_ chatJID: String,
                                   question: String,
                                   options: [String],
                                   selectableCount: Int) throws
        -> BridgeSendPollResult
    {
        lastPollQuestion = question
        lastPollOptions = options
        lastPollSelectable = selectableCount
        if let pollError { throw pollError }
        guard let r = cannedPollResult else {
            throw NSError(domain: "fake", code: 0)
        }
        return r
    }
}

@MainActor
final class ConversationViewModelPollCreateTests: XCTestCase {

    private func makeVM(client: WAClient) -> ConversationViewModel {
        ConversationViewModel(chatJID: "12@s.whatsapp.net", client: client)
    }

    func testSendPollTrimsAndDropsEmpty() async throws {
        let fake = try FakeWAClient.make()
        fake.cannedPollResult = BridgeSendPollResult(
            messageID: "M1",
            timestamp: 100,
            poll: BridgePoll(
                question: "Q",
                options: [
                    BridgePollOption(name: "A", hash: "ha"),
                    BridgePollOption(name: "B", hash: "hb"),
                ],
                selectableCount: 1))
        let vm = makeVM(client: fake)

        await vm.sendPoll(question: "  Q  ",
                          options: ["A", "  ", "B", ""],
                          allowMultiple: false)

        XCTAssertEqual(fake.lastPollQuestion, "Q")
        XCTAssertEqual(fake.lastPollOptions, ["A", "B"])
        XCTAssertEqual(fake.lastPollSelectable, 1)
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.id, "M1")
    }

    func testSendPollMultiSetsZeroSelectable() async throws {
        let fake = try FakeWAClient.make()
        fake.cannedPollResult = BridgeSendPollResult(
            messageID: "M2", timestamp: 100,
            poll: BridgePoll(question: "Q",
                             options: [
                                BridgePollOption(name: "A", hash: "ha"),
                                BridgePollOption(name: "B", hash: "hb"),
                             ],
                             selectableCount: 0))
        let vm = makeVM(client: fake)
        await vm.sendPoll(question: "Q",
                          options: ["A", "B"],
                          allowMultiple: true)
        XCTAssertEqual(fake.lastPollSelectable, 0)
    }

    func testSendPollNoopOnTooFewOptions() async throws {
        let fake = try FakeWAClient.make()
        let vm = makeVM(client: fake)
        await vm.sendPoll(question: "Q",
                          options: ["A", "   "],
                          allowMultiple: false)
        XCTAssertNil(fake.lastPollQuestion)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func testSendPollNoopOnEmptyQuestion() async throws {
        let fake = try FakeWAClient.make()
        let vm = makeVM(client: fake)
        await vm.sendPoll(question: "   ",
                          options: ["A", "B"],
                          allowMultiple: false)
        XCTAssertNil(fake.lastPollQuestion)
    }

    func testSendPollNoopOnTooManyOptions() async throws {
        let fake = try FakeWAClient.make()
        let vm = makeVM(client: fake)
        let thirteen = (1...13).map { "Option \($0)" }
        await vm.sendPoll(question: "Q",
                          options: thirteen,
                          allowMultiple: false)
        XCTAssertNil(fake.lastPollQuestion)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func testSendPollOnErrorSetsTransientError() async throws {
        let fake = try FakeWAClient.make()
        fake.pollError = NSError(domain: "x", code: 1)
        let vm = makeVM(client: fake)
        vm.showPollComposer = true
        await vm.sendPoll(question: "Q",
                          options: ["A", "B"],
                          allowMultiple: false)
        XCTAssertNotNil(vm.transientError)
        XCTAssertTrue(vm.messages.isEmpty)
    }
}
