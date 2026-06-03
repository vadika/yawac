import XCTest
import SwiftData
@testable import yawac

@MainActor
final class ViewOnceRevealTests: XCTestCase {

    func testRevealFlipsLockedAndDeletesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewonce-\(UUID()).bin")
        try Data([0xff, 0xd8]).write(to: url)

        let msg = makeMessage()
        msg.isViewOnce = true
        msg.viewOnceLocked = false
        msg.mediaPath = url.path

        ViewOnceReveal.reveal(msg)

        XCTAssertTrue(msg.viewOnceLocked)
        XCTAssertNil(msg.mediaPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(msg.viewOnceRevealedAt)
    }

    func testRevealIdempotentOnSecondCall() {
        let msg = makeMessage()
        msg.isViewOnce = true
        msg.viewOnceLocked = true
        msg.mediaPath = nil

        ViewOnceReveal.reveal(msg)
        XCTAssertTrue(msg.viewOnceLocked)
        XCTAssertNil(msg.mediaPath)
    }

    func testRevealNoOpWhenFileMissing() {
        let msg = makeMessage()
        msg.isViewOnce = true
        msg.viewOnceLocked = false
        msg.mediaPath = "/tmp/non-existent-\(UUID()).bin"
        ViewOnceReveal.reveal(msg)
        XCTAssertTrue(msg.viewOnceLocked)
        XCTAssertNil(msg.mediaPath)
    }

    /// Minimal PersistedMessage factory. The model's explicit init (T12)
    /// requires id/chatJID/senderJID/fromMe/timestamp/kind; every other
    /// field has a default. We don't need a ModelContext for these tests
    /// since SwiftData's `@Model` is happy mutating a detached instance.
    private func makeMessage() -> PersistedMessage {
        PersistedMessage(
            id: UUID().uuidString,
            chatJID: "1234@s.whatsapp.net",
            senderJID: "1234@s.whatsapp.net",
            fromMe: false,
            timestamp: Date(),
            kind: "image"
        )
    }
}
