// yawac/UI/QuickSendPopover.swift
import SwiftUI

/// Root content view for the menu-bar quick-send `NSPopover`. Switches
/// between the chat picker and the composer based on
/// `selectedChatJID`. Width is fixed to 320pt; height adapts to
/// content via SwiftUI's natural sizing (the popover frames it).
struct QuickSendPopover: View {

    let session: SessionViewModel
    let client: WAClient
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var selectedChatJID: String?

    var body: some View {
        VStack(spacing: 0) {
            if session.client == nil {
                placeholder("No account paired")
            } else if let jid = selectedChatJID {
                composer(for: jid)
            } else {
                picker
            }
        }
        .frame(width: 320)
    }

    @ViewBuilder
    private var picker: some View {
        QuickSendChatPicker(
            query: $query,
            selectedChatJID: $selectedChatJID,
            chats: chats,
            nameResolver: { chat in
                let resolved = session.displayName(for: chat.jid)
                if !resolved.isEmpty { return resolved }
                return chat.name.isEmpty ? chat.jid : chat.name
            })
    }

    @ViewBuilder
    private func composer(for jid: String) -> some View {
        let resolved = session.displayName(for: jid)
        let displayName = resolved.isEmpty
            ? (chats.first(where: { $0.jid == jid })?.name ?? jid)
            : resolved
        QuickSendComposer(
            chatJID: jid,
            displayName: displayName,
            send: { [client] chatJID, body in
                _ = try await Task.detached(priority: .userInitiated) {
                    try client.sendText(chatJID, body)
                }.value
            },
            onClose: onClose,
            onBack: { selectedChatJID = nil })
    }

    @ViewBuilder
    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 4) {
            Text(text).scaledUI(12).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var chats: [Chat] {
        session.chatList?.chats ?? []
    }
}
