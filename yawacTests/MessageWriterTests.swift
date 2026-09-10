import XCTest
import SwiftData
import SQLite3
@testable import yawac

@MainActor
final class MessageWriterTests: XCTestCase {
    private var directory: URL!
    private var readContext: ModelContext?
    private var url: URL { directory.appendingPathComponent("messages.store") }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        readContext = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func container() throws -> ModelContainer {
        let schema = Schema([PersistedMessage.self, PersistedReaction.self, PersistedPollVote.self, PersistedChat.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
    }

    private func message(_ id: String = "m1", text: String = "original") throws -> BridgeMessage {
        let object: [String: Any] = [
            "id": id, "chat_jid": "123@lid", "sender_jid": "sender@lid",
            "sender_push_name": "Alice", "from_me": false, "timestamp": 1700000000,
            "kind": "audio", "text": text, "is_forwarded": true, "is_view_once": true,
            "media": ["mime_type": "audio/ogg", "waveform": "AQID", "is_ptt": true,
                      "width": 400, "height": 300, "caption": "caption", "file_name": "voice.ogg"],
            "quoted": ["message_id": "quote", "sender_jid": "sender@lid", "from_me": false,
                       "kind": "text", "snippet": "quoted text"],
            "poll": ["question": "Question?", "options": [["name": "yes", "hash": "abc"]], "selectable_count": 1],
            "location": ["lat": 60.1, "lng": 24.9, "name": "Here", "address": "Address"],
            "contact": ["vcard": "VCARD", "display_name": "Contact"],
            "contacts_array": ["display_name": "Contacts", "contacts": [["vcard": "VCARD2", "display_name": "Second"]]],
        ]
        return try JSONDecoder().decode(BridgeMessage.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func read() throws -> PersistedMessage {
        let context = ModelContext(try container())
        readContext = context
        return try XCTUnwrap(context.fetch(FetchDescriptor<PersistedMessage>()).first)
    }

    func testMetadataSurvivesDiskReopen() async throws {
        let index = MessageIndex(storeURL: url)
        let writer = MessageWriter(container: try container(), index: index, canonicalize: { _ in "123@s.whatsapp.net" })
        let outcomes = try await writer.enqueue([message()])
        XCTAssertFalse(outcomes[0].alreadySeen)
        let row = try read()
        XCTAssertEqual(row.chatJID, "123@s.whatsapp.net")
        XCTAssertEqual(row.senderPushName, "Alice")
        XCTAssertTrue(row.isForwarded)
        XCTAssertTrue(row.isPTT)
        XCTAssertEqual(row.audioWaveform, Data([1, 2, 3]))
        XCTAssertEqual(row.mediaWidth, 400)
        XCTAssertEqual(row.mediaHeight, 300)
        XCTAssertTrue(row.isViewOnce)
        XCTAssertEqual(row.quotedMessageID, "quote")
        XCTAssertEqual(row.locationLat, 60.1)
        XCTAssertEqual(row.contactVCard, "VCARD")
        XCTAssertTrue(try XCTUnwrap(row.contactsJSON).contains("VCARD2"))
        XCTAssertNotNil(row.pollJSON)
        XCTAssertEqual(index.searchGlobal(query: "original", limit: 10).count, 1)
    }

    func testReplayDoesNotUndoEditOrRevoke() async throws {
        let index = MessageIndex(storeURL: url)
        let writer = MessageWriter(container: try container(), index: index, canonicalize: { $0 })
        _ = try await writer.enqueue([message()])
        try await writer.enqueueMutations([.edit(id: "m1", chatJID: "123@lid", newText: "replacement", at: .now)])
        let replay = try await writer.enqueue([message()])
        XCTAssertTrue(replay[0].alreadySeen)
        XCTAssertEqual(try read().text, "replacement")
        XCTAssertTrue(index.searchGlobal(query: "original", limit: 10).isEmpty)
        XCTAssertEqual(index.searchGlobal(query: "replacement", limit: 10).count, 1)
        try await writer.enqueueMutations([.revoke(id: "m1", chatJID: "123@lid", by: "sender", at: .now)])
        _ = try await writer.enqueue([message()])
        XCTAssertNotNil(try read().revokedAt)
        XCTAssertEqual(index.countAll(), 0)
    }

    func testFailedSourceCommitRollsBackAndNeverIndexes() async throws {
        struct Failed: Error {}
        let container = try container()
        let index = MessageIndex(storeURL: url)
        let writer = MessageWriter(container: container, index: index,
                                   beforeSave: { throw Failed() }, canonicalize: { $0 })
        do {
            _ = try await writer.enqueue([message()])
            XCTFail("Expected commit failure")
        } catch is Failed {}
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessage>()), 0)
        XCTAssertEqual(index.countAll(), 0)
    }

    func testRepairFindsChangedRowsWithUnchangedCountAndRemovesOrphans() async throws {
        let container = try container()
        let index = MessageIndex(storeURL: url)
        let writer = MessageWriter(container: container, index: index, canonicalize: { $0 })
        _ = try await writer.enqueue([message()])
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<PersistedMessage>()).first)
        row.text = "recovered"
        try context.save() // Simulate interruption between source commit and index update.
        await index.bootstrapIfNeeded()
        XCTAssertEqual(index.searchGlobal(query: "recovered", limit: 10).count, 1)
        XCTAssertTrue(index.searchGlobal(query: "original", limit: 10).isEmpty)
        context.delete(row)
        try context.save()
        await index.bootstrapIfNeeded()
        XCTAssertEqual(index.countAll(), 0)
    }

    func testLargeBurstPersistsOneRowPerID() async throws {
        let container = try container()
        let index = MessageIndex(storeURL: url)
        let writer = MessageWriter(container: container, index: index, canonicalize: { $0 })
        let messages = try (0..<1500).map { try message("m\($0)") }
        let start = Date()
        _ = try await writer.enqueue(messages + messages.prefix(100))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessage>()), 1500)
        XCTAssertEqual(index.countAll(), 1500)
        print("writer benchmark: 1500 unique + 100 replay messages, \(Date().timeIntervalSince(start)) seconds")
    }
    func testPendingMutationsReplayAndBoundUnknownTargets() async throws {
        let writer = MessageWriter(container: try container(), index: MessageIndex(storeURL: url), canonicalize: { $0 })
        for n in 0..<300 {
            try await writer.enqueueMutations([.edit(id: "m\(n)", chatJID: "123@lid", newText: "edited", at: .now)])
        }
        try await writer.enqueueMutations([.revoke(id: "m299", chatJID: "123@lid", by: "sender", at: .now)])
        let commit = try await writer.write([.message(message("m0")), .message(message("m299"))])
        XCTAssertNil(commit.changed.first { $0.id == "m0" }?.editedAt)
        XCTAssertNotNil(commit.changed.first { $0.id == "m299" }?.editedAt)
        XCTAssertNotNil(commit.changed.first { $0.id == "m299" }?.revokedAt)
    }

    func testReceiptAndVoteUpdatesSurviveDiskReopen() async throws {
        let writer = MessageWriter(container: try container(), index: MessageIndex(storeURL: url), canonicalize: { $0 })
        try await writer.enqueueMutations([.delivery(id: "m1", status: "read")])
        _ = try await writer.enqueue([message()])
        try await writer.enqueueMutations([.delivery(id: "m1", status: "delivered")])
        _ = try await writer.write([.vote(chat: "123@lid", message: "m1", voter: "me", hashes: ["a"], at: Date(timeIntervalSince1970: 1))])
        _ = try await writer.write([.vote(chat: "123@lid", message: "m1", voter: "me", hashes: ["b"], at: Date(timeIntervalSince1970: 2))])
        let context = ModelContext(try container())
        XCTAssertEqual(try context.fetch(FetchDescriptor<PersistedMessage>()).first?.deliveryStatus, "read")
        let votes = try context.fetch(FetchDescriptor<PersistedPollVote>())
        XCTAssertEqual(votes.count, 1)
        XCTAssertEqual(votes.first?.optionHashesJSON, "[\"b\"]")
    }

    func testViewOnceCommitLocksReplayAndDeletesFile() async throws {
        let writer = MessageWriter(container: try container(), index: MessageIndex(storeURL: url), canonicalize: { $0 })
        let path = directory.appendingPathComponent("media.jpg")
        try Data([1, 2, 3]).write(to: path)
        _ = try await writer.enqueue([message()])
        try await writer.enqueueMutations([.mediaPath(id: "m1", path: path.path)])
        try await writer.enqueueMutations([.viewOnce(id: "m1")])
        _ = try await writer.enqueue([message()])
        let row = try read()
        XCTAssertTrue(row.viewOnceLocked)
        XCTAssertNil(row.mediaPath)
        XCTAssertNil(row.mediaCaption)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testMergeRebindAndPurgeSurviveDiskReopen() async throws {
        let store = try container()
        let seed = ModelContext(store)
        let lid = PersistedChat(jid: "123@lid", name: "Alice", lastMessageText: "old", lastTimestamp: .now, unread: 2)
        let pn = PersistedChat(jid: "123@s.whatsapp.net", name: "123@s.whatsapp.net", lastMessageText: "older", lastTimestamp: .distantPast, unread: 3)
        seed.insert(lid); seed.insert(pn)
        seed.insert(PersistedChat(jid: "456:7@s.whatsapp.net", name: "Bob"))
        try seed.save()
        let index = MessageIndex(storeURL: url)
        let writer = MessageWriter(container: store, index: index, canonicalize: { $0 })
        _ = try await writer.enqueue([message()])
        _ = try await writer.write([.vote(chat: "123@lid", message: "m1", voter: "voter", hashes: ["a"], at: .now)])
        try await writer.mergeChats([(lid: "123@lid", pn: "123@s.whatsapp.net"),
                                     (lid: "456:7@s.whatsapp.net", pn: "456@s.whatsapp.net")])
        let reopened = ModelContext(try container())
        let chats = try reopened.fetch(FetchDescriptor<PersistedChat>())
        XCTAssertEqual(chats.count, 2)
        XCTAssertEqual(chats.first { $0.jid == "123@s.whatsapp.net" }?.unread, 5)
        XCTAssertTrue(chats.contains { $0.jid == "456@s.whatsapp.net" })
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<PersistedMessage>()).first?.chatJID, "123@s.whatsapp.net")
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<PersistedPollVote>()).first?.chatJID, "123@s.whatsapp.net")
        try await writer.purgeChat("123@s.whatsapp.net")
        let purged = ModelContext(try container())
        XCTAssertEqual(try purged.fetchCount(FetchDescriptor<PersistedMessage>()), 0)
        XCTAssertEqual(try purged.fetchCount(FetchDescriptor<PersistedPollVote>()), 0)
        XCTAssertEqual(try purged.fetchCount(FetchDescriptor<PersistedChat>()), 1)
        XCTAssertEqual(index.countAll(), 0)
    }

    func testAllOutgoingBodiesRoundTrip() async throws {
        let contact = ContactPayload(jid: "123@s.whatsapp.net", displayName: "Name", phone: "+123")
        let bodies: [UIMessage.Body] = [
            .text("text"), .system("system"),
            .media(kind: "audio", caption: "caption", fileName: "voice.ogg", localPath: "/tmp/voice.ogg", waveform: Data([1, 2]), isPTT: true),
            .poll(question: "Question", options: [.init(name: "Yes", hash: "hash")], selectableCount: 1),
            .location(.init(lat: 60, lng: 24, name: "Here", address: "Address"), isLive: true, sequence: 10),
            .contact(contact), .contacts([contact])
        ]
        let writer = MessageWriter(container: try container(), index: MessageIndex(storeURL: url), canonicalize: { $0 })
        let messages = bodies.enumerated().map { n, body -> BridgeMessage in
            var message = UIMessage(id: "out\(n)", chatJID: "chat", senderJID: "me", fromMe: true, timestamp: .now, body: body)
            message.isForwarded = true
            message.quotedMessageID = "quote"
            return BridgeMessage(outgoing: message, ownJID: "own")
        }
        _ = try await writer.enqueue(messages)
        let reopened = ModelContext(try container())
        let rows = try reopened.fetch(FetchDescriptor<PersistedMessage>())
        for (n, body) in bodies.enumerated() {
            let row = try XCTUnwrap(rows.first { $0.id == "out\(n)" })
            XCTAssertEqual(row.uiMessage.body, body)
            XCTAssertEqual(row.senderJID, "own")
            XCTAssertEqual(row.quotedMessageID, "quote")
            XCTAssertTrue(row.isForwarded)
        }
    }

    func testFailedViewOnceSaveLeavesFileAndReplayStateIntact() async throws {
        struct Failed: Error {}
        let container = try container()
        let index = MessageIndex(storeURL: url)
        let writer = MessageWriter(container: container, index: index, canonicalize: { $0 })
        let path = directory.appendingPathComponent("once.bin")
        try Data([1]).write(to: path)
        _ = try await writer.enqueue([message()])
        try await writer.enqueueMutations([.mediaPath(id: "m1", path: path.path)])
        let failing = MessageWriter(container: container, index: index, beforeSave: { throw Failed() }, canonicalize: { $0 })
        do { try await failing.enqueueMutations([.viewOnce(id: "m1")]); XCTFail("Save unexpectedly succeeded") }
        catch is Failed {}
        XCTAssertFalse(try read().viewOnceLocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testUnavailableIndexDoesNotTurnCommittedSourceIntoFailure() async throws {
        let container = try container()
        let unavailable = MessageIndex(storeURL: directory) // A directory cannot be a SQLite database.
        let writer = MessageWriter(container: container, index: unavailable, canonicalize: { $0 })
        let outcomes = try await writer.enqueue([message()])
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessage>()), 1)
        if case .failed = unavailable.progress {} else { XCTFail("Search failure was not surfaced") }
        let repaired = MessageIndex(storeURL: url)
        try repaired.reconcile()
        XCTAssertEqual(repaired.searchGlobal(query: "original", limit: 10).count, 1)
    }

    func testReactionReplacementAndRemovalSurviveReopen() async throws {
        let writer = MessageWriter(container: try container(), index: MessageIndex(storeURL: url), canonicalize: { $0 })
        func reaction(_ emoji: String, _ time: Int64) -> BridgeReaction {
            .init(chatJID: "chat", targetMessageID: "m1", targetFromMe: false,
                  senderJID: "sender", emoji: emoji, timestamp: time)
        }
        try await writer.enqueueReactions([reaction("👍", 1), reaction("❤️", 2)])
        let reopened = ModelContext(try container())
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<PersistedReaction>()).first?.emoji, "❤️")
        try await writer.enqueueReactions([reaction("", 3)])
        XCTAssertEqual(try ModelContext(try container()).fetchCount(FetchDescriptor<PersistedReaction>()), 0)
    }

}
