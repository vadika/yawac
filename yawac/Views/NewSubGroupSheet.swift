import SwiftUI

/// Modal sheet for creating a sub-group inside an existing community
/// parent. Mirrors `NewGroupSheet` — same name field with the 0/25
/// counter, same shared `ParticipantChipPicker`. Title quotes the
/// parent name so the user sees which community they're adding to.
/// Confirm calls `model.create()` then forwards the new sub-group JID
/// via `onCreated` before dismissing.
struct NewSubGroupSheet: View {
    @Bindable var model: NewSubGroupSheetModel
    /// Display name of the parent community, rendered in the sheet
    /// title. Pure presentation — the bridge call uses
    /// `model.parentJID` which is fixed at init.
    let parentName: String
    /// Full contact list to drive the suggestion picker. The picker
    /// filters this in-memory; loading the list itself is the caller's
    /// concern (typically `ChatListViewModel.contacts`).
    var contacts: [BridgeContact]
    /// Invoked once the bridge returns a JID. Caller is expected to
    /// dismiss any container sheet binding and navigate to the new
    /// sub-group chat.
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
        HStack(alignment: .firstTextBaseline) {
            Text("New sub-group in \u{201C}\(parentName)\u{201D}")
                .scaledUI(15, weight: .semibold)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
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
            TextField("Sub-group name", text: $model.name)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Participant picker

    @ViewBuilder
    private var participantPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Participants (optional)")
                .scaledUI(11).foregroundStyle(Theme.textFaint)
            ParticipantChipPicker(chips: $model.chips,
                                  query: $model.query,
                                  contacts: contacts)
        }
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
}
