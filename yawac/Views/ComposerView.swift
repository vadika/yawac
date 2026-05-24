import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var vm: ConversationViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                attachFile()
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.textMuted)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Attach file")

            TextField("Message…", text: $vm.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(Theme.ui(14))
                .foregroundStyle(Theme.text)
                .padding(.vertical, 6)
                .tint(Theme.accent)
                .focused($focused)
                .onChange(of: vm.draft) { _, new in
                    vm.setTyping(!new.isEmpty)
                }
                .onSubmit { Task { await vm.sendDraft() } }

            Button {
                // Emoji picker placeholder — system emoji panel via menu.
                NSApp.orderFrontCharacterPalette(nil)
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.textMuted)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Emoji")

            Button {
                Task { await vm.sendDraft() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Theme.accent : Theme.surfaceAlt,
                                in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.pillRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.pillRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Theme.bg)
    }

    private var canSend: Bool {
        !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
