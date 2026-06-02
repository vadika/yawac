import XCTest
@testable import yawac

@MainActor
final class JoinRequestStoreTests: XCTestCase {

    func testDecrementClampsAtZero() {
        let store = JoinRequestStore()
        store.set(chatJID: "g1@g.us", count: 2)
        store.decrement(chatJID: "g1@g.us", by: 5)
        XCTAssertEqual(store.counts["g1@g.us"] ?? -1, 0)
    }

    func testClearRemovesEntry() {
        let store = JoinRequestStore()
        store.set(chatJID: "g1@g.us", count: 3)
        store.clear(chatJID: "g1@g.us")
        XCTAssertNil(store.counts["g1@g.us"])
    }

    func testRefreshSetsCountFromClient() async {
        let client = StubJoinRequestClient(responses: [
            "g1@g.us": [BridgeJoinRequest(jid: "u@s.whatsapp.net",
                                          requestedAt: 1)]
        ])
        let store = JoinRequestStore(client: client)
        await store.refresh(chatJID: "g1@g.us")
        XCTAssertEqual(store.counts["g1@g.us"], 1)
    }

    func testRefreshAllAdminBoundedConcurrency() async {
        let probe = ConcurrencyProbe()
        let chats = (0..<10).map { "g\($0)@g.us" }
        let client = StubJoinRequestClient(probe: probe,
                                           responsesFor: chats)
        let store = JoinRequestStore(client: client)
        await store.refreshAllAdmin(chatJIDs: chats)
        XCTAssertLessThanOrEqual(probe.peakConcurrency, 4)
        for chat in chats {
            XCTAssertEqual(store.counts[chat], 1, "missing \(chat)")
        }
    }
}

final class ConcurrencyProbe: @unchecked Sendable {
    private var inFlight = 0
    private(set) var peakConcurrency = 0
    private let lock = NSLock()
    func enter() {
        lock.lock(); defer { lock.unlock() }
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
    }
    func leave() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
    }
}

final class StubJoinRequestClient: JoinRequestClient, @unchecked Sendable {
    private let responses: [String: [BridgeJoinRequest]]
    private let probe: ConcurrencyProbe?
    init(responses: [String: [BridgeJoinRequest]] = [:],
         probe: ConcurrencyProbe? = nil) {
        self.responses = responses
        self.probe = probe
    }
    convenience init(probe: ConcurrencyProbe, responsesFor chats: [String]) {
        let map = Dictionary(uniqueKeysWithValues: chats.map {
            ($0, [BridgeJoinRequest(jid: "u@s.whatsapp.net", requestedAt: 1)])
        })
        self.init(responses: map, probe: probe)
    }
    func getGroupJoinRequests(chatJID: String) throws -> [BridgeJoinRequest] {
        probe?.enter()
        defer { probe?.leave() }
        Thread.sleep(forTimeInterval: 0.02)
        return responses[chatJID] ?? []
    }
}
