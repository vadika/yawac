import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelGroupMemberAddModeTests: XCTestCase {

    private func makeVM() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }

    private func chat(_ jid: String, isAllMemberAdd: Bool = false) -> Chat {
        var c = Chat(jid: jid, name: jid, lastMessage: "",
                     lastTimestamp: 0, unread: 0)
        c.isAllMemberAdd = isAllMemberAdd
        return c
    }

    // MARK: - applyGroupMemberAddMode

    func testApplyGroupMemberAddModeUpdatesChat() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us")]
        vm.applyGroupMemberAddMode(chatJID: "g@g.us", allMembersCanAdd: true)
        XCTAssertTrue(vm.chats.first { $0.jid == "g@g.us" }?.isAllMemberAdd ?? false)
        vm.applyGroupMemberAddMode(chatJID: "g@g.us", allMembersCanAdd: false)
        XCTAssertFalse(vm.chats.first { $0.jid == "g@g.us" }?.isAllMemberAdd ?? true)
    }

    func testApplyGroupMemberAddModeUnknownChatNoop() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us")]
        vm.applyGroupMemberAddMode(chatJID: "other@g.us", allMembersCanAdd: true)
        XCTAssertEqual(vm.chats.count, 1)
        XCTAssertFalse(vm.chats[0].isAllMemberAdd)
    }

    func testApplyGroupMemberAddModeOnEmptyListNoop() {
        let vm = makeVM()
        vm.applyGroupMemberAddMode(chatJID: "unknown@g.us", allMembersCanAdd: true)
        XCTAssertTrue(vm.chats.isEmpty)
    }

    // MARK: - mergeGroups hydration

    func testMergeGroupsHydratesMemberAddModeOnFreshInsert() {
        let vm = makeVM()
        let bg = BridgeGroupModel.stub(jid: "g@g.us",
                                       amAdmin: true,
                                       meJID: "me@s.whatsapp.net",
                                       isAllMemberAdd: true)
        vm.mergeGroups([bg])
        let c = vm.chats.first { $0.jid == "g@g.us" }
        XCTAssertEqual(c?.isAllMemberAdd, true)
    }

    func testMergeGroupsRefreshesMemberAddModeOnExistingChat() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", isAllMemberAdd: false)]
        let bg = BridgeGroupModel.stub(jid: "g@g.us",
                                       amAdmin: true,
                                       meJID: "me@s.whatsapp.net",
                                       isAllMemberAdd: true)
        vm.mergeGroups([bg])
        let c = vm.chats.first { $0.jid == "g@g.us" }
        XCTAssertEqual(c?.isAllMemberAdd, true)
    }

    func testMergeGroupsCanClearMemberAddModeOnExistingChat() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", isAllMemberAdd: true)]
        let bg = BridgeGroupModel.stub(jid: "g@g.us",
                                       amAdmin: true,
                                       meJID: "me@s.whatsapp.net",
                                       isAllMemberAdd: false)
        vm.mergeGroups([bg])
        let c = vm.chats.first { $0.jid == "g@g.us" }
        XCTAssertEqual(c?.isAllMemberAdd, false)
    }

    // MARK: - JSON round-trip

    func testBridgeGroupModelDecodesIsAllMemberAdd() throws {
        let json = #"""
        {
            "jid": "g@g.us",
            "name": "Test",
            "topic": "",
            "owner_jid": "me@s.whatsapp.net",
            "created": 0,
            "participants": [],
            "is_all_member_add": true
        }
        """#
        let bg = try JSONDecoder().decode(BridgeGroupModel.self,
                                          from: Data(json.utf8))
        XCTAssertTrue(bg.isAllMemberAdd)
    }

    func testBridgeGroupModelMissingIsAllMemberAddDefaultsFalse() throws {
        let json = #"""
        {
            "jid": "g@g.us",
            "name": "Test",
            "topic": "",
            "owner_jid": "me@s.whatsapp.net",
            "created": 0,
            "participants": []
        }
        """#
        let bg = try JSONDecoder().decode(BridgeGroupModel.self,
                                          from: Data(json.utf8))
        XCTAssertFalse(bg.isAllMemberAdd)
    }
}
