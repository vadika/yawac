import XCTest
@testable import yawac

final class ChatLastTimestampShortTests: XCTestCase {

    // Build a Chat whose lastTimestamp is `offset` seconds before now.
    private func chat(secondsAgo offset: TimeInterval) -> Chat {
        let ts = Int64(Date().timeIntervalSince1970 - offset)
        return Chat(
            jid: "test@s.whatsapp.net",
            name: "Test",
            lastMessage: "",
            lastTimestamp: ts,
            unread: 0
        )
    }

    private func chat(daysAgo days: Int) -> Chat {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let ts = Int64(date.timeIntervalSince1970)
        return Chat(
            jid: "test@s.whatsapp.net",
            name: "Test",
            lastMessage: "",
            lastTimestamp: ts,
            unread: 0
        )
    }

    func testTodayUsesLocaleAwareTime() {
        let s = chat(secondsAgo: 3 * 3600).lastTimestampShort
        XCTAssertTrue(s.contains(":") || s.contains("."),
                      "expected time-of-day with locale separator, got \(s)")
        XCTAssertTrue(s.contains(where: \.isNumber), "expected digits, got \(s)")
        XCTAssertNotEqual(s, "Yest")
    }

    func testYesterdayIsLocalizedNamedDay() {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        let expected = f.localizedString(from: DateComponents(day: -1))
        let s = chat(daysAgo: 1).lastTimestampShort
        XCTAssertEqual(s, expected)
        XCTAssertNotEqual(s, "Yest", "must not emit the old hard-coded literal")
    }

    func testThreeDaysAgoIsWeekday() {
        let s = chat(daysAgo: 3).lastTimestampShort
        XCTAssertFalse(s.contains(where: \.isNumber), "weekday should have no digits, got \(s)")
        XCTAssertFalse(s.isEmpty)
    }

    func testThirtyDaysAgoHasNoYear() {
        let s = chat(daysAgo: 30).lastTimestampShort
        XCTAssertTrue(s.contains(where: \.isNumber), "expected a day number, got \(s)")
        let trailing = s.suffix(3)
        XCTAssertFalse(trailing.first == " " && trailing.dropFirst().allSatisfy(\.isNumber),
                       "30-day form should not include year, got \(s)")
    }

    func testTwoHundredDaysAgoIncludesYear() {
        let s = chat(daysAgo: 200).lastTimestampShort
        let parts = s.split(separator: " ")
        XCTAssertGreaterThanOrEqual(parts.count, 3, "expected '<d> <MMM> <yy>', got \(s)")
        let yearToken = parts.last.map(String.init) ?? ""
        XCTAssertEqual(yearToken.count, 2, "year token should be 2 digits, got \(yearToken)")
        XCTAssertTrue(yearToken.allSatisfy(\.isNumber), "year token should be numeric, got \(yearToken)")
    }

    func testZeroTimestampReturnsEmpty() {
        let s = chat(secondsAgo: 0).lastTimestampShort
        XCTAssertFalse(s.isEmpty)
        let zeroed = Chat(
            jid: "x", name: "x", lastMessage: "",
            lastTimestamp: 0, unread: 0
        )
        XCTAssertEqual(zeroed.lastTimestampShort, "")
    }
}
