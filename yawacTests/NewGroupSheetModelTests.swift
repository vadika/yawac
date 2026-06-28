import XCTest
@testable import yawac

@MainActor
final class NewGroupSheetModelTests: XCTestCase {

    func testCanCreateRequiresName() {
        let m = NewGroupSheetModel { _, _ in "new@g.us" }
        XCTAssertFalse(m.canCreate)
        m.name = "  "
        XCTAssertFalse(m.canCreate)
        m.name = "A"
        XCTAssertTrue(m.canCreate)
    }

    func testNameCappedAt25() {
        let m = NewGroupSheetModel { _, _ in "new@g.us" }
        m.name = String(repeating: "x", count: 30)
        XCTAssertEqual(m.name.count, 25)
    }

    func testCreateCallsBridgeWithChipJIDs() async {
        let captured = Captured()
        let m = NewGroupSheetModel { name, jids in
            captured.record(name: name, jids: jids)
            return "new@g.us"
        }
        m.name = "Climbers"
        m.chips = [
            BridgeContact(jid: "a@s.whatsapp.net", name: "A",
                          pushName: nil, fullName: nil, businessName: nil),
            BridgeContact(jid: "b@s.whatsapp.net", name: "B",
                          pushName: nil, fullName: nil, businessName: nil)
        ]
        await m.create()
        XCTAssertEqual(captured.lastName, "Climbers")
        XCTAssertEqual(captured.lastJIDs, ["a@s.whatsapp.net", "b@s.whatsapp.net"])
        XCTAssertEqual(m.createdJID, "new@g.us")
        XCTAssertNil(m.error)
    }

    func testCreateFailureLeavesError() async {
        let m = NewGroupSheetModel { _, _ in throw TestError.boom }
        m.name = "Climbers"
        await m.create()
        XCTAssertNotNil(m.error)
        XCTAssertNil(m.createdJID)
    }

    /// Sendable holder for closure recording (closure is @Sendable so
    /// captured state must be too).
    private final class Captured: @unchecked Sendable {
        var lastName: String?
        var lastJIDs: [String]?
        func record(name: String, jids: [String]) {
            lastName = name
            lastJIDs = jids
        }
    }
}

enum TestError: Error { case boom }
