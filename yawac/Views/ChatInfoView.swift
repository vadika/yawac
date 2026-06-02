import SwiftUI
import AppKit

struct ChatInfoView: View {
    let chatJID: String
    /// Called when the user clicks the inspector's X. Toggled into the
    /// parent's @State so the inspector binding closes — using
    /// `@Environment(\.dismiss)` here would close the enclosing window
    /// instead of the inspector (the inspector content shares the
    /// window's dismiss environment).
    var onClose: (() -> Void)? = nil
    /// Forwarded into Shared Media / Files cells — called with the
    /// tapped message id so the conversation pane can scroll + flash
    /// the original bubble. Plumbed by `ConversationView`.
    var onJumpToMessage: ((String) -> Void)? = nil
    /// Bumps whenever the conversation message list changes (new
    /// inbound, history sync). Drives a re-fetch of the SHARED MEDIA
    /// / FILES sections so they pick up newly-persisted rows.
    var messageRevision: Int = 0
    /// Optional messageID → local file path lookup, sourced from
    /// `ConversationViewModel.localPaths`. Lets shared-media cells
    /// pick up just-downloaded files even when the persisted row
    /// still has a nil mediaPath.
    var mediaPathResolver: ((String) -> String?)? = nil
    @Environment(SessionViewModel.self) private var session
    @Environment(\.modelContext) private var modelContext
    @State private var group: BridgeGroupModel?
    @State private var loadingGroup = false
    @State private var loadError: String?
    @State private var subGroups: [BridgeSubGroup] = []
    @State private var joiningSubJID: String? = nil

    enum JoinStatus: Equatable {
        case pending(String)   // "Request sent…"
        case error(String)     // "Couldn't join…"
        var text: String {
            switch self {
            case .pending(let s), .error(let s): return s
            }
        }
        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }
    @State private var joinStatusByJID: [String: JoinStatus] = [:]
    @State private var userAbout: String?
    @State private var loadingUserInfo = false
    @State private var mediaVM: ChatMediaViewModel?
    @State private var confirmBlock = false
    @State private var confirmLeave = false
    @State private var editingName: Bool = false
    @State private var editingDescription: Bool = false
    @State private var nameDraft: String = ""
    @State private var descriptionDraft: String = ""
    @State private var addPanelOpen: Bool = false
    @State private var addPanelModel: AddParticipantsPanelModel? = nil
    @State private var addPanelError: String? = nil
    @State private var participantOpError: String? = nil
    @State private var confirmRemoveJID: String? = nil
    @State private var confirmDemoteJID: String? = nil
    @State private var avatarMenuOpen: Bool = false
    @State private var avatarError: String? = nil
    @State private var pickedImage: NSImage? = nil
    @State private var confirmRemovePhoto: Bool = false
    @State private var inviteSheetOpen: Bool = false

    private var isGroup: Bool { chatJID.hasSuffix("@g.us") }
    private var name: String { session.displayName(for: chatJID) }

    var body: some View {
        VStack(spacing: 0) {
            // ─── Title-bar gutter. 64pt matches the chat header so the
            // inspector seam aligns with the conversation pane's seam.
            eyebrow
                .padding(.horizontal, 18)
                .frame(height: 64)
                .background(Theme.sidebarBg)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    jidRow
                    if isGroup {
                        if loadingGroup {
                            ProgressView().controlSize(.small).tint(Theme.accent)
                                .frame(maxWidth: .infinity)
                        }
                        if let err = loadError {
                            Text(err).scaledUI(12)
                                .foregroundStyle(Color.red.opacity(0.85))
                        }
                        if let g = group { groupBody(g) }
                    } else {
                        userBody
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 22)
            }
        }
        .background(Theme.sidebarBg)
        .frame(minWidth: 300)
        .ignoresSafeArea(.container, edges: .top)
        .task(id: chatJID) {
            if isGroup {
                await loadGroup()
            } else {
                await loadUserInfo()
            }
            let vm = ChatMediaViewModel(chatJID: chatJID, context: modelContext)
            vm.externalPathResolver = mediaPathResolver
            vm.reload(limit: nil)
            mediaVM = vm
        }
        .onChange(of: messageRevision) { _, _ in
            mediaVM?.externalPathResolver = mediaPathResolver
            mediaVM?.reload(limit: nil)
        }
        .confirmationDialog("Block \(name)?", isPresented: $confirmBlock) {
            Button("Block", role: .destructive) {
                session.setBlocked(chatJID, blocked: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won't be able to message you or see when you're online.")
        }
        .confirmationDialog("Leave \(name)?", isPresented: $confirmLeave) {
            Button("Leave", role: .destructive) { leaveGroup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop receiving messages from this group.")
        }
        .confirmationDialog(
            "Remove \(confirmRemoveJID.map { session.displayName(for: $0) } ?? "member")?",
            isPresented: Binding(
                get: { confirmRemoveJID != nil },
                set: { if !$0 { confirmRemoveJID = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let jid = confirmRemoveJID, let g = group {
                    applyParticipantOp(group: g, action: "remove", jid: jid)
                }
                confirmRemoveJID = nil
            }
            Button("Cancel", role: .cancel) { confirmRemoveJID = nil }
        } message: {
            Text("They'll stop receiving messages from this group.")
        }
        .confirmationDialog(
            "Demote \(confirmDemoteJID.map { session.displayName(for: $0) } ?? "admin")?",
            isPresented: Binding(
                get: { confirmDemoteJID != nil },
                set: { if !$0 { confirmDemoteJID = nil } })
        ) {
            Button("Demote", role: .destructive) {
                if let jid = confirmDemoteJID, let g = group {
                    applyParticipantOp(group: g, action: "demote", jid: jid)
                }
                confirmDemoteJID = nil
            }
            Button("Cancel", role: .cancel) { confirmDemoteJID = nil }
        } message: {
            Text("They'll lose admin privileges in this group.")
        }
        .sheet(isPresented: $inviteSheetOpen) {
            if let client = session.client {
                InviteLinkSheet(chatJID: chatJID,
                                chatName: name,
                                isAdmin: isAdminForCurrentGroup,
                                client: client,
                                onClose: { inviteSheetOpen = false })
            }
        }
    }

    private func leaveGroup() {
        guard let client = session.client else { return }
        let jid = chatJID
        Task { @MainActor in
            do {
                try await Task.detached { try client.leaveGroup(jid: jid) }.value
                session.chatList?.applyIncomingDelete(chatJID: jid)
                onClose?()
            } catch {
                NSLog("[yawac/leaveGroup] failed jid=%@ err=%@",
                      jid, String(describing: error))
            }
        }
    }

    // ─── Eyebrow ─────────────────────────────────────────────────────
    @ViewBuilder
    private var eyebrow: some View {
        HStack {
            Text((isGroup ? "GROUP INFO" : "USER INFO"))
                .scaledUI(10, weight: .semibold)
                .tracking(1.4)
                .foregroundStyle(Theme.textFaint)
            Spacer()
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .scaledIcon(11, weight: .semibold)
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    // ─── Hero (avatar + name + subline) ──────────────────────────────
    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                AvatarView(jid: chatJID, name: name, size: 92)
                if isGroup, isAdminForCurrentGroup {
                    avatarHoverOverlay
                }
            }
            VStack(spacing: 4) {
                Text(name)
                    .scaledUI(20, weight: .semibold)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                if isGroup, let g = group {
                    Text("GROUP · \(g.participants.count) MEMBERS")
                        .scaledUI(10.5, weight: .medium)
                        .tracking(1)
                        .foregroundStyle(Theme.textMuted)
                } else if !isGroup {
                    if let about = userAbout, !about.isEmpty {
                        Text(about)
                            .scaledUI(12)
                            .foregroundStyle(Theme.textMuted)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    } else if loadingUserInfo {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                    }
                }
            }
            if let err = avatarError {
                Text(err)
                    .scaledUI(11)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var isAdminForCurrentGroup: Bool {
        guard let g = group else { return false }
        return isCurrentUserAdmin(g)
    }

    @State private var avatarHovered: Bool = false

    @ViewBuilder
    private var avatarHoverOverlay: some View {
        Group {
            if avatarHovered {
                Circle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 92, height: 92)
                    .overlay {
                        Text("EDIT\nPHOTO")
                            .scaledUI(10, weight: .semibold)
                            .tracking(0.6)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.white)
                    }
            }
        }
        .frame(width: 92, height: 92)
        .contentShape(Circle())
        .onHover { avatarHovered = $0 }
        .onTapGesture { avatarMenuOpen = true }
        .confirmationDialog("Group photo",
                            isPresented: $avatarMenuOpen,
                            titleVisibility: .visible) {
            Button("Change photo…") { pickPhoto() }
            Button("Remove photo", role: .destructive) {
                confirmRemovePhoto = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove group photo?",
                            isPresented: $confirmRemovePhoto) {
            Button("Remove", role: .destructive) { removePhoto() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: Binding(
            get: { pickedImage.map { ImageBox(image: $0) } },
            set: { pickedImage = $0?.image })
        ) { box in
            AvatarCropSheet(original: box.image,
                            onApply: { data in
                                pickedImage = nil
                                uploadAvatar(data)
                            },
                            onCancel: { pickedImage = nil })
        }
    }

    private struct ImageBox: Identifiable {
        let id = UUID()
        let image: NSImage
    }

    private func pickPhoto() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url,
                  let img = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async {
                pickedImage = img
            }
        }
    }

    private func uploadAvatar(_ data: Data) {
        guard let client = session.client else { return }
        let chatJID = self.chatJID
        Task { @MainActor in
            do {
                _ = try client.setGroupPhoto(chatJID: chatJID, jpeg: data)
                await AvatarCache.shared.invalidate(jid: chatJID)
            } catch {
                avatarError = error.localizedDescription
                scheduleAvatarErrorAutodismiss()
            }
        }
    }

    private func removePhoto() {
        guard let client = session.client else { return }
        let chatJID = self.chatJID
        Task { @MainActor in
            do {
                try await Task.detached {
                    try client.removeGroupPhoto(chatJID: chatJID)
                }.value
                await AvatarCache.shared.invalidate(jid: chatJID)
            } catch {
                avatarError = error.localizedDescription
                scheduleAvatarErrorAutodismiss()
            }
        }
    }

    private func scheduleAvatarErrorAutodismiss() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            avatarError = nil
        }
    }

    // ─── JID row with copy ───────────────────────────────────────────
    @ViewBuilder
    private var jidRow: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(chatJID, forType: .string)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "number")
                    .scaledIcon(11, weight: .medium)
                    .foregroundStyle(Theme.textMuted)
                Text(chatJID)
                    .scaledMono(11.5)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "doc.on.doc")
                    .scaledIcon(11, weight: .regular)
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy JID")
    }

    // ─── User body (1:1) ─────────────────────────────────────────────
    @ViewBuilder
    private var userBody: some View {
        if let pushName = session.contactNames[chatJID] {
            metadataRow([
                .init(label: "PUSH NAME", value: pushName),
                .init(label: "TYPE", value: "Direct chat"),
            ])
        } else {
            metadataRow([
                .init(label: "TYPE", value: "Direct chat"),
            ])
        }
        actionRow(actions: [
            .init(label: "Mute", icon: "speaker.slash"),
            .init(label: "Search", icon: "magnifyingglass"),
            session.isBlocked(chatJID)
                ? .init(label: "Unblock", icon: "hand.raised.slash",
                        action: { session.setBlocked(chatJID, blocked: false) })
                : .init(label: "Block", icon: "hand.raised", destructive: true,
                        action: { confirmBlock = true }),
        ])
        starredSection
        sharedMediaSection
        filesSection
    }

    @MainActor
    private func loadUserInfo() async {
        guard let client = session.client else { return }
        userAbout = nil
        loadingUserInfo = true
        defer { loadingUserInfo = false }
        let info = try? client.getUserInfo(jid: chatJID)
        userAbout = info?.status
    }

    // ─── Group body ──────────────────────────────────────────────────
    private func isCurrentUserAdmin(_ g: BridgeGroupModel) -> Bool {
        let client = session.client
        let rawOwn = client?.ownJID ?? ""
        guard !rawOwn.isEmpty else { return false }
        // Match across both LID and PN forms: the participant entry may
        // carry an @lid JID while ownJID is the @s.whatsapp.net form (or
        // vice versa) for the same physical person.
        let ownBare = JIDNormalize.bare(rawOwn)
        let ownCanon = JIDNormalize.canonical(rawOwn, client: client)
        return g.participants.contains { p in
            guard p.isAdmin || p.isSuper else { return false }
            let pBare = JIDNormalize.bare(p.jid)
            if pBare == ownBare || pBare == ownCanon { return true }
            let pCanon = JIDNormalize.canonical(p.jid, client: client)
            return pCanon == ownBare || pCanon == ownCanon
        }
    }

    @ViewBuilder
    private func groupBody(_ g: BridgeGroupModel) -> some View {
        let admin = isCurrentUserAdmin(g)
        let chat = session.chatList?.chats.first(where: { $0.jid == g.jid })
            ?? Chat(jid: g.jid, name: g.name,
                    lastMessage: "", lastTimestamp: 0, unread: 0)

        // NAME
        sectionCard(label: "NAME") {
            if editingName {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Group name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .scaledUI(13)
                        .foregroundStyle(Theme.text)
                        .onChange(of: nameDraft) { _, new in
                            if new.count > 100 {
                                nameDraft = String(new.prefix(100))
                            }
                        }
                    HStack {
                        Text("\(nameDraft.count)/100")
                            .scaledMono(10)
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Cancel") {
                            editingName = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textMuted)
                        Button("Save") {
                            session.chatList?.setGroupName(chat, to: nameDraft)
                            editingName = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || nameDraft == chat.name)
                    }
                }
            } else {
                HStack(alignment: .top) {
                    Text(chat.name)
                        .scaledUI(13)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if admin {
                        Button {
                            nameDraft = chat.name
                            editingName = true
                        } label: {
                            Image(systemName: "pencil")
                                .scaledIcon(11, weight: .semibold)
                                .foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Edit name")
                    }
                }
            }
        }

        // DESCRIPTION
        sectionCard(label: "DESCRIPTION") {
            if editingDescription {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Add a description",
                              text: $descriptionDraft,
                              axis: .vertical)
                        .lineLimit(3...10)
                        .textFieldStyle(.plain)
                        .scaledUI(13)
                        .foregroundStyle(Theme.text)
                        .onChange(of: descriptionDraft) { _, new in
                            if new.count > 512 {
                                descriptionDraft = String(new.prefix(512))
                            }
                        }
                    HStack {
                        Text("\(descriptionDraft.count)/512")
                            .scaledMono(10)
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Cancel") {
                            editingDescription = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textMuted)
                        Button("Save") {
                            session.chatList?.setGroupDescription(chat,
                                to: descriptionDraft)
                            editingDescription = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(descriptionDraft == (chat.groupDescription ?? ""))
                    }
                }
            } else {
                HStack(alignment: .top) {
                    let desc = (chat.groupDescription ?? "").isEmpty
                        ? nil
                        : chat.groupDescription
                    Group {
                        if let d = desc {
                            Text(Linkify.attributed(d))
                                .scaledUI(13)
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                        } else {
                            Text("No description")
                                .scaledUI(13)
                                .foregroundStyle(Theme.textFaint)
                                .italic()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if admin {
                        Button {
                            descriptionDraft = chat.groupDescription ?? ""
                            editingDescription = true
                        } label: {
                            Image(systemName: "pencil")
                                .scaledIcon(11, weight: .semibold)
                                .foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Edit description")
                    }
                }
            }
        }

        metadataRow([
            .init(label: "MEMBERS", value: "\(g.participants.count)"),
            .init(label: "CREATED",
                  value: Date(timeIntervalSince1970: TimeInterval(g.created))
                    .formatted(.dateTime.day().month(.abbreviated).year())),
        ])

        actionRow(actions: [
            .init(label: "Mute", icon: "speaker.slash"),
            .init(label: "Search", icon: "magnifyingglass"),
            .init(label: "Invite", icon: "link",
                  action: { inviteSheetOpen = true }),
            .init(label: "Leave", icon: "rectangle.portrait.and.arrow.right",
                  destructive: true, action: { confirmLeave = true }),
        ])

        starredSection
        sharedMediaSection
        filesSection

        HStack {
            sectionLabel("PARTICIPANTS", trailing: "\(g.participants.count)")
            if admin {
                Button {
                    openAddPanel(group: g)
                } label: {
                    Label("Add member", systemImage: "plus")
                        .scaledUI(11, weight: .medium)
                        .foregroundStyle(Theme.accentText)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
        }
        if addPanelOpen, let model = addPanelModel {
            AddParticipantsPanel(
                model: model,
                onCommit: { jids in commitAdd(group: g, jids: jids) },
                onCancel: { closeAddPanel() }
            )
            .padding(.bottom, 6)
        }
        if let err = participantOpError {
            Text(err)
                .scaledUI(11)
                .foregroundStyle(Color.red.opacity(0.9))
                .padding(.bottom, 4)
        }
        VStack(spacing: 0) {
            ForEach(sortedParticipants(g.participants), id: \.jid) { p in
                participantRow(p, in: g, currentUserIsAdmin: admin)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }

        // Surface community sibling groups whenever there's a parent —
        // either we ARE the parent, or we're a sub-group with a known
        // parent. Skip the current chat (no self-row in its own list).
        let directory = subGroups.filter { $0.jid != chatJID }
        if !directory.isEmpty {
            let label = g.isParent ? "LINKED GROUPS" : "COMMUNITY GROUPS"
            sectionLabel(label, trailing: "\(directory.count)")
            VStack(spacing: 0) {
                ForEach(directory, id: \.jid) { sub in
                    subGroupRow(sub)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
        }
    }

    // ─── Starred messages ────────────────────────────────────────────
    @ViewBuilder
    private var starredSection: some View {
        if let vm = mediaVM, vm.starredTotal > 0 {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("STARRED", trailing: "\(vm.starredTotal)")
                VStack(spacing: 0) {
                    ForEach(vm.starred) { item in
                        StarredMessageRow(item: item) {
                            onJumpToMessage?(item.id)
                        }
                        if item.id != vm.starred.last?.id {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    // ─── Shared media + files ────────────────────────────────────────
    @ViewBuilder
    private var sharedMediaSection: some View {
        if let vm = mediaVM, vm.mediaTotal > 0 {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("SHARED MEDIA", trailing: "\(vm.mediaTotal)")
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(maximum: 108),
                                            spacing: 6,
                                            alignment: .leading),
                        count: 3),
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(vm.media) { item in
                        SharedMediaCell(item: item, onTap: jumpOrOpen)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        if let vm = mediaVM, vm.filesTotal > 0 {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("FILES", trailing: "\(vm.filesTotal)")
                VStack(spacing: 0) {
                    ForEach(vm.files) { item in
                        SharedFileRow(item: item, onTap: jumpOrOpen)
                        if item.id != vm.files.last?.id {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    /// Cell tap policy: if the parent supplied an `onJumpToMessage`
    /// callback (i.e. we're inside the conversation inspector),
    /// scroll the conversation to the original bubble; otherwise
    /// fall back to opening the file in the system default app.
    private func jumpOrOpen(messageID: String, fallbackPath: String?) {
        if let onJumpToMessage {
            onJumpToMessage(messageID)
        } else if let p = fallbackPath, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
    }

    // ─── Reusable bits ───────────────────────────────────────────────
    private struct MetaItem { let label: String; let value: String }
    @ViewBuilder
    private func metadataRow(_ items: [MetaItem]) -> some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text(items[i].label)
                        .scaledUI(9.5, weight: .semibold)
                        .tracking(1)
                        .foregroundStyle(Theme.textFaint)
                    Text(items[i].value)
                        .scaledUI(14, weight: .medium)
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
        }
    }

    private struct ActionItem {
        let label: String
        let icon: String
        var destructive: Bool = false
        var action: (() -> Void)? = nil
    }
    @ViewBuilder
    private func actionRow(actions: [ActionItem]) -> some View {
        HStack(spacing: 8) {
            ForEach(actions.indices, id: \.self) { i in
                let a = actions[i]
                Button { a.action?() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: a.icon)
                            .scaledIcon(14, weight: .regular)
                        Text(a.label)
                            .scaledUI(11.5, weight: .medium)
                    }
                    .foregroundStyle(a.destructive ? Color.red.opacity(0.95) : Theme.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(a.action == nil)
            }
        }
    }

    @ViewBuilder
    private func sectionCard<C: View>(label: String,
                                      @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .scaledUI(9.5, weight: .semibold)
                .tracking(1)
                .foregroundStyle(Theme.textFaint)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .scaledUI(10, weight: .semibold)
                .tracking(1.2)
                .foregroundStyle(Theme.textFaint)
            Spacer()
            if let trailing {
                Text(trailing)
                    .scaledMono(10.5)
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func participantRow(_ p: BridgeParticipantModel,
                                in group: BridgeGroupModel,
                                currentUserIsAdmin: Bool) -> some View {
        Button {
            let jid = p.jid
            Task { @MainActor in
                session.requestSelectChat(jid)
            }
        } label: {
            HStack(spacing: 10) {
                AvatarView(jid: p.jid, name: session.displayName(for: p.jid), size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.displayName(for: p.jid))
                            .scaledUI(13, weight: .medium)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if p.isSuper {
                            roleBadge("SUPER", color: Theme.superRole)
                        } else if p.isAdmin {
                            roleBadge("ADMIN", color: Theme.adminRole)
                        }
                    }
                    Text(p.jid)
                        .scaledMono(10.5)
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy JID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.jid, forType: .string)
            }
            Button("Copy name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.displayName(for: p.jid),
                                               forType: .string)
            }
            if currentUserIsAdmin && !isCurrentUser(p.jid) {
                Divider()
                if p.isAdmin || p.isSuper {
                    Button("Demote") { confirmDemoteJID = p.jid }
                } else {
                    Button("Promote to admin") {
                        applyParticipantOp(group: group, action: "promote",
                                           jid: p.jid)
                    }
                }
                Button("Remove from group", role: .destructive) {
                    confirmRemoveJID = p.jid
                }
            }
        }
    }

    @ViewBuilder
    private func roleBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .scaledUI(9, weight: .bold)
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
    }

    @ViewBuilder
    private func subGroupRow(_ sub: BridgeSubGroup) -> some View {
        let joined = session.chatList?.chats.contains(where: { $0.jid == sub.jid }) ?? false
        let displayName = sub.name.isEmpty
            ? session.displayName(for: sub.jid)
            : sub.name
        let status = joinStatusByJID[sub.jid]
        HStack(spacing: 10) {
            AvatarView(jid: sub.jid, name: displayName, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .scaledUI(13, weight: .medium)
                    .foregroundStyle(joined ? Theme.text : Theme.textMuted)
                    .lineLimit(1)
                if let status {
                    Text(status.text)
                        .scaledUI(11)
                        .foregroundStyle(status.isError
                                         ? Color.red.opacity(0.85)
                                         : Theme.accentText)
                        .lineLimit(2)
                } else {
                    Text(sub.jid)
                        .scaledMono(10.5)
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if joined {
                Image(systemName: "arrow.right")
                    .scaledIcon(11, weight: .medium)
                    .foregroundStyle(Theme.textMuted)
            } else if joiningSubJID == sub.jid {
                ProgressView().controlSize(.small)
            } else {
                Button("Join") {
                    Task { await join(sub: sub) }
                }
                .buttonStyle(.plain)
                .scaledUI(11, weight: .semibold)
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.accentSoft, in: Capsule())
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard joined else { return }
            session.requestSelectChat(sub.jid)
        }
    }

    @MainActor
    private func join(sub: BridgeSubGroup) async {
        guard let client = session.client else { return }
        joiningSubJID = sub.jid
        joinStatusByJID[sub.jid] = nil
        defer { joiningSubJID = nil }
        do {
            let joinedJID = try client.joinSubGroup(subJID: sub.jid)
            // JoinGroupWithLink returns a JID for both instant-join
            // AND pending-approval; whatsmeow swallows the distinction.
            // Probe via getGroupInfo — succeeds only when the user is
            // actually a member.
            if let info = try? client.getGroupInfo(jid: joinedJID) {
                session.chatList?.mergeGroups([info])
            } else {
                joinStatusByJID[sub.jid] =
                    .pending("Request sent — waiting for admin approval")
            }
        } catch {
            joinStatusByJID[sub.jid] =
                .error(error.localizedDescription)
        }
    }

    private struct StarredMessageRow: View {
        let item: ChatMediaViewModel.StarredItem
        let onTap: () -> Void

        private var icon: String {
            switch item.kind {
            case "image":    return "photo"
            case "video":    return "play.rectangle"
            case "audio":    return "waveform"
            case "document": return "doc"
            case "sticker":  return "face.smiling"
            case "poll":     return "chart.bar"
            default:         return "text.bubble"
            }
        }

        var body: some View {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: "star.fill")
                        .scaledIcon(11, weight: .medium)
                        .foregroundStyle(.yellow)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.snippet)
                            .scaledUI(12.5)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Image(systemName: icon)
                                .scaledIcon(9.5)
                                .foregroundStyle(Theme.textFaint)
                            Text(item.timestamp,
                                 format: .dateTime.day().month(.abbreviated)
                                    .hour(.twoDigits(amPM: .omitted)).minute())
                                .scaledMono(10.5)
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func openAddPanel(group: BridgeGroupModel) {
        guard let client = session.client else { return }
        let existing = Set(group.participants.map(\.jid))
        let contacts = session.contactNames.map { (jid, name) in
            BridgeContact(jid: jid, name: name,
                          pushName: nil, fullName: nil, businessName: nil)
        }
        addPanelModel = AddParticipantsPanelModel(
            existingParticipantJIDs: existing,
            allContacts: contacts,
            validator: client)
        addPanelOpen = true
    }

    private func closeAddPanel() {
        addPanelOpen = false
        addPanelModel = nil
    }

    private func commitAdd(group: BridgeGroupModel, jids: [String]) {
        guard let client = session.client, let model = addPanelModel else { return }
        model.inFlight = true
        let chatJID = group.jid
        Task { @MainActor in
            defer { model.inFlight = false }
            do {
                let resp = try client.updateGroupParticipants(
                    chatJID: chatJID, action: "add",
                    participantJIDs: jids)
                model.applyResult(resp)
                await loadGroup()
            } catch {
                participantOpError = error.localizedDescription
                scheduleParticipantErrorAutodismiss()
            }
        }
    }

    private func scheduleParticipantErrorAutodismiss() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            participantOpError = nil
        }
    }

    private func isCurrentUser(_ jid: String) -> Bool {
        let own = session.client?.ownJID ?? ""
        guard !own.isEmpty else { return false }
        return JIDNormalize.bare(jid) == JIDNormalize.bare(own)
            || JIDNormalize.canonical(jid, client: session.client) ==
               JIDNormalize.canonical(own, client: session.client)
    }

    private func applyParticipantOp(group: BridgeGroupModel,
                                    action: String,
                                    jid: String) {
        guard let client = session.client else { return }
        let chatJID = group.jid
        Task { @MainActor in
            do {
                _ = try client.updateGroupParticipants(
                    chatJID: chatJID, action: action,
                    participantJIDs: [jid])
                await loadGroup()
            } catch {
                participantOpError = error.localizedDescription
                scheduleParticipantErrorAutodismiss()
            }
        }
    }

    private func sortedParticipants(_ ps: [BridgeParticipantModel])
        -> [BridgeParticipantModel] {
        ps.sorted { lhs, rhs in
            let lt = (lhs.isSuper ? 2 : (lhs.isAdmin ? 1 : 0))
            let rt = (rhs.isSuper ? 2 : (rhs.isAdmin ? 1 : 0))
            if lt != rt { return lt > rt }
            return session.displayName(for: lhs.jid)
                .localizedCaseInsensitiveCompare(session.displayName(for: rhs.jid))
                == .orderedAscending
        }
    }

    @MainActor
    private func loadGroup() async {
        guard let client = session.client else { return }
        loadingGroup = true
        defer { loadingGroup = false }
        // Reset cross-chat state so a non-community group doesn't
        // carry the previous chat's directory.
        subGroups = []
        joinStatusByJID = [:]
        do {
            let g = try client.getGroupInfo(jid: chatJID)
            self.group = g
            // Reconcile chat-list row with the freshly-fetched group
            // metadata. Phone-side renames + description edits arrive
            // only via events.GroupInfo for live changes; cold-opens of
            // the inspector are our other reliable sync point.
            session.chatList?.applyLocalGroupInfo(
                chatJID: chatJID,
                name: g.name.isEmpty ? nil : g.name,
                description: g.topic.isEmpty ? "" : g.topic)
            // Populate the sub-groups directory whether the user is
            // viewing the community parent OR a sub-group of one. The
            // parent can't be opened as a chat (default-sub redirect),
            // so the announce / sub-group inspector is the practical
            // entry point for browsing siblings.
            let parentForDirectory: String? = g.isParent
                ? chatJID
                : g.linkedParentJID
            if let parent = parentForDirectory, !parent.isEmpty,
               let subs = try? client.listSubGroups(parentJID: parent) {
                self.subGroups = subs
            }
        } catch {
            self.loadError = error.localizedDescription
        }
    }
}
