import XCTest
@testable import yawac

@MainActor
final class ConversationFindStateTests: XCTestCase {

    private var tmpDB: URL!
    private var idx: MessageIndex!

    override func setUp() async throws {
        try await super.setUp()
        // Warm up the structured-concurrency timer subsystem (see
        // MessageSearchViewModelTests for rationale).
        try await Task.sleep(for: .milliseconds(1))
        tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-find-\(UUID().uuidString).sqlite")
        idx = MessageIndex(storeURL: tmpDB)
        idx.ensureSchema()
        let jid = "A@s.whatsapp.net"
        idx.upsert(.init(messageID: "a", chatJID: jid, timestamp: 10,
                         kind: "text",
                         text: "alpha", caption: "", quoted: "", sender: "",
                         fromMe: false, senderJID: ""))
        idx.upsert(.init(messageID: "b", chatJID: jid, timestamp: 20,
                         kind: "text",
                         text: "alpha beta", caption: "", quoted: "", sender: "",
                         fromMe: false, senderJID: ""))
        idx.upsert(.init(messageID: "c", chatJID: jid, timestamp: 30,
                         kind: "text",
                         text: "alpha gamma", caption: "", quoted: "", sender: "",
                         fromMe: false, senderJID: ""))
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDB)
        try await super.tearDown()
    }

    private func makeVM() throws -> ConversationViewModel {
        let dir = NSTemporaryDirectory().appending("yawac-cfs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let client = try WAClient(dbPath: dir.appending("/state.db"))
        let vm = ConversationViewModel(chatJID: "A@s.whatsapp.net", client: client)
        vm.messageIndex = idx
        return vm
    }

    func testToggleFindActiveClearsState() throws {
        let vm = try makeVM()
        vm.findActive = true
        vm.findQuery = "alpha"
        vm.findActive = false
        XCTAssertEqual(vm.findQuery, "")
        XCTAssertTrue(vm.findHits.isEmpty)
        XCTAssertEqual(vm.findCurrentIdx, 0)
    }

    func testRunFindPopulatesHits() async throws {
        let vm = try makeVM()
        vm.findQuery = "alpha"
        await vm.runFindForTest()
        XCTAssertEqual(vm.findHits.map(\.messageID), ["a", "b", "c"])
    }

    func testNextAndPrevWrap() async throws {
        let vm = try makeVM()
        vm.findQuery = "alpha"
        await vm.runFindForTest()
        XCTAssertEqual(vm.findCurrentIdx, 0)
        vm.findNext()
        XCTAssertEqual(vm.findCurrentIdx, 1)
        vm.findNext(); vm.findNext()           // wrap
        XCTAssertEqual(vm.findCurrentIdx, 0)
        vm.findPrev()                          // wrap back
        XCTAssertEqual(vm.findCurrentIdx, 2)
    }

    func testFindHitIDsReflectsHits() async throws {
        let vm = try makeVM()
        vm.findQuery = "alpha"
        await vm.runFindForTest()
        XCTAssertEqual(vm.findHitIDs, ["a", "b", "c"])
    }
}
