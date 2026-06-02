import XCTest
@testable import yawac

@MainActor
final class PendingRequestsSectionModelTests: XCTestCase {

    func testSingleApproveDropsRowAndDecrements() async {
        let store = JoinRequestStore()
        store.set(chatJID: "g@g.us", count: 2)
        let stub = StubRequestUpdater(responses: [
            "approve+[a@s.whatsapp.net]": [.init(jid: "a@s.whatsapp.net", errorCode: 0)]
        ])
        let m = PendingRequestsSectionModel(
            chatJID: "g@g.us",
            updater: stub, store: store)
        m.requests = [
            .init(jid: "a@s.whatsapp.net", displayName: "Anna", requestedAt: 1),
            .init(jid: "b@s.whatsapp.net", displayName: "B",    requestedAt: 1)
        ]
        await m.approve(jid: "a@s.whatsapp.net")
        XCTAssertEqual(m.requests.map(\.jid), ["b@s.whatsapp.net"])
        XCTAssertEqual(store.counts["g@g.us"], 1)
    }

    func testBulkApproveKeepsFailedRows() async {
        let store = JoinRequestStore()
        store.set(chatJID: "g@g.us", count: 3)
        let stub = StubRequestUpdater(responses: [
            "approve+[a@s.whatsapp.net,b@s.whatsapp.net,c@s.whatsapp.net]": [
                .init(jid: "a@s.whatsapp.net", errorCode: 0),
                .init(jid: "b@s.whatsapp.net", errorCode: 403),
                .init(jid: "c@s.whatsapp.net", errorCode: 0)
            ]
        ])
        let m = PendingRequestsSectionModel(
            chatJID: "g@g.us", updater: stub, store: store)
        m.requests = [
            .init(jid: "a@s.whatsapp.net", displayName: "A", requestedAt: 1),
            .init(jid: "b@s.whatsapp.net", displayName: "B", requestedAt: 1),
            .init(jid: "c@s.whatsapp.net", displayName: "C", requestedAt: 1)
        ]
        await m.approveAll()
        XCTAssertEqual(m.requests.map(\.jid), ["b@s.whatsapp.net"])
        XCTAssertEqual(store.counts["g@g.us"], 1)
        XCTAssertNotNil(m.error)
    }
}

final class StubRequestUpdater: RequestUpdater, @unchecked Sendable {
    var responses: [String: [BridgeJoinRequestResult]] = [:]
    init(responses: [String: [BridgeJoinRequestResult]] = [:]) {
        self.responses = responses
    }
    func updateGroupJoinRequests(chatJID: String,
                                 action: String,
                                 jids: [String]) throws -> [BridgeJoinRequestResult] {
        let key = "\(action)+[\(jids.joined(separator: ","))]"
        return responses[key] ?? []
    }
}
