import AppKit
import Foundation
import Network

/// Accelerates WhatsApp reconnection on three OS signals — wake from
/// sleep, network-path change, app becoming active — that whatsmeow's
/// own keepalive/backoff would otherwise take up to ~3 min to act on.
///
/// Signals are coalesced through a single debounce window so a burst
/// (wake + network + active often fire together) yields one reconnect.
/// A wake in the window forces a reconnect unconditionally because the
/// post-sleep socket is half-open and `isConnected()` returns a stale
/// true; network/active-only windows reconnect only when actually down.
///
/// OS wiring lives in `start()`. The decision logic in `trigger(_:)` is
/// closure-injected so it can be unit-tested without real sleep.
@MainActor
final class ConnectivityMonitor {
    enum Reason { case wake, network, appActive }

    private let debounce: Duration
    /// Delays *between* reconnect attempts; the last value repeats for
    /// every attempt past the array's end. The loop retries
    /// indefinitely while disconnected (until connected, cancelled, or
    /// `stop()`), because the window after a path flips `.satisfied`
    /// but DNS/routing isn't usable yet can outlast any fixed schedule
    /// — observed 50s+ of `no such host` after Wi-Fi returned.
    private let retryBackoff: [Duration]
    private let isReady: () -> Bool
    private let isConnected: () -> Bool
    private let reconnect: (_ force: Bool) async -> Void

    private var debounceTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var wakeInWindow = false

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "yawac.connectivity.path")
    private var sawFirstPath = false
    private var observers: [NSObjectProtocol] = []

    init(debounce: Duration = .seconds(2),
         retryBackoff: [Duration] = [.seconds(2), .seconds(4), .seconds(8),
                                     .seconds(8), .seconds(8)],
         isReady: @escaping () -> Bool,
         isConnected: @escaping () -> Bool,
         reconnect: @escaping (_ force: Bool) async -> Void) {
        self.debounce = debounce
        self.retryBackoff = retryBackoff
        self.isReady = isReady
        self.isConnected = isConnected
        self.reconnect = reconnect
    }

    /// Begins listening to OS signals. Call once after the client is
    /// created.
    func start() {
        // Sleep/wake is delivered on NSWorkspace's OWN notification
        // center, not NotificationCenter.default — a common bug source.
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trigger(.wake) }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trigger(.appActive) }
            })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.handlePath(satisfied: path.status == .satisfied) }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func stop() {
        debounceTask?.cancel(); debounceTask = nil
        loopTask?.cancel(); loopTask = nil
        pathMonitor.cancel()
        let ws = NSWorkspace.shared.notificationCenter
        for o in observers {
            ws.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
    }

    private func handlePath(satisfied: Bool) {
        // The first path callback fires at startup with the current
        // route — ignore it so a healthy boot connection isn't churned.
        guard sawFirstPath else { sawFirstPath = true; return }
        guard satisfied else { return }
        trigger(.network)
    }

    /// Coalesces triggers within one debounce window into a single
    /// reconnect decision. Exposed (not private) for unit tests.
    func trigger(_ reason: Reason) {
        if reason == .wake { wakeInWindow = true }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.fire()
        }
    }

    private func fire() {
        let force = wakeInWindow
        wakeInWindow = false
        guard isReady() else { return }
        // Already up and this isn't a post-sleep half-open suspicion →
        // nothing to do.
        if !force && isConnected() { return }
        startReconnectLoop(force: force)
    }

    /// Retries reconnect with backoff until the socket is up or the
    /// backoff schedule is exhausted. Attempts are awaited (serialized)
    /// so two `Connect()` calls never overlap and contend on the socket
    /// lock. A fresh trigger cancels an in-flight loop and starts over.
    /// A `force` first attempt (post-sleep wake) bypasses the
    /// `isConnected()` guard because that flag is stale-true on a
    /// half-open socket.
    private func startReconnectLoop(force: Bool) {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var i = 0
            while !Task.isCancelled {
                let mustForce = force && i == 0
                if !mustForce && self.isConnected() { return }
                NSLog("[yawac/connectivity] reconnect attempt \(i + 1) force=\(mustForce)")
                await self.reconnect(mustForce)
                if Task.isCancelled || self.isConnected() { return }
                // Escalate through the schedule, then hold at its last
                // value forever so a late DNS recovery still reconnects.
                let delay = self.retryBackoff[min(i, self.retryBackoff.count - 1)]
                try? await Task.sleep(for: delay)
                i += 1
            }
        }
    }
}
