import SwiftUI

struct ContactPickerSheet: View {
    @Bindable var model: ContactPickerSheetModel
    @Environment(\.dismiss) private var dismiss
    var onSend: (ContactPayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send contact").font(.headline)

            TextField("Search", text: $model.query)
                .textFieldStyle(.roundedBorder)

            List(model.filtered, id: \.jid,
                 selection: $model.selectedJID) { contact in
                Text(contact.name).tag(contact.jid as String?)
            }
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Send") {
                    if let p = model.buildPayload() {
                        onSend(p)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
