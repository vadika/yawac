import XCTest
@testable import yawac

/// Verifies the deliberately-naive phone formatter in `BlockedPanel`.
/// The Settings → Blocked redesign promises "never show a raw JID";
/// this helper does the heavy lifting for the "formatted phone" branch,
/// so regressions in the country-code split would silently leak digits
/// next to user-visible names.
final class BlockedPanelPhoneFormatTests: XCTestCase {

    // MARK: - formatPhone

    func testFinnishMobile() {
        // +358 (FI, 3-digit CC), 9-digit body: last 4 right-aligned,
        // remainder right-aligned into 3-digit chunks.
        XCTAssertEqual(BlockedPanel.formatPhone("358401234567"),
                       "+358 40 123 4567")
    }

    func testRussianMobile() {
        // +7 (RU, 1-digit CC since 7 is not in the known 2/3-digit sets)
        XCTAssertEqual(BlockedPanel.formatPhone("79161234567"),
                       "+7 916 123 4567")
    }

    func testUSMobile() {
        // +1 (US, 1-digit CC) + standard 10-digit NANP body
        XCTAssertEqual(BlockedPanel.formatPhone("14155552671"),
                       "+1 415 555 2671")
    }

    func testUKMobile() {
        // +44 (GB, 2-digit CC) + 7700 900123
        XCTAssertEqual(BlockedPanel.formatPhone("447700900123"),
                       "+44 770 090 0123")
    }

    func testGermanMobile() {
        // +49 (DE, 2-digit CC), 11-digit body — last 4 right-aligned,
        // remainder right-aligned into 3-digit groups (so the leading
        // chunk takes the leftover digit).
        XCTAssertEqual(BlockedPanel.formatPhone("4915123456789"),
                       "+49 1 512 345 6789")
    }

    func testShortTailUsesTwoDigitGroups() {
        // Short body (<=6) flips to 2-digit groups instead of 3.
        XCTAssertEqual(BlockedPanel.formatPhone("358123456"),
                       "+358 12 34 56")
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(BlockedPanel.formatPhone(""), "")
    }

    func testSingleDigitReturnsPlusOnly() {
        XCTAssertEqual(BlockedPanel.formatPhone("9"), "+9")
    }

    // MARK: - maskedID

    func testMaskShortIDReturnsAsIs() {
        // <=6 chars: just slap a + in front and call it a day.
        XCTAssertEqual(BlockedPanel.maskedID("abcdef"), "+abcdef")
    }

    func testMaskLongIDChunksWithEllipsis() {
        // Mirrors the spec example shape: +109 95 452 47744…
        XCTAssertEqual(BlockedPanel.maskedID("1099545247744"),
                       "+109 95 452 47744…")
    }
}
