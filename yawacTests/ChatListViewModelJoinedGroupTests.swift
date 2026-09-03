import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelJoinedGroupTests: XCTestCase {
    private func group(created: Int64) -> BridgeGroupModel {
        BridgeGroupModel(
            jid: "120363407507540222@g.us",
            name: "Helkyn valmennusryhmä 2026",
            topic: "",
            ownerJID: "12345@s.whatsapp.net",
            created: created,
            participants: [])
    }

    func testGroupSnapshotUsesCreationTimeInsteadOfEpoch() {
        let vm = ChatListViewModel(client: nil)
        vm.mergeGroups([group(created: 1_768_780_800)])

        XCTAssertEqual(vm.chats.first?.lastTimestamp, 1_768_780_800)
    }

    func testJoinedGroupUsesJoinNotificationTime() {
        let vm = ChatListViewModel(client: nil)
        vm.mergeJoinedGroup(
            group(created: 1_768_780_800),
            at: Date(timeIntervalSince1970: 1_777_478_400))

        XCTAssertEqual(vm.chats.first?.lastTimestamp, 1_777_478_400)
    }

    func testHistoryConversationAdvancesGroupPastCreationTimestamp() {
        let vm = ChatListViewModel(client: nil)
        vm.chats = [Chat(
            jid: "120363407507540222@g.us",
            name: "120363407507540222@g.us",
            lastMessage: "",
            lastTimestamp: 1_768_780_800,
            unread: 0)]

        vm.applyHistoryConversation(
            chatJID: "120363407507540222@g.us",
            name: "Helkyn valmennusryhmä 2026",
            at: Date(timeIntervalSince1970: 1_777_478_400))

        XCTAssertEqual(vm.chats.first?.name, "Helkyn valmennusryhmä 2026")
        XCTAssertEqual(vm.chats.first?.lastTimestamp, 1_777_478_400)
    }
}
