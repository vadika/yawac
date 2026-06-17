import SwiftUI

/// F91: small modal that asks for a folder name. Used by the rail
/// context menu's "New folder…" and the chat-row "Add to folder…"
/// submenu's "New folder…" trailing item.
struct NewFolderSheet: View {

    @Binding var isPresented: Bool
    let onCreate: (String) -> Void

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New folder")
                .scaledUI(14, weight: .semibold)
                .foregroundStyle(Theme.text)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { nameFocused = true }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        isPresented = false
    }
}
