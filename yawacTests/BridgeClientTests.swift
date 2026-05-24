import XCTest
@testable import yawac

final class BridgeClientTests: XCTestCase {
    func testDecodeBridgeMessage() throws {
        let json = #"""
        {"id":"X","chat_jid":"a@s","sender_jid":"b@s","from_me":false,
         "timestamp":42,"kind":"text","text":"hi"}
        """#
        let m = try JSONDecoder().decode(BridgeMessage.self, from: Data(json.utf8))
        XCTAssertEqual(m.text, "hi")
        XCTAssertEqual(m.timestamp, 42)
    }

    func testDecodePhoneCheckResultRegistered() throws {
        let json = #"""
        {"jid":"4915123456789@s.whatsapp.net","registered":true}
        """#
        let r = try JSONDecoder().decode(PhoneCheckResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.jid, "4915123456789@s.whatsapp.net")
        XCTAssertTrue(r.registered)
        XCTAssertNil(r.businessName)
        XCTAssertNil(r.pushName)
        XCTAssertNil(r.fullName)
    }

    func testDecodePhoneCheckResultNotRegistered() throws {
        let json = #"{"jid":"","registered":false}"#
        let r = try JSONDecoder().decode(PhoneCheckResult.self, from: Data(json.utf8))
        XCTAssertFalse(r.registered)
        XCTAssertNil(r.pushName)
        XCTAssertNil(r.fullName)
    }

    func testDecodePhoneCheckResultBusiness() throws {
        let json = #"""
        {"jid":"49123@s.whatsapp.net","registered":true,"business_name":"Acme"}
        """#
        let r = try JSONDecoder().decode(PhoneCheckResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.businessName, "Acme")
        XCTAssertNil(r.pushName)
        XCTAssertNil(r.fullName)
    }

    func testDecodePhoneCheckResultWithPushName() throws {
        let json = #"""
        {"jid":"49123@s.whatsapp.net","registered":true,"push_name":"Alice","full_name":"Alice Smith"}
        """#
        let r = try JSONDecoder().decode(PhoneCheckResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.pushName, "Alice")
        XCTAssertEqual(r.fullName, "Alice Smith")
    }
}
