import AppKit
import SwiftUI
import XCTest
@testable import yawac

@MainActor
final class ViewportReadModifierTests: XCTestCase {
    final class Client: WAClient {
        override nonisolated func markRead(chatJID: String, senderJID: String, messageIDs: [String]) throws {}
    }

    @Observable
    final class Presentation {
        var phase: ScenePhase = .inactive
        var visible = true
    }

    private struct Row: View {
        let vm: ConversationViewModel
        let presentation: Presentation

        var body: some View {
            VStack {
                if presentation.visible {
                    Text("message")
                        .modifier(ViewportReadModifier(messageID: "inbound", vm: vm))
                }
            }
            .environment(\.scenePhase, presentation.phase)
        }
    }

    private func withRow(_ body: (ConversationViewModel, ChatListViewModel, Presentation, NSView) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try Client(dbPath: directory.appendingPathComponent("bridge.sqlite").path)
        let vm = ConversationViewModel(chatJID: "123@s.whatsapp.net", client: client)
        let chats = ChatListViewModel(client: client, bootstrap: false)
        chats.chats = [Chat(jid: vm.chatJID, name: "Peer", lastMessage: "message", lastTimestamp: 0, unread: 2)]
        vm.chatList = chats
        vm.messages = [UIMessage(id: "inbound", chatJID: vm.chatJID, senderJID: "peer",
                                 fromMe: false, timestamp: .now, body: .text("message"))]
        let presentation = Presentation()
        let host = NSHostingView(rootView: Row(vm: vm, presentation: presentation))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        try await body(vm, chats, presentation, host)
    }

    func testReturningToAlreadyVisibleMessageClearsOnlyItsUnreadCount() async throws {
        try await withRow { vm, chats, presentation, host in
            vm.unreadInboundIDs = ["inbound", "offscreen"]
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(2200))
            XCTAssertEqual(chats.chats.first?.unread, 2)

            presentation.phase = .active
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(2300))
            XCTAssertEqual(chats.chats.first?.unread, 1)
            XCTAssertEqual(vm.unreadInboundIDs, ["offscreen"])
        }
    }

    func testUnreadHydratedAfterAppearanceStartsReadTracking() async throws {
        try await withRow { vm, chats, presentation, host in
            presentation.phase = .active
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            vm.unreadInboundIDs = ["inbound", "offscreen"]
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(2300))
            XCTAssertEqual(chats.chats.first?.unread, 1)
        }
    }

    func testLeavingTheAppOrRowCancelsReadTracking() async throws {
        try await withRow { vm, chats, presentation, host in
            vm.unreadInboundIDs = ["inbound", "offscreen"]
            presentation.phase = .active
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            presentation.phase = .inactive
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(2200))
            XCTAssertEqual(chats.chats.first?.unread, 2)

            presentation.phase = .active
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            presentation.visible = false
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(2200))
            XCTAssertEqual(chats.chats.first?.unread, 2)
        }
    }
}
