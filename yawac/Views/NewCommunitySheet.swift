import SwiftUI

/// Modal sheet for creating a WhatsApp community parent group. Shows a
/// name field with a live 0/25 counter (server-enforced limit) and a
/// short hint explaining that members join via linked or new sub-groups
/// rather than at parent-creation time. Confirm calls `model.create()`
/// then forwards the new parent JID via `onCreated` before dismissing.
struct NewCommunitySheet: View {
    @Bindable var model: NewCommunitySheetModel
    /// Invoked once the bridge returns a JID. Caller is expected to
    /// dismiss any container sheet binding and navigate to the new
    /// community parent.
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            nameField
            hint
            if let err = model.error {
                Text(err)
                    .scaledUI(11)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.sidebarBg)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("New community")
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
            TextField("Community name", text: $model.name)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Hint

    @ViewBuilder
    private var hint: some View {
        Text("A community holds related groups together. Members are added by linking or creating sub-groups.")
            .scaledUI(11)
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
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
            Button("Create") {
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
}
