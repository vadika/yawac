import XCTest
@testable import yawac

@MainActor
final class CVMReplyEditTargetTests: XCTestCase {

    private func makeMessage(id: String, fromMe: Bool = true) -> UIMessage {
        UIMessage(id: id,
                  chatJID: "1@s.whatsapp.net",
                  senderJID: "1@s.whatsapp.net",
                  fromMe: fromMe,
                  timestamp: Date(),
                  body: .text("hi"))
    }

    private func makeCVM() throws -> ConversationViewModel {
        let dbDir = NSTemporaryDirectory().appending("yawac-cvm-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        let client = try WAClient(dbPath: dbDir.appending("/state.db"))
        return ConversationViewModel(chatJID: "1@s.whatsapp.net", client: client)
    }

    func testStartReplyClearsEditTarget() throws {
        let vm = try makeCVM()
        vm.editTarget = makeMessage(id: "A")
        vm.startReply(to: makeMessage(id: "B"))
        XCTAssertNil(vm.editTarget)
        XCTAssertEqual(vm.replyTarget?.id, "B")
    }

    func testStartEditClearsReplyTarget() throws {
        let vm = try makeCVM()
        vm.replyTarget = makeMessage(id: "A")
        vm.startEdit(makeMessage(id: "B"))
        XCTAssertNil(vm.replyTarget)
        XCTAssertEqual(vm.editTarget?.id, "B")
    }

    func testCancelComposeClearsBoth() throws {
        let vm = try makeCVM()
        vm.replyTarget = makeMessage(id: "A")
        vm.cancelCompose()
        XCTAssertNil(vm.replyTarget)
        XCTAssertNil(vm.editTarget)
    }
}
