import SwiftUI

/// Reusable chip + suggestion picker shared by `NewGroupSheet` and
/// `NewSubGroupSheet`. Owns no state itself: chip selection and query
/// are passed in by binding so the host sheet's model is the single
/// source of truth.
///
/// Filtering is an in-memory substring match over `BridgeContact.name`
/// / `fullName`, case-insensitive, capped at 80 hits to match
/// `AddParticipantsPanelModel`. Existing chips are excluded from
/// suggestions so the picker doesn't offer the same contact twice.
struct ParticipantChipPicker: View {
    @Binding var chips: [BridgeContact]
    @Binding var query: String
    var contacts: [BridgeContact]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chipRow
            divider
            suggestionsRow
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .frame(minHeight: 240)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    @ViewBuilder
    private var chipRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.jid) { c in
                HStack(spacing: 4) {
                    Text(c.name)
                        .scaledUI(11, weight: .medium)
                        .foregroundStyle(Color.white)
                    Button {
                        chips.removeAll { $0.jid == c.jid }
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
            TextField("Search contacts…", text: $query)
                .textFieldStyle(.plain)
                .scaledUI(12)
                .foregroundStyle(Theme.text)
                .frame(minWidth: 100)
        }
        .padding(8)
    }

    @ViewBuilder
    private var suggestionsRow: some View {
        let suggestions = filteredSuggestions
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.jid) { c in
                    Button {
                        addChip(c)
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
                if suggestions.isEmpty {
                    Text("No matches")
                        .scaledUI(11)
                        .foregroundStyle(Theme.textFaint)
                        .padding(10)
                }
            }
        }
        .frame(maxHeight: 220)
    }

    /// Capped, in-memory filter over `contacts`. Matches `name` /
    /// `fullName` substrings case-insensitively; existing chips are
    /// excluded so the picker doesn't offer to add the same contact
    /// twice. Cap at 80 to match `AddParticipantsPanelModel`.
    private var filteredSuggestions: [BridgeContact] {
        let chipJIDs = Set(chips.map(\.jid))
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                     .lowercased()
        var out: [BridgeContact] = []
        out.reserveCapacity(80)
        for c in contacts {
            if chipJIDs.contains(c.jid) { continue }
            if !q.isEmpty {
                let hay = (c.name + "\n" + (c.fullName ?? "")).lowercased()
                if !hay.contains(q) { continue }
            }
            out.append(c)
            if out.count >= 80 { break }
        }
        return out
    }

    private func addChip(_ c: BridgeContact) {
        guard !chips.contains(where: { $0.jid == c.jid }) else { return }
        chips.append(c)
        query = ""
    }
}
