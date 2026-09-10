import SwiftUI
import SwiftData
import AppKit
import UserNotifications
import Sparkle
import AppIntents

@main
struct YawacApp: App {
    @State private var session: SessionViewModel
    @State private var showShortcuts = false
    // F41: Sparkle 2 updater. The controller owns its own Updater
    // instance, reads SUFeedURL + SUPublicEDKey from Info.plist, and
    // fires a background update check on launch. The "Check for
    // Updates…" menu item drives a manual check via
    // `updater.checkForUpdates`.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: !AppPaths.isRunningTests,
        updaterDelegate: nil,
        userDriverDelegate: nil)
    @State private var translation: TranslationViewModel = {
        let store = TranslationStore()
        let mgr = TranslationModelManager()
        mgr.refreshState()
        let engine = TranslationEngine()
        let vm = TranslationViewModel(
            store: store,
            model: mgr,
            loadEngine: { url in try await engine.load(modelDir: url) },
            translateText: { text, source, target in
                try await engine.translate(text, from: source, to: target)
            })
        // Kick off engine load in the background if model is on disk
        // already. First translate after launch is then instant.
        if !AppPaths.isRunningTests, case .ready(let dir) = mgr.state {
            Task.detached(priority: .utility) {
                try? await engine.load(modelDir: dir)
            }
        }
        return vm
    }()
    let container: ModelContainer

    init() {
        do {
            self.container = try ModelContainer(
                for: PersistedMessage.self,
                PersistedChat.self,
                PersistedReaction.self,
                PersistedPollVote.self,
                PersistedFolder.self,
                configurations: ModelConfiguration(url: AppPaths.messageStoreURL))
        } catch {
            fatalError("ModelContainer: \(error)")
        }
        _session = State(initialValue: SessionViewModel(container: container))
        guard !AppPaths.isRunningTests else { return }
        Task { await NotificationService.requestAuthorization() }
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared

    }

    var body: some Scene {
        WindowGroup("yawac") {
            AppRoot()
                .environment(session)
                .environment(translation)
                .modelContainer(container)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
                .background(Theme.bg)
                .graphiteWindow()
                .onAppear {
                    // F73: apply initial dock policy. Moved here from
                    // init() because NSApp isn't ready in App.init().
                    let keep = UserDefaults.standard
                        .object(forKey: "yawac.dock.keep") as? Bool ?? true
                    NSApp.setActivationPolicy(keep ? .regular : .accessory)
                    // F73: bind the session every appearance (the
                    // singleton survives WindowGroup teardown), then
                    // reflect the current "Show in menu bar" setting.
                    MenuBarController.shared.bind(session: session)
                    // F97: register session for App Intents dependency injection.
                    // Done here (not init()) because @State can't be read from App.init.
                    AppDependencyManager.shared.add(dependency: session)
                    let show = UserDefaults.standard
                        .object(forKey: "yawac.menuBar.show") as? Bool ?? false
                    // Test-host runs would otherwise race the GlobalHotkeyTests for ⌘⇧Y;
                    // keep the status item + hotkey out of XCTest hosts.
                    let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                    MenuBarController.shared.setEnabled(show && !underTest)
                }
                .sheet(isPresented: $showShortcuts) {
                    KeyboardShortcutsView()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Account") {
                Button("Log Out") {
                    Task { await session.logout() }
                }
                .keyboardShortcut("Q", modifiers: [.command, .shift])
            }
            CommandMenu("Find") {
                FindCommands()
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.updater.checkForUpdates()
                }
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts…") {
                    showShortcuts = true
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(translation)
                .environment(session)
        }
    }
}

private struct FindCommands: View {
    @FocusedValue(\.activeConversation) private var conversation

    var body: some View {
        Button("Find…") {
            conversation?.findActive.toggle()
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(conversation == nil)
    }
}

/// Helper that brings the main yawac window forward or hides it,
/// implementing classic tray-icon behaviour.
enum WindowToggler {
    /// Unconditionally brings the main window to the foreground.
    /// Use this from notification taps where we always want to show the app.
    static func bringToFront() {
        let app = NSApp!
        app.activate(ignoringOtherApps: true)
        let windows = app.windows.filter { w in
            !(w is NSPanel) && w.canBecomeKey
        }
        if let target = windows.first {
            if target.isMiniaturized { target.deminiaturize(nil) }
            target.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(#selector(NSApplication.unhide(_:)), to: nil, from: nil)
        }
    }

    static func toggleMain() {
        let app = NSApp!
        // Find a non-popover, non-status visible window of our app.
        let windows = app.windows.filter { w in
            !(w is NSPanel) && w.canBecomeKey
        }
        if let visible = windows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
            visible.orderOut(nil)
        } else if let hidden = windows.first {
            if hidden.isMiniaturized {
                hidden.deminiaturize(nil)
            }
            app.activate(ignoringOtherApps: true)
            hidden.makeKeyAndOrderFront(nil)
        } else {
            // No window exists (closed by user) — ask the WindowGroup to
            // open a fresh one via the open-window environment action.
            // Done via NSApp's reopen path:
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(#selector(NSApplication.unhide(_:)), to: nil, from: nil)
        }
    }
}
