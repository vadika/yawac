import XCTest
@testable import yawac

/// F123: displayName must find a contact name keyed under the @lid
/// form when asked for the PN form (reverse of the canonical lookup).
@MainActor
final class SessionViewModelDisplayNameTests: XCTestCase {

    final class StubLIDClient: WAClient {
        override nonisolated func resolvePNToLID(_ jid: String) -> String {
            jid == "358400929611@s.whatsapp.net" ? "228732912554197@lid" : jid
        }

        static func make() throws -> StubLIDClient {
            let dir = NSTemporaryDirectory()
                .appending("yawac-displayname-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            return try StubLIDClient(dbPath: dir + "/state.db")
        }
    }

    func testPNLookupFindsLIDKeyedName() throws {
        let session = SessionViewModel()
        session.client = try StubLIDClient.make()
        session.ingestPushName(jid: "228732912554197@lid", name: "Marjaana")
        XCTAssertEqual(session.displayName(for: "358400929611@s.whatsapp.net"),
                       "Marjaana")
    }
}
