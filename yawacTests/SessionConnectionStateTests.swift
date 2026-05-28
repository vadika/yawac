import XCTest
@testable import yawac

@MainActor
final class SessionConnectionStateTests: XCTestCase {

    func testStartsConnecting() {
        let s = SessionViewModel()
        XCTAssertEqual(s.connection, .connecting)
    }

    func testMarkConnectedGoesOnline() {
        let s = SessionViewModel()
        s.markDisconnected()
        s.markConnected()
        XCTAssertEqual(s.connection, .online)
    }

    func testMarkDisconnectedGoesConnecting() {
        let s = SessionViewModel()
        s.markConnected()
        s.markDisconnected()
        XCTAssertEqual(s.connection, .connecting)
    }

    func testWatchdogFlipsToOfflineWhenStillDown() async throws {
        let s = SessionViewModel()
        s.offlineDelay = .milliseconds(10)
        s.markDisconnected()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(s.connection, .offline)
    }

    func testReconnectBeforeWatchdogStaysOnline() async throws {
        let s = SessionViewModel()
        s.offlineDelay = .milliseconds(50)
        s.markDisconnected()
        s.markConnected()   // recovers before the watchdog fires
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(s.connection, .online)
    }
}
