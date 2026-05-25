import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var vm: ConversationViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            replyChip
            editChip
            inputRow
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Theme.bg)
        .onChange(of: vm.editTarget?.id) { _, _ in
            // Pre-fill draft when an edit starts; reset when it ends.
            if let m = vm.editTarget {
                if case .text(let t) = m.body { vm.draft = t }
            }
        }
    }

    private var inputRow: some View {
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
                .onSubmit {
                    if vm.editTarget != nil {
                        Task { await vm.saveEdit(vm.draft); vm.draft = "" }
                    } else {
                        Task { await vm.sendDraft() }
                    }
                }
                .onKeyPress(.escape) {
                    let wasEditing = (vm.editTarget != nil)
                    if vm.replyTarget != nil || vm.editTarget != nil {
                        vm.cancelCompose()
                        if wasEditing { vm.draft = "" }
                        return .handled
                    }
                    return .ignored
                }

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
                if vm.editTarget != nil {
                    Task { await vm.saveEdit(vm.draft); vm.draft = "" }
                } else {
                    Task { await vm.sendDraft() }
                }
            } label: {
                Image(systemName: vm.editTarget != nil ? "checkmark" : "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Theme.accent : Theme.surfaceAlt,
                                in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help(vm.editTarget != nil ? "Save edit (⌘↩)" : "Send (⌘↩)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.pillRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.pillRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var canSend: Bool {
        let body = vm.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        if let m = vm.editTarget, case .text(let t) = m.body, body == t {
            return false
        }
        return true
    }

    @ViewBuilder
    private var replyChip: some View {
        if let q = vm.replyTarget {
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(replySenderLabel(for: q))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(replyPreview(for: q))
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    vm.cancelCompose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Cancel reply")
            }
            .padding(8)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var editChip: some View {
        if vm.editTarget != nil {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .foregroundStyle(Theme.accent)
                Text("Editing message")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    vm.cancelCompose()
                    vm.draft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Cancel edit")
            }
            .padding(8)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func replySenderLabel(for m: UIMessage) -> String {
        if m.fromMe { return "Replying to yourself" }
        if let i = m.senderJID.firstIndex(of: "@") {
            return "Replying to " + String(m.senderJID[..<i])
        }
        return "Replying to " + m.senderJID
    }

    private func replyPreview(for m: UIMessage) -> String {
        switch m.body {
        case .text(let t):
            return t
        case .media(let kind, let caption, let fileName, _):
            if let c = caption, !c.isEmpty { return c }
            if kind == "document", let n = fileName, !n.isEmpty { return n }
            return "[\(kind)]"
        case .poll(let q, _, _):
            return q
        case .system(let s):
            return s
        }
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
