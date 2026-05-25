import XCTest
@testable import yawac

final class MessageLifecycleTests: XCTestCase {
    private func msg(fromMe: Bool,
                     body: UIMessage.Body = .text("hi"),
                     ageSec: TimeInterval,
                     revokedAt: Date? = nil,
                     locallyDeleted: Bool = false) -> UIMessage {
        var m = UIMessage(id: "X",
                          chatJID: "1@s.whatsapp.net",
                          senderJID: "1@s.whatsapp.net",
                          fromMe: fromMe,
                          timestamp: Date().addingTimeInterval(-ageSec),
                          body: body)
        m.revokedAt = revokedAt
        m.locallyDeleted = locallyDeleted
        return m
    }

    func testCanEditOwnRecentText() {
        XCTAssertTrue(MessageLifecycle.canEdit(msg(fromMe: true, ageSec: 60)))
    }

    func testCannotEditOldText() {
        XCTAssertFalse(MessageLifecycle.canEdit(msg(fromMe: true, ageSec: 16 * 60)))
    }

    func testCannotEditPeerMessage() {
        XCTAssertFalse(MessageLifecycle.canEdit(msg(fromMe: false, ageSec: 60)))
    }

    func testCannotEditNonText() {
        XCTAssertFalse(MessageLifecycle.canEdit(
            msg(fromMe: true,
                body: .media(kind: "image", caption: nil, fileName: nil, localPath: nil),
                ageSec: 60)))
    }

    func testCannotEditRevoked() {
        XCTAssertFalse(MessageLifecycle.canEdit(
            msg(fromMe: true, ageSec: 60, revokedAt: Date())))
    }

    func testCanRevokeOwnRecent() {
        XCTAssertTrue(MessageLifecycle.canRevoke(msg(fromMe: true, ageSec: 3600)))
    }

    func testCannotRevokePastWindow() {
        XCTAssertFalse(MessageLifecycle.canRevoke(msg(fromMe: true, ageSec: 49 * 3600)))
    }

    func testCannotRevokeForeign() {
        XCTAssertFalse(MessageLifecycle.canRevoke(msg(fromMe: false, ageSec: 60)))
    }
}
