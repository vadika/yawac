import XCTest
import SwiftData
@testable import yawac

final class WhatsAppLinkTests: XCTestCase {
    func testChatURLForms() throws {
        for value in ["whatsapp://send?phone=358401234567", "https://wa.me/358401234567",
                      "https://wa.me/+358401234567/", "https://api.whatsapp.com/send?phone=%2B358401234567",
                      "https://web.whatsapp.com/send/?phone=358401234567", "WHATSAPP://SEND?phone=358401234567"] {
            XCTAssertEqual(WhatsAppLink.parse(try XCTUnwrap(URL(string: value))),
                           .chat(phone: "358401234567", text: nil), value)
        }
    }

    func testTextDecodingPreservesUnicodeNewlinesAndEncodedPlus() throws {
        let url = try XCTUnwrap(URL(string: "whatsapp://send?phone=358401234567&text=Hi+there%2B%20%F0%9F%91%8B%0A100%25%20%2520"))
        XCTAssertEqual(WhatsAppLink.parse(url), .chat(phone: "358401234567", text: "Hi there+ 👋\n100% %20"))
    }

    func testShareLinksWithoutRecipient() throws {
        for value in ["whatsapp://send?text=Hello", "https://wa.me/?text=Hello", "https://api.whatsapp.com/send?text=Hello"] {
            XCTAssertEqual(WhatsAppLink.parse(try XCTUnwrap(URL(string: value))), .share(text: "Hello"))
        }
        XCTAssertEqual(WhatsAppLink.parse(URL(string: "whatsapp://send")!), .share(text: ""))
        XCTAssertEqual(WhatsAppLink.parse(URL(string: "whatsapp://app")!), .app)
    }

    func testInvites() throws {
        for value in ["whatsapp://chat?code=AbCdEfGhIjKlMnOpQr", "https://chat.whatsapp.com/AbCdEfGhIjKlMnOpQr?mode=ac_t"] {
            XCTAssertEqual(WhatsAppLink.parse(try XCTUnwrap(URL(string: value))), .invite(code: "AbCdEfGhIjKlMnOpQr"))
        }
    }

    func testRejectsUnrelatedMalformedAndAmbiguousLinks() throws {
        for value in ["https://example.com/send?phone=123456789", "https://wa.me.evil.test/123456789",
                      "https://user@wa.me/123456789", "https://wa.me:444/123456789",
                      "https://wa.me/123456789/extra", "https://wa.me/123abc456", "https://wa.me/0123456789",
                      "https://wa.me/1234567890123456", "whatsapp://send?phone=123456789&phone=987654321",
                      "whatsapp://send?phone=123456789&text=one&text=two",
                      "whatsapp://call?phone=123456789", "whatsapp://send/extra?phone=123456789",
                      "https://chat.whatsapp.com/code/extra", "https://wa.me/message/businessCode"] {
            XCTAssertNil(WhatsAppLink.parse(try XCTUnwrap(URL(string: value))), value)
        }
    }
}

@MainActor
final class WhatsAppLinkRoutingTests: XCTestCase {
    private func withSession(_ body: (SessionViewModel, ModelContainer) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([PersistedMessage.self, PersistedChat.self, PersistedReaction.self,
                             PersistedPollVote.self, PersistedFolder.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let session = SessionViewModel(container: container)
        let client = try WAClient(dbPath: directory.appendingPathComponent("bridge.db").path)
        session.client = client
        session.chatList = ChatListViewModel(client: client, context: container.mainContext, bootstrap: false)
        try body(session, container)
    }

    func testColdStartLinkWaitsForReadyAndOpensDraftInMatchingChat() throws {
        try withSession { session, container in
            XCTAssertTrue(session.handleWhatsAppURL(URL(string: "whatsapp://send?phone=358401234567&text=Hello")!))
            XCTAssertNil(session.nav.currentJID)
            XCTAssertNotNil(session.pendingWhatsAppLink)
            session.state = .ready
            session.processPendingWhatsAppLink()
            XCTAssertEqual(session.nav.currentJID, "358401234567@s.whatsapp.net")
            XCTAssertNil(session.pendingWhatsAppLink)
            XCTAssertEqual(session.chatList?.chats.count, 1)

            let other = ConversationViewModel(chatJID: "other@s.whatsapp.net", client: session.client!)
            session.applyPendingURLDraft(to: other)
            XCTAssertEqual(other.draft, "")
            let vm = ConversationViewModel(chatJID: session.nav.currentJID!, client: session.client!, context: container.mainContext)
            vm.draft = "Existing draft"
            session.applyPendingURLDraft(to: vm)
            XCTAssertEqual(vm.draft, "Existing draft\nHello")
            session.applyPendingURLDraft(to: vm)
            XCTAssertEqual(vm.draft, "Existing draft\nHello")
            XCTAssertTrue(vm.messages.isEmpty)
        }
    }

    func testSameChatLinkAppliesImmediatelyAndKeepsExistingDraft() throws {
        try withSession { session, _ in
            session.state = .ready
            let vm = ConversationViewModel(chatJID: "358401234567@s.whatsapp.net", client: session.client!)
            session.currentConversation = vm
            vm.draft = "Keep me"
            let url = URL(string: "https://wa.me/358401234567?text=Hello")!
            session.handleWhatsAppURL(url)
            XCTAssertEqual(vm.draft, "Keep me\nHello")
            session.handleWhatsAppURL(URL(string: "https://wa.me/358401234567")!)
            XCTAssertEqual(vm.draft, "Keep me\nHello")
            XCTAssertEqual(session.chatList?.chats.count, 1)
            XCTAssertTrue(vm.messages.isEmpty)
        }
    }

    func testInviteUsesPreviewAndShareNeedsRecipient() throws {
        try withSession { session, _ in
            session.state = .ready
            session.handleWhatsAppURL(URL(string: "whatsapp://chat?code=AbCdEfGhIjKlMnOpQr")!)
            XCTAssertEqual(session.pendingShortcutQuery, "https://chat.whatsapp.com/AbCdEfGhIjKlMnOpQr")
            XCTAssertNil(session.nav.currentJID)
            session.handleWhatsAppURL(URL(string: "whatsapp://send?text=Choose+someone")!)
            XCTAssertEqual(session.urlShareText, "Choose someone")
            XCTAssertNil(session.nav.currentJID)
        }
    }

    func testInvalidCustomLinkShowsErrorAndUnrelatedWebLinkFallsThrough() {
        let session = SessionViewModel()
        XCTAssertFalse(session.handleWhatsAppURL(URL(string: "https://example.com")!))
        XCTAssertNil(session.urlOpenError)
        XCTAssertTrue(session.handleWhatsAppURL(URL(string: "whatsapp://unknown")!))
        XCTAssertNotNil(session.urlOpenError)
        XCTAssertNil(session.pendingWhatsAppLink)
    }
}
