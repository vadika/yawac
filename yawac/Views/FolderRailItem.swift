import SwiftUI

/// F91: single row in the FolderRail. Visual only — selection and
/// badge state pass in via the parent. Three flavors via `Kind`:
/// custom folder (PersistedFolder-backed), "All chats", "Archived".
struct FolderRailItem: View {

    enum Kind {
        case custom(PersistedFolder)
        case all
        case archived
    }

    let kind: Kind
    let isSelected: Bool
    let badge: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: iconName)
                        .scaledIcon(20, weight: isSelected ? .semibold : .regular)
                        .foregroundStyle(iconColor)
                        .frame(width: 44, height: 36)
                        .background(
                            isSelected ? Theme.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                    if badge > 0 {
                        Text(badgeText)
                            .scaledMono(9, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                            .offset(x: 4, y: -2)
                    }
                }
                Text(label)
                    .scaledUI(10.5, weight: isSelected ? .semibold : .regular)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(labelColor)
            }
            .frame(width: 72)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch kind {
        case .custom: return "folder.fill"
        case .all: return "bubble.left.and.bubble.right.fill"
        case .archived: return "archivebox.fill"
        }
    }

    private var label: String {
        switch kind {
        case .custom(let f): return f.name
        case .all: return "All chats"
        case .archived: return "Archived"
        }
    }

    private var iconColor: Color {
        isSelected ? Theme.accentText : Theme.textMuted
    }

    private var labelColor: Color {
        isSelected ? Theme.accentText : Theme.textMuted
    }

    private var badgeText: String {
        badge > 99 ? "99+" : "\(badge)"
    }
}
