import XCTest
@testable import yawac

final class MentionResolverTests: XCTestCase {

    // Simulates SessionViewModel.displayName: unknown PN JID echoes
    // "+<digits>"; the @lid form is the one that actually has the name.
    func testPlusEchoFallbackDoesNotMaskLIDResolution() {
        let out = resolveMentionsText("@165562483245097 caltopo!!") { jid in
            jid == "165562483245097@lid" ? "MariaV" : "+165562483245097"
        }
        XCTAssertEqual(out, "@MariaV caltopo!!")
    }

    func testUnknownEverywhereKeepsPlusDigitsFallback() {
        let out = resolveMentionsText("hi @12345678") { _ in "+12345678" }
        XCTAssertEqual(out, "hi @+12345678")
    }

    func testPNNameResolves() {
        let out = resolveMentionsText("hi @31612345678") { jid in
            jid == "31612345678@s.whatsapp.net" ? "Bob" : "+31612345678"
        }
        XCTAssertEqual(out, "hi @Bob")
    }
}
