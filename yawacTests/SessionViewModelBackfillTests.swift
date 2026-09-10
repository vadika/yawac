import XCTest
import SwiftData
@testable import yawac

/// Full history uses a duration, independently of any locally stored anchor.
@MainActor
final class SessionViewModelBackfillTests: XCTestCase {

    private static let flagKey = "historyBackfillCompleted"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.flagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.flagKey)
        super.tearDown()
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: PersistedMessage.self, configurations: config)
        return ModelContext(container)
    }

    func testFirstBootWithPersistedMessageRequestsBackfill() async throws {
        UserDefaults.standard.set(false, forKey: Self.flagKey)
        let context = try makeInMemoryContext()
        let row = PersistedMessage(
            id: "MSG-OLDEST",
            chatJID: "1@s.whatsapp.net",
            senderJID: "1@s.whatsapp.net",
            fromMe: false,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: "text",
            text: "old")
        context.insert(row)
        try context.save()

        let stub = try StubBackfillClient.make()
        let svm = SessionViewModel()
        svm.client = stub
        svm.modelContext = context

        await svm.requestHistoryBackfillIfNeeded()

        let snap = stub.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.durationDays, 3650)
        // Flag stays false until the first HistorySync arrives (T12 flips it
        // from ContentView). Requesting the IQ alone does not flip it.
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.flagKey))
    }

    func testFlagSetSkipsRequest() async throws {
        UserDefaults.standard.set(true, forKey: Self.flagKey)
        let context = try makeInMemoryContext()
        // Even with an anchor row available, the gate must short-circuit.
        let row = PersistedMessage(
            id: "MSG-OLDEST",
            chatJID: "1@s.whatsapp.net",
            senderJID: "1@s.whatsapp.net",
            fromMe: false,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: "text",
            text: "old")
        context.insert(row)
        try context.save()

        let stub = try StubBackfillClient.make()
        let svm = SessionViewModel()
        svm.client = stub
        svm.modelContext = context

        await svm.requestHistoryBackfillIfNeeded()

        let snap = stub.snapshot()
        XCTAssertEqual(snap.count, 0)
        XCTAssertNil(snap.durationDays)
    }

    func testEmptyPersistedStoreStillIssuesRequest() async throws {
        // F56 (v0.9.66): fresh installs with no persisted rows used to
        // short-circuit here, leaving the user with only the
        // INITIAL_BOOTSTRAP chunk's messages. The type-6 packet doesn't
        // need anchor info, so we now always send the request — empty
        // anchor strings are harmless.
        UserDefaults.standard.set(false, forKey: Self.flagKey)
        let context = try makeInMemoryContext()
        let stub = try StubBackfillClient.make()
        let svm = SessionViewModel()
        svm.client = stub
        svm.modelContext = context

        await svm.requestHistoryBackfillIfNeeded()

        let snap = stub.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.durationDays, 3650)
        // Flag stays false until the first HistorySync arrives (T12 flips
        // it from ContentView). Requesting the IQ alone does not flip it.
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.flagKey))
    }
}

/// Subclass of `WAClient` that captures `requestFullHistorySync` parameters
/// without going to the Go bridge. Mirrors the `FakeWAClient` pattern used
/// by `ConversationViewModelPollCreateTests`: a real `super.init(dbPath:)`
/// over a throwaway temp directory keeps gomobile happy, then individual
/// methods are overridden to record their arguments.
///
/// SessionViewModel invokes `requestFullHistorySync` from a `Task.detached`,
/// so the override runs off-main. Captured state lives in an NSLock-guarded
/// box so the test's MainActor assertions see the value the bridge call
/// produced (the producing task is `await`-ed via `.value` before
/// `requestHistoryBackfillIfNeeded` returns).
final class StubBackfillCapture: @unchecked Sendable {
    struct Snapshot {
        var count: Int = 0
        var durationDays: Int32?
    }
    private let lock = NSLock()
    private var state = Snapshot()

    func record(durationDays: Int32) {
        lock.lock(); defer { lock.unlock() }
        state.count += 1
        state.durationDays = durationDays
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}

@MainActor
final class StubBackfillClient: WAClient {
    nonisolated let capture = StubBackfillCapture()

    static func make() throws -> StubBackfillClient {
        let dir = NSTemporaryDirectory()
            .appending("yawac-backfill-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return try StubBackfillClient(dbPath: dir + "/state.db")
    }

    override nonisolated func requestFullHistorySync(durationDays: Int32) throws {
        capture.record(durationDays: durationDays)
    }

    func snapshot() -> StubBackfillCapture.Snapshot { capture.snapshot() }
}
