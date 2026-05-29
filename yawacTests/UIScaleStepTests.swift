import XCTest
import SwiftUI
@testable import yawac

final class UIScaleStepTests: XCTestCase {

    func testDefaultMapsToLarge() {
        XCTAssertEqual(UIScaleStep.default.dynamicTypeSize, .large)
    }

    func testAllStepsMap() {
        XCTAssertEqual(UIScaleStep.small.dynamicTypeSize, .small)
        XCTAssertEqual(UIScaleStep.compact.dynamicTypeSize, .medium)
        XCTAssertEqual(UIScaleStep.default.dynamicTypeSize, .large)
        XCTAssertEqual(UIScaleStep.large.dynamicTypeSize, .xLarge)
        XCTAssertEqual(UIScaleStep.xLarge.dynamicTypeSize, .xxLarge)
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

    func testLabels() {
        XCTAssertEqual(UIScaleStep.default.label, "Default")
        XCTAssertEqual(UIScaleStep.xLarge.label, "X-Large")
    }
}
