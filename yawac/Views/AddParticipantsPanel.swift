import SwiftUI

struct AddParticipantsPanel: View {
    @Bindable var model: AddParticipantsPanelModel
    var onCommit: ([String]) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chipRow
            divider
            suggestionsRow
            divider
            footer
            if let res = model.result {
                resultStrip(res)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    @ViewBuilder
    private var chipRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(model.chips, id: \.jid) { c in
                HStack(spacing: 4) {
                    Text(c.name).scaledUI(11, weight: .medium)
                        .foregroundStyle(Color.white)
                    Button {
                        model.removeChip(c.jid)
                    } label: {
                        Image(systemName: "xmark")
                            .scaledIcon(8, weight: .semibold)
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.accent, in: Capsule())
            }
            TextField("Search contacts or +phone…",
                      text: Bindable(model).query)
                .textFieldStyle(.plain)
                .scaledUI(12)
                .foregroundStyle(Theme.text)
                .frame(minWidth: 100)
        }
        .padding(8)
    }

    @ViewBuilder
    private var suggestionsRow: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let candidate = model.phoneCandidate {
                    Button {
                        model.addPhoneCandidate()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .scaledIcon(11)
                                .foregroundStyle(Theme.accent)
                            Text("Add \(candidate.fullName ?? candidate.pushName ?? candidate.jid) (on WhatsApp)")
                                .scaledUI(12)
                                .foregroundStyle(Theme.text)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(model.suggestions, id: \.jid) { c in
                    Button {
                        model.addChip(c)
                    } label: {
                        HStack(spacing: 8) {
                            Text(c.name)
                                .scaledUI(12)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(c.jid)
                                .scaledMono(10)
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if model.suggestions.isEmpty && model.phoneCandidate == nil {
                    Text(model.validating ? "Checking…" : "No matches")
                        .scaledUI(11)
                        .foregroundStyle(Theme.textFaint)
                        .padding(10)
                }
            }
        }
        .frame(maxHeight: 200)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if model.inFlight {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
            Button(model.chips.isEmpty ? "Add" : "Add \(model.chips.count)") {
                onCommit(model.chips.map(\.jid))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.chips.isEmpty || model.inFlight)
        }
        .padding(8)
    }

    @ViewBuilder
    private func resultStrip(_ res: AddParticipantsPanelModel.AddResult)
        -> some View {
        HStack(spacing: 8) {
            ForEach(Array(res.rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 3) {
                    Image(systemName: icon(for: r.kind))
                        .scaledIcon(10, weight: .semibold)
                        .foregroundStyle(color(for: r.kind))
                    Text(label(for: r))
                        .scaledUI(11)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                model.dismissResult()
            } label: {
                Image(systemName: "xmark")
                    .scaledIcon(9, weight: .semibold)
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Theme.surface.opacity(0.6))
    }

    private func icon(for kind: AddParticipantsPanelModel.AddResult.Row.Kind) -> String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .pending: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for kind: AddParticipantsPanelModel.AddResult.Row.Kind) -> Color {
        switch kind {
        case .ok: return .green
        case .pending: return .orange
        case .failed: return .red
        }
    }

    private func label(for row: AddParticipantsPanelModel.AddResult.Row) -> String {
        switch row.kind {
        case .ok: return row.displayName
        case .pending: return "\(row.displayName) — invite sent"
        case .failed: return "\(row.displayName) — not added"
        }
    }
}

/// Minimal flow layout for chip + textfield wrapping. Native
/// SwiftUI HStack doesn't wrap; this is a single-file Layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxW: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x)
        }
        return CGSize(width: min(width, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y),
                      proposal: ProposedViewSize(width: s.width, height: s.height))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
