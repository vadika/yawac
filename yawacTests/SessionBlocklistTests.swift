import XCTest
@testable import yawac

@MainActor
final class SessionBlocklistTests: XCTestCase {

    func testApplyChangesBlockThenUnblock() {
        let s = SessionViewModel()
        s.applyBlocklistChange(action: "",
            changes: [(jid: "1@s.whatsapp.net", action: "block")])
        XCTAssertTrue(s.isBlocked("1@s.whatsapp.net"))
        s.applyBlocklistChange(action: "",
            changes: [(jid: "1@s.whatsapp.net", action: "unblock")])
        XCTAssertFalse(s.isBlocked("1@s.whatsapp.net"))
    }

    func testIsBlockedStripsDeviceSuffix() {
        let s = SessionViewModel()
        s.applyBlocklistChange(action: "",
            changes: [(jid: "1@s.whatsapp.net", action: "block")])
        // A device-suffixed JID for the same user resolves to blocked.
        XCTAssertTrue(s.isBlocked("1:23@s.whatsapp.net"))
    }
}
