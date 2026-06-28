import SwiftUI

/// Slim breadcrumb bar that renders directly above the chat header when
/// the user has drilled into a chat from another one (member tap,
/// participant row, reply-privately, community sub-group, mention
/// popover, quoted-message author). Reads "Back to {origin name}" with
/// the origin's avatar; shows a "{n} deep" chip when the trail is more
/// than one hop, and surfaces the ⌘[ shortcut.
///
/// See `docs/superpowers/specs/2026-06-06-chat-navigation-stack-spec.md`.
struct BackBar: View {
    let originJID: String
    let originName: String
    let depth: Int
    let onBack: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            backButton
                // Cap at ~70% so a long origin name truncates instead of
                // shoving the depth chip / ⌘[ off the right edge.
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            if depth > 1 {
                depthChip
            }
            shortcutHint
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(Theme.sidebarBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("Back to")
                    .foregroundStyle(.secondary)
                AvatarView(jid: originJID, name: originName, size: 16)
                Text(originName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.accentText)
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(hovered ? Theme.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Back to \(originName) (⌘[)")
    }

    private var depthChip: some View {
        Text("\(depth) deep")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }

    private var shortcutHint: some View {
        Text("⌘[")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}
