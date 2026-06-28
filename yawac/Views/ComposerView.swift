import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ComposerView {
    /// Writes an NSImage's PNG representation to a unique file under
    /// the system temp dir so it can be staged through the same
    /// path as a Finder-attached image.
    fileprivate static func saveImageToTemp(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("yawac-paste-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

struct ComposerView: View {
    @Bindable var vm: ConversationViewModel
    @Environment(SessionViewModel.self) private var session
    @Environment(\.uiScaleFactor) private var uiScale
    @FocusState private var focused: Bool
    @State private var recorder = VoiceRecorder()
    @State private var wantsCancel = false
    @State private var pasteMonitor: Any?
    @State private var showLocationPicker = false
    @State private var showContactPicker = false

    var body: some View {
        if let chat = currentChat, chat.isAnnounce, !chat.amAdmin {
            announceLockedNotice
        } else {
            composerBody
        }
    }

    /// The active `Chat` for `vm.chatJID`. Resolved through the session's
    /// canonical chat list so the gate stays in sync with the same
    /// `isAnnounce` / `amAdmin` fields ChatInfoView mutates.
    private var currentChat: Chat? {
        session.chatList?.chats.first(where: { $0.jid == vm.chatJID })
    }

    /// Shown in place of the composer when the chat is in announce mode
    /// and the user is not an admin. WhatsApp would reject the message
    /// server-side anyway; replacing the input row makes the gate
    /// visible up-front instead of surfacing a delivery failure later.
    private var announceLockedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "megaphone.fill")
                .scaledIcon(14)
                .foregroundStyle(Theme.textMuted)
            Text("Only admins can send messages in this group.")
                .italic()
                .scaledUI(12)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Theme.surface)
    }

    private var composerBody: some View {
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
        .animation(.easeOut(duration: 0.15), value: vm.pendingLocations)
        .animation(.easeOut(duration: 0.15), value: vm.pendingContacts)
        .animation(.easeOut(duration: 0.12), value: vm.picker.isActive)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Theme.bg)
        // F63: file drops on the composer area used to fall through to
        // SwiftUI's TextField (NSTextField on macOS), which has a
        // built-in NSDraggingDestination that inserts the dropped
        // URL as text — so dragging an image from Finder pasted
        // the file:// link into the message body instead of staging
        // the image as an attachment. The ConversationView-level
        // `.onDrop` never fired because AppKit handled it locally.
        // Mounting `.onDrop` on the composer's outer VStack catches
        // the drop before it reaches the TextField.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in vm.stageAttachment(at: url) }
                    }
                }
            }
            return true
        }
        .onChange(of: vm.editTarget?.id) { _, _ in
            // Pre-fill draft when an edit starts; reset when it ends.
            if let m = vm.editTarget {
                if case .text(let t) = m.body { vm.draft = t }
            }
        }
        .onChange(of: vm.replyTarget?.id) { _, new in
            if new != nil { focused = true }
        }
        .onAppear { installPasteMonitor() }
        .onDisappear { removePasteMonitor() }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheet(
                model: LocationPickerSheetModel(),
                onSend: { payload in
                    vm.stageLocation(payload)
                }
            )
        }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerSheet(
                model: ContactPickerSheetModel(contacts: contactsForPicker),
                onSend: { payload in
                    vm.stageContact(payload)
                }
            )
        }
    }

    /// Contact list passed to `ContactPickerSheet`. Mirrors the dedup
    /// pattern from `ChatListView.contactsForPicker`: walk
    /// `session.contactNames`, prefer the PN form over `@lid` when both
    /// are known, and drop self.
    private var contactsForPicker: [BridgeContact] {
        guard let client = session.client else { return [] }
        let selfKey = JIDNormalize.key(client.ownJID, client: client)
        var byKey: [String: BridgeContact] = [:]
        for (jid, name) in session.contactNames {
            let key = JIDNormalize.key(jid, client: client)
            if key == selfKey { continue }
            if let existing = byKey[key] {
                if existing.jid.hasSuffix("@lid"), !key.hasSuffix("@lid") {
                    byKey[key] = BridgeContact(
                        jid: key, name: name,
                        pushName: nil, fullName: nil, businessName: nil)
                }
                continue
            }
            byKey[key] = BridgeContact(
                jid: key, name: name,
                pushName: nil, fullName: nil, businessName: nil)
        }
        return Array(byKey.values)
    }

    /// Local NSEvent monitor watching for ⌘V while the composer is
    /// alive. Necessary because SwiftUI's `.onPasteCommand` on a
    /// TextField never fires — the TextField consumes the paste at
    /// the NSResponder level first, inserting the pasteboard's text
    /// representation (e.g. the file's path string). Intercepting at
    /// the window's local key-down lets us check the pasteboard
    /// ourselves and stage attachments when the payload is a file URL
    /// or image bitmap. Plain text paste falls through unchanged.
    private func installPasteMonitor() {
        removePasteMonitor()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌘V (allow capslock; reject shift/option/control combos).
            let flags = event.modifierFlags
            guard flags.contains(.command),
                  !flags.contains(.shift),
                  !flags.contains(.option),
                  !flags.contains(.control),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }
            if pasteAttachmentsFromPasteboard() {
                return nil    // consumed; default paste suppressed
            }
            return event      // not a file/image — let TextField paste text
        }
    }

    private func removePasteMonitor() {
        if let m = pasteMonitor {
            NSEvent.removeMonitor(m)
            pasteMonitor = nil
        }
    }

    /// Inspects the general pasteboard for file URLs or image bitmaps
    /// and stages them through `vm.stageAttachment`. Returns true when
    /// it consumed at least one item.
    @discardableResult
    private func pasteAttachmentsFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        // File URLs only — Chrome/Safari "Copy Image" puts its https source
        // URL on the pasteboard alongside the bitmap; without this filter
        // the URL branch wins and we try to stage the web URL as a file.
        let fileOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOnly) as? [URL],
           !urls.isEmpty {
            for url in urls { vm.stageAttachment(at: url) }
            return true
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first,
           let url = ComposerView.saveImageToTemp(first) {
            vm.stageAttachment(at: url)
            return true
        }
        return false
    }

    private var draftIsEmpty: Bool {
        vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasStaged: Bool {
        !vm.pendingAttachments.isEmpty
            || !vm.pendingLocations.isEmpty
            || !vm.pendingContacts.isEmpty
    }

    private var showMic: Bool {
        draftIsEmpty && vm.editTarget == nil && !hasStaged
    }

    private func send() {
        if hasStaged {
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
            Menu {
                Button {
                    attachFile()
                } label: {
                    Label("Attach file…", systemImage: "paperclip")
                }
                Button {
                    showLocationPicker = true
                } label: {
                    Label("Send location…", systemImage: "location")
                }
                Button {
                    showContactPicker = true
                } label: {
                    Label("Send contact…", systemImage: "person.crop.circle")
                }
                Button {
                    vm.showPollComposer = true
                } label: {
                    Label("New poll…", systemImage: "chart.bar.doc.horizontal")
                }
            } label: {
                Image(systemName: "paperclip")
                    .scaledIcon(15, weight: .regular)
                    .foregroundStyle(Theme.textMuted)
                    .padding(4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Attach")

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
                .onKeyPress(keys: [.return], phases: .down) { keyPress in
                    // ⇧Return → newline. Plain Return falls through to
                    // onSubmit (which sends) or to the picker commit.
                    if keyPress.modifiers.contains(.shift) {
                        vm.draft += "\n"
                        return .handled
                    }
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
        if hasStaged { return true }
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
        case .media(_, let caption, let fileName, _, _, _):
            if let c = caption, !c.isEmpty { return c }
            if let n = fileName, !n.isEmpty { return n }
            return ""
        case .poll(let q, _, _):
            return q
        case .location(let loc, let isLive, _):
            let label = isLive ? "Live location" : "Location"
            return loc.name.isEmpty ? label : "\(label): \(loc.name)"
        case .contact(let c):
            return "Contact: \(c.displayName)"
        case .contacts(let cs):
            return "Contacts: \(cs.count)"
        case .system(let s):
            return s
        }
    }

    private func replyMediaKind(for m: UIMessage) -> String? {
        if case .media(let kind, _, _, _, _, _) = m.body { return kind }
        return nil
    }

    private func replyThumbnailPath(for m: UIMessage) -> String? {
        guard case .media(let kind, _, _, let embedded, _, _) = m.body,
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
        if hasStaged {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.pendingAttachments) { att in
                        attachmentChip(att)
                    }
                    ForEach(Array(vm.pendingLocations.enumerated()), id: \.offset) { idx, loc in
                        locationChip(loc, index: idx)
                    }
                    ForEach(Array(vm.pendingContacts.enumerated()), id: \.offset) { idx, card in
                        contactChip(card, index: idx)
                    }
                }
                .padding(.vertical, 2)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func locationChip(_ loc: LocationPayload, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .scaledIcon(18)
                    .foregroundStyle(Theme.textMuted)
                Text(loc.name.isEmpty ? "Location" : loc.name)
                    .scaledUI(8)
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .frame(width: 48)
            }
            .frame(width: 56, height: 56)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                vm.removePendingLocation(at: index)
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

    private func contactChip(_ card: ContactPayload, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Image(systemName: "person.crop.circle.fill")
                    .scaledIcon(18)
                    .foregroundStyle(Theme.textMuted)
                Text(card.displayName.isEmpty ? "Contact" : card.displayName)
                    .scaledUI(8)
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .frame(width: 48)
            }
            .frame(width: 56, height: 56)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                vm.removePendingContact(at: index)
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

            // View-once toggle — only meaningful for image/video.
            // Pinned to the chip's bottom-trailing corner via a fixed
            // 56×56 frame; previously used .frame(maxWidth:.infinity,
            // maxHeight:.infinity, alignment:.bottomTrailing) which made
            // the ZStack expand to fill its parent, bloating the chip
            // (and the whole composer) beyond its 56×56 footprint.
            if att.kind == "image" || att.kind == "video" {
                Button {
                    vm.toggleViewOnce(att.id)
                } label: {
                    Image(systemName: att.viewOnce ? "eye.fill" : "eye")
                        .scaledIcon(12)
                        .foregroundStyle(att.viewOnce ? Theme.accent : .white,
                                         .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(2)
                .frame(width: 56, height: 56, alignment: .bottomTrailing)
                .help(att.viewOnce ? "View once: on" : "Send as view once")
            }
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
