import XCTest
@testable import yawac

@MainActor
final class CVMForwardTests: XCTestCase {

    private func makeCVM() throws -> ConversationViewModel {
        let dir = NSTemporaryDirectory().appending("yawac-fwd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let client = try WAClient(dbPath: dir.appending("/state.db"))
        return ConversationViewModel(chatJID: "1@s.whatsapp.net", client: client)
    }

    private func text(_ id: String) -> UIMessage {
        UIMessage(id: id, chatJID: "1@s.whatsapp.net", senderJID: "1@s.whatsapp.net",
                  fromMe: false, timestamp: Date(), body: .text("hi"))
    }

    private func mediaNoRefNoCaption(_ id: String) -> UIMessage {
        UIMessage(id: id, chatJID: "1@s.whatsapp.net", senderJID: "1@s.whatsapp.net",
                  fromMe: false, timestamp: Date(),
                  body: .media(kind: "image", caption: nil, fileName: nil, localPath: nil))
    }

    private func systemMsg(_ id: String) -> UIMessage {
        UIMessage(id: id, chatJID: "1@s.whatsapp.net", senderJID: "system",
                  fromMe: false, timestamp: Date(), body: .system("x"))
    }

    func testCanForwardText() throws {
        let vm = try makeCVM()
        XCTAssertTrue(vm.canForward(text("A")))
    }

    func testCannotForwardSystem() throws {
        let vm = try makeCVM()
        XCTAssertFalse(vm.canForward(systemMsg("A")))
    }

    func testCannotForwardMediaWithoutRefOrCaption() throws {
        let vm = try makeCVM()
        // No PersistedMessage row exists for this id → no ref; no caption.
        XCTAssertFalse(vm.canForward(mediaNoRefNoCaption("A")))
    }

    func testBeginForwardEntersModeAndPreselects() throws {
        let vm = try makeCVM()
        vm.beginForward(text("A"))
        XCTAssertTrue(vm.forwardSelecting)
        XCTAssertEqual(vm.forwardSelection, ["A"])
    }

    func testBeginForwardSkipsPreselectWhenNotForwardable() throws {
        let vm = try makeCVM()
        vm.beginForward(systemMsg("A"))
        XCTAssertTrue(vm.forwardSelecting)
        XCTAssertTrue(vm.forwardSelection.isEmpty)
    }

    func testToggleAddsAndRemoves() throws {
        let vm = try makeCVM()
        vm.beginForward(text("A"))
        vm.messages = [text("A"), text("B")]
        vm.toggleForward("B")
        XCTAssertEqual(vm.forwardSelection, ["A", "B"])
        vm.toggleForward("A")
        XCTAssertEqual(vm.forwardSelection, ["B"])
    }

    func testCancelForwardClears() throws {
        let vm = try makeCVM()
        vm.beginForward(text("A"))
        vm.cancelForward()
        XCTAssertFalse(vm.forwardSelecting)
        XCTAssertTrue(vm.forwardSelection.isEmpty)
    }
}
