import XCTest
@testable import yawac

final class UIMessageContactsArrayTests: XCTestCase {

    func test_init_parses_contacts_array_kind() throws {
        let json = """
        {
          "id": "wamid.1",
          "chat_jid": "1@s.whatsapp.net",
          "sender_jid": "1@s.whatsapp.net",
          "from_me": false,
          "timestamp": 1700000000,
          "kind": "contacts",
          "contacts_array": {
            "display_name": "Contacts",
            "contacts": [
              { "vcard": "BEGIN:VCARD\\nVERSION:3.0\\nFN:Anna\\nTEL;type=CELL;waid=11:+11\\nEND:VCARD", "display_name": "Anna" },
              { "vcard": "BEGIN:VCARD\\nVERSION:3.0\\nFN:Bob\\nTEL;type=CELL;waid=22:+22\\nEND:VCARD", "display_name": "Bob" }
            ]
          }
        }
        """
        let bm = try JSONDecoder().decode(BridgeMessage.self, from: Data(json.utf8))
        let m = UIMessage(bm)
        guard case .contacts(let cards) = m.body else {
            return XCTFail("expected .contacts body, got \(m.body)")
        }
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].displayName, "Anna")
        XCTAssertEqual(cards[0].phone, "+11")
        XCTAssertEqual(cards[0].jid, "11@s.whatsapp.net")
        XCTAssertEqual(cards[1].displayName, "Bob")
    }
}
