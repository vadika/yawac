import SwiftUI

/// Modal for saving / editing a contact's display name. Calls `onSave(full,
/// first)` with trimmed values; first name is optional.
struct ContactNameSheet: View {
    let initialName: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fullName: String
    @State private var firstName: String

    init(initialName: String, onSave: @escaping (String, String) -> Void) {
        self.initialName = initialName
        self.onSave = onSave
        _fullName = State(initialValue: initialName)
        _firstName = State(initialValue: "")
    }

    private var trimmedFull: String {
        fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save contact")
                .font(Theme.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 6) {
                Text("Full name")
                    .font(Theme.ui(11)).foregroundStyle(Theme.textFaint)
                TextField("Full name", text: $fullName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("First name (optional)")
                    .font(Theme.ui(11)).foregroundStyle(Theme.textFaint)
                TextField("First name", text: $firstName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if !trimmedFull.isEmpty {
                        onSave(trimmedFull,
                               firstName.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedFull.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Theme.sidebarBg)
    }
}
