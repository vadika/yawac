import XCTest
@testable import yawac

@MainActor
final class ChatListBlockArchiveTests: XCTestCase {

    private func makeVM() -> ChatListViewModel {
        // nil client + nil context: loadChats no-ops; we seed chats directly
        // and exercise the in-memory reconcile paths.
        ChatListViewModel(client: nil, context: nil)
    }

    private func chat(_ jid: String, name: String) -> Chat {
        Chat(jid: jid, name: name, lastMessage: "", lastTimestamp: 0, unread: 0)
    }

    func testApplyIncomingArchiveSetsAndClears() {
        let vm = makeVM()
        vm.chats = [chat("1@s.whatsapp.net", name: "A")]
        vm.applyIncomingArchive(chatJID: "1@s.whatsapp.net", archived: true)
        XCTAssertNotNil(vm.chats[0].archivedAt)
        vm.applyIncomingArchive(chatJID: "1@s.whatsapp.net", archived: false)
        XCTAssertNil(vm.chats[0].archivedAt)
    }

    func testApplyIncomingContactRenames() {
        let vm = makeVM()
        vm.chats = [chat("1@s.whatsapp.net", name: "1@s.whatsapp.net")]
        vm.applyIncomingContact(jid: "1@s.whatsapp.net", fullName: "Alice")
        XCTAssertEqual(vm.chats[0].name, "Alice")
    }

    func testApplyIncomingContactIgnoresEmptyName() {
        let vm = makeVM()
        vm.chats = [chat("1@s.whatsapp.net", name: "Keep")]
        vm.applyIncomingContact(jid: "1@s.whatsapp.net", fullName: "")
        XCTAssertEqual(vm.chats[0].name, "Keep")
    }

    func testApplyIncomingDeleteRemovesFromList() {
        let vm = makeVM()
        vm.chats = [chat("1@s.whatsapp.net", name: "A"), chat("2@s.whatsapp.net", name: "B")]
        vm.applyIncomingDelete(chatJID: "1@s.whatsapp.net")
        XCTAssertEqual(vm.chats.map(\.jid), ["2@s.whatsapp.net"])
    }
}
