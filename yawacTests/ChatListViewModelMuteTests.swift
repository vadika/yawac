import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelMuteTests: XCTestCase {

    private func makeVM() -> ChatListViewModel {
        // No client / no context — pure helpers don't need either.
        ChatListViewModel(client: nil, context: nil)
    }

    private func seed(_ vm: ChatListViewModel, _ chats: [Chat]) {
        vm.chats = chats
    }

    private func chat(_ jid: String, mutedUntil: Date? = nil,
                      unread: Int = 0) -> Chat {
        var c = Chat(jid: jid, name: jid, lastMessage: "",
                     lastTimestamp: 0, unread: unread)
        c.mutedUntil = mutedUntil
        return c
    }

    func testIsMutedNilReturnsFalse() {
        let vm = makeVM()
        seed(vm, [chat("a@s.whatsapp.net")])
        XCTAssertFalse(vm.isMuted("a@s.whatsapp.net", now: Date()))
    }

    func testIsMutedFutureReturnsTrue() {
        let vm = makeVM()
        let until = Date().addingTimeInterval(3600)
        seed(vm, [chat("a@s.whatsapp.net", mutedUntil: until)])
        XCTAssertTrue(vm.isMuted("a@s.whatsapp.net", now: Date()))
    }

    func testIsMutedPastReturnsFalse() {
        let vm = makeVM()
        let until = Date().addingTimeInterval(-3600)
        seed(vm, [chat("a@s.whatsapp.net", mutedUntil: until)])
        XCTAssertFalse(vm.isMuted("a@s.whatsapp.net", now: Date()))
    }

    func testApplyLocalMuteSetsMutedUntil() {
        let vm = makeVM()
        seed(vm, [chat("a@s.whatsapp.net")])
        let until = Date().addingTimeInterval(3600)
        vm.applyLocalMute(chatJID: "a@s.whatsapp.net", mutedUntil: until)
        XCTAssertEqual(vm.chats.first?.mutedUntil, until)
    }

    func testApplyLocalMuteNilUnmutes() {
        let vm = makeVM()
        let until = Date().addingTimeInterval(3600)
        seed(vm, [chat("a@s.whatsapp.net", mutedUntil: until)])
        vm.applyLocalMute(chatJID: "a@s.whatsapp.net", mutedUntil: nil)
        XCTAssertNil(vm.chats.first?.mutedUntil)
    }

    func testIsMutedForNotificationNonMuted() {
        let vm = makeVM()
        seed(vm, [chat("a@s.whatsapp.net")])
        let msg = BridgeMessage.stubText(chatJID: "a@s.whatsapp.net", text: "hi")
        XCTAssertFalse(vm.isMutedForNotification(chatJID: "a@s.whatsapp.net",
                                                 message: msg))
    }

    func testIsMutedForNotificationMutedNoMention() {
        let vm = makeVM()
        let until = Date().addingTimeInterval(3600)
        seed(vm, [chat("group@g.us", mutedUntil: until)])
        let msg = BridgeMessage.stubText(chatJID: "group@g.us", text: "hello")
        XCTAssertTrue(vm.isMutedForNotification(chatJID: "group@g.us",
                                                message: msg,
                                                ownPhoneDigits: "5550100"))
    }

    func testIsMutedForNotificationMentionPierces() {
        let vm = makeVM()
        let until = Date().addingTimeInterval(3600)
        seed(vm, [chat("group@g.us", mutedUntil: until)])
        let msg = BridgeMessage.stubText(chatJID: "group@g.us",
                                         text: "ping @5550100 plz")
        XCTAssertFalse(vm.isMutedForNotification(chatJID: "group@g.us",
                                                 message: msg,
                                                 ownPhoneDigits: "5550100"))
    }
}

private extension BridgeMessage {
    /// Minimal text-only stub for notification-gate tests.
    static func stubText(chatJID: String, text: String) -> BridgeMessage {
        BridgeMessage(id: UUID().uuidString,
                      chatJID: chatJID,
                      senderJID: "x@s.whatsapp.net",
                      senderPushName: nil,
                      fromMe: false,
                      timestamp: Int64(Date().timeIntervalSince1970),
                      kind: "text",
                      text: text,
                      media: nil,
                      poll: nil,
                      quoted: nil,
                      isForwarded: false,
                      location: nil,
                      locationSequence: nil,
                      contact: nil,
                      isViewOnce: false)
    }
}
