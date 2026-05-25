import XCTest
@testable import yawac

@MainActor
final class TranslationStoreTests: XCTestCase {
    func testStartInFlightReturnsTrueOnceFalseOnSecondCall() {
        let store = TranslationStore()
        XCTAssertTrue(store.startInFlight("a"))
        XCTAssertFalse(store.startInFlight("a"))
    }

    func testStartInFlightForDifferentIDsBothSucceed() {
        let store = TranslationStore()
        XCTAssertTrue(store.startInFlight("a"))
        XCTAssertTrue(store.startInFlight("b"))
    }

    func testFinishStoresEntryAndClearsInFlight() {
        let store = TranslationStore()
        _ = store.startInFlight("a")
        let entry = TranslationStore.Entry(
            original: "Hallo",
            translated: "Hello",
            sourceLang: "de",
            showingTranslated: true)
        store.finish("a", with: entry)
        XCTAssertEqual(store.entry(for: "a"), entry)
        XCTAssertTrue(store.startInFlight("a"),
                      "in-flight should be cleared after finish")
    }

    func testFailClearsInFlightWithoutStoringEntry() {
        let store = TranslationStore()
        _ = store.startInFlight("a")
        store.fail("a")
        XCTAssertNil(store.entry(for: "a"))
        XCTAssertTrue(store.startInFlight("a"))
    }

    func testToggleFlipsShowingTranslated() {
        let store = TranslationStore()
        let entry = TranslationStore.Entry(
            original: "Hallo",
            translated: "Hello",
            sourceLang: "de",
            showingTranslated: true)
        store.finish("a", with: entry)
        store.toggle("a")
        XCTAssertEqual(store.entry(for: "a")?.showingTranslated, false)
        store.toggle("a")
        XCTAssertEqual(store.entry(for: "a")?.showingTranslated, true)
    }

    func testToggleOnUnknownIDIsNoop() {
        let store = TranslationStore()
        store.toggle("nope")
        XCTAssertNil(store.entry(for: "nope"))
    }
}
