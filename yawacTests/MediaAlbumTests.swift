import XCTest
import SwiftData
@testable import yawac

@MainActor
final class MediaAlbumTests: XCTestCase {
    final class Capture: @unchecked Sendable {
        struct Call {
            let kind: String
            let files: [String]
            let caption: String
            let expiration: Int32
            let viewOnce: Bool
        }
        private let lock = NSLock()
        private var calls: [Call] = []
        private var failureAfter: Int?

        func fail(after count: Int) { lock.lock(); defer { lock.unlock() }; failureAfter = count }
        func record(_ call: Call) -> (Int, Int?) {
            lock.lock(); defer { lock.unlock() }
            calls.append(call)
            return (calls.count, failureAfter)
        }
        var recorded: [Call] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    final class RecordingClient: WAClient {
        nonisolated let capture = Capture()

        override nonisolated func sendAlbum(_ chatJID: String, files: [BridgeAlbumFile], caption: String,
                                            ephemeralSeconds: Int32 = 0) throws -> BridgeAlbumSendResult {
            let (number, failure) = capture.record(.init(kind: "album", files: files.map(\.path),
                                                        caption: caption, expiration: ephemeralSeconds, viewOnce: false))
            if failure == 0 { throw NSError(domain: "test", code: 1) }
            let count = min(failure ?? files.count, files.count)
            return BridgeAlbumSendResult(albumID: "album-\(number)", items: (0..<count).map {
                BridgeSendResult(messageID: "\(number)-\($0)", timestamp: 1_700_000_000)
            }, error: count < files.count ? "offline" : nil)
        }

        override nonisolated func sendImage(_ chatJID: String, path: String, caption: String,
                                            ephemeralSeconds: Int32 = 0, viewOnce: Bool = false) throws -> BridgeSendResult {
            let (number, _) = capture.record(.init(kind: "image", files: [path], caption: caption,
                                                   expiration: ephemeralSeconds, viewOnce: viewOnce))
            return BridgeSendResult(messageID: "single-\(number)", timestamp: 1_700_000_000)
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeVM() throws -> (ConversationViewModel, RecordingClient) {
        let client = try RecordingClient(dbPath: directory.appendingPathComponent("state.db").path)
        return (ConversationViewModel(chatJID: "1@s.whatsapp.net", client: client), client)
    }

    private func attachment(_ name: String, kind: String = "image", viewOnce: Bool = false) throws -> PendingAttachment {
        let url = directory.appendingPathComponent(name)
        try Data("media".utf8).write(to: url)
        return PendingAttachment(url: url, kind: kind, viewOnce: viewOnce)
    }

    private func removeCachedFiles(_ vm: ConversationViewModel) {
        for path in vm.localPaths.values { try? FileManager.default.removeItem(atPath: path) }
    }

    func testMultipleMediaSendAsOneAlbumWithOneCaption() async throws {
        let (vm, client) = try makeVM()
        defer { removeCachedFiles(vm) }
        let files = try [attachment("first.png"), attachment("second.mp4", kind: "video"), attachment("third.png")]
        vm.pendingAttachments = files
        vm.draft = "  Our trip  "
        vm.ephemeralExpirationSeconds = 86400
        await vm.sendPendingAttachments()

        XCTAssertEqual(client.capture.recorded.count, 1)
        let call = try XCTUnwrap(client.capture.recorded.first)
        XCTAssertEqual(call.kind, "album")
        XCTAssertEqual(call.files, files.map { $0.url.path })
        XCTAssertEqual(call.caption, "Our trip")
        XCTAssertEqual(call.expiration, 86400)
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        XCTAssertEqual(vm.draft, "")
        XCTAssertEqual(vm.messages.map(\.albumID), ["album-1", "album-1", "album-1"])
        XCTAssertEqual(vm.messages.map(\.albumIndex), [0, 1, 2])
        let captions = vm.messages.compactMap { message -> String? in
            if case .media(_, let caption, _, _, _, _) = message.body { return caption }
            return nil
        }
        XCTAssertEqual(captions, ["Our trip"])
        guard case .album(let members) = vm.timeline().last else { return XCTFail("Expected one album row") }
        XCTAssertEqual(members.map(\.id), vm.messages.map(\.id))
    }

    func testSinglePhotoAndViewOnceKeepTheirExistingSendPath() async throws {
        let (vm, client) = try makeVM()
        defer { removeCachedFiles(vm) }
        vm.pendingAttachments = try [attachment("first.png"), attachment("private.png", viewOnce: true)]
        vm.draft = "Caption"
        await vm.sendPendingAttachments()
        XCTAssertEqual(client.capture.recorded.map(\.kind), ["image", "image"])
        XCTAssertEqual(client.capture.recorded.map(\.viewOnce), [false, true])
        XCTAssertTrue(vm.messages.allSatisfy { $0.albumID == nil })
        XCTAssertTrue(vm.messages[1].isViewOnce)
    }

    func testFailedAlbumRestoresFilesCaptionAndOtherStagedItems() async throws {
        let (vm, client) = try makeVM()
        let files = try [attachment("first.png"), attachment("second.png")]
        vm.pendingAttachments = files
        vm.draft = "Caption"
        vm.stageLocation(.init(lat: 60, lng: 24, name: "Here", address: ""))
        vm.stageContact(.init(jid: "2@s.whatsapp.net", displayName: "Friend", phone: "2"))
        client.capture.fail(after: 0)
        await vm.sendPendingAttachments()
        XCTAssertEqual(vm.pendingAttachments.map(\.id), files.map(\.id))
        XCTAssertEqual(vm.draft, "Caption")
        XCTAssertEqual(vm.pendingLocations.count, 1)
        XCTAssertEqual(vm.pendingContacts.count, 1)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertNotNil(vm.transientError)
    }

    func testPartialFailureRestoresOnlyUnsentFilesWithoutRepeatingCaption() async throws {
        let (vm, client) = try makeVM()
        defer { removeCachedFiles(vm) }
        let files = try [attachment("first.png"), attachment("second.png"), attachment("third.png")]
        vm.pendingAttachments = files
        vm.draft = "Caption"
        client.capture.fail(after: 1)
        await vm.sendPendingAttachments()
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.albumID, "album-1")
        XCTAssertEqual(vm.pendingAttachments.map(\.id), Array(files.dropFirst()).map(\.id))
        XCTAssertEqual(vm.draft, "")
        XCTAssertNotNil(vm.transientError)
    }

    private func media(_ id: String, album: String?, index: Int?, sender: String = "sender") -> UIMessage {
        var message = UIMessage(id: id, chatJID: "1@s.whatsapp.net", senderJID: sender, fromMe: false,
                                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                body: .media(kind: "image", caption: nil, fileName: nil, localPath: nil))
        message.albumID = album
        message.albumIndex = index
        return message
    }

    func testTimelineGroupsByExplicitAssociationAndOrdersByAlbumIndex() {
        let messages = [media("second", album: "a", index: 1), media("unrelated", album: nil, index: nil),
                        media("first", album: "a", index: 0), media("other-sender", album: "a", index: 2, sender: "other")]
        let rows = TimelineItem.sectioned(messages)
        XCTAssertEqual(rows.count, 4) // date, album, unrelated, other sender
        guard case .album(let members) = rows[1] else { return XCTFail("Expected album") }
        XCTAssertEqual(members.map(\.id), ["first", "second"])
        XCTAssertEqual(rows[2].id, "unrelated")
        XCTAssertEqual(rows[3].id, "other-sender")
    }

    func testLegacyMessagesRemainSeparateAndMissingAlbumIndicesKeepOrder() {
        let rows = TimelineItem.sectioned([media("one", album: nil, index: nil), media("two", album: nil, index: nil)])
        XCTAssertEqual(rows.count, 3)
        let album = TimelineItem.sectioned([media("z", album: "a", index: nil), media("a", album: "a", index: nil)])
        guard case .album(let members) = album.last else { return XCTFail("Expected album") }
        XCTAssertEqual(members.map(\.id), ["z", "a"])
    }

    func testAlbumAssociationSurvivesPersistenceReplayAndReopen() async throws {
        let url = directory.appendingPathComponent("messages.store")
        let schema = Schema([PersistedMessage.self, PersistedReaction.self, PersistedPollVote.self, PersistedChat.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let writer = MessageWriter(container: container, index: MessageIndex(storeURL: url), canonicalize: { $0 })
        let first = BridgeMessage(outgoing: media("first", album: "album", index: 0), ownJID: "me")
        let second = BridgeMessage(outgoing: media("second", album: "album", index: 1), ownJID: "me")
        let decoded = try JSONDecoder().decode(BridgeMessage.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(UIMessage(decoded).albumID, "album")
        _ = try await writer.enqueue([decoded, second])
        _ = try await writer.enqueue([BridgeMessage(outgoing: media("first", album: nil, index: nil), ownJID: "me")])

        let reopened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(reopened)
        let messages = try context.fetch(FetchDescriptor<PersistedMessage>()).map(\.uiMessage)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0.albumID == "album" })
        guard case .album(let members) = TimelineItem.sectioned(messages).last else { return XCTFail("Expected restored album") }
        XCTAssertEqual(members.map(\.id), ["first", "second"])
    }
}
