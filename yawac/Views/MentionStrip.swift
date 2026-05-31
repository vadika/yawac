import SwiftUI

/// Slim inline list anchored above the composer, gated on
/// `picker.isActive`. Renders one row per filtered candidate plus a
/// loading state. ↑/↓/Tab/Enter/Esc are handled by ComposerView's
/// `.onKeyPress` chain — this view is render-only.
struct MentionStrip: View {

    @Bindable var picker: MentionPickerViewModel
    let onCommit: (MentionPickerViewModel.Candidate) -> Void

    var body: some View {
        if picker.isActive {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(picker.filtered.prefix(5).enumerated()),
                        id: \.offset) { idx, cand in
                    row(cand: cand, isSelected: idx == picker.selectedIdx)
                        .contentShape(Rectangle())
                        .onTapGesture { onCommit(cand) }
                }
                if picker.filtered.count > 5 {
                    ScrollView {
                        ForEach(Array(picker.filtered.dropFirst(5).enumerated()),
                                id: \.offset) { _, cand in
                            row(cand: cand, isSelected: false)
                                .contentShape(Rectangle())
                                .onTapGesture { onCommit(cand) }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
            .padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func row(cand: MentionPickerViewModel.Candidate,
                     isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            switch cand {
            case .everyone:
                Image(systemName: "megaphone.fill")
                    .scaledIcon(14, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20)
                Text("@everyone")
                    .scaledUI(13, weight: .semibold)
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.text)
                Spacer()
            case .participant(let jid, let name):
                Image(systemName: "person.circle.fill")
                    .scaledIcon(18)
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 20, height: 20)
                Text("@\(name)")
                    .scaledUI(13)
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.text)
                Spacer()
                Text(phoneOnly(jid))
                    .scaledMono(10)
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Theme.accentSoft : Color.clear)
    }

    private func phoneOnly(_ jid: String) -> String {
        guard let at = jid.firstIndex(of: "@") else { return jid }
        return String(jid[..<at])
    }
}
