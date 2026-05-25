import SwiftUI
import SwiftData
import AppKit
import UserNotifications

@main
struct YawacApp: App {
    @State private var session = SessionViewModel()
    @State private var translation: TranslationViewModel = {
        let store = TranslationStore()
        let mgr = TranslationModelManager()
        mgr.refreshState()
        let engine = TranslationEngine()
        let vm = TranslationViewModel(store: store, model: mgr, engine: engine)
        // Kick off engine load in the background if model is on disk
        // already. First translate after launch is then instant.
        if case .ready(let dir) = mgr.state {
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
                PersistedPollVote.self)
        } catch {
            fatalError("ModelContainer: \(error)")
        }
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
        }

        MenuBarExtra("yawac",
                     image: session.totalUnread > 0 ? "MenuBarActive" : "MenuBarIdle") {
            if session.totalUnread > 0 {
                Text("\(session.totalUnread) unread")
                    .foregroundStyle(.secondary)
                Divider()
            }
            Button("Show / Hide Window") {
                WindowToggler.toggleMain()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Quit yawac") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(translation)
        }
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
