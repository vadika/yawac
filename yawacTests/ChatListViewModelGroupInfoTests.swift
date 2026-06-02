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

    // MARK: - T29: joinApprovalMode wire-up

    func testApplyIncomingJoinApprovalModeOnFlipsFlag() {
        let vm = makeVM()
        var c = chat("g@g.us")
        c.joinApprovalMode = false
        vm.chats = [c]
        vm.applyIncomingJoinApprovalMode(chatJID: "g@g.us", on: true)
        XCTAssertTrue(vm.chats.first?.joinApprovalMode ?? false)
    }

    func testApplyIncomingJoinApprovalModeOffFlipsFlag() {
        let vm = makeVM()
        var c = chat("g@g.us")
        c.joinApprovalMode = true
        vm.chats = [c]
        vm.applyIncomingJoinApprovalMode(chatJID: "g@g.us", on: false)
        XCTAssertFalse(vm.chats.first?.joinApprovalMode ?? true)
    }

    func testApplyIncomingJoinApprovalModeUnknownChatNoop() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us")]
        // Should not crash or grow `chats` for an unknown JID.
        vm.applyIncomingJoinApprovalMode(chatJID: "other@g.us", on: true)
        XCTAssertEqual(vm.chats.count, 1)
        XCTAssertFalse(vm.chats[0].joinApprovalMode)
    }

    func testPendingRequestsChipGatedByAmAdmin() {
        let vm = makeVM()
        let session = SessionViewModel()
        vm.session = session
        var c = chat("g@g.us")
        c.amAdmin = false
        vm.chats = [c]
        session.joinRequestStore.set(chatJID: "g@g.us", count: 3)
        // Non-admin: no chip even with a non-zero count.
        XCTAssertNil(vm.pendingRequestsChip(for: vm.chats[0]))
    }

    func testPendingRequestsChipShownForAdminWithPending() {
        let vm = makeVM()
        let session = SessionViewModel()
        vm.session = session
        var c = chat("g@g.us")
        c.amAdmin = true
        vm.chats = [c]
        session.joinRequestStore.set(chatJID: "g@g.us", count: 2)
        XCTAssertEqual(vm.pendingRequestsChip(for: vm.chats[0]), 2)
    }

    func testPendingRequestsChipHiddenWhenAdminButZeroPending() {
        let vm = makeVM()
        let session = SessionViewModel()
        vm.session = session
        var c = chat("g@g.us")
        c.amAdmin = true
        vm.chats = [c]
        // No entry in the store at all → nil.
        XCTAssertNil(vm.pendingRequestsChip(for: vm.chats[0]))
        // Explicit zero → still nil.
        session.joinRequestStore.set(chatJID: "g@g.us", count: 0)
        XCTAssertNil(vm.pendingRequestsChip(for: vm.chats[0]))
    }
}
