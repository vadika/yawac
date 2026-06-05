import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(TranslationViewModel.self) private var translation
    @Environment(SessionViewModel.self) private var session

    @AppStorage("yawac.translate.targetLang")
    private var targetLang: String = "en"
    @AppStorage(UIScaleStep.storageKey) private var scaleStepRaw = UIScaleStep.default.rawValue

    // ─── About me state ──────────────────────────────────────────────
    @State private var aboutDraft: String = ""
    @State private var aboutBaseline: String = ""
    @State private var aboutSaving: Bool = false
    @State private var aboutError: String?
    @State private var avatarMenuOpen: Bool = false
    @State private var avatarError: String?
    @State private var pickedAvatar: NSImage?
    @State private var confirmRemoveAvatar: Bool = false

    private static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("de", "German"), ("fi", "Finnish"),
        ("ru", "Russian"), ("fr", "French"), ("es", "Spanish"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
        ("ar", "Arabic"), ("tr", "Turkish"), ("uk", "Ukrainian"),
        ("pl", "Polish"), ("sv", "Swedish"), ("no", "Norwegian"),
        ("da", "Danish"), ("el", "Greek"), ("he", "Hebrew"),
        ("hi", "Hindi"), ("id", "Indonesian"), ("ms", "Malay"),
        ("ro", "Romanian"), ("cs", "Czech"), ("hu", "Hungarian"),
        ("bg", "Bulgarian"), ("th", "Thai"), ("vi", "Vietnamese"),
    ]

    var body: some View {
        Form {
            Section("About me") {
                aboutMeSection
            }

            Section("Display") {
                let step = UIScaleStep.from(scaleStepRaw)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Interface size")
                        Spacer()
                        Text(step.label).foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(scaleStepRaw) },
                            set: { scaleStepRaw = UIScaleStep.from(Int($0.rounded())).rawValue }
                        ),
                        in: 0...Double(UIScaleStep.allCases.count - 1),
                        step: 1
                    )
                    Text("Aa  The quick brown fox")
                        .scaledUI(14)
                        .environment(\.uiScaleFactor, step.scaleFactor)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Translation") {
                Picker("Target language", selection: $targetLang) {
                    ForEach(Self.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
            }

            Section("Never translate") {
                if translation.denylist.isEmpty {
                    Text("No languages excluded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(translation.denylist).sorted(), id: \.self) { code in
                        HStack {
                            Text(Locale.current.localizedString(
                                forLanguageCode: code) ?? code)
                            Spacer()
                            Button("Remove") {
                                translation.allowLanguage(code)
                            }
                        }
                    }
                }
                Menu("Add language") {
                    ForEach(Self.languages, id: \.code) { lang in
                        if !translation.denylist.contains(lang.code) {
                            Button(lang.name) {
                                translation.denyLanguage(lang.code)
                            }
                        }
                    }
                }
            }

            Section("Blocked contacts") {
                if session.blockedJIDs.isEmpty {
                    Text("No blocked contacts.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.blockedJIDs.sorted(), id: \.self) { jid in
                        HStack {
                            Text(session.displayName(for: jid))
                            Spacer()
                            Button("Unblock") {
                                session.setBlocked(jid, blocked: false)
                            }
                        }
                    }
                }
            }

            Section("Translation model") {
                modelSection
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .onAppear {
            translation.model.refreshState()
            session.loadBlocklist()
        }
        .task {
            if let info = await session.fetchSelfInfo() {
                let about = info.status ?? ""
                aboutBaseline = about
                aboutDraft = about
            }
        }
        .sheet(item: Binding(
            get: { pickedAvatar.map { ImageBox(image: $0) } },
            set: { pickedAvatar = $0?.image })
        ) { box in
            AvatarCropSheet(original: box.image,
                            onApply: { data in
                                pickedAvatar = nil
                                uploadAvatar(data)
                            },
                            onCancel: { pickedAvatar = nil })
        }
        .confirmationDialog("Remove profile photo?",
                            isPresented: $confirmRemoveAvatar) {
            Button("Remove", role: .destructive) { removeAvatar() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private struct ImageBox: Identifiable {
        let id = UUID()
        let image: NSImage
    }

    // ─── About me section ───────────────────────────────────────────
    @ViewBuilder
    private var aboutMeSection: some View {
        let own = session.client?.ownJID ?? ""
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    if own.isEmpty {
                        Circle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 64, height: 64)
                    } else {
                        AvatarView(jid: own,
                                   name: session.displayName(for: own),
                                   size: 64)
                    }
                    Menu {
                        Button("Choose photo…") { pickAvatar() }
                        Button("Remove photo", role: .destructive) {
                            confirmRemoveAvatar = true
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .medium))
                            .padding(5)
                            .background(Color.accentColor, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(own.isEmpty)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if own.isEmpty {
                        Text("Not paired")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(session.displayName(for: own))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("Edit display name on your phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("About")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $aboutDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .disabled(own.isEmpty)
                HStack {
                    if let err = aboutError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                    Spacer()
                    Button("Save About") { saveAbout() }
                        .disabled(aboutDraft == aboutBaseline
                                  || aboutSaving
                                  || own.isEmpty)
                }
            }

            if let avatarError {
                Text(avatarError).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url,
                  let img = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async {
                pickedAvatar = img
            }
        }
    }

    private func uploadAvatar(_ data: Data) {
        guard let client = session.client else {
            avatarError = "Not paired."
            return
        }
        let own = client.ownJID
        guard !own.isEmpty else {
            avatarError = "Not paired."
            return
        }
        Task { @MainActor in
            do {
                try await Task.detached {
                    try client.setSelfAvatar(jpegBytes: data)
                }.value
                await AvatarCache.shared.invalidate(
                    jid: JIDNormalize.key(own, client: client))
                avatarError = nil
            } catch {
                avatarError = (error as NSError).localizedDescription
            }
        }
    }

    private func removeAvatar() {
        guard let client = session.client else { return }
        let own = client.ownJID
        guard !own.isEmpty else { return }
        Task { @MainActor in
            do {
                try await Task.detached {
                    try client.removeSelfAvatar()
                }.value
                await AvatarCache.shared.invalidate(
                    jid: JIDNormalize.key(own, client: client))
                avatarError = nil
            } catch {
                avatarError = (error as NSError).localizedDescription
            }
        }
    }

    private func saveAbout() {
        guard let client = session.client else {
            aboutError = "Not paired."
            return
        }
        let msg = aboutDraft
        aboutSaving = true
        aboutError = nil
        Task { @MainActor in
            defer { aboutSaving = false }
            do {
                try await Task.detached {
                    try client.setSelfAbout(msg)
                }.value
                aboutBaseline = msg
            } catch {
                aboutError = (error as NSError).localizedDescription
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        switch translation.model.state {
        case .absent:
            VStack(alignment: .leading, spacing: 6) {
                Text("Model not installed.")
                    .foregroundStyle(.secondary)
                Button("Download (≈ 2.3 GB)") {
                    Task { await translation.model.download() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading model…")
                ProgressView(value: p)
            }
        case .ready(let url):
            VStack(alignment: .leading, spacing: 6) {
                Text("Installed at \(url.lastPathComponent)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Update") {
                        Task {
                            await translation.model.delete()
                            await translation.model.download()
                        }
                    }
                    Button("Delete") {
                        Task { await translation.model.delete() }
                    }
                    .foregroundStyle(.red)
                }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text("Error: \(msg)").foregroundStyle(.red)
                Button("Retry") {
                    Task { await translation.model.download() }
                }
            }
        }
    }
}
