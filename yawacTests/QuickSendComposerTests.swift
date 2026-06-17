// yawacTests/QuickSendComposerTests.swift
import XCTest
@testable import yawac

@MainActor
final class QuickSendComposerTests: XCTestCase {

    func testEmptyOrWhitespaceDraftIsBlocked() {
        XCTAssertFalse(QuickSendComposer.canSend(draft: ""))
        XCTAssertFalse(QuickSendComposer.canSend(draft: "  "))
        XCTAssertFalse(QuickSendComposer.canSend(draft: "\n\n  \n"))
        XCTAssertTrue(QuickSendComposer.canSend(draft: "hi"))
    }

    func testAttemptSendSuccessClosesPopover() async {
        var closed = false
        let result = await QuickSendComposer.attemptSend(
            chatJID: "1@s.whatsapp.net",
            draft: "hi",
            sender: { _, _ in /* no throw → success */ },
            onClose: { closed = true })
        if case .success = result {} else {
            XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(closed)
    }

    func testAttemptSendFailureKeepsPopoverOpenAndReturnsError() async {
        struct BogusError: Error, LocalizedError {
            var errorDescription: String? { "phone offline" }
        }
        var closed = false
        let result = await QuickSendComposer.attemptSend(
            chatJID: "1@s.whatsapp.net",
            draft: "hi",
            sender: { _, _ in throw BogusError() },
            onClose: { closed = true })
        XCTAssertFalse(closed)
        if case .failure(let msg) = result {
            XCTAssertEqual(msg, "phone offline")
        } else {
            XCTFail("expected failure, got \(result)")
        }
    }
}
