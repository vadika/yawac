import XCTest
@testable import yawac

/// F104d — verifies `sendPendingAttachments` branches on the staged
/// contact count: a single staged card keeps the existing
/// `sendOneContact` path (single ContactMessage); ≥2 staged cards
/// fire one `sendContacts` call so WhatsApp renders the bubble as a
/// ContactsArrayMessage instead of N separate cards.
@MainActor
final class ConversationViewModelMultiContactSendTests: XCTestCase {

    /// Thread-safe capture shared with the nonisolated bridge overrides.
    /// The WAClient.send* methods are `nonisolated` (called from
    /// ConversationViewModel on MainActor but executing synchronously
    /// on the current thread), so the override cannot touch
    /// MainActor-isolated storage — an NSLock-backed @unchecked
    /// Sendable holder is the same shape `StubBackfillCapture` uses.
    final class Capture: @unchecked Sendable {
        struct Single { let jid: String; let vcard: String; let name: String }
        struct Array  { let jid: String; let name: String; let vcards: [String] }
        private let lock = NSLock()
        private var _single: [Single] = []
        private var _array:  [Array]  = []

        func recordSingle(_ s: Single) {
            lock.lock(); defer { lock.unlock() }
            _single.append(s)
        }
        func recordArray(_ a: Array) {
            lock.lock(); defer { lock.unlock() }
            _array.append(a)
        }
        var single: [Single] {
            lock.lock(); defer { lock.unlock() }
            return _single
        }
        var array: [Array] {
            lock.lock(); defer { lock.unlock() }
            return _array
        }
    }

    @MainActor
    final class RecordingClient: WAClient {
        nonisolated let capture = Capture()

        static func make() throws -> RecordingClient {
            let dir = NSTemporaryDirectory()
                .appending("yawac-multi-contact-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            return try RecordingClient(dbPath: dir + "/state.db")
        }

        override nonisolated func sendContact(chatJID: String,
                                              vcard: String,
                                              displayName: String,
                                              ephemeralSeconds: Int32 = 0) throws
            -> BridgeSendResult
        {
            capture.recordSingle(.init(jid: chatJID, vcard: vcard,
                                       name: displayName))
            return BridgeSendResult(messageID: "wamid.single.\(capture.single.count + 1)",
                                    timestamp: 1_700_000_000)
        }

        override nonisolated func sendContacts(chatJID: String,
                                               displayName: String,
                                               vcards: [String],
                                               ephemeralSeconds: Int32 = 0) throws
            -> BridgeSendResult
        {
            capture.recordArray(.init(jid: chatJID, name: displayName,
                                      vcards: vcards))
            return BridgeSendResult(messageID: "wamid.array.\(capture.array.count + 1)",
                                    timestamp: 1_700_000_001)
        }
    }

    func test_single_staged_contact_uses_sendContact() async throws {
        let client = try RecordingClient.make()
        let vm = ConversationViewModel(chatJID: "1@s.whatsapp.net",
                                       client: client)
        vm.stageContact(ContactPayload(
            jid: "11@s.whatsapp.net", displayName: "Anna",
            phone: "+11",
            vcard: "BEGIN:VCARD\nFN:Anna\nEND:VCARD"))
        await vm.sendPendingAttachments()
        XCTAssertEqual(client.capture.single.count, 1)
        XCTAssertEqual(client.capture.array.count, 0)
    }

    func test_two_staged_contacts_use_sendContacts() async throws {
        let client = try RecordingClient.make()
        let vm = ConversationViewModel(chatJID: "1@s.whatsapp.net",
                                       client: client)
        vm.stageContact(ContactPayload(
            jid: "11@s.whatsapp.net", displayName: "Anna",
            phone: "+11",
            vcard: "BEGIN:VCARD\nFN:Anna\nEND:VCARD"))
        vm.stageContact(ContactPayload(
            jid: "22@s.whatsapp.net", displayName: "Bob",
            phone: "+22",
            vcard: "BEGIN:VCARD\nFN:Bob\nEND:VCARD"))
        await vm.sendPendingAttachments()
        XCTAssertEqual(client.capture.single.count, 0)
        XCTAssertEqual(client.capture.array.count, 1)
        XCTAssertEqual(client.capture.array.first?.vcards.count, 2)
    }
}
