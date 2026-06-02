import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelGroupParticipantsTests: XCTestCase {
    private func makeVM() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }

    func testApplyAddPublishesTick() {
        let vm = makeVM()
        let before = vm.groupParticipantsTick
        vm.applyGroupParticipantsChange(
            chatJID: "g@g.us", action: "add",
            jids: ["1@s.whatsapp.net"], at: Date())
        XCTAssertNotEqual(vm.groupParticipantsTick, before)
        XCTAssertEqual(vm.lastParticipantsChange?.chatJID, "g@g.us")
        XCTAssertEqual(vm.lastParticipantsChange?.action, "add")
        XCTAssertEqual(vm.lastParticipantsChange?.jids,
                       ["1@s.whatsapp.net"])
    }

    func testApplyPromotePublishesTick() {
        let vm = makeVM()
        let before = vm.groupParticipantsTick
        vm.applyGroupParticipantsChange(
            chatJID: "g@g.us", action: "promote",
            jids: ["1@s.whatsapp.net"], at: Date())
        XCTAssertNotEqual(vm.groupParticipantsTick, before)
        XCTAssertEqual(vm.lastParticipantsChange?.action, "promote")
    }

    func testApplyEmptyJIDsStillTicks() {
        let vm = makeVM()
        let before = vm.groupParticipantsTick
        vm.applyGroupParticipantsChange(
            chatJID: "g@g.us", action: "remove",
            jids: [], at: Date())
        XCTAssertNotEqual(vm.groupParticipantsTick, before)
    }
}
