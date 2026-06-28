import SwiftUI

/// Settings → Translation. Three cards: target language + auto-translate,
/// the never-translate denylist, and the on-device model card.
///
/// Reads / writes `TranslationViewModel` for the denylist + model state,
/// and `@AppStorage` directly for the target language so the cold-start
/// path that boots before the VM constructs (e.g. menu-bar previews) still
/// reads a stable value.
struct TranslationPanel: View {
    @Environment(TranslationViewModel.self) private var translation
    @AppStorage("yawac.translate.targetLang") private var targetLang: String = "en"
    @AppStorage("yawac.translate.auto")       private var autoTranslate: Bool = false

    /// 30-language list — keep in sync with the prior `SettingsView`.
    /// Hoisted here so `TranslationPanel` is self-contained and the
    /// "Never translate" Menu can present the same set with denylisted
    /// items filtered out.
    static let languages: [(code: String, name: String)] = [
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
        VStack(alignment: .leading, spacing: 26) {
            translationCard
            denylistCard
            modelCard
        }
    }

    // MARK: - Translation

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Translation")
            SettingsCard {
                SettingsRow(label: "Target language") {
                    SettingsSelect(
                        selection: $targetLang,
                        options: Self.languages.map { ($0.name, $0.code) }
                    )
                }
                SettingsRow(label: "Translate automatically") {
                    SettingsSwitch(isOn: $autoTranslate)
                }
            }
        }
    }

    // MARK: - Never translate

    private var denylistCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Never translate")
            SettingsCard {
                if translation.denylist.isEmpty {
                    HStack {
                        Text("No languages excluded.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                } else {
                    ForEach(Array(translation.denylist).sorted(), id: \.self) { code in
                        SettingsRow(label: name(for: code)) {
                            SettingsPillButton("Remove", style: .neutral) {
                                translation.allowLanguage(code)
                            }
                        }
                    }
                }
                addLanguageRow
            }
        }
    }

    private var addLanguageRow: some View {
        Menu {
            ForEach(Self.languages, id: \.code) { lang in
                if !translation.denylist.contains(lang.code) {
                    Button(lang.name) {
                        translation.denyLanguage(lang.code)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text("Add language")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func name(for code: String) -> String {
        if let known = Self.languages.first(where: { $0.code == code })?.name {
            return known
        }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: - Translation model

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Translation model")
            SettingsCard {
                modelBody
            }
        }
    }

    @ViewBuilder
    private var modelBody: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.accentSoft)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Qwen2.5-3B-Instruct")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    installedBadge
                }
                Text("4-bit · on-device · 1.9 GB")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                modelStateBody
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var installedBadge: some View {
        if case .ready = translation.model.state {
            Text("INSTALLED")
                .font(.system(size: 10, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Theme.installed)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.installedSoft,
                            in: RoundedRectangle(cornerRadius: 4))
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var modelStateBody: some View {
        switch translation.model.state {
        case .absent:
            HStack {
                SettingsPillButton("Download (≈ 2.3 GB)", style: .primary) {
                    Task { await translation.model.download() }
                }
            }
            .padding(.top, 6)
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading model… \(Int(p * 100))%")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(maxWidth: 280)
            }
            .padding(.top, 6)
        case .ready:
            HStack(spacing: 8) {
                SettingsPillButton("Update", style: .neutral) {
                    Task {
                        await translation.model.delete()
                        await translation.model.download()
                    }
                }
                SettingsPillButton("Delete", style: .danger) {
                    Task { await translation.model.delete() }
                }
            }
            .padding(.top, 6)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text("Error: \(msg)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
                SettingsPillButton("Retry", style: .neutral) {
                    Task { await translation.model.download() }
                }
            }
            .padding(.top, 6)
        }
    }
}
