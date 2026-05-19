import XCTest
@testable import yawac

final class SmokeTests: XCTestCase {
    func testAppBundleLoads() {
        XCTAssertNotNil(Bundle.main.bundleIdentifier)
    }
}
