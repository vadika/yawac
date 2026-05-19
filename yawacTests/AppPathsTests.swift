import XCTest
@testable import yawac

final class AppPathsTests: XCTestCase {
    func testDatabasePath() throws {
        let p = try AppPaths.databaseURL()
        XCTAssertTrue(p.path.hasSuffix("yawac/yawac.sqlite"),
                      "got: \(p.path)")
    }

    func testMediaCachePath() throws {
        let p = try AppPaths.mediaCacheURL()
        XCTAssertTrue(p.path.hasSuffix("yawac-media"), "got: \(p.path)")
    }
}
