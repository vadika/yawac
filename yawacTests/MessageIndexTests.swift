import XCTest
import SQLite3
@testable import yawac

final class MessageIndexTests: XCTestCase {

    private var tmpDB: URL!

    override func setUp() {
        super.setUp()
        tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-fts-\(UUID().uuidString).sqlite")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDB)
        super.tearDown()
    }

    private func makeIndex() -> MessageIndex {
        let idx = MessageIndex(storeURL: tmpDB)
        idx.ensureSchema()
        return idx
    }

    private func field(_ id: String, _ text: String,
                       chat: String = "c@s.whatsapp.net",
                       ts: Int64 = 0, caption: String = "",
                       quoted: String = "", sender: String = "")
        -> MessageIndex.MessageFields
    {
        MessageIndex.MessageFields(
            messageID: id, chatJID: chat, timestamp: ts,
            text: text, caption: caption, quoted: quoted, sender: sender)
    }

    func testSchemaIsIdempotent() {
        let idx = makeIndex()
        idx.ensureSchema()
        idx.ensureSchema()
        XCTAssertEqual(idx.countAll(), 0)
    }

    func testUpsertInsertsRow() {
        let idx = makeIndex()
        idx.upsert(field("m1", "Hello Finland"))
        XCTAssertEqual(idx.countAll(), 1)
    }

    func testUpsertReplacesByID() {
        let idx = makeIndex()
        idx.upsert(field("m1", "first"))
        idx.upsert(field("m1", "second"))
        XCTAssertEqual(idx.countAll(), 1)
        let g = idx.searchGlobal(query: "first", limit: 10)
        XCTAssertEqual(g.count, 0)
        let g2 = idx.searchGlobal(query: "second", limit: 10)
        XCTAssertEqual(g2.count, 1)
    }

    func testDeleteByID() {
        let idx = makeIndex()
        idx.upsert(field("m1", "Finland"))
        idx.delete(messageID: "m1")
        XCTAssertEqual(idx.countAll(), 0)
    }

    func testPrefixMatch() {
        let idx = makeIndex()
        idx.upsert(field("m1", "Finland"))
        XCTAssertEqual(idx.searchGlobal(query: "fin", limit: 10).count, 1)
        XCTAssertEqual(idx.searchGlobal(query: "nland", limit: 10).count, 0)
    }

    func testSearchInChatFilters() {
        let idx = makeIndex()
        idx.upsert(field("m1", "shared term", chat: "A@s.whatsapp.net"))
        idx.upsert(field("m2", "shared term", chat: "B@s.whatsapp.net"))
        let hits = idx.searchInChat(jid: "A@s.whatsapp.net",
                                    query: "shared", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.chatJID, "A@s.whatsapp.net")
    }

    func testInChatOrderedByTimestampAscending() {
        let idx = makeIndex()
        idx.upsert(field("a", "x", ts: 30))
        idx.upsert(field("b", "x", ts: 10))
        idx.upsert(field("c", "x", ts: 20))
        let hits = idx.searchInChat(jid: "c@s.whatsapp.net",
                                    query: "x", limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["b", "c", "a"])
    }

    func testEmptyQueryReturnsEmpty() {
        let idx = makeIndex()
        idx.upsert(field("m1", "Finland"))
        XCTAssertTrue(idx.searchGlobal(query: "", limit: 10).isEmpty)
        XCTAssertTrue(idx.searchGlobal(query: "   ", limit: 10).isEmpty)
    }

    func testSpecialCharsAreStripped() {
        let idx = makeIndex()
        idx.upsert(field("m1", "foo bar"))
        XCTAssertNoThrow(idx.searchGlobal(query: "foo(bar)\"*:", limit: 10))
    }

    func testSnippetMarksHits() {
        let idx = makeIndex()
        idx.upsert(field("m1", "the quick brown fox jumps over"))
        let hits = idx.searchGlobal(query: "brown", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].snippet.contains("⟦brown⟧"),
                      "expected ⟦…⟧ markers, got \(hits[0].snippet)")
    }

    func testMultiFieldIndexed() {
        let idx = makeIndex()
        idx.upsert(MessageIndex.MessageFields(
            messageID: "m1", chatJID: "c@s.whatsapp.net", timestamp: 0,
            text: "", caption: "vacation pic",
            quoted: "earlier reply", sender: "Alice"))
        XCTAssertEqual(idx.searchGlobal(query: "vacation", limit: 10).count, 1)
        XCTAssertEqual(idx.searchGlobal(query: "earlier", limit: 10).count, 1)
        XCTAssertEqual(idx.searchGlobal(query: "alice", limit: 10).count, 1)
    }
}
