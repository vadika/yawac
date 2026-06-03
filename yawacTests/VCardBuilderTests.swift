import XCTest
@testable import yawac

final class VCardBuilderTests: XCTestCase {

    func testBuildVCardShape() {
        let vcard = VCardBuilder.build(
            jid: "358405551234@s.whatsapp.net",
            name: "Anna Berg",
            phone: "+358405551234")
        XCTAssertTrue(vcard.contains("BEGIN:VCARD"))
        XCTAssertTrue(vcard.contains("VERSION:3.0"))
        XCTAssertTrue(vcard.contains("FN:Anna Berg"))
        XCTAssertTrue(vcard.contains("waid=358405551234"))
        XCTAssertTrue(vcard.contains("+358405551234"))
        XCTAssertTrue(vcard.contains("END:VCARD"))
    }

    func testParseWAIDExtraction() {
        let vcard = """
        BEGIN:VCARD
        VERSION:3.0
        FN:Anna Berg
        TEL;type=CELL;waid=358405551234:+358405551234
        END:VCARD
        """
        let waid = VCardBuilder.parseWAID(vcard)
        XCTAssertEqual(waid, "358405551234")
    }

    func testParseWAIDReturnsNilWhenAbsent() {
        let vcard = "BEGIN:VCARD\nVERSION:3.0\nFN:X\nTEL:+1234\nEND:VCARD"
        XCTAssertNil(VCardBuilder.parseWAID(vcard))
    }
}
