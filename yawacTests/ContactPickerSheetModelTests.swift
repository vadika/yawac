import XCTest
@testable import yawac

@MainActor
final class ContactPickerSheetModelTests: XCTestCase {

    func testCanSendRequiresSelection() {
        let m = ContactPickerSheetModel(contacts: [])
        XCTAssertFalse(m.canSend)
        m.selectedJID = "1@s.whatsapp.net"
        XCTAssertTrue(m.canSend)
    }

    func testBuildPayloadFromSelection() {
        let contacts = [
            BridgeContact(jid: "358405551234@s.whatsapp.net",
                          name: "Anna",
                          pushName: nil,
                          fullName: nil,
                          businessName: nil)
        ]
        let m = ContactPickerSheetModel(contacts: contacts)
        m.selectedJID = "358405551234@s.whatsapp.net"
        let payload = m.buildPayload()
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.displayName, "Anna")
        XCTAssertEqual(payload?.jid, "358405551234@s.whatsapp.net")
        XCTAssertEqual(payload?.phone, "+358405551234")
        XCTAssertTrue(payload?.vcard.contains("waid=358405551234") ?? false)
    }
}
