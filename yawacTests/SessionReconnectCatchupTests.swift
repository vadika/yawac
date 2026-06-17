import XCTest
@testable import yawac

/// Verifies the F92 reconnect catch-up sync gate on SessionViewModel.
///   - When `historyBackfillCompleted` is false, the method is a no-op
///     (first-pair flow owns the sync).
///   - When `client` is nil, the method is a no-op (no connection to use).
///   - When both are satisfied but the throttle window hasn't expired,
///     the method skips and leaves the timestamp unchanged.
///   - When the throttle window has expired, the method advances
///     `lastReconnectCatchupAt` to ~now (even if the send fails due to
///     no real bridge underneath).
///
/// Implementation order inside `requestReconnectCatchupSyncIfNeeded`:
///   1. guard historyBackfillCompleted
///   2. guard client
///   3. throttle check
///   4. advance timestamp + send
@MainActor
final class SessionReconnectCatchupTests: XCTestCase {

    private static let catchupKey = "yawac.lastReconnectCatchupAt"
    private static let flagKey    = "historyBackfillCompleted"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.catchupKey)
        UserDefaults.standard.removeObject(forKey: Self.flagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.catchupKey)
        UserDefaults.standard.removeObject(forKey: Self.flagKey)
        super.tearDown()
    }

    // MARK: - no-op paths

    func testSkipsWhenInitialBackfillIncomplete() async {
        // historyBackfillCompleted = false → catch-up is a no-op.
        UserDefaults.standard.set(false, forKey: Self.flagKey)
        let session = SessionViewModel()
        await session.requestReconnectCatchupSyncIfNeeded()
        // lastReconnectCatchupAt should remain 0 because the function early-returned.
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: Self.catchupKey), 0,
            "catch-up must not advance the timestamp when the one-shot backfill hasn't completed")
    }

    func testSkipsWhenClientNil() async {
        // No client set on the session → no-op (guard client fires after guard historyBackfillCompleted).
        UserDefaults.standard.set(true, forKey: Self.flagKey)
        let session = SessionViewModel()
        await session.requestReconnectCatchupSyncIfNeeded()
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: Self.catchupKey), 0,
            "catch-up must not advance the timestamp when client is nil")
    }

    func testSkipsWhenWithinThrottleWindow() async throws {
        // Set lastReconnectCatchupAt to "1 minute ago" and historyBackfillCompleted true.
        // Use a real stub so the client guard passes; the throttle fires before the send.
        UserDefaults.standard.set(true, forKey: Self.flagKey)
        let recentTs = Date().timeIntervalSince1970 - 60   // 1 min ago
        UserDefaults.standard.set(recentTs, forKey: Self.catchupKey)

        let stub = try StubBackfillClient.make()
        let session = SessionViewModel()
        session.client = stub
        await session.requestReconnectCatchupSyncIfNeeded()

        // Timestamp must remain unchanged — no send occurred.
        let after = UserDefaults.standard.double(forKey: Self.catchupKey)
        XCTAssertEqual(after, recentTs, accuracy: 0.5,
                       "timestamp must not advance when inside the 5-min throttle window")
        // And no requestFullHistorySync was called on the stub.
        XCTAssertEqual(stub.snapshot().count, 0,
                       "no history-sync IQ should be sent within the throttle window")
    }

    // MARK: - fires path

    func testFiresWhenThrottleExpiredAndStampsNow() async throws {
        // Set lastReconnectCatchupAt to "10 minutes ago" (past throttle).
        // historyBackfillCompleted true, stub client attached.
        // The function advances the timestamp BEFORE the send, so even
        // though the stub doesn't error, we can assert the stamp moved.
        UserDefaults.standard.set(true, forKey: Self.flagKey)
        let tenMinAgo = Date().timeIntervalSince1970 - 600
        UserDefaults.standard.set(tenMinAgo, forKey: Self.catchupKey)

        let stub = try StubBackfillClient.make()
        let session = SessionViewModel()
        session.client = stub
        await session.requestReconnectCatchupSyncIfNeeded()

        let after = UserDefaults.standard.double(forKey: Self.catchupKey)
        XCTAssertGreaterThan(after, tenMinAgo + 500,
                             "lastReconnectCatchupAt must advance to ~now after throttle expires")
        // Stub captured one call with count=7.
        let snap = stub.snapshot()
        XCTAssertEqual(snap.count, 1, "exactly one requestFullHistorySync should fire")
        XCTAssertEqual(snap.chatJID, "",  "catch-up uses empty anchor chatJID")
        XCTAssertEqual(snap.msgID,   "",  "catch-up uses empty anchor msgID")
        XCTAssertEqual(snap.fromMe,  false)
        XCTAssertEqual(snap.tsUnix,  0,   "catch-up uses zero anchor timestamp")
    }

    func testLogoutResetsThrottleTimestamp() async {
        // Verify that logout() zeroes lastReconnectCatchupAt (so re-pair starts fresh).
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.catchupKey)
        let session = SessionViewModel()
        await session.logout()
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: Self.catchupKey), 0,
            "logout() must reset the catch-up throttle timestamp")
    }
}
