import XCTest
@testable import yawac

@MainActor
final class NewCommunitySheetModelTests: XCTestCase {

    func testCanCreateRequiresName() {
        let m = NewCommunitySheetModel { _ in "comm@g.us" }
        XCTAssertFalse(m.canCreate)
        m.name = "Outdoor"
        XCTAssertTrue(m.canCreate)
    }

    func testNameCapped() {
        let m = NewCommunitySheetModel { _ in "comm@g.us" }
        m.name = String(repeating: "x", count: 40)
        XCTAssertEqual(m.name.count, 25)
    }

    func testCreateCallsBridge() async {
        let captured = Captured()
        let m = NewCommunitySheetModel { name in
            captured.lastName = name
            return "comm@g.us"
        }
        m.name = "Outdoor"
        await m.create()
        XCTAssertEqual(captured.lastName, "Outdoor")
        XCTAssertEqual(m.createdJID, "comm@g.us")
    }

    private final class Captured: @unchecked Sendable {
        var lastName: String?
    }
}
