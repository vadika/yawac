import SwiftUI

/// Modal sheet for creating a plain (non-community) WhatsApp group.
/// Shows a name field with a live 0/25 counter (server-enforced limit),
/// a chip + suggestion picker for selecting initial participants, and a
/// confirm button that calls `model.create()` then forwards the new
/// group JID via `onCreated` before dismissing.
struct NewGroupSheet: View {
    @Bindable var model: NewGroupSheetModel
    /// Full contact list to drive the suggestion picker. The picker
    /// filters this in-memory; loading the list itself is the caller's
    /// concern (typically `ChatListViewModel.contacts`).
    var contacts: [BridgeContact]
    /// Invoked once the bridge returns a JID. Caller is expected to
    /// dismiss any container sheet binding and navigate to the new chat.
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            nameField
            participantPicker
            if let err = model.error {
                Text(err)
                    .scaledUI(11)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.sidebarBg)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("New group")
                .scaledUI(15, weight: .semibold)
                .foregroundStyle(Theme.text)
            Spacer()
            Text("\(model.name.count) / 25")
                .scaledMono(10)
                .foregroundStyle(
                    model.name.count >= 25 ? Color.red.opacity(0.9)
                                           : Theme.textFaint
                )
        }
    }

    // MARK: - Name field

    @ViewBuilder
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .scaledUI(11).foregroundStyle(Theme.textFaint)
            TextField("Group name", text: $model.name)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Participant picker

    @ViewBuilder
    private var participantPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Participants (optional)")
                .scaledUI(11).foregroundStyle(Theme.textFaint)
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
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    @ViewBuilder
    private var chipRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(model.chips, id: \.jid) { c in
                HStack(spacing: 4) {
                    Text(c.name)
                        .scaledUI(11, weight: .medium)
                        .foregroundStyle(Color.white)
                    Button {
                        model.chips.removeAll { $0.jid == c.jid }
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
            TextField("Search contacts…", text: $model.query)
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

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if model.inFlight {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .disabled(model.inFlight)
            Button(createButtonLabel) {
                Task {
                    await model.create()
                    if let jid = model.createdJID {
                        onCreated(jid)
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCreate)
        }
    }

    private var createButtonLabel: String {
        model.chips.isEmpty ? "Create"
                            : "Create with \(model.chips.count)"
    }

    // MARK: - Filtering

    /// Capped, in-memory filter over `contacts`. Matches `name` /
    /// `fullName` substrings case-insensitively; existing chips are
    /// excluded so the picker doesn't offer to add the same contact
    /// twice. Cap at 80 to match `AddParticipantsPanelModel`.
    private var filteredSuggestions: [BridgeContact] {
        let chipJIDs = Set(model.chips.map(\.jid))
        let q = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard !model.chips.contains(where: { $0.jid == c.jid }) else { return }
        model.chips.append(c)
        model.query = ""
    }
}
