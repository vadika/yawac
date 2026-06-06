import SwiftUI

struct SettingsView: View {
    @Environment(TranslationViewModel.self) private var translation
    @Environment(SessionViewModel.self) private var session

    @AppStorage("yawac.translate.targetLang")
    private var targetLang: String = "en"
    @AppStorage(UIScaleStep.storageKey) private var scaleStepRaw = UIScaleStep.default.rawValue
    @State private var showLinkedDevices = false

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

            Section("Account") {
                Button {
                    showLinkedDevices = true
                } label: {
                    HStack {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .foregroundStyle(.secondary)
                        Text("Linked devices…")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.state != .ready)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .onAppear {
            translation.model.refreshState()
            session.loadBlocklist()
        }
        .sheet(isPresented: $showLinkedDevices) {
            LinkedDevicesSheet()
                .environment(session)
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
