import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelEphemeralTests: XCTestCase {

    private func makeVM() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }

    private func chat(_ jid: String,
                      ephemeralSeconds: Int32 = 0) -> Chat {
        var c = Chat(jid: jid, name: jid, lastMessage: "",
                     lastTimestamp: 0, unread: 0)
        c.ephemeralExpirationSeconds = ephemeralSeconds
        return c
    }

    func testApplyEphemeralTimerUpdatesChat() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us")]
        vm.applyEphemeralTimer(chatJID: "g@g.us", seconds: 86_400)
        XCTAssertEqual(
            vm.chats.first { $0.jid == "g@g.us" }?.ephemeralExpirationSeconds,
            86_400)
    }

    func testApplyEphemeralTimerCanClearToOff() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", ephemeralSeconds: 604_800)]
        vm.applyEphemeralTimer(chatJID: "g@g.us", seconds: 0)
        XCTAssertEqual(
            vm.chats.first { $0.jid == "g@g.us" }?.ephemeralExpirationSeconds,
            0)
    }

    func testApplyEphemeralTimerUnknownChatNoop() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us")]
        vm.applyEphemeralTimer(chatJID: "other@g.us", seconds: 86_400)
        XCTAssertEqual(vm.chats.count, 1)
        XCTAssertEqual(vm.chats[0].ephemeralExpirationSeconds, 0)
    }

    func testMergeGroupsHydratesEphemeral() {
        let vm = makeVM()
        let bg = BridgeGroupModel.stub(jid: "g@g.us",
                                       amAdmin: true,
                                       meJID: "me@s.whatsapp.net",
                                       ephemeralExpirationSeconds: 604_800)
        vm.mergeGroups([bg])
        XCTAssertEqual(
            vm.chats.first { $0.jid == "g@g.us" }?.ephemeralExpirationSeconds,
            604_800)
    }

    func testMergeGroupsUpdatesEphemeralOnExistingChat() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", ephemeralSeconds: 86_400)]
        let bg = BridgeGroupModel.stub(jid: "g@g.us",
                                       amAdmin: true,
                                       meJID: "me@s.whatsapp.net",
                                       ephemeralExpirationSeconds: 7_776_000)
        vm.mergeGroups([bg])
        XCTAssertEqual(
            vm.chats.first { $0.jid == "g@g.us" }?.ephemeralExpirationSeconds,
            7_776_000)
    }
}
