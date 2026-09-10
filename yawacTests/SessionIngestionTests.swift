import XCTest
import SwiftData
@testable import yawac

@MainActor
final class SessionIngestionTests: XCTestCase {
    private func message(_ id: String) -> BridgeMessage {
        BridgeMessage(id: id, chatJID: "123@s.whatsapp.net", senderJID: "456@s.whatsapp.net",
                      senderPushName: "Sender", fromMe: false, timestamp: 1700000000,
                      kind: "text", text: "original", media: nil, poll: nil, quoted: nil,
                      isForwarded: false, location: nil, locationSequence: nil,
                      contact: nil, contactsArray: nil, isViewOnce: false)
    }

    private func withSession(_ body: (SessionViewModel, ModelContainer) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([PersistedMessage.self, PersistedChat.self, PersistedReaction.self,
                             PersistedPollVote.self, PersistedFolder.self])
        let container = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, url: directory.appendingPathComponent("messages.store")))
        let client = try WAClient(dbPath: directory.appendingPathComponent("bridge.sqlite").path)
        let session = SessionViewModel(container: container)
        await session.prepare(client: client, container: container)
        try await body(session, container)
    }

    func testBurstPersistsWithoutAnyViewsOrConversation() async throws {
        try await withSession { session, container in
            for index in 0..<1500 { session.receive(.message(message("m\(index)"))) }
            session.receive(.message(message("m0")))
            await session.flushPendingWrites()
            XCTAssertNil(session.persistenceError)
            XCTAssertNil(session.currentConversation)
            XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessage>()), 1500)
            XCTAssertEqual(session.chatList?.chats.count, 1)
        }
    }

    func testMessageThenEditCommitsInOrder() async throws {
        try await withSession { session, container in
            session.receive(.message(message("m1")))
            session.receive(.messageEdited(chatJID: "123@s.whatsapp.net", messageID: "m1",
                                           newText: "edited", timestamp: 1700000001))
            await session.flushPendingWrites()
            let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedMessage>())
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.text, "edited")
            XCTAssertEqual(session.chatList?.chats.first?.lastMessage, "edited")
        }
    }

    func testEditBeforeTargetSurvivesSeparateBatches() async throws {
        try await withSession { session, container in
            session.receive(.messageEdited(chatJID: "123@s.whatsapp.net", messageID: "m1",
                                           newText: "edited", timestamp: 1700000001))
            await session.flushPendingWrites()
            session.receive(.message(message("m1")))
            await session.flushPendingWrites()
            let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedMessage>())
            XCTAssertEqual(rows.first?.text, "edited")
        }
    }

    func testRawBusRetainsLargeBurstBeforeConsumerStarts() async {
        let bus = WAEventBus()
        for index in 0..<1500 { bus.onEvent("message", jsonPayload: String(index)) }
        var received = 0
        for await event in bus.stream {
            XCTAssertEqual(event.payload, String(received))
            received += 1
            if received == 1500 { break }
        }
        XCTAssertEqual(received, 1500)
    }
    func testEditDuringSnapshotLoadCannotBeOverwrittenBySnapshot() async throws {
        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            func pause(_ built: XCTestExpectation) async {
                await withCheckedContinuation { continuation = $0; built.fulfill() }
            }
            func release() { continuation?.resume(); continuation = nil }
        }
        try await withSession { session, container in
            session.receive(.message(message("m1")))
            let jid = "123@s.whatsapp.net"
            func reaction(_ sender: String, _ emoji: String, _ timestamp: Int64) -> WAClient.Event {
                .reaction(.init(chatJID: jid, targetMessageID: "m1", targetFromMe: false,
                                senderJID: sender, emoji: emoji, timestamp: timestamp))
            }
            session.receive(reaction("removed", "👍", 1))
            session.receive(reaction("unchanged", "❤️", 1))
            let poll = UIMessage(id: "poll", chatJID: jid, senderJID: "sender", fromMe: false,
                timestamp: Date(timeIntervalSince1970: 1700000000),
                body: .poll(question: "Question", options: [], selectableCount: 1))
            session.receive(.message(BridgeMessage(outgoing: poll, ownJID: "own")))
            session.receive(.pollVote(chatJID: jid, pollMessageID: "poll", voterJID: "a", optionHashes: ["old"]))
            session.receive(.pollVote(chatJID: jid, pollMessageID: "poll", voterJID: "b", optionHashes: ["old"]))
            await session.flushPendingWrites()
            let client = try XCTUnwrap(session.client)
            let conversation = ConversationViewModel(chatJID: "123@s.whatsapp.net", client: client,
                context: container.mainContext, writer: session.messageWriter)
            conversation.chatList = session.chatList
            session.currentConversation = conversation
            let built = expectation(description: "snapshot built")
            let gate = Gate()
            conversation.beforeHistoryPresentation = { await gate.pause(built) }
            conversation.loadHistory()
            await fulfillment(of: [built], timeout: 3)
            session.receive(.messageEdited(chatJID: "123@s.whatsapp.net", messageID: "m1",
                newText: "newest", timestamp: 1700000001))
            session.receive(reaction("removed", "", 2))
            session.receive(reaction("new", "😆", 2))
            session.receive(.pollVote(chatJID: jid, pollMessageID: "poll", voterJID: "a", optionHashes: ["new"]))
            await session.flushPendingWrites()
            await gate.release()
            await conversation.waitForHistoryLoad()
            XCTAssertEqual(conversation.messages.first?.body, .text("newest"))
            XCTAssertNil(conversation.reactionsBySender["m1"]?["removed"])
            XCTAssertEqual(conversation.reactionsBySender["m1"]?["unchanged"], "❤️")
            XCTAssertEqual(conversation.reactionsBySender["m1"]?["new"], "😆")
            XCTAssertEqual(conversation.voters(for: "poll")["old"], ["b"])
            XCTAssertEqual(conversation.voters(for: "poll")["new"], ["a"])
        }
    }

    func testDeletionOrdersAfterAdmittedMessagesAndSuppressesReplay() async throws {
        try await withSession { session, container in
            session.receive(.message(message("m1")))
            session.receive(.chatDeleted(chatJID: "123@s.whatsapp.net", timestamp: Int64(Date().timeIntervalSince1970)))
            await session.flushPendingWrites()
            session.receive(.message(message("m1")))
            await session.flushPendingWrites()
            XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessage>()), 0)
            XCTAssertEqual(session.chatList?.chats.count, 0)
        }
    }

    func testOutgoingWithoutConversationPersistsAndEndedSessionRejectsLateSend() async throws {
        try await withSession { session, container in
            let client = try XCTUnwrap(session.client)
            let outgoing = BridgeMessage(outgoing: UIMessage(id: "sent", chatJID: "789@s.whatsapp.net",
                senderJID: "me", fromMe: true, timestamp: .now, body: .text("sent elsewhere")), ownJID: "me")
            try await session.recordOutgoing(outgoing, from: client)
            XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessage>()), 1)
            XCTAssertEqual(session.chatList?.chats.first?.lastMessage, "sent elsewhere")
            await session.stopSessionWork()
            do { try await session.recordOutgoing(message("late"), from: client); XCTFail("Old session accepted a send") }
            catch {}
            session.receive(.message(message("late-event")))
            await session.flushPendingWrites()
            XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessage>()), 1)
        }
    }

}
