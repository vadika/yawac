import Foundation
import Observation
import SwiftUI

/// Lightweight identity-and-trail entry for the chat navigation stack.
/// `id` is the canonical JID; `displayName` is the resolved contact /
/// group name (never a raw JID). `kind` lets the BackBar pick the right
/// avatar style if it ever needs to (today both use `AvatarView` by JID).
struct ChatRef: Identifiable, Equatable {
    let id: String
    let displayName: String
    let kind: Kind

    enum Kind: Equatable { case group, direct }
}

/// Navigation stack that backs the BackBar.
///
/// Sidebar selection / search-hit jumps reset the trail via `openRoot`.
/// In-chat taps (sender avatar, participant row, community sub-group,
/// reply-privately, mention popover, quoted-message author) push onto
/// the stack via `push`. `back` pops one hop. At depth 1 the BackBar
/// does not render — there is nothing to go back to.
///
/// Scroll restore uses the **last-anchored message id** per chat,
/// captured on `.onDisappear` of the conversation and replayed via
/// `ScrollViewReader.scrollTo` on the next mount.
@MainActor
@Observable
final class ChatNavigation {
    private(set) var stack: [ChatRef] = []

    /// Last-seen-message-id anchor per chat id. Persists across re-pushes
    /// of the same chat so a back-pop into a previously-visited chat
    /// restores its scroll position rather than snapping to the bottom.
    private(set) var scrollAnchors: [String: String] = [:]

    var current: ChatRef?    { stack.last }
    var currentJID: String?  { stack.last?.id }
    var origin: ChatRef?     { stack.count > 1 ? stack[stack.count - 2] : nil }
    var depth: Int           { max(0, stack.count - 1) }
    var canGoBack: Bool      { stack.count > 1 }

    /// Sidebar / search-hit selection — reset the trail.
    /// No-op when already at this root at depth 0 so a re-tap of the
    /// same sidebar row doesn't churn the binding.
    func openRoot(_ chat: ChatRef) {
        if stack.count == 1, current?.id == chat.id { return }
        stack = [chat]
    }

    /// Drill in from the current chat (member tap, participant row,
    /// reply-privately, community sub-group, mention popover, quoted
    /// author). Tapping the chat you're already in is a no-op — spec §6
    /// explicitly forbids pushing the same chat onto itself.
    func push(_ chat: ChatRef) {
        guard current?.id != chat.id else { return }
        stack.append(chat)
    }

    /// Pop one hop. No-op at the root.
    func back() {
        guard stack.count > 1 else { return }
        stack.removeLast()
    }

    /// Clear the stack entirely (logout, no-chat-selected).
    func clear() { stack = [] }

    /// Remove a chat from the trail (deletion sync). If it was the top,
    /// the now-top entry becomes current; if it was the only entry, the
    /// stack empties.
    func removeChat(jid: String) {
        stack.removeAll { $0.id == jid }
        scrollAnchors.removeValue(forKey: jid)
    }

    func captureAnchor(jid: String, messageID: String) {
        scrollAnchors[jid] = messageID
    }

    func anchor(jid: String) -> String? {
        scrollAnchors[jid]
    }
}
