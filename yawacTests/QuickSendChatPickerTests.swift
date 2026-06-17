import XCTest
@testable import yawac

@MainActor
final class QuickSendChatPickerTests: XCTestCase {

    private func chat(_ jid: String,
                      _ name: String,
                      _ ts: Int64) -> Chat {
        Chat(jid: jid, name: name, lastMessage: "",
             lastTimestamp: ts, unread: 0)
    }

    func testRecentOrderingDESCByLastTimestamp() {
        let all = [
            chat("1@s.whatsapp.net", "Alice", 100),
            chat("2@s.whatsapp.net", "Bob", 300),
            chat("3@s.whatsapp.net", "Carol", 200),
        ]
        let out = QuickSendChatPicker.filter(chats: all, query: "", recentLimit: 5)
        XCTAssertEqual(out.map(\.name), ["Bob", "Carol", "Alice"])
    }

    func testRecentLimitCapsTheList() {
        let all = (0..<30).map { i in
            chat("\(i)@s.whatsapp.net", "Chat\(i)", Int64(i))
        }
        let out = QuickSendChatPicker.filter(chats: all, query: "", recentLimit: 15)
        XCTAssertEqual(out.count, 15)
        XCTAssertEqual(out.first?.name, "Chat29")  // newest
    }

    func testSearchIsCaseInsensitiveAndSubstring() {
        let all = [
            chat("1@s.whatsapp.net", "Alice", 100),
            chat("2@s.whatsapp.net", "Bob", 300),
            chat("3@s.whatsapp.net", "alicia keys", 200),
        ]
        let out = QuickSendChatPicker.filter(chats: all, query: "ali", recentLimit: 100)
        XCTAssertEqual(out.map(\.name), ["alicia keys", "Alice"])
    }

    func testSearchMatchesJIDDigitPrefix() {
        let all = [
            chat("3725060015@s.whatsapp.net", "", 100),
            chat("1234567890@s.whatsapp.net", "", 200),
        ]
        // Unsaved contact: filter by phone prefix.
        let out = QuickSendChatPicker.filter(chats: all, query: "37250", recentLimit: 100)
        XCTAssertEqual(out.map(\.jid), ["3725060015@s.whatsapp.net"])
    }

    func testQueryBypassesRecentLimit() {
        // 30 chats, all named "Match", recentLimit 5. With a matching
        // query the full set should be searchable, not just the top 5.
        let all = (0..<30).map { i in
            chat("\(i)@s.whatsapp.net", "Match\(i)", Int64(i))
        }
        let out = QuickSendChatPicker.filter(chats: all, query: "match",
                                             recentLimit: 5)
        XCTAssertEqual(out.count, 30)
    }
}
