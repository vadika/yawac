import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var vm: ConversationViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Button {
                attachFile()
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.borderless)
            TextField("Message", text: $vm.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(8)
                .background(.gray.opacity(0.15), in: .rect(cornerRadius: 8))
                .focused($focused)
                .onChange(of: vm.draft) { _, new in
                    vm.setTyping(!new.isEmpty)
                }
                .onSubmit { Task { await vm.sendDraft() } }
            Button {
                Task { await vm.sendDraft() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await vm.sendAttachment(at: url) }
        }
    }
}
