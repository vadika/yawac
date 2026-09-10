import XCTest
@testable import yawac

@MainActor
final class HistoryRunTests: XCTestCase {
    private func anchor(_ id: Int) -> SessionViewModel.HistoryAnchor {
        .init(jid: "\(id)@s.whatsapp.net", msgID: "m\(id)", senderJID: "sender", fromMe: false, tsUnix: 100)
    }

    func testDoubleStartOneRoundUsesOneAnchorSnapshotForRequests() async {
        let session = SessionViewModel()
        var fullRequests = 0
        var requests: [Int] = []
        var samples = 0
        var sleeps: [Duration] = []
        session.fullHistoryRequest = { fullRequests += 1 }
        session.historyAnchorLoader = { samples += 1; return (0..<7).map(self.anchor) }
        session.historyRequest = { _, count in requests.append(count) }
        session.historySleep = { sleeps.append($0) }
        session.startFullHistorySync()
        session.startFullHistorySync()
        await session.waitForFullHistorySync()
        XCTAssertEqual(fullRequests, 1)
        XCTAssertEqual(requests, Array(repeating: 200, count: 7))
        XCTAssertEqual(samples, 2)
        XCTAssertEqual(sleeps.last, .seconds(60))
        XCTAssertFalse(session.fullSync.inFlight)
        XCTAssertEqual(session.fullSync.completion, "No older messages observed in the last round")
    }

    func testCancellationWaitsForOutstandingRequestAndStopsScheduling() async {
        let session = SessionViewModel()
        let entered = expectation(description: "request entered")
        var resume: CheckedContinuation<Void, Never>?
        var requests = 0
        session.fullHistoryRequest = {}
        session.historyAnchorLoader = { [self.anchor(1), self.anchor(2)] }
        session.historyRequest = { _, _ in
            requests += 1
            await withCheckedContinuation { resume = $0; entered.fulfill() }
        }
        session.startFullHistorySync()
        await fulfillment(of: [entered], timeout: 2)
        session.cancelFullHistorySync()
        XCTAssertTrue(session.fullSync.inFlight, "An outstanding bridge call still belongs to the run")
        session.startFullHistorySync()
        resume?.resume()
        await session.waitForFullHistorySync()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(session.fullSync.completion, "Cancelled")
        XCTAssertFalse(session.fullSync.inFlight)
    }

    func testTimeoutCancelsTheRunDuringThrottle() async {
        let session = SessionViewModel()
        let throttling = expectation(description: "throttle entered")
        var resumeTimeout: CheckedContinuation<Void, Never>?
        var requests = 0
        session.fullHistoryRequest = {}
        session.historyAnchorLoader = { [self.anchor(1), self.anchor(2)] }
        session.historyTimeoutSleep = { await withCheckedContinuation { resumeTimeout = $0 } }
        session.historyRequest = { _, _ in requests += 1 }
        session.historySleep = { _ in
            throttling.fulfill()
            try await Task.sleep(for: .seconds(3600))
        }
        session.startFullHistorySync()
        await fulfillment(of: [throttling], timeout: 2)
        resumeTimeout?.resume()
        await session.waitForFullHistorySync()
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(session.fullSync.inFlight)
        XCTAssertEqual(session.fullSync.completion, "Timed out waiting for history")
    }

    func testRequestFailureIsReportedAndStopsTheRun() async {
        struct Failure: Error {}
        let session = SessionViewModel()
        var requests = 0
        session.fullHistoryRequest = {}
        session.historyAnchorLoader = { [self.anchor(1), self.anchor(2)] }
        session.historyRequest = { _, _ in requests += 1; throw Failure() }
        session.startFullHistorySync()
        await session.waitForFullHistorySync()
        XCTAssertEqual(requests, 1)
        XCTAssertNotNil(session.fullSync.failure)
        XCTAssertEqual(session.fullSync.completion, "History request failed")
    }
}
