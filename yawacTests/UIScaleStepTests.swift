import XCTest
import SwiftUI
@testable import yawac

final class UIScaleStepTests: XCTestCase {

    func testDefaultFactorIsOne() {
        // Default step must be a no-op vs the pre-feature build.
        XCTAssertEqual(UIScaleStep.default.scaleFactor, 1.0)
    }

    func testFactorsAreMonotonic() {
        let factors = UIScaleStep.allCases.map(\.scaleFactor)
        XCTAssertEqual(factors, factors.sorted())
        XCTAssertEqual(UIScaleStep.small.scaleFactor, 0.88)
        XCTAssertEqual(UIScaleStep.xLarge.scaleFactor, 1.23)
    }

    func testFromClampsBelow() {
        XCTAssertEqual(UIScaleStep.from(-3), .small)
    }

    func testFromClampsAbove() {
        XCTAssertEqual(UIScaleStep.from(99), .xLarge)
    }

    func testFromExact() {
        XCTAssertEqual(UIScaleStep.from(2), .default)
    }

    func testFromBoundaries() {
        // Exact, non-clamped boundary indices — guard against off-by-one.
        XCTAssertEqual(UIScaleStep.from(0), .small)
        XCTAssertEqual(UIScaleStep.from(UIScaleStep.allCases.count - 1), .xLarge)
    }

    func testLabels() {
        XCTAssertEqual(UIScaleStep.default.label, "Default")
        XCTAssertEqual(UIScaleStep.xLarge.label, "X-Large")
    }
}
