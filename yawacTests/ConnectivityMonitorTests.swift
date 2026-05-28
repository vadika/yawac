import XCTest
@testable import yawac

@MainActor
final class ConnectivityMonitorTests: XCTestCase {

    private final class Box {
        var calls: [Bool] = []   // each element = the `force` flag passed
        var connected: Bool
        var succeedOnReconnect: Bool
        init(connected: Bool, succeedOnReconnect: Bool) {
            self.connected = connected
            self.succeedOnReconnect = succeedOnReconnect
        }
    }

    /// Fast monitor: 10ms debounce, three 5ms retry slots. `connected`
    /// seeds the initial socket state; `succeedOnReconnect` makes the
    /// injected reconnect closure flip `connected` true (simulating a
    /// successful dial) so the retry loop terminates.
    private func makeMonitor(connected: Bool,
                             succeedOnReconnect: Bool = true,
                             ready: Bool = true,
                             backoff: [Duration] = [.milliseconds(5)]) -> (ConnectivityMonitor, Box) {
        let box = Box(connected: connected, succeedOnReconnect: succeedOnReconnect)
        let m = ConnectivityMonitor(
            debounce: .milliseconds(10),
            retryBackoff: backoff,
            isReady: { ready },
            isConnected: { box.connected },
            reconnect: { force in
                box.calls.append(force)
                if box.succeedOnReconnect { box.connected = true }
            }
        )
        return (m, box)
    }

    func testWakeForcesReconnectEvenWhenConnected() async throws {
        let (m, box) = makeMonitor(connected: true)
        m.trigger(.wake)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.calls, [true], "wake must force one reconnect even if connected")
    }

    func testNetworkSkipsWhenConnected() async throws {
        let (m, box) = makeMonitor(connected: true)
        m.trigger(.network)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.calls, [], "network change while connected must not reconnect")
    }

    func testNetworkReconnectsWhenDisconnected() async throws {
        let (m, box) = makeMonitor(connected: false)
        m.trigger(.network)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.calls, [false], "network change while down reconnects once on success")
    }

    func testBurstCoalescesToOneReconnect() async throws {
        let (m, box) = makeMonitor(connected: false)
        m.trigger(.network)
        m.trigger(.appActive)
        m.trigger(.wake)
        try await Task.sleep(for: .milliseconds(200))
        // Coalesced to one loop; wake in the window upgrades to force.
        XCTAssertEqual(box.calls, [true])
    }

    func testNotReadySuppressesReconnect() async throws {
        let (m, box) = makeMonitor(connected: false, ready: false)
        m.trigger(.wake)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.calls, [], "must not reconnect while not ready (e.g. mid-pairing)")
    }

    func testRetriesRepeatedlyWhileDown() async throws {
        // Dial keeps failing (connected never flips). Backoff is two
        // 5ms slots then a 10s hold, so within the window we get 3
        // attempts then it parks on the long delay. Proves it keeps
        // retrying past a single attempt (rides the DNS-not-ready
        // window) rather than giving up. stop() tears the loop down.
        let (m, box) = makeMonitor(connected: false, succeedOnReconnect: false,
                                   backoff: [.milliseconds(5), .milliseconds(5), .seconds(10)])
        m.trigger(.network)
        try await Task.sleep(for: .milliseconds(200))
        m.stop()
        XCTAssertEqual(box.calls.count, 3, "should retry several times while down")
        XCTAssertEqual(box.calls, [false, false, false])
    }
}
