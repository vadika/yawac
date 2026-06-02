import XCTest
@testable import yawac

final class InviteLinkParserTests: XCTestCase {
    func testHttpsChatWhatsapp() {
        XCTAssertEqual(InviteLink.parseCode(
            "https://chat.whatsapp.com/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testHttpChatWhatsapp() {
        XCTAssertEqual(InviteLink.parseCode(
            "http://chat.whatsapp.com/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testBareChatWhatsapp() {
        XCTAssertEqual(InviteLink.parseCode(
            "chat.whatsapp.com/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testHttpsWaMe() {
        XCTAssertEqual(InviteLink.parseCode(
            "https://wa.me/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testBareWaMe() {
        XCTAssertEqual(InviteLink.parseCode(
            "wa.me/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testBareCodeAccepted() {
        // Real WhatsApp invite codes are 22 chars; 16 is the lower bound.
        XCTAssertEqual(InviteLink.parseCode(
            "AbCdEfGhIjKlMnOpQrSt"), "AbCdEfGhIjKlMnOpQrSt")
    }

    func testShortQueryRejected() {
        XCTAssertNil(InviteLink.parseCode("Anna"))
        XCTAssertNil(InviteLink.parseCode("Anna Berg"))
        XCTAssertNil(InviteLink.parseCode("AbCdEf"))
    }

    func testEmptyRejected() {
        XCTAssertNil(InviteLink.parseCode(""))
        XCTAssertNil(InviteLink.parseCode("   "))
    }

    func testOtherHostRejected() {
        XCTAssertNil(InviteLink.parseCode(
            "https://example.com/AbCdEfGhIjKlMnOpQrSt"))
        XCTAssertNil(InviteLink.parseCode(
            "https://signal.me/AbCdEfGhIjKlMnOpQrSt"))
    }

    func testTrailingPathStripped() {
        XCTAssertEqual(InviteLink.parseCode(
            "https://chat.whatsapp.com/AbCdEfGhIjKlMnOpQr?extra=1"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testWhitespaceTrimmed() {
        XCTAssertEqual(InviteLink.parseCode(
            "  https://chat.whatsapp.com/AbCdEfGhIjKlMn  "),
            "AbCdEfGhIjKlMn")
    }

    func testNonAlphanumericInBareCodeRejected() {
        XCTAssertNil(InviteLink.parseCode("AbCdEfGh-IjKlMnOpQr"))
        XCTAssertNil(InviteLink.parseCode("AbCdEfGh IjKlMnOpQr"))
    }
}
