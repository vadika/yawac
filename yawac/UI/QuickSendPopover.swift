// yawac/UI/QuickSendPopover.swift
import SwiftUI

/// Root content view for the menu-bar quick-send `NSPopover`. Switches
/// between the chat picker and the composer based on
/// `selectedChatJID`. Width is fixed to 320pt; height adapts to
/// content via SwiftUI's natural sizing (the popover frames it).
struct QuickSendPopover: View {

    let session: SessionViewModel
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var selectedChatJID: String?

    private struct NotPairedError: Error, LocalizedError {
        var errorDescription: String? { "No account paired" }
    }

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
            nameResolver: { chat in resolvedName(for: chat.jid) })
    }

    @ViewBuilder
    private func composer(for jid: String) -> some View {
        QuickSendComposer(
            chatJID: jid,
            displayName: resolvedName(for: jid),
            send: { [session] chatJID, body in
                // F87: lazy read so the popover doesn't carry a stale
                // WAClient reference across logout → re-pair churn. The
                // closure is @Sendable so we hop to MainActor to read the
                // currently-bound client + its bare JID (both are
                // MainActor-isolated SessionViewModel/WAClient state).
                let (client, ownJID): (WAClient, String) = try await MainActor.run {
                    guard let c = session.client else { throw NotPairedError() }
                    return (c, c.ownJID)
                }
                let result = try await Task.detached(priority: .userInitiated) {
                    try client.sendText(chatJID, body)
                }.value
                // F87: yawac is the originator of this send and whatsmeow doesn't
                // echo own outbound sends back as events.Message. Inject a
                // synthetic .message into the bridge event stream so the chat
                // list + any open ConversationView pick it up via their existing
                // subscribers — same downstream behavior as a real inbound msg.
                let synthetic = BridgeMessage(
                    id: result.messageID,
                    chatJID: chatJID,
                    senderJID: ownJID,
                    senderPushName: nil,
                    fromMe: true,
                    timestamp: result.timestamp,
                    kind: "text",
                    text: body,
                    media: nil,
                    poll: nil,
                    quoted: nil,
                    isForwarded: false,
                    location: nil,
                    locationSequence: nil,
                    contact: nil,
                    contactsArray: nil,
                    isViewOnce: false)
                client.dispatchSynthetic(.message(synthetic))
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

    /// Three-tier name resolution: session-resolved (LID→PN aware via F60) →
    /// the chat row's own name from the sidebar list → raw JID.
    private func resolvedName(for jid: String) -> String {
        let resolved = session.displayName(for: jid)
        if !resolved.isEmpty { return resolved }
        if let chat = chats.first(where: { $0.jid == jid }),
           !chat.name.isEmpty { return chat.name }
        return jid
    }
}
