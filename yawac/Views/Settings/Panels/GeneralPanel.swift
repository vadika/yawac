import SwiftUI
import AppKit

/// Settings → General. Five toggles + one Select grouped into General /
/// Notifications cards.
///
/// **Wiring status** (v0.9.13): the `@AppStorage` keys are new and
/// cosmetic-only — none of these prefs are read by the rest of the app
/// yet. They're persisted so a future release that wires up actual
/// launch-at-login (SMAppService), menu-bar visibility, and notification
/// preview/sound can pick the existing values up without forcing every
/// user to re-tick them. The Settings UI is the source of truth for the
/// design system shipping in this release; the functional plumbing
/// follows as separate features.
struct GeneralPanel: View {
    @AppStorage("yawac.launchAtLogin")          private var launchAtLogin = false
    @AppStorage("yawac.menuBar.show")           private var showInMenuBar = false
    @AppStorage("yawac.dock.keep")              private var keepInDock = true
    @AppStorage("yawac.notifications.enabled")  private var notifEnabled = true
    @AppStorage("yawac.notifications.preview")  private var notifPreview = true
    @AppStorage("yawac.notifications.sound")    private var notifSound: String = "Default"

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionLabel("General")
                SettingsCard {
                    SettingsRow(label: "Launch at login") {
                        SettingsSwitch(isOn: $launchAtLogin)
                    }
                    SettingsRow(label: "Show in menu bar") {
                        SettingsSwitch(isOn: $showInMenuBar)
                    }
                    SettingsRow(label: "Keep in dock") {
                        SettingsSwitch(isOn: $keepInDock)
                    }
                }
                .onChange(of: keepInDock) { _, newValue in
                    NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                    if newValue {
                        WindowToggler.bringToFront()
                    }
                }
                .onChange(of: launchAtLogin) { _, newValue in
                    _ = LaunchAtLoginService.apply(newValue)
                }
                .onChange(of: showInMenuBar) { _, newValue in
                    MenuBarController.shared.setEnabled(newValue)
                }
                .onAppear {
                    // System truth wins on first display so a manual System Settings
                    // removal doesn't leave the toggle stuck on.
                    launchAtLogin = LaunchAtLoginService.isEnabled
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionLabel("Notifications")
                SettingsCard {
                    SettingsRow(label: "Message notifications") {
                        SettingsSwitch(isOn: $notifEnabled)
                    }
                    SettingsRow(label: "Show preview text") {
                        SettingsSwitch(isOn: $notifPreview)
                    }
                    SettingsRow(label: "Notification sound") {
                        SettingsSelect(
                            selection: $notifSound,
                            options: Self.soundOptions
                        )
                    }
                }
            }
        }
    }

    private static let soundOptions: [(label: String, value: String)] = [
        ("Default", "Default"),
        ("Pop",     "Pop"),
        ("Glass",   "Glass"),
        ("None",    "None"),
    ]
}
