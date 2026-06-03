import XCTest
import CoreLocation
import MapKit
@testable import yawac

@MainActor
final class LocationPickerSheetModelTests: XCTestCase {

    func testInitialStateAtFallbackCenter() {
        let m = LocationPickerSheetModel()
        XCTAssertEqual(m.selectedCoord.latitude, m.region.center.latitude, accuracy: 0.0001)
    }

    func testUpdateCoordRecordsName() {
        let m = LocationPickerSheetModel()
        m.updateCoord(lat: 60.17, lng: 24.94,
                      name: "Senate Square",
                      address: "Helsinki, Finland")
        XCTAssertEqual(m.resolvedName, "Senate Square")
        XCTAssertEqual(m.resolvedAddress, "Helsinki, Finland")
        XCTAssertEqual(m.selectedCoord.latitude, 60.17, accuracy: 0.0001)
        XCTAssertEqual(m.selectedCoord.longitude, 24.94, accuracy: 0.0001)
    }

    func testStagePayload() {
        let m = LocationPickerSheetModel()
        m.updateCoord(lat: 60.17, lng: 24.94,
                      name: "X", address: "Y")
        let payload = m.buildPayload()
        XCTAssertEqual(payload.lat, 60.17, accuracy: 0.0001)
        XCTAssertEqual(payload.name, "X")
    }
}
