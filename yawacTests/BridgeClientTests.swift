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
}
