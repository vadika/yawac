import XCTest
@testable import yawac

@MainActor
final class MessageSearchViewModelTests: XCTestCase {

    private var tmpDB: URL!
    private var idx: MessageIndex!

    override func setUp() async throws {
        try await super.setUp()
        // Warm up the structured-concurrency timer subsystem — first
        // Task.sleep on this hardware (M-series + Xcode 26 SDK) has a
        // ~400ms cold-start that swamps a 30ms debounce window.
        try await Task.sleep(for: .milliseconds(1))
        tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-search-\(UUID().uuidString).sqlite")
        idx = MessageIndex(storeURL: tmpDB)
        idx.ensureSchema()
        idx.upsert(.init(messageID: "m1", chatJID: "A@s.whatsapp.net",
                         timestamp: 10, kind: "text",
                         text: "Hello Finland", caption: "",
                         quoted: "", sender: "Alice"))
        idx.upsert(.init(messageID: "m2", chatJID: "B@s.whatsapp.net",
                         timestamp: 20, kind: "text",
                         text: "Hello world", caption: "",
                         quoted: "", sender: "Bob"))
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDB)
        try await super.tearDown()
    }

    func testDebouncedGlobalReturnsResults() async throws {
        let vm = MessageSearchViewModel(index: idx, debounceMs: 30)
        vm.query = "hello"
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(vm.globalHits.count, 2)
    }

    func testInChatFiltersByJID() async throws {
        let vm = MessageSearchViewModel(index: idx, debounceMs: 30)
        await vm.runInChat(jid: "A@s.whatsapp.net", query: "hello")
        XCTAssertEqual(vm.inChatHits.count, 1)
        XCTAssertEqual(vm.inChatHits.first?.chatJID, "A@s.whatsapp.net")
    }

    func testNewQueryCancelsPrior() async throws {
        let vm = MessageSearchViewModel(index: idx, debounceMs: 30)
        vm.query = "hello"
        vm.query = "finland"
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(vm.globalHits.map(\.messageID), ["m1"],
                       "prior debounced query must be cancelled")
    }

    func testEmptyQueryClearsResults() async throws {
        let vm = MessageSearchViewModel(index: idx, debounceMs: 30)
        vm.query = "hello"
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(vm.globalHits.isEmpty)
        vm.query = ""
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(vm.globalHits.isEmpty)
    }
}
