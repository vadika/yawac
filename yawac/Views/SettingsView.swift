import SwiftUI

/// Settings window — v0.9.13 redesign per Claude Design handoff
/// (`docs/superpowers/specs/2026-06-06-settings-redesign-spec.md`).
///
/// Replaces the prior single-scroll `Form` with the macOS System
/// Settings pattern: a fixed 200pt category rail on the left, a
/// scrolling content pane on the right that centers its column at
/// `maxWidth: 620`. The selected category is persisted across launches
/// in `@AppStorage("yawac.settings.lastCategory")` — reopening Settings
/// lands on the panel you last touched.
///
/// Each panel is its own file under `Views/Settings/Panels/` and pulls
/// the view-models it actually needs out of `@Environment`; only those
/// that read `TranslationViewModel` / `SessionViewModel` get them
/// passed through, so the rail panes (General / Display) stay cheap
/// to render.
///
/// `NavigationSplitView` styling notes:
/// - `.navigationSplitViewColumnWidth(200)` pins the rail at exactly
///   200pt; `.frame(minWidth: 880, minHeight: 600)` keeps the content
///   pane breathable. The window itself isn't `.hiddenInset` (that
///   would require a `WindowGroup` modifier the app doesn't expose
///   here) — the standard macOS title bar sits above both columns.
///   This is the one spec deviation worth flagging.
/// - `SettingsPalette.bg` is set on the outermost background so the
///   gap between the two columns (the rare layouts where it shows)
///   matches the rest of the window instead of system gray.
struct SettingsView: View {
    @Environment(TranslationViewModel.self) private var translation
    @Environment(SessionViewModel.self) private var session

    @AppStorage("yawac.settings.lastCategory")
    private var lastCategory: String = SettingsCategory.general.rawValue

    private var selection: SettingsCategory {
        SettingsCategory(rawValue: lastCategory) ?? .general
    }

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general, display, translation, privacy, blocked, account, diagnostics
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general:     return "General"
            case .display:     return "Display"
            case .translation: return "Translation"
            case .privacy:     return "Privacy"
            case .blocked:     return "Blocked"
            case .account:     return "Account"
            case .diagnostics: return "Diagnostics"
            }
        }
        var icon: String {
            switch self {
            case .general:     return "gearshape"
            case .display:     return "display"
            case .translation: return "globe"
            case .privacy:     return "lock"
            case .blocked:     return "nosign"
            case .account:     return "person.crop.circle"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebarColumn
                .navigationSplitViewColumnWidth(200)
        } detail: {
            contentColumn
        }
        .background(SettingsPalette.bg)
        .frame(minWidth: 880, minHeight: 600)
        .onAppear {
            translation.model.refreshState()
            session.loadBlocklist()
        }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SettingsPalette.text)
                .padding(.horizontal, 14)
                .padding(.top, 18)
            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { cat in
                    sidebarRow(cat)
                }
            }
            .padding(.horizontal, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsPalette.sidebarBg)
    }

    @ViewBuilder
    private func sidebarRow(_ cat: SettingsCategory) -> some View {
        let active = selection == cat
        Button {
            lastCategory = cat.rawValue
        } label: {
            HStack(spacing: 9) {
                Image(systemName: cat.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(active ? SettingsPalette.accent
                                            : SettingsPalette.textMuted)
                    .frame(width: 18)
                Text(cat.label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(active ? SettingsPalette.accentText
                                            : SettingsPalette.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(active ? SettingsPalette.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content column

    private var contentColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selection.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsPalette.text)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .frame(height: 44)
            .background(SettingsPalette.bg)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(SettingsPalette.hairline)
                    .frame(height: 1)
            }

            ScrollView {
                VStack(spacing: 26) {
                    panelBody
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .background(SettingsPalette.bg)
    }

    @ViewBuilder
    private var panelBody: some View {
        switch selection {
        case .general:     GeneralPanel()
        case .display:     DisplayPanel()
        case .translation: TranslationPanel().environment(translation)
        case .privacy:     PrivacyPanel().environment(session)
        case .blocked:     BlockedPanel().environment(session)
        case .account:     AccountPanel().environment(session)
        case .diagnostics: DiagnosticsPanel().environment(session)
        }
    }
}
