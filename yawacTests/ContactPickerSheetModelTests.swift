import XCTest
@testable import yawac

@MainActor
final class ContactPickerSheetModelTests: XCTestCase {

    private func make(_ jids: [String]) -> ContactPickerSheetModel {
        let contacts = jids.map {
            BridgeContact(jid: $0, name: $0.prefix(2).uppercased(),
                          pushName: nil, fullName: nil, businessName: nil)
        }
        return ContactPickerSheetModel(contacts: contacts)
    }

    func test_toggle_adds_then_removes() {
        let m = make(["111@s.whatsapp.net", "222@s.whatsapp.net"])
        XCTAssertTrue(m.selectedJIDs.isEmpty)
        XCTAssertFalse(m.canSend)
        m.toggle("111@s.whatsapp.net")
        XCTAssertEqual(m.selectedJIDs, ["111@s.whatsapp.net"])
        XCTAssertTrue(m.canSend)
        m.toggle("111@s.whatsapp.net")
        XCTAssertTrue(m.selectedJIDs.isEmpty)
        XCTAssertFalse(m.canSend)
    }

    func test_buildPayloads_preserves_contacts_order_not_selection_order() {
        let m = make(["111@s.whatsapp.net", "222@s.whatsapp.net", "333@s.whatsapp.net"])
        // Select in reverse order.
        m.toggle("333@s.whatsapp.net")
        m.toggle("111@s.whatsapp.net")
        let payloads = m.buildPayloads()
        XCTAssertEqual(payloads.map { $0.jid },
                       ["111@s.whatsapp.net", "333@s.whatsapp.net"])
    }

    func test_buildPayloads_empty_when_nothing_selected() {
        let m = make(["111@s.whatsapp.net"])
        XCTAssertEqual(m.buildPayloads(), [])
    }
}
