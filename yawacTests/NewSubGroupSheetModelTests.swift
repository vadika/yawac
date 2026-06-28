import XCTest
@testable import yawac

@MainActor
final class NewSubGroupSheetModelTests: XCTestCase {

    func testCreatePassesParentAndJIDs() async {
        let captured = Captured()
        let m = NewSubGroupSheetModel(parentJID: "parent@g.us") { parent, name, jids in
            captured.record(parent: parent, name: name, jids: jids)
            return "sub@g.us"
        }
        m.name = "Hiking"
        m.chips = [BridgeContact(jid: "a@s.whatsapp.net", name: "A",
                                 pushName: nil, fullName: nil,
                                 businessName: nil)]
        await m.create()
        XCTAssertEqual(captured.lastParent, "parent@g.us")
        XCTAssertEqual(captured.lastName, "Hiking")
        XCTAssertEqual(captured.lastJIDs, ["a@s.whatsapp.net"])
        XCTAssertEqual(m.createdJID, "sub@g.us")
    }

    func testFailureSurfacesError() async {
        let m = NewSubGroupSheetModel(parentJID: "parent@g.us") { _, _, _ in
            throw TestError.boom
        }
        m.name = "Hiking"
        await m.create()
        XCTAssertNotNil(m.error)
        XCTAssertNil(m.createdJID)
    }

    private final class Captured: @unchecked Sendable {
        var lastParent: String?
        var lastName: String?
        var lastJIDs: [String]?
        func record(parent: String, name: String, jids: [String]) {
            lastParent = parent
            lastName = name
            lastJIDs = jids
        }
    }
}
