import XCTest
@testable import yawac

@MainActor
final class NewSubGroupSheetModelTests: XCTestCase {

    func testCreatePassesParentAndJIDs() async {
        let stub = StubSubGroupCreator()
        let m = NewSubGroupSheetModel(parentJID: "parent@g.us",
                                      creator: stub)
        m.name = "Hiking"
        m.chips = [BridgeContact(jid: "a@s.whatsapp.net", name: "A",
                                 pushName: nil, fullName: nil,
                                 businessName: nil)]
        await m.create()
        XCTAssertEqual(stub.lastParent, "parent@g.us")
        XCTAssertEqual(stub.lastName, "Hiking")
        XCTAssertEqual(stub.lastJIDs, ["a@s.whatsapp.net"])
        XCTAssertEqual(m.createdJID, "sub@g.us")
    }

    func testFailureSurfacesError() async {
        let stub = StubSubGroupCreator(throwError: TestError.boom)
        let m = NewSubGroupSheetModel(parentJID: "parent@g.us",
                                      creator: stub)
        m.name = "Hiking"
        await m.create()
        XCTAssertNotNil(m.error)
        XCTAssertNil(m.createdJID)
    }
}

final class StubSubGroupCreator: SubGroupCreator, @unchecked Sendable {
    var lastParent: String?
    var lastName: String?
    var lastJIDs: [String]?
    var throwError: Error?
    init(throwError: Error? = nil) { self.throwError = throwError }
    func createSubGroup(parentJID: String, name: String,
                        participantJIDs: [String]) throws -> String {
        if let throwError { throw throwError }
        lastParent = parentJID
        lastName = name
        lastJIDs = participantJIDs
        return "sub@g.us"
    }
}
