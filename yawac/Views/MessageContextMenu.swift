import AppKit
import SwiftUI

/// Custom right-click menu for message bubbles. Replaces the system
/// `.contextMenu` so we can render a horizontal reaction strip on top
/// of the menu items — something AppKit's NSMenu cannot do.
///
/// Trigger: `RightClickCatcher` overlay flips `present` to `true`;
/// SwiftUI's `.popover` anchors the content to the bubble.
struct MessageContextMenu: View {
    let message: UIMessage
    let canEdit: Bool
    let canRevoke: Bool
    let onPickReaction: (String) -> Void
    let onReply: () -> Void
    /// Group-only affordance: switch to a DM with the sender and seed
    /// that conversation's reply target with this message. nil when the
    /// menu is shown in a 1:1 chat, when this is an own message, or when
    /// the caller didn't wire the handoff — the item only renders when
    /// the closure is non-nil AND the gating conditions hold.
    let onReplyPrivately: (() -> Void)?
    let onForward: () -> Void
    let onCopyText: () -> Void
    let onStar: () -> Void
    let onPin: () -> Void
    let onDeleteForMe: () -> Void
    let onDeleteForEveryone: () -> Void
    let onEdit: () -> Void
    let dismiss: () -> Void

    private static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    private var bodyText: String? {
        if case .text(let t) = message.body, !t.isEmpty { return t }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            reactionsStrip
            divider
            VStack(spacing: 0) {
                MenuRow(icon: "arrowshape.turn.up.left",
                        label: "Reply",
                        shortcut: "⌘R",
                        action: { dismiss(); onReply() })
                // Group-only: surface "Reply privately…" for inbound
                // messages so the user can DM the sender with the group
                // message quoted. Gating mirrors WhatsApp behaviour —
                // hidden in 1:1 chats and for own messages.
                if message.chatJID.hasSuffix("@g.us"),
                   !message.fromMe,
                   let onReplyPrivately {
                    MenuRow(icon: "arrowshape.turn.up.left.fill",
                            label: "Reply privately…",
                            action: { dismiss(); onReplyPrivately() })
                }
                MenuRow(icon: "arrowshape.turn.up.right",
                        label: "Forward",
                        action: { dismiss(); onForward() })
                if let _ = bodyText {
                    MenuRow(icon: "doc.on.doc",
                            label: "Copy text",
                            shortcut: "⌘C",
                            action: { dismiss(); onCopyText() })
                }
                if canEdit {
                    MenuRow(icon: "pencil",
                            label: "Edit",
                            shortcut: "⌘E",
                            action: { dismiss(); onEdit() })
                }
                MenuRow(icon: message.starredAt != nil ? "star.fill" : "star",
                        label: message.starredAt != nil ? "Unstar" : "Star",
                        shortcut: "⌘S",
                        action: { dismiss(); onStar() })
                MenuRow(icon: message.pinnedAt != nil ? "pin.fill" : "pin",
                        label: message.pinnedAt != nil ? "Unpin" : "Pin",
                        action: { dismiss(); onPin() })
            }
            divider.padding(.horizontal, 8).padding(.vertical, 4)
            VStack(spacing: 0) {
                MenuRow(icon: "trash",
                        label: "Delete for me",
                        shortcut: "⌫",
                        destructive: true,
                        action: { dismiss(); onDeleteForMe() })
                if canRevoke {
                    MenuRow(icon: "trash",
                            label: "Delete for everyone",
                            destructive: true,
                            action: { dismiss(); onDeleteForEveryone() })
                }
            }
            .padding(.bottom, 4)
        }
        .frame(width: 240)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 12)
        .background(keyboardShortcutSink)
    }

    @ViewBuilder
    private var reactionsStrip: some View {
        HStack(spacing: 0) {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                ReactionButton(emoji: emoji) {
                    dismiss(); onPickReaction(emoji)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.04))
            .frame(height: 1)
    }

    /// Hidden Buttons that own keyboard shortcuts while the popover is
    /// in the responder chain. SwiftUI delivers ⌘R/⌘C/⌫ here even
    /// though the visible MenuRows can't carry shortcuts directly.
    private var keyboardShortcutSink: some View {
        VStack(spacing: 0) {
            Button("") { dismiss(); onReply() }
                .keyboardShortcut("r", modifiers: .command)
            if bodyText != nil {
                Button("") { dismiss(); onCopyText() }
                    .keyboardShortcut("c", modifiers: .command)
            }
            if canEdit {
                Button("") { dismiss(); onEdit() }
                    .keyboardShortcut("e", modifiers: .command)
            }
            Button("") { dismiss(); onStar() }
                .keyboardShortcut("s", modifiers: .command)
            Button("") { dismiss(); onDeleteForMe() }
                .keyboardShortcut(.delete, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Row

private struct MenuRow: View {
    let icon: String
    let label: String
    var shortcut: String? = nil
    var destructive: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    private var foreground: Color {
        if disabled { return Theme.textFaint }
        if destructive {
            return Color(red: 232/255, green: 113/255, blue: 103/255)
        }
        if hovering { return Theme.accent }
        return Theme.text
    }

    private var background: Color {
        if disabled || !hovering { return .clear }
        if destructive {
            return Color(red: 232/255, green: 113/255, blue: 103/255, opacity: 0.12)
        }
        return Theme.accent.opacity(0.14)
    }

    private var shortcutColor: Color {
        if destructive {
            return Color(red: 232/255, green: 113/255, blue: 103/255, opacity: 0.7)
        }
        return Theme.textFaint
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .scaledIcon(11, weight: .regular)
                    .frame(width: 16, alignment: .center)
                Text(label)
                    .scaledUI(13.5)
                Spacer(minLength: 4)
                if let shortcut {
                    Text(shortcut)
                        .scaledMono(10.5)
                        .foregroundStyle(shortcutColor)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { h in
            guard !disabled else { return }
            hovering = h
        }
    }
}

// MARK: - Reaction strip buttons

private struct ReactionButton: View {
    let emoji: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .scaledUI(18)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    hovering ? Color(white: 0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .scaleEffect(hovering && !reduceMotion ? 1.18 : 1.0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08),
                           value: hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Right-click catcher

/// Invisible NSView overlay that intercepts only right-mouse-down,
/// letting every other event fall through to the SwiftUI bubble
/// underneath (text selection, mention link clicks, etc.). Reports
/// the click position as a `UnitPoint` (0…1 of view bounds, AppKit's
/// flipped Y already inverted to SwiftUI's top-down) so the caller
/// can anchor a popover at the actual mouse location instead of a
/// fixed corner.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (UnitPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = RightClickHost()
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RightClickHost)?.onRightClick = onRightClick
    }
}

private final class RightClickHost: NSView {
    var onRightClick: ((UnitPoint) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept right-clicks. Other events fall through.
        guard let evt = NSApp.currentEvent, evt.type == .rightMouseDown else {
            return nil
        }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        // AppKit's coordinate system is bottom-up; SwiftUI's UnitPoint
        // is top-down. Invert Y.
        let u = UnitPoint(
            x: min(max(local.x / w, 0), 1),
            y: min(max(1 - (local.y / h), 0), 1)
        )
        onRightClick?(u)
    }
}
