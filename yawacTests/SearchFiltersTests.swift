import XCTest
@testable import yawac

/// Coverage for the v0.8.4 SearchFilters surface: every filter
/// dimension applied through `searchInChat` / `searchGlobal`, plus
/// the combined-AND semantics check.
final class SearchFiltersTests: XCTestCase {

    private var tmpDB: URL!

    override func setUp() {
        super.setUp()
        tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-filters-\(UUID().uuidString).sqlite")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDB)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeIndex() -> MessageIndex {
        let idx = MessageIndex(storeURL: tmpDB)
        idx.ensureSchema()
        return idx
    }

    /// Tuple shape: (msgid, chatjid, ts, kind, text, sender_push_name).
    private func seed(_ idx: MessageIndex,
                      _ rows: [(String, String, Int64, String, String, String)]) {
        for r in rows {
            idx.upsert(.init(
                messageID: r.0, chatJID: r.1, timestamp: r.2,
                kind: r.3, text: r.4, caption: "", quoted: "",
                sender: r.5, fromMe: false))
        }
    }

    // MARK: - Tests

    func testSenderFilterRestrictsResults() {
        let idx = makeIndex()
        seed(idx, [
            ("m1", "g@g.us", 1_700_000_000, "text", "hello", "Anna"),
            ("m2", "g@g.us", 1_700_000_010, "text", "hello", "Bob"),
        ])
        var f = MessageIndex.SearchFilters()
        f.sender = "Anna"
        let hits = idx.searchInChat(jid: "g@g.us", query: "hello",
                                    filters: f, limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m1"])
    }

    func testKindFilterRestrictsResults() {
        let idx = makeIndex()
        seed(idx, [
            ("m1", "g@g.us", 1_700_000_000, "text",  "hello", "A"),
            ("m2", "g@g.us", 1_700_000_010, "image", "hello", "A"),
        ])
        var f = MessageIndex.SearchFilters()
        f.kind = "image"
        let hits = idx.searchInChat(jid: "g@g.us", query: "hello",
                                    filters: f, limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m2"])
    }

    func testDateRangeFilter() {
        let idx = makeIndex()
        seed(idx, [
            ("m1", "g@g.us", 1_700_000_000, "text", "hello", "A"),
            ("m2", "g@g.us", 1_700_100_000, "text", "hello", "A"),
            ("m3", "g@g.us", 1_700_200_000, "text", "hello", "A"),
        ])
        var f = MessageIndex.SearchFilters()
        f.fromTimestamp = 1_700_050_000
        f.toTimestamp   = 1_700_150_000
        let hits = idx.searchInChat(jid: "g@g.us", query: "hello",
                                    filters: f, limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m2"])
    }

    func testFromOnlyDateFilter() {
        let idx = makeIndex()
        seed(idx, [
            ("m1", "g@g.us", 100, "text", "hello", "A"),
            ("m2", "g@g.us", 200, "text", "hello", "A"),
            ("m3", "g@g.us", 300, "text", "hello", "A"),
        ])
        var f = MessageIndex.SearchFilters()
        f.fromTimestamp = 150
        let hits = idx.searchInChat(jid: "g@g.us", query: "hello",
                                    filters: f, limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m2", "m3"])
    }

    func testCombinedFiltersUseAnd() {
        let idx = makeIndex()
        seed(idx, [
            ("m1", "g@g.us", 100, "text",  "hello", "Anna"),
            ("m2", "g@g.us", 100, "image", "hello", "Anna"),
            ("m3", "g@g.us", 100, "image", "hello", "Bob"),
            ("m4", "g@g.us", 500, "image", "hello", "Anna"),
        ])
        var f = MessageIndex.SearchFilters()
        f.sender = "Anna"
        f.kind   = "image"
        f.toTimestamp = 200
        let hits = idx.searchInChat(jid: "g@g.us", query: "hello",
                                    filters: f, limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m2"])
    }

    func testGlobalChatFilter() {
        let idx = makeIndex()
        seed(idx, [
            ("m1", "a@g.us", 1_700_000_000, "text", "hello", "A"),
            ("m2", "b@g.us", 1_700_000_010, "text", "hello", "A"),
        ])
        let hits = idx.searchGlobal(query: "hello",
                                    filters: .init(),
                                    chatJID: "a@g.us",
                                    limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m1"])
    }

    func testGlobalSenderFilter() {
        let idx = makeIndex()
        seed(idx, [
            ("m1", "a@g.us", 1, "text", "hello", "Anna"),
            ("m2", "b@g.us", 2, "text", "hello", "Bob"),
        ])
        var f = MessageIndex.SearchFilters()
        f.sender = "Bob"
        let hits = idx.searchGlobal(query: "hello",
                                    filters: f, limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m2"])
    }

    func testEmptyFiltersMatchesAllPriorBehavior() {
        let idx = makeIndex()
        seed(idx, [
            ("m1", "g@g.us", 1, "text", "hello world", "A"),
            ("m2", "g@g.us", 2, "text", "hello world", "B"),
        ])
        let hits = idx.searchInChat(jid: "g@g.us", query: "hello",
                                    filters: .init(), limit: 10)
        XCTAssertEqual(Set(hits.map(\.messageID)), ["m1", "m2"])
    }

    func testIsEmptyHelper() {
        XCTAssertTrue(MessageIndex.SearchFilters().isEmpty)
        var f = MessageIndex.SearchFilters()
        f.sender = "X"
        XCTAssertFalse(f.isEmpty)
    }
}
