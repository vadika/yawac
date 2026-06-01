import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelGroupInfoTests: XCTestCase {

    private func makeVM() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }

    private func chat(_ jid: String, name: String = "G",
                      description: String? = nil) -> Chat {
        var c = Chat(jid: jid, name: name, lastMessage: "",
                     lastTimestamp: 0, unread: 0)
        c.groupDescription = description
        return c
    }

    func testApplyIncomingNameOnlyUpdatesName() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "Old", description: "desc")]
        vm.applyIncomingGroupInfo(chatJID: "g@g.us",
                                  name: "New", description: nil, at: Date())
        XCTAssertEqual(vm.chats.first?.name, "New")
        XCTAssertEqual(vm.chats.first?.groupDescription, "desc")
    }

    func testApplyIncomingDescriptionOnlyUpdatesDescription() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "G", description: "old")]
        vm.applyIncomingGroupInfo(chatJID: "g@g.us",
                                  name: nil, description: "new", at: Date())
        XCTAssertEqual(vm.chats.first?.name, "G")
        XCTAssertEqual(vm.chats.first?.groupDescription, "new")
    }

    func testApplyIncomingBothUpdates() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "Old", description: "old")]
        vm.applyIncomingGroupInfo(chatJID: "g@g.us",
                                  name: "New", description: "new", at: Date())
        XCTAssertEqual(vm.chats.first?.name, "New")
        XCTAssertEqual(vm.chats.first?.groupDescription, "new")
    }

    func testApplyIncomingNilBothNoop() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "G", description: "d")]
        vm.applyIncomingGroupInfo(chatJID: "g@g.us",
                                  name: nil, description: nil, at: Date())
        XCTAssertEqual(vm.chats.first?.name, "G")
        XCTAssertEqual(vm.chats.first?.groupDescription, "d")
    }

    func testApplyLocalGroupInfoEmptyDescriptionStoredAsNil() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "G", description: "old")]
        vm.applyLocalGroupInfo(chatJID: "g@g.us", name: nil, description: "")
        XCTAssertNil(vm.chats.first?.groupDescription)
    }
}
