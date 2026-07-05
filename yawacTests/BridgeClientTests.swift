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

    // F118 regression: bridge emits media fields with omitempty, and
    // synthesized Decodable does NOT honor stored-property defaults.
    // A required `is_ptt` made every image/video/document without the
    // key fail decode and drop silently for a month.
    func testDecodeMediaMessageWithoutIsPTT() throws {
        let json = #"""
        {"id":"X","chat_jid":"a@g.us","sender_jid":"b@lid","from_me":false,
         "timestamp":42,"kind":"image","media":{"mime_type":"image/jpeg",
         "width":100,"height":50,"size_bytes":1234}}
        """#
        let m = try JSONDecoder().decode(BridgeMessage.self, from: Data(json.utf8))
        XCTAssertEqual(m.kind, "image")
        XCTAssertEqual(m.media?.mimeType, "image/jpeg")
        XCTAssertNil(m.media?.isPTT)
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

    func testDecodeChatArchived() {
        let e = WAClient.decode(kind: "ChatArchived",
            payload: #"{"chat_jid":"a@s.whatsapp.net","archived":true,"timestamp":7}"#)
        guard case let .chatArchived(jid, archived, ts) = e else {
            return XCTFail("not chatArchived: \(e)")
        }
        XCTAssertEqual(jid, "a@s.whatsapp.net")
        XCTAssertTrue(archived)
        XCTAssertEqual(ts, 7)
    }

    func testDecodeChatDeleted() {
        let e = WAClient.decode(kind: "ChatDeleted",
            payload: #"{"chat_jid":"a@s.whatsapp.net","timestamp":9}"#)
        guard case let .chatDeleted(jid, ts) = e else {
            return XCTFail("not chatDeleted: \(e)")
        }
        XCTAssertEqual(jid, "a@s.whatsapp.net")
        XCTAssertEqual(ts, 9)
    }

    func testDecodeContactUpdated() {
        let e = WAClient.decode(kind: "ContactUpdated",
            payload: #"{"jid":"a@s.whatsapp.net","full_name":"Bob","first_name":"B"}"#)
        guard case let .contactUpdated(jid, full, first) = e else {
            return XCTFail("not contactUpdated: \(e)")
        }
        XCTAssertEqual(jid, "a@s.whatsapp.net")
        XCTAssertEqual(full, "Bob")
        XCTAssertEqual(first, "B")
    }

    func testDecodeBlocklistChanged() {
        let e = WAClient.decode(kind: "BlocklistChanged",
            payload: #"{"action":"","changes":[{"jid":"a@s.whatsapp.net","action":"block"}]}"#)
        guard case let .blocklistChanged(action, changes) = e else {
            return XCTFail("not blocklistChanged: \(e)")
        }
        XCTAssertEqual(action, "")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].jid, "a@s.whatsapp.net")
        XCTAssertEqual(changes[0].action, "block")
    }
}
