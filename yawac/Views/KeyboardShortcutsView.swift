import SwiftUI

struct KeyboardShortcutsView: View {

    struct Entry {
        let label: String
        let keys: [String]   // rendered left-to-right as separate chips
    }

    private let sections: [(title: String, entries: [Entry])] = [
        ("Compose", [
            Entry(label: "Send message",                    keys: ["⌘", "↩"]),
            Entry(label: "Cancel reply / edit",             keys: ["Esc"]),
            Entry(label: "Recall last own message",         keys: ["↑"]),
            Entry(label: "Mention picker (in group)",       keys: ["@"]),
        ]),
        ("Find", [
            Entry(label: "Find in conversation",            keys: ["⌘", "F"]),
            Entry(label: "Next match",                      keys: ["⌘", "G"]),
            Entry(label: "Previous match",                  keys: ["⇧", "⌘", "G"]),
            Entry(label: "Focus sidebar search",            keys: ["⌘", "K"]),
        ]),
        ("Messages (right-click row's quick-actions)", [
            Entry(label: "Reply",                           keys: ["⌘", "R"]),
            Entry(label: "Copy",                            keys: ["⌘", "C"]),
            Entry(label: "Edit",                            keys: ["⌘", "E"]),
            Entry(label: "Star / unstar",                   keys: ["⌘", "S"]),
            Entry(label: "Delete-for-me / cancel forward",  keys: ["⌫"]),
        ]),
        ("App", [
            Entry(label: "Show shortcuts",                  keys: ["⌘", "?"]),
            Entry(label: "Log out",                         keys: ["⇧", "⌘", "Q"]),
        ]),
    ]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .scaledUI(15, weight: .semibold)
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .scaledIcon(11, weight: .semibold)
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Theme.bg)
            .overlay(Rectangle().frame(height: 1)
                        .foregroundStyle(Theme.border), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections, id: \.title) { section in
                        sectionView(title: section.title, entries: section.entries)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 520, height: 460)
        .background(Theme.bg)
    }

    @ViewBuilder
    private func sectionView(title: String, entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .scaledUI(10, weight: .semibold)
                .tracking(1.2)
                .foregroundStyle(Theme.textFaint)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                    row(entry)
                    if idx != entries.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 8) {
            Text(entry.label)
                .scaledUI(13)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(entry.keys.enumerated()), id: \.offset) { _, k in
                    keyChip(k)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func keyChip(_ key: String) -> some View {
        Text(key)
            .scaledMono(11.5, weight: .semibold)
            .foregroundStyle(Theme.text)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 6)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.border, lineWidth: 1))
    }
}
