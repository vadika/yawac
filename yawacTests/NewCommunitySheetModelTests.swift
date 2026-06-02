import XCTest
@testable import yawac

@MainActor
final class NewCommunitySheetModelTests: XCTestCase {

    func testCanCreateRequiresName() {
        let m = NewCommunitySheetModel(creator: StubCommunityCreator())
        XCTAssertFalse(m.canCreate)
        m.name = "Outdoor"
        XCTAssertTrue(m.canCreate)
    }

    func testNameCapped() {
        let m = NewCommunitySheetModel(creator: StubCommunityCreator())
        m.name = String(repeating: "x", count: 40)
        XCTAssertEqual(m.name.count, 25)
    }

    func testCreateCallsBridge() async {
        let stub = StubCommunityCreator()
        let m = NewCommunitySheetModel(creator: stub)
        m.name = "Outdoor"
        await m.create()
        XCTAssertEqual(stub.lastName, "Outdoor")
        XCTAssertEqual(m.createdJID, "comm@g.us")
    }
}

final class StubCommunityCreator: CommunityCreator, @unchecked Sendable {
    var lastName: String?
    var throwError: Error?
    func createCommunity(name: String) throws -> String {
        if let throwError { throw throwError }
        lastName = name
        return "comm@g.us"
    }
}
