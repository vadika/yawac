import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelGroupAnnounceLockedTests: XCTestCase {

    private func makeVM() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }

    private func chat(_ jid: String,
                      isAnnounce: Bool = false,
                      isLocked: Bool = false) -> Chat {
        var c = Chat(jid: jid, name: jid, lastMessage: "",
                     lastTimestamp: 0, unread: 0)
        c.isAnnounce = isAnnounce
        c.isLocked = isLocked
        return c
    }

    // MARK: - applyGroupAnnounce

    func testApplyGroupAnnounceUpdatesChat() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us")]
        vm.applyGroupAnnounce(chatJID: "g@g.us", on: true)
        XCTAssertTrue(vm.chats.first { $0.jid == "g@g.us" }?.isAnnounce ?? false)
        vm.applyGroupAnnounce(chatJID: "g@g.us", on: false)
        XCTAssertFalse(vm.chats.first { $0.jid == "g@g.us" }?.isAnnounce ?? true)
    }

    func testApplyGroupAnnounceUnknownChatNoop() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us")]
        vm.applyGroupAnnounce(chatJID: "other@g.us", on: true)
        XCTAssertEqual(vm.chats.count, 1)
        XCTAssertFalse(vm.chats[0].isAnnounce)
    }

    // MARK: - applyGroupLocked

    func testApplyGroupLockedUpdatesChat() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us")]
        vm.applyGroupLocked(chatJID: "g@g.us", on: true)
        XCTAssertTrue(vm.chats.first { $0.jid == "g@g.us" }?.isLocked ?? false)
        vm.applyGroupLocked(chatJID: "g@g.us", on: false)
        XCTAssertFalse(vm.chats.first { $0.jid == "g@g.us" }?.isLocked ?? true)
    }

    func testApplyGroupLockedUnknownChatNoop() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us")]
        vm.applyGroupLocked(chatJID: "other@g.us", on: true)
        XCTAssertEqual(vm.chats.count, 1)
        XCTAssertFalse(vm.chats[0].isLocked)
    }

    func testApplyOnEmptyListNoop() {
        let vm = makeVM()
        vm.applyGroupAnnounce(chatJID: "unknown@g.us", on: true)
        vm.applyGroupLocked(chatJID: "unknown@g.us", on: true)
        XCTAssertTrue(vm.chats.isEmpty)
    }

    // MARK: - mergeGroups hydration

    func testMergeGroupsHydratesAnnounceAndLockedOnFreshInsert() {
        let vm = makeVM()
        let bg = BridgeGroupModel.stub(jid: "g@g.us",
                                       amAdmin: true,
                                       meJID: "me@s.whatsapp.net",
                                       isAnnounce: true,
                                       isLocked: true)
        vm.mergeGroups([bg])
        let c = vm.chats.first { $0.jid == "g@g.us" }
        XCTAssertEqual(c?.isAnnounce, true)
        XCTAssertEqual(c?.isLocked, true)
    }

    func testMergeGroupsRefreshesAnnounceAndLockedOnExistingChat() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", isAnnounce: false, isLocked: false)]
        let bg = BridgeGroupModel.stub(jid: "g@g.us",
                                       amAdmin: true,
                                       meJID: "me@s.whatsapp.net",
                                       isAnnounce: true,
                                       isLocked: true)
        vm.mergeGroups([bg])
        let c = vm.chats.first { $0.jid == "g@g.us" }
        XCTAssertEqual(c?.isAnnounce, true)
        XCTAssertEqual(c?.isLocked, true)
    }

    func testMergeGroupsCanClearAnnounceAndLockedOnExistingChat() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", isAnnounce: true, isLocked: true)]
        let bg = BridgeGroupModel.stub(jid: "g@g.us",
                                       amAdmin: true,
                                       meJID: "me@s.whatsapp.net",
                                       isAnnounce: false,
                                       isLocked: false)
        vm.mergeGroups([bg])
        let c = vm.chats.first { $0.jid == "g@g.us" }
        XCTAssertEqual(c?.isAnnounce, false)
        XCTAssertEqual(c?.isLocked, false)
    }
}
