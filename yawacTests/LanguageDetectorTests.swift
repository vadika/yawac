import XCTest
@testable import yawac

final class LanguageDetectorTests: XCTestCase {
    func testDetectsGerman() {
        let lang = LanguageDetector.detect(
            "Guten Tag, wie geht es Ihnen heute Morgen?")
        XCTAssertEqual(lang, "de")
    }

    func testDetectsFinnish() {
        let lang = LanguageDetector.detect(
            "Hei, miten voit tänä aamuna ystäväni?")
        XCTAssertEqual(lang, "fi")
    }

    func testDetectsEnglish() {
        let lang = LanguageDetector.detect(
            "Hello there, this is a perfectly normal sentence.")
        XCTAssertEqual(lang, "en")
    }

    func testRejectsTooShort() {
        XCTAssertNil(LanguageDetector.detect("Hi"))
        XCTAssertNil(LanguageDetector.detect("Hello!"))
    }

    func testRejectsEmojiOnly() {
        XCTAssertNil(LanguageDetector.detect("👍😊🚀🎉🔥"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(LanguageDetector.detect(""))
        XCTAssertNil(LanguageDetector.detect("           "))
    }

    func testCacheReturnsSameResult() {
        let text = "Bonjour mes amis comment allez-vous aujourd'hui"
        let a = LanguageDetector.detect(text)
        let b = LanguageDetector.detect(text)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }
}
