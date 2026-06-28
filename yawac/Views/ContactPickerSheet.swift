import SwiftUI

struct ContactPickerSheet: View {
    @Bindable var model: ContactPickerSheetModel
    @Environment(\.dismiss) private var dismiss
    var onSend: ([ContactPayload]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send contact").font(.headline)

            TextField("Search", text: $model.query)
                .textFieldStyle(.roundedBorder)

            List(model.filtered, id: \.jid) { contact in
                Button {
                    model.toggle(contact.jid)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.isSelected(contact.jid)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.isSelected(contact.jid)
                                             ? Theme.accent : Theme.textMuted)
                        Text(contact.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(sendButtonLabel) {
                    let payloads = model.buildPayloads()
                    guard !payloads.isEmpty else { return }
                    onSend(payloads)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var sendButtonLabel: String {
        model.selectedJIDs.count >= 2
            ? "Send \(model.selectedJIDs.count) contacts"
            : "Send"
    }
}
