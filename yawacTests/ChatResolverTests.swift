import XCTest
@testable import yawac

final class ChatResolverTests: XCTestCase {

    func testEmptyInputThrowsNotFound() {
        XCTAssertThrowsError(
            try ChatResolver.resolveChat("", in: [makeChat("1@s.whatsapp.net", "Alice")])
        ) { err in
            guard case ChatResolveError.notFound = err else {
                XCTFail("expected notFound, got \(err)")
                return
            }
        }
    }

    func testPhoneMatchesWhatsAppNet() throws {
        let chats = [
            makeChat("12345@s.whatsapp.net", "Alice"),
            makeChat("67890@s.whatsapp.net", "Bob"),
        ]
        let out = try ChatResolver.resolveChat("12345", in: chats)
        XCTAssertEqual(out.jid, "12345@s.whatsapp.net")
    }

    func testPhoneMatchesLIDFallback() throws {
        let chats = [makeChat("99999@lid", "Carol")]
        let out = try ChatResolver.resolveChat("99999", in: chats)
        XCTAssertEqual(out.jid, "99999@lid")
    }

    func testPhoneWithPlusAndSpacesNormalized() throws {
        let chats = [makeChat("12345550100@s.whatsapp.net", "Alice")]
        let out = try ChatResolver.resolveChat("+1 234 555-0100", in: chats)
        XCTAssertEqual(out.jid, "12345550100@s.whatsapp.net")
    }

    func testExactNameMatch() throws {
        let chats = [
            makeChat("1@s.whatsapp.net", "Alice"),
            makeChat("2@s.whatsapp.net", "Bob"),
        ]
        let out = try ChatResolver.resolveChat("Alice", in: chats)
        XCTAssertEqual(out.jid, "1@s.whatsapp.net")
    }

    func testSubstringNameMatchCaseInsensitive() throws {
        let chats = [makeChat("1@s.whatsapp.net", "Alice Smith")]
        let out = try ChatResolver.resolveChat("alice", in: chats)
        XCTAssertEqual(out.jid, "1@s.whatsapp.net")
    }

    func testAmbiguousNameThrows() {
        let chats = [
            makeChat("1@s.whatsapp.net", "Alice Smith"),
            makeChat("2@s.whatsapp.net", "Alice Jones"),
        ]
        XCTAssertThrowsError(try ChatResolver.resolveChat("alice", in: chats)) { err in
            guard case let ChatResolveError.ambiguous(_, matches) = err else {
                XCTFail("expected ambiguous, got \(err)")
                return
            }
            XCTAssertEqual(matches.sorted(), ["Alice Jones", "Alice Smith"])
        }
    }

    func testNoMatchThrowsNotFound() {
        let chats = [makeChat("1@s.whatsapp.net", "Alice")]
        XCTAssertThrowsError(try ChatResolver.resolveChat("Charlie", in: chats)) { err in
            guard case ChatResolveError.notFound = err else {
                XCTFail("expected notFound, got \(err)")
                return
            }
        }
    }

    private func makeChat(_ jid: String, _ name: String) -> Chat {
        Chat(jid: jid, name: name, lastMessage: "", lastTimestamp: 0, unread: 0)
    }
}
