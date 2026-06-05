import XCTest
@testable import yawac

/// Covers `SessionViewModel.fetchSelfInfo` — the helper that
/// hydrates the "About me" Settings section by calling
/// `WAClient.getUserInfo(jid: ownJID)`.
///
/// We only exercise the early-return guards here; the live IQ
/// path requires a real pairing and is covered by manual smoke.
@MainActor
final class OwnProfileEditTests: XCTestCase {

    func testFetchSelfInfoReturnsNilWithNilClient() async {
        let svm = SessionViewModel()
        let info = await svm.fetchSelfInfo()
        XCTAssertNil(info)
    }

    func testFetchSelfInfoReturnsNilWithEmptyOwnJID() async throws {
        let svm = SessionViewModel()
        svm.client = try StubSelfChatClient.make(ownJID: "")
        let info = await svm.fetchSelfInfo()
        XCTAssertNil(info)
    }
}
