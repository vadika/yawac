import XCTest
@testable import yawac

@MainActor
final class CVMPendingStashTests: XCTestCase {

    private func makeCVM() throws -> ConversationViewModel {
        let dbDir = NSTemporaryDirectory().appending("yawac-stash-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        let client = try WAClient(dbPath: dbDir.appending("/state.db"))
        return ConversationViewModel(chatJID: "1@s.whatsapp.net", client: client)
    }

    private func makeMessage(id: String) -> UIMessage {
        UIMessage(id: id,
                  chatJID: "1@s.whatsapp.net",
                  senderJID: "1@s.whatsapp.net",
                  fromMe: true,
                  timestamp: Date(),
                  body: .text("old"))
    }

    func testIncomingEditAppliesWhenRowPresent() throws {
        let vm = try makeCVM()
        vm.messages = [makeMessage(id: "M1")]
        vm.applyIncomingEdit(chatJID: vm.chatJID, messageID: "M1",
                             newText: "new", at: Date())
        if case .text(let t) = vm.messages[0].body {
            XCTAssertEqual(t, "new")
        } else {
            XCTFail("body not text")
        }
        XCTAssertNotNil(vm.messages[0].editedAt)
        XCTAssertEqual(vm.pendingEditsCount, 0)
    }

    func testIncomingEditStashesWhenRowMissing() throws {
        let vm = try makeCVM()
        vm.applyIncomingEdit(chatJID: vm.chatJID, messageID: "M1",
                             newText: "new", at: Date())
        XCTAssertEqual(vm.pendingEditsCount, 1)
        vm.messages = [makeMessage(id: "M1")]
        vm.replayPendingForLoadedRows()
        if case .text(let t) = vm.messages[0].body {
            XCTAssertEqual(t, "new")
        } else {
            XCTFail("body not text after replay")
        }
        XCTAssertEqual(vm.pendingEditsCount, 0)
    }

    func testIncomingRevokeStashesWhenRowMissing() throws {
        let vm = try makeCVM()
        vm.applyIncomingRevoke(chatJID: vm.chatJID, messageID: "M1",
                               revokedBy: "1@s.whatsapp.net", at: Date())
        XCTAssertEqual(vm.pendingRevokesCount, 1)
        vm.messages = [makeMessage(id: "M1")]
        vm.replayPendingForLoadedRows()
        XCTAssertNotNil(vm.messages[0].revokedAt)
        XCTAssertEqual(vm.pendingRevokesCount, 0)
    }

    func testStashLRUCap() throws {
        let vm = try makeCVM()
        for i in 0..<300 {
            vm.applyIncomingEdit(chatJID: vm.chatJID,
                                 messageID: "M\(i)", newText: "x", at: Date())
        }
        XCTAssertLessThanOrEqual(vm.pendingEditsCount, 256)
    }
}
