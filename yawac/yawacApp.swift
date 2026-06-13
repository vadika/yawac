import SwiftUI
import SwiftData
import AppKit
import UserNotifications
import Sparkle

@main
struct YawacApp: App {
    @State private var session = SessionViewModel()
    @State private var showShortcuts = false
    // F41: Sparkle 2 updater. The controller owns its own Updater
    // instance, reads SUFeedURL + SUPublicEDKey from Info.plist, and
    // fires a background update check on launch. The "Check for
    // Updates…" menu item drives a manual check via
    // `updater.checkForUpdates`.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)
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
        // F73 dock policy moved to .onAppear (NSApp isn't ready in
        // App.init() — calling setActivationPolicy there triggers a
        // Swift runtime assertion crash on launch).
        //
        // F45: chat-scoped fetches need a B-tree index on
        // (chatJID, timestamp) etc. SwiftData's `#Index<T>` macro is
        // not used — adding it changes nothing in the entity attribute
        // graph (v0.9.61 shipped it inside a VersionedSchema migration
        // and CoreData rejected the launch with "Duplicate version
        // checksums detected"). Indices are managed via raw SQL
        // instead: open the store path as SQLite and run
        // `CREATE INDEX IF NOT EXISTS` for each predicate column. Runs
        // on a background task so it doesn't push first-paint;
        // idempotent so re-launches are ms-cheap no-ops.
        Task.detached(priority: .utility) {
            if let url = SwiftDataIndexes.defaultStoreURL {
                SwiftDataIndexes.ensure(at: url)
            }
        }
        // F37: prune SwiftData's transaction log on startup. The
        // backing CoreData store keeps an ATRANSACTION + ACHANGE
        // history for CloudKit / cross-device sync semantics yawac
        // doesn't use. With 44k message rows the log + its indexes
        // had reached 207 MB on top of 32 MB of real data — every
        // flush during full-history sync had to append to (and
        // re-index) the log on top of the actual insert, which was a
        // direct beachball contributor. Prune to a 7-day rolling
        // window on each launch; the daily growth is tiny once
        // history sync settles.
        Task.detached(priority: .utility) { [container = self.container] in
            await pruneSwiftDataHistory(container: container,
                                        keepDays: 7)
        }
        Task { await NotificationService.requestAuthorization() }
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared

        Task.detached(priority: .utility) {
            await MessageIndex.shared.bootstrapIfNeeded()
        }
        // Wake-rate hunt instrumentation. Logs per-second platform-idle
        // and interrupt wake counts under subsystem 'dev.vadikas.yawac.yawac'
        // category 'perf'. Matches the kernel's wake-attribution counter
        // — directly tells us when wakes spike and what we were doing.
        WakeRateProbe.start()
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
                    let show = UserDefaults.standard
                        .object(forKey: "yawac.menuBar.show") as? Bool ?? false
                    MenuBarController.shared.setEnabled(show)
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

/// F37: Drop SwiftData/CoreData transaction history older than
/// `keepDays` days. The history tables back CloudKit / cross-device
/// sync semantics yawac doesn't use; left unpruned they grow into
/// hundreds of MB of garbage. SwiftData exposes the underlying
/// CoreData history API only obliquely, so this runs a raw SQLite
/// DELETE against the same on-disk store. Off-main + bounded; failure
/// is non-fatal (next launch tries again).
private func pruneSwiftDataHistory(container: ModelContainer,
                                   keepDays: Int) async {
    let supportDir = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first
    guard let storeURL = supportDir?.appendingPathComponent("default.store") else {
        return
    }
    // ZTIMESTAMP on ATRANSACTION is a CoreData reference epoch
    // (2001-01-01). Convert keepDays back from that anchor.
    let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        .timeIntervalSinceReferenceDate
    let path = storeURL.path
    let sql = """
    DELETE FROM ACHANGE WHERE ZTRANSACTIONID IN
        (SELECT Z_PK FROM ATRANSACTION WHERE ZTIMESTAMP < \(cutoff));
    DELETE FROM ATRANSACTION WHERE ZTIMESTAMP < \(cutoff);
    """
    let task = Process()
    task.launchPath = "/usr/bin/sqlite3"
    task.arguments = [path, sql]
    let pipe = Pipe()
    task.standardError = pipe
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        NSLog("[yawac/prune-history] failed: %@", String(describing: error))
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
