import XCTest
@testable import yawac

@MainActor
final class NewGroupSheetModelTests: XCTestCase {

    func testCanCreateRequiresName() {
        let m = NewGroupSheetModel(creator: StubGroupCreator())
        XCTAssertFalse(m.canCreate)
        m.name = "  "
        XCTAssertFalse(m.canCreate)
        m.name = "A"
        XCTAssertTrue(m.canCreate)
    }

    func testNameCappedAt25() {
        let m = NewGroupSheetModel(creator: StubGroupCreator())
        m.name = String(repeating: "x", count: 30)
        XCTAssertEqual(m.name.count, 25)
    }

    func testCreateCallsBridgeWithChipJIDs() async {
        let stub = StubGroupCreator()
        let m = NewGroupSheetModel(creator: stub)
        m.name = "Climbers"
        m.chips = [
            BridgeContact(jid: "a@s.whatsapp.net", name: "A",
                          pushName: nil, fullName: nil, businessName: nil),
            BridgeContact(jid: "b@s.whatsapp.net", name: "B",
                          pushName: nil, fullName: nil, businessName: nil)
        ]
        await m.create()
        XCTAssertEqual(stub.lastName, "Climbers")
        XCTAssertEqual(stub.lastJIDs, ["a@s.whatsapp.net", "b@s.whatsapp.net"])
        XCTAssertEqual(m.createdJID, "new@g.us")
        XCTAssertNil(m.error)
    }

    func testCreateFailureLeavesError() async {
        let stub = StubGroupCreator(throwError: TestError.boom)
        let m = NewGroupSheetModel(creator: stub)
        m.name = "Climbers"
        await m.create()
        XCTAssertNotNil(m.error)
        XCTAssertNil(m.createdJID)
    }
}

enum TestError: Error { case boom }

final class StubGroupCreator: GroupCreator, @unchecked Sendable {
    var lastName: String?
    var lastJIDs: [String]?
    var throwError: Error?
    init(throwError: Error? = nil) { self.throwError = throwError }
    func createGroup(name: String, participantJIDs: [String]) throws -> String {
        if let throwError { throw throwError }
        lastName = name
        lastJIDs = participantJIDs
        return "new@g.us"
    }
}
