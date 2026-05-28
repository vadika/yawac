import XCTest
@testable import yawac

@MainActor
final class ConnectivityMonitorTests: XCTestCase {

    /// Builds a monitor with a 10ms debounce and capturing closures.
    private func makeMonitor(connected: Bool, ready: Bool = true)
        -> (ConnectivityMonitor, () -> [Bool]) {
        let box = CallBox()
        let m = ConnectivityMonitor(
            debounce: .milliseconds(10),
            isReady: { ready },
            isConnected: { connected },
            reconnect: { force in box.calls.append(force) }
        )
        return (m, { box.calls })
    }

    private final class CallBox { var calls: [Bool] = [] }

    func testWakeForcesReconnectEvenWhenConnected() async throws {
        let (m, calls) = makeMonitor(connected: true)
        m.trigger(.wake)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls(), [true], "wake must force reconnect even if connected")
    }

    func testNetworkSkipsWhenConnected() async throws {
        let (m, calls) = makeMonitor(connected: true)
        m.trigger(.network)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls(), [], "network change while connected must not reconnect")
    }

    func testNetworkReconnectsWhenDisconnected() async throws {
        let (m, calls) = makeMonitor(connected: false)
        m.trigger(.network)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls(), [false], "network change while down reconnects (non-forced)")
    }

    func testBurstCoalescesToOneReconnect() async throws {
        let (m, calls) = makeMonitor(connected: false)
        m.trigger(.network)
        m.trigger(.appActive)
        m.trigger(.wake)
        try await Task.sleep(for: .milliseconds(40))
        // Coalesced to a single call; wake in the window upgrades to force.
        XCTAssertEqual(calls(), [true])
    }

    func testNotReadySuppressesReconnect() async throws {
        let (m, calls) = makeMonitor(connected: false, ready: false)
        m.trigger(.wake)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls(), [], "must not reconnect while not ready (e.g. mid-pairing)")
    }
}
