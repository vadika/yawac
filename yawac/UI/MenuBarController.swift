import AppKit
import SwiftUI

/// Owns the menubar status item. Replaces `MenuBarExtra` (which can't
/// distinguish left- vs right-click on macOS — both fire the menu) with
/// a raw `NSStatusItem`:
///
///   - Left-click  → toggle the quick-send popover.
///   - Right-click → drop the action menu (unread count, Show Main
///     Window, Quit, etc).
///
/// F73: the status item is now optional — `bind(session:)` caches the
/// session on launch and `setEnabled(_:)` installs / tears down to
/// follow the `yawac.menuBar.show` preference. `install()` must run
/// from a SwiftUI lifecycle hook so `NSApp` is fully wired by the time
/// we touch `NSStatusBar`.
///
/// F87: the install/teardown bundle also owns an `NSPopover` for the
/// quick-send UI and a Carbon `GlobalHotkey` (⌘⇧Y) — all three follow
/// the `yawac.menuBar.show` toggle as one unit.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var item: NSStatusItem?
    private weak var session: SessionViewModel?
    private var observationTask: Task<Void, Never>?

    // F87: popover + global hotkey lifecycle.
    private var popover: NSPopover?
    private let hotkey = GlobalHotkey()

    override private init() { super.init() }

    /// Cache the session for later install/uninstall cycles driven by
    /// the Settings toggle. Safe to call multiple times.
    func bind(session: SessionViewModel) {
        self.session = session
    }

    /// F73: turn the status item on or off without tearing the cached
    /// session reference.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            tearDown()
        }
    }

    private func install() {
        guard self.item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.item = item
        refreshIcon()
        startObservingUnread()

        // F87: register the global ⌘⇧Y hotkey alongside the status
        // item. The lifecycle is bundled — disabling the menu bar
        // setting tears both down.
        hotkey.register { [weak self] in
            Task { @MainActor [weak self] in
                self?.togglePopover()
            }
        }
    }

    private func tearDown() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        }
        popover = nil
        hotkey.unregister()

        guard let item else { return }
        observationTask?.cancel()
        observationTask = nil
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    /// Re-arms whenever `session.totalUnread` mutates so the menubar
    /// glyph flips between `MenuBarIdle` and `MenuBarActive` without
    /// extra wiring. `withObservationTracking` fires `onChange` exactly
    /// once per change — we re-arm from inside the callback so the task
    /// stays purely event-driven (no 60s wake loop).
    private func startObservingUnread() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            self?.armUnreadObserver()
        }
    }

    @MainActor
    private func armUnreadObserver() {
        withObservationTracking {
            _ = self.session?.totalUnread
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshIcon()
                self?.armUnreadObserver()
            }
        }
    }

    private func refreshIcon() {
        guard let button = item?.button else { return }
        let unread = session?.totalUnread ?? 0
        let name = unread > 0 ? "MenuBarActive" : "MenuBarIdle"
        let img = NSImage(named: name)
        img?.isTemplate = (unread == 0)
        button.image = img
    }

    @objc private func handleClick(_ sender: Any?) {
        let isRightClick = (NSApp.currentEvent?.type == .rightMouseUp)
            || (NSApp.currentEvent?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            popContextMenu()
        } else {
            // F87: left-click now toggles the quick-send popover
            // instead of bringing the main window forward. "Show Main
            // Window" lives in the right-click context menu.
            togglePopover()
        }
    }

    /// F87: public entry point for both the status-item left-click and
    /// the Carbon ⌘⇧Y hotkey callback. Idempotent — clicking while
    /// the popover is already open closes it.
    func togglePopover() {
        guard let item, let button = item.button else { return }
        guard let session else { return }
        guard let client = session.client else {
            // No client = no point opening the popover.
            return
        }
        let popover = ensurePopover(session: session, client: client)
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Activate yawac just enough to host the popover focus,
            // without bringing the main window forward — `.accessory`
            // is the policy when `yawac.dock.keep` is false, so
            // forcing activation is necessary for keyboard focus.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds,
                         of: button, preferredEdge: .minY)
        }
    }

    private func ensurePopover(session: SessionViewModel,
                               client: WAClient) -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let root = QuickSendPopover(session: session,
                                    client: client,
                                    onClose: { [weak self] in
            self?.popover?.performClose(nil)
        })
        popover.contentViewController = NSHostingController(rootView: root)
        self.popover = popover
        return popover
    }

    private func popContextMenu() {
        guard let item else { return }
        let menu = buildMenu()
        // Standard pattern: attach the menu, fire performClick, then
        // detach so the next left-click runs handleClick instead of
        // popping the menu again.
        item.menu = menu
        item.button?.performClick(nil)
        DispatchQueue.main.async { [weak item] in item?.menu = nil }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if let unread = session?.totalUnread, unread > 0 {
            let header = NSMenuItem(title: "\(unread) unread",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }
        // F87: "Show Main Window" entered the context menu when
        // left-click moved to the popover.
        let show = NSMenuItem(title: "Show Main Window",
                              action: #selector(menuShowWindow),
                              keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let toggle = NSMenuItem(title: "Show / Hide Window",
                                action: #selector(menuToggleWindow),
                                keyEquivalent: "h")
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit yawac",
                              action: #selector(menuQuit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func menuShowWindow() { WindowToggler.bringToFront() }
    @objc private func menuToggleWindow() { WindowToggler.toggleMain() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
