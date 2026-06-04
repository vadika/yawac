import AppKit
import SwiftUI

/// Owns the menubar status item. Replaces `MenuBarExtra` (which can't
/// distinguish left- vs right-click on macOS — both fire the menu) with
/// a raw `NSStatusItem`:
///
///   - Left-click  → show / hide / unminimize the main window.
///   - Right-click → drop the action menu (unread count, Quit, etc).
///
/// `install(session:)` must be called from a SwiftUI lifecycle hook so
/// `NSApp` is fully wired by the time we touch `NSStatusBar`.
@MainActor
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private weak var session: SessionViewModel?
    private var observationTask: Task<Void, Never>?

    func install(session: SessionViewModel) {
        guard self.item == nil else { return }
        self.session = session
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.item = item
        refreshIcon()
        startObservingUnread()
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
            WindowToggler.bringToFront()
        }
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
            let header = NSMenuItem(title: "\(unread) unread", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }
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

    @objc private func menuToggleWindow() { WindowToggler.toggleMain() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
