import Foundation
import XCTest
@testable import yawac

/// Regression coverage for targeted recent-history recovery. Automatic
/// reconnect fan-out used to issue one peer request per stored chat, waking the
/// primary phone repeatedly. Recovery now runs only for a chat the user opens
/// (or a newly joined group) and is deduplicated for the app session.
@MainActor
final class SessionReconnectCatchupTests: XCTestCase {
    private static let flagKey = "historyBackfillCompleted"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.flagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.flagKey)
        super.tearDown()
    }

    func testSkipsWhenInitialBackfillIncomplete() async throws {
        let stub = try StubRecentHistoryClient.make()
        let session = SessionViewModel()
        session.client = stub

        await session.requestRecentHistoryIfNeeded(for: "12345@s.whatsapp.net")

        XCTAssertEqual(stub.capture.snapshot().count, 0)
    }

    func testRequestsOnlyTheRelevantChatOncePerSession() async throws {
        UserDefaults.standard.set(true, forKey: Self.flagKey)
        let stub = try StubRecentHistoryClient.make()
        let session = SessionViewModel()
        session.client = stub

        await session.requestRecentHistoryIfNeeded(for: "12345@s.whatsapp.net")
        await session.requestRecentHistoryIfNeeded(for: "12345@s.whatsapp.net")

        let snapshot = stub.capture.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.chatJIDs, ["12345@s.whatsapp.net"])
        XCTAssertEqual(snapshot.limits, [50])
    }

    func testDifferentRelevantChatsEachGetOneRequest() async throws {
        UserDefaults.standard.set(true, forKey: Self.flagKey)
        let stub = try StubRecentHistoryClient.make()
        let session = SessionViewModel()
        session.client = stub

        await session.requestRecentHistoryIfNeeded(for: "12345@s.whatsapp.net")
        await session.requestRecentHistoryIfNeeded(for: "67890@s.whatsapp.net")

        XCTAssertEqual(
            stub.capture.snapshot().chatJIDs,
            ["12345@s.whatsapp.net", "67890@s.whatsapp.net"])
    }

    func testFailedRequestCanRetry() async throws {
        UserDefaults.standard.set(true, forKey: Self.flagKey)
        let stub = try StubRecentHistoryClient.make(failFirst: true)
        let session = SessionViewModel()
        session.client = stub

        await session.requestRecentHistoryIfNeeded(for: "12345@s.whatsapp.net")
        await session.requestRecentHistoryIfNeeded(for: "12345@s.whatsapp.net")

        XCTAssertEqual(stub.capture.snapshot().count, 2)
    }
}

final class StubRecentHistoryCapture: @unchecked Sendable {
    struct Snapshot {
        var count = 0
        var chatJIDs: [String] = []
        var limits: [Int] = []
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var failNext: Bool

    init(failFirst: Bool) {
        failNext = failFirst
    }

    func record(chatJID: String, count: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        state.count += 1
        state.chatJIDs.append(chatJID)
        state.limits.append(count)
        if failNext {
            failNext = false
            throw StubError.requestFailed
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private enum StubError: Error {
        case requestFailed
    }
}

@MainActor
final class StubRecentHistoryClient: WAClient {
    nonisolated let capture: StubRecentHistoryCapture

    private init(dbPath: String, failFirst: Bool) throws {
        capture = StubRecentHistoryCapture(failFirst: failFirst)
        try super.init(dbPath: dbPath)
    }

    static func make(failFirst: Bool = false) throws -> StubRecentHistoryClient {
        let dir = NSTemporaryDirectory()
            .appending("yawac-recent-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return try StubRecentHistoryClient(
            dbPath: dir + "/state.db", failFirst: failFirst)
    }

    override nonisolated func requestRecentHistory(chatJID: String,
                                                   count: Int) throws {
        try capture.record(chatJID: chatJID, count: count)
    }
}
