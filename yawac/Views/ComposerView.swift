import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var vm: ConversationViewModel
    @Environment(SessionViewModel.self) private var session
    @Environment(\.uiScaleFactor) private var uiScale
    @FocusState private var focused: Bool
    @State private var recorder = VoiceRecorder()
    @State private var wantsCancel = false

    var body: some View {
        VStack(spacing: 8) {
            replyChip
            editChip
            attachmentStrip
            MentionStrip(picker: vm.picker, onCommit: commitMention)
            if recorder.state == .recording {
                RecordingBar(recorder: recorder, cancelHint: wantsCancel)
            }
            inputRow
        }
        .animation(.easeOut(duration: 0.15), value: vm.pendingAttachments)
        .animation(.easeOut(duration: 0.12), value: vm.picker.isActive)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Theme.bg)
        .onChange(of: vm.editTarget?.id) { _, _ in
            // Pre-fill draft when an edit starts; reset when it ends.
            if let m = vm.editTarget {
                if case .text(let t) = m.body { vm.draft = t }
            }
        }
        .onChange(of: vm.replyTarget?.id) { _, new in
            if new != nil { focused = true }
        }
    }

    private var draftIsEmpty: Bool {
        vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showMic: Bool {
        draftIsEmpty && vm.editTarget == nil && vm.pendingAttachments.isEmpty
    }

    private func send() {
        if !vm.pendingAttachments.isEmpty {
            Task { await vm.sendPendingAttachments() }
        } else if vm.editTarget != nil {
            Task { await vm.saveEdit(vm.draft); vm.draft = "" }
        } else {
            Task { await vm.sendDraft() }
        }
    }

    private func commitMention(_ cand: MentionPickerViewModel.Candidate) {
        let r = vm.picker.triggerRange ?? findCurrentTriggerRange()
        guard let r else { return }
        let insertion = "@\(cand.label) "
        vm.draft.replaceSubrange(r, with: insertion)
        vm.activeMentions.append(.init(displayName: cand.label, jid: cand.jid))
        vm.picker.cancel()
    }

    /// `picker.cancel()` clears triggerRange before this closure may run
    /// (e.g. tab while only one candidate); recompute by finding the
    /// last '@' in the current draft as a fallback.
    private func findCurrentTriggerRange() -> Range<String.Index>? {
        guard let at = vm.draft.lastIndex(of: "@") else { return nil }
        return at..<vm.draft.endIndex
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Button {
                attachFile()
            } label: {
                Image(systemName: "paperclip")
                    .scaledIcon(15, weight: .regular)
                    .foregroundStyle(Theme.textMuted)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Attach file")

            TextField(vm.pendingAttachments.isEmpty ? "Message…" : "Caption…",
                      text: $vm.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .scaledUI(14)
                .foregroundStyle(Theme.text)
                .padding(.vertical, 6)
                .tint(Theme.accent)
                .focused($focused)
                .onChange(of: vm.draft) { _, new in
                    vm.setTyping(!new.isEmpty)
                    Task { await vm.loadGroupParticipantsIfNeeded() }
                    let candidates: [MentionPickerViewModel.Candidate] = {
                        if let parts = vm.groupParticipants, !parts.isEmpty {
                            return parts.map { .participant(
                                jid: $0.jid,
                                displayName: session.displayName(for: $0.jid)) }
                        }
                        if !vm.chatJID.hasSuffix("@g.us") {
                            return [.participant(
                                jid: vm.chatJID,
                                displayName: session.displayName(for: vm.chatJID))]
                        }
                        return []
                    }()
                    vm.picker.setCandidates(candidates,
                                            includeEveryone: vm.chatJID.hasSuffix("@g.us"))
                    vm.picker.update(text: new)
                }
                .onSubmit { send() }
                .onKeyPress(.tab) {
                    guard vm.picker.isActive else { return .ignored }
                    if let pick = vm.picker.commitSelected() {
                        commitMention(pick)
                    }
                    return .handled
                }
                .onKeyPress(.return) {
                    guard vm.picker.isActive else { return .ignored }
                    if let pick = vm.picker.commitSelected() {
                        commitMention(pick)
                    }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard vm.picker.isActive else { return .ignored }
                    vm.picker.move(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    if vm.picker.isActive {
                        vm.picker.move(by: -1)
                        return .handled
                    }
                    guard vm.editTarget == nil, vm.replyTarget == nil,
                          vm.draft.isEmpty
                    else { return .ignored }
                    vm.editLastOwnMessage()
                    return vm.editTarget == nil ? .ignored : .handled
                }
                .onKeyPress(.escape) {
                    if vm.picker.isActive {
                        vm.picker.cancel()
                        return .handled
                    }
                    let wasEditing = (vm.editTarget != nil)
                    if vm.replyTarget != nil || vm.editTarget != nil {
                        vm.cancelCompose()
                        if wasEditing { vm.draft = "" }
                        return .handled
                    }
                    return .ignored
                }

            Button {
                NSApp.orderFrontCharacterPalette(nil)
            } label: {
                Image(systemName: "face.smiling")
                    .scaledIcon(15, weight: .regular)
                    .foregroundStyle(Theme.textMuted)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Emoji")

            if showMic {
                micButton
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: vm.editTarget != nil ? "checkmark" : "paperplane.fill")
                        .scaledIcon(13, weight: .semibold)
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
        if !vm.pendingAttachments.isEmpty { return true }
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
            ReplyPreview(
                author: replyAuthorName(for: q),
                text: replySnippet(for: q),
                mediaKind: replyMediaKind(for: q),
                mediaThumbnailPath: replyThumbnailPath(for: q),
                onCancel: { vm.cancelCompose() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var editChip: some View {
        if vm.editTarget != nil {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .foregroundStyle(Theme.accent)
                Text("Editing message")
                    .scaledUI(11)
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

    private func replyAuthorName(for m: UIMessage) -> String {
        if m.fromMe { return "yourself" }
        let name = session.displayName(for: m.senderJID)
        return name.isEmpty ? m.senderJID : name
    }

    private func replySnippet(for m: UIMessage) -> String {
        switch m.body {
        case .text(let t):
            return t
        case .media(_, let caption, let fileName, _):
            if let c = caption, !c.isEmpty { return c }
            if let n = fileName, !n.isEmpty { return n }
            return ""
        case .poll(let q, _, _):
            return q
        case .system(let s):
            return s
        }
    }

    private func replyMediaKind(for m: UIMessage) -> String? {
        if case .media(let kind, _, _, _) = m.body { return kind }
        return nil
    }

    private func replyThumbnailPath(for m: UIMessage) -> String? {
        guard case .media(let kind, _, _, let embedded) = m.body,
              kind == "image" || kind == "sticker" || kind == "video"
        else { return nil }
        // MessageRow resolves media via vm.localPaths (populated from
        // MediaCache + persisted store) — embedded localPath on the
        // UIMessage is often nil for inbound media until it lands. Look
        // up by message id first, then fall back to the embedded path.
        if let resolved = vm.localPaths[m.id], !resolved.isEmpty {
            return resolved
        }
        return embedded
    }

    /// Push-and-hold mic, drawn entirely by AppKit. Pure NSView keeps
    /// SwiftUI's _ButtonGesture machinery from touching the click — on
    /// macOS 26 that pipeline crashes inside `MainActor.assumeIsolated`
    /// when its host view re-renders during dispatch.
    private var micButton: some View {
        MicNSButton(
            symbolPointSize: 14 * uiScale,
            isRecording: recorder.state == .recording,
            onDown: {
                Task { @MainActor in
                    guard await recorder.requestPermission() else { return }
                    recorder.start()
                }
            },
            onMove: { dy in wantsCancel = dy > 40 },
            onUp: {
                if wantsCancel || recorder.state != .recording {
                    recorder.cancel()
                } else if let r = try? recorder.finish() {
                    Task { await vm.sendVoiceNote(r) }
                } else {
                    recorder.cancel()
                }
                wantsCancel = false
            }
        )
        .frame(width: 32, height: 32)
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { vm.stageAttachment(at: url) }
        }
    }

    // ─── Staged-attachment preview strip ─────────────────────────────
    @ViewBuilder
    private var attachmentStrip: some View {
        if !vm.pendingAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.pendingAttachments) { att in
                        attachmentChip(att)
                    }
                }
                .padding(.vertical, 2)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func attachmentChip(_ att: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if att.kind == "image", let img = NSImage(contentsOf: att.url) {
                    Image(nsImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipped()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: chipIcon(att.kind))
                            .scaledIcon(18)
                            .foregroundStyle(Theme.textMuted)
                        Text(att.url.lastPathComponent)
                            .scaledUI(8)
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .frame(width: 48)
                    }
                    .frame(width: 56, height: 56)
                }
            }
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                vm.removePendingAttachment(att.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledIcon(14)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(2)
            .help("Remove")
        }
    }

    private func chipIcon(_ kind: String) -> String {
        switch kind {
        case "video": return "film.fill"
        case "audio": return "waveform"
        default:      return "doc.fill"
        }
    }
}

/// Push-and-hold mic, drawn + click-handled entirely in AppKit so the
/// SwiftUI Button gesture machinery never sees the click. On macOS 26,
/// SwiftUI's `_ButtonGesture` dispatch crashes inside
/// `MainActor.assumeIsolated` when the host view re-renders during a
/// click — replacing the SwiftUI Image+overlay with a real NSView
/// sidesteps that pipeline entirely.
private struct MicNSButton: NSViewRepresentable {
    let symbolPointSize: CGFloat
    let isRecording: Bool
    let onDown: () -> Void
    let onMove: (CGFloat) -> Void
    let onUp: () -> Void

    func makeNSView(context: Context) -> MicView {
        let v = MicView()
        v.symbolPointSize = symbolPointSize
        v.isRecording = isRecording
        v.onDown = onDown
        v.onMove = onMove
        v.onUp = onUp
        return v
    }

    func updateNSView(_ v: MicView, context: Context) {
        v.symbolPointSize = symbolPointSize
        v.isRecording = isRecording
        v.onDown = onDown
        v.onMove = onMove
        v.onUp = onUp
    }

    final class MicView: NSView {
        var onDown: (() -> Void)?
        var onMove: ((CGFloat) -> Void)?
        var onUp: (() -> Void)?
        var symbolPointSize: CGFloat = 14 {
            didSet {
                guard symbolPointSize != oldValue else { return }
                applySymbolConfiguration()
            }
        }
        var isRecording: Bool = false {
            didSet {
                imageView.image = NSImage(systemSymbolName: isRecording ? "mic.fill" : "mic",
                                          accessibilityDescription: nil)
                applySymbolConfiguration()
                layer?.backgroundColor = (isRecording ? NSColor.systemRed
                                                       : NSColor.controlAccentColor).cgColor
            }
        }
        private var startY: CGFloat = 0
        private let imageView = NSImageView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 16
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor

            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
            applySymbolConfiguration()
            imageView.contentTintColor = .white
            imageView.imageScaling = .scaleProportionallyDown
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startY = event.locationInWindow.y
            onDown?()
        }
        override func mouseDragged(with event: NSEvent) {
            onMove?(event.locationInWindow.y - startY)
        }
        override func mouseUp(with event: NSEvent) {
            onUp?()
        }

        private func applySymbolConfiguration() {
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: symbolPointSize, weight: .semibold)
        }
    }
}
