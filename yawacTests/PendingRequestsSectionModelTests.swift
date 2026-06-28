import XCTest
@testable import yawac

@MainActor
final class PendingRequestsSectionModelTests: XCTestCase {

    func testSingleApproveDropsRowAndDecrements() async {
        let store = JoinRequestStore()
        store.set(chatJID: "g@g.us", count: 2)
        let m = PendingRequestsSectionModel(
            chatJID: "g@g.us",
            updateRequests: { _, action, jids in
                guard action == "approve",
                      jids == ["a@s.whatsapp.net"] else { return [] }
                return [.init(jid: "a@s.whatsapp.net", errorCode: 0)]
            },
            store: store)
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
        let m = PendingRequestsSectionModel(
            chatJID: "g@g.us",
            updateRequests: { _, action, jids in
                guard action == "approve",
                      jids == ["a@s.whatsapp.net",
                               "b@s.whatsapp.net",
                               "c@s.whatsapp.net"] else { return [] }
                return [
                    .init(jid: "a@s.whatsapp.net", errorCode: 0),
                    .init(jid: "b@s.whatsapp.net", errorCode: 403),
                    .init(jid: "c@s.whatsapp.net", errorCode: 0)
                ]
            },
            store: store)
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
