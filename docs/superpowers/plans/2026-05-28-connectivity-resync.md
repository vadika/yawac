# Connectivity State + Resync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Accelerate WhatsApp reconnection after sleep/network-change/app-activate, surface accurate connection state in the UI, and resync state on every reconnect.

**Architecture:** A Swift `ConnectivityMonitor` listens for OS signals (wake, network-path change, app-active), debounces them, and forces a clean socket cycle via a new bridge `Reconnect()`. `SessionViewModel` gains a `connection` sub-state driven by whatsmeow's `Connected`/`Disconnected` events, surfaced through the existing `SyncBanner`. Pin/appstate reconcile runs on every reconnect. We lean on whatsmeow's existing keepalive/auto-reconnect — we only accelerate recovery and surface state.

**Tech Stack:** Go (whatsmeow bridge via gomobile), Swift/SwiftUI, Network.framework (`NWPathMonitor`), AppKit (`NSWorkspace`/`NSApplication` notifications).

**Spec:** `docs/superpowers/specs/2026-05-28-connectivity-resync-design.md`

> **STATUS: Shipped** in release `0.1.0+be7e053`. All tasks implemented + tested.
>
> **As-built deviations from the plan** (discovered during execution):
> - The single debounced reconnect raced DNS recovery (NWPathMonitor reports
>   `.satisfied` before DNS is usable). Replaced the one-shot attempt with an
>   **indefinite retry loop** (escalating backoff 2/4/8s, capped, until
>   connected/cancelled), serialized + off-main, with separate debounce/loop
>   task handles to avoid a self-cancel race.
> - Tried the `netcgo` build tag to force Go's cgo DNS resolver (the pure-Go
>   resolver lags `resolv.conf` ~40–60s after a Wi-Fi flap). It **destabilized
>   gomobile** (beachball/crash on disconnect) → reverted. Indefinite retry is
>   the accepted stable fix; the DNS lag is documented in `docs/TODO.md`.
> - Banner lifted to app level (ContentView) instead of staying conversation-only,
>   so it shows with no chat open.
> - Read-receipt dwell (2s viewport) landed alongside (pre-existing uncommitted work).

---

## File Structure

- `bridge/client.go` (modify) — add `Reconnect()` + `IsConnected()`.
- `bridge/reconnect_test.go` (create) — Go tests for the two methods.
- `yawac/Bridge/WAClient.swift` (modify) — `forceReconnect()` + `connected` Swift wrappers.
- `yawac/Services/ConnectivityMonitor.swift` (create) — OS-signal listener + debounced reconnect decision. Pure logic injectable for tests.
- `yawac/ViewModels/SessionViewModel.swift` (modify) — `Connection` sub-state, transitions, owns the monitor.
- `yawac/Views/ConversationView.swift` (modify) — fold `connection` into `currentSyncState`.
- `yawac/ContentView.swift` (modify) — reconcile on `.connected`.
- `yawacTests/ConnectivityMonitorTests.swift` (create) — debounce/coalesce/gating tests.
- `yawacTests/SessionConnectionStateTests.swift` (create) — connection transition tests.

After adding the two new Swift files, the Xcode project must be regenerated with `xcodegen generate` (the repo uses XcodeGen; new files under `yawac/` are picked up from `project.yml`'s source globs but the `.pbxproj` must be regenerated).

---

## Task 1: Bridge `Reconnect()` + `IsConnected()`

**Files:**
- Modify: `bridge/client.go`
- Test: `bridge/reconnect_test.go`

- [x] **Step 1: Write the failing test**

Create `bridge/reconnect_test.go`:

```go
package bridge

import "testing"

func TestReconnectNoopWhenUnpaired(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/rc.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	// Fresh client has no Store.ID — Reconnect must return nil without
	// touching the socket (the QR/pair flow owns connect when unpaired).
	if err := c.Reconnect(); err != nil {
		t.Fatalf("Reconnect on unpaired client: got %v, want nil", err)
	}
	if c.IsConnected() {
		t.Fatal("fresh client should not report connected")
	}
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd bridge && go test -run TestReconnectNoopWhenUnpaired ./...`
Expected: FAIL — `c.Reconnect undefined` / `c.IsConnected undefined` (compile error).

- [x] **Step 3: Write minimal implementation**

In `bridge/client.go`, add after the `Close()` method (around line 124):

```go
// Reconnect forces a clean socket cycle. Calls whatsmeow's
// Disconnect/Connect directly (NOT the bridge Connect wrapper) so the
// event handler + prekey loop registered on first Connect aren't
// duplicated — handlers live on the Client, not the socket, so they
// persist across cycles. Disconnect sets whatsmeow's expectedDisconnect
// flag so its own auto-reconnect goroutine won't race us.
func (c *Client) Reconnect() error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	if c.wa.Store.ID == nil {
		return nil // unpaired → QR/pair flow owns connect
	}
	c.wa.Disconnect()
	return c.wa.Connect()
}

// IsConnected reports whether the websocket is currently up. Note: after
// a macOS sleep the socket can be half-open and this returns a stale
// true — callers that must recover from sleep should force a reconnect
// rather than gating on this.
func (c *Client) IsConnected() bool {
	return c.wa != nil && c.wa.IsConnected()
}
```

`errors` is already imported in `client.go`. No new imports needed.

- [x] **Step 4: Run test to verify it passes**

Run: `cd bridge && go test -run TestReconnectNoopWhenUnpaired ./...`
Expected: PASS.

- [x] **Step 5: Verify whole bridge still builds + tests**

Run: `cd bridge && go build ./... && go test -short ./...`
Expected: build success; tests pass (network tests skipped under `-short`).

- [x] **Step 6: Commit**

```bash
git add bridge/client.go bridge/reconnect_test.go
git commit -m "bridge: add Reconnect() + IsConnected() for forced socket cycle"
```

---

## Task 2: Regenerate bridge framework + WAClient wrappers

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`

This task exposes the new bridge methods to Swift. It has no unit test (the calls block on gomobile and need a live socket); it is compile-checked and exercised manually in Task 7.

- [x] **Step 1: Rebuild the bridge xcframework so the new Go methods are visible to Swift**

Run: `cd /Users/vadikas/Work/yawac && ./scripts/build-xcframework.sh`
Expected: ends with `Built: build/Bridge.xcframework`.

- [x] **Step 2: Add the Swift wrappers**

In `yawac/Bridge/WAClient.swift`, add after the `sendPresence(available:)` method (near line 332):

```swift
    /// Forces a clean socket cycle on the Go side. nonisolated so the
    /// blocking gomobile call runs off the main actor.
    nonisolated func forceReconnect() {
        try? go.reconnect()
    }

    /// Current websocket state per whatsmeow. Stale-true after sleep —
    /// see bridge IsConnected doc. nonisolated for off-main calls.
    nonisolated var connected: Bool {
        go.isConnected()
    }
```

Note: gomobile maps Go `Reconnect()` → Swift `reconnect()` and `IsConnected()` → `isConnected()`. `go.reconnect()` is a throwing call (Go method returns `error`); `go.isConnected()` returns `Bool`.

- [x] **Step 3: Verify the app builds**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild -scheme yawac -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD '`
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 4: Commit**

```bash
git add yawac/Bridge/WAClient.swift build/Bridge.xcframework
git commit -m "WAClient: forceReconnect() + connected wrappers"
```

---

## Task 3: ConnectivityMonitor (core logic + tests)

**Files:**
- Create: `yawac/Services/ConnectivityMonitor.swift`
- Test: `yawacTests/ConnectivityMonitorTests.swift`

The monitor's OS wiring (`NWPathMonitor`, notification observers) lives in `start()`, which tests do not call. Tests drive `trigger(_:)` directly with injected closures, so the debounce/coalesce/gating logic is verified without real sleep or network.

- [x] **Step 1: Write the failing test**

Create `yawacTests/ConnectivityMonitorTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class ConnectivityMonitorTests: XCTestCase {

    /// Builds a monitor with a 10ms debounce and capturing closures.
    private func makeMonitor(connected: Bool, ready: Bool = true)
        -> (ConnectivityMonitor, () -> [Bool]) {
        var calls: [Bool] = []   // each element = the `force` flag passed
        let m = ConnectivityMonitor(
            debounce: .milliseconds(10),
            isReady: { ready },
            isConnected: { connected },
            reconnect: { force in calls.append(force) }
        )
        return (m, { calls })
    }

    func testWakeForcesReconnectEvenWhenConnected() async throws {
        let (m, calls) = makeMonitor(connected: true)
        m.trigger(.wake)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls(), [true], "wake must force reconnect even if connected")
    }

    func testNetworkSkipsWhenConnected() async throws {
        let (m, calls) = makeMonitor(connected: true)
        m.trigger(.network)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls(), [], "network change while connected must not reconnect")
    }

    func testNetworkReconnectsWhenDisconnected() async throws {
        let (m, calls) = makeMonitor(connected: false)
        m.trigger(.network)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls(), [false], "network change while down reconnects (non-forced)")
    }

    func testBurstCoalescesToOneReconnect() async throws {
        let (m, calls) = makeMonitor(connected: false)
        m.trigger(.network)
        m.trigger(.appActive)
        m.trigger(.wake)
        try await Task.sleep(for: .milliseconds(40))
        // Coalesced to a single call; wake in the window upgrades to force.
        XCTAssertEqual(calls(), [true])
    }

    func testNotReadySuppressesReconnect() async throws {
        let (m, calls) = makeMonitor(connected: false, ready: false)
        m.trigger(.wake)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls(), [], "must not reconnect while not ready (e.g. mid-pairing)")
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' -only-testing:yawacTests/ConnectivityMonitorTests 2>&1 | grep -E 'error:|Cannot find|FAIL|PASS|** TEST'`
Expected: FAIL — `Cannot find 'ConnectivityMonitor' in scope` (type doesn't exist yet).

- [x] **Step 3: Write minimal implementation**

Create `yawac/Services/ConnectivityMonitor.swift`:

```swift
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
    private let isReady: () -> Bool
    private let isConnected: () -> Bool
    private let reconnect: (_ force: Bool) -> Void

    private var pending: Task<Void, Never>?
    private var wakeInWindow = false

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "yawac.connectivity.path")
    private var sawFirstPath = false
    private var observers: [NSObjectProtocol] = []

    init(debounce: Duration = .seconds(2),
         isReady: @escaping () -> Bool,
         isConnected: @escaping () -> Bool,
         reconnect: @escaping (_ force: Bool) -> Void) {
        self.debounce = debounce
        self.isReady = isReady
        self.isConnected = isConnected
        self.reconnect = reconnect
    }

    /// Begins listening to OS signals. Idempotent-ish: call once after
    /// the client is created.
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
        pending?.cancel()
        pending = nil
        pathMonitor.cancel()
        let ws = NSWorkspace.shared.notificationCenter
        for o in observers { ws.removeObserver(o); NotificationCenter.default.removeObserver(o) }
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
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.fire()
        }
    }

    private func fire() {
        let force = wakeInWindow
        wakeInWindow = false
        guard isReady() else { return }
        if force || !isConnected() {
            reconnect(force)
        }
    }
}
```

- [x] **Step 4: Regenerate the Xcode project so the new file is in the target**

Run: `cd /Users/vadikas/Work/yawac && xcodegen generate`
Expected: `Created project at /Users/vadikas/Work/yawac/yawac.xcodeproj`.

- [x] **Step 5: Run test to verify it passes**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' -only-testing:yawacTests/ConnectivityMonitorTests 2>&1 | grep -E 'error:|FAIL|** TEST'`
Expected: `** TEST SUCCEEDED **`.

- [x] **Step 6: Commit**

```bash
git add yawac/Services/ConnectivityMonitor.swift yawacTests/ConnectivityMonitorTests.swift yawac.xcodeproj
git commit -m "ConnectivityMonitor: debounced reconnect on wake/network/active"
```

---

## Task 4: SessionViewModel connection sub-state + own the monitor

**Files:**
- Modify: `yawac/ViewModels/SessionViewModel.swift`
- Test: `yawacTests/SessionConnectionStateTests.swift`

The connection transitions are extracted into internal `markConnected()` / `markDisconnected()` methods (called from the existing `handle(_:)` cases) so they're directly testable via `@testable import`. The offline watchdog delay is an internal var so tests can shrink it.

- [x] **Step 1: Write the failing test**

Create `yawacTests/SessionConnectionStateTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class SessionConnectionStateTests: XCTestCase {

    func testStartsConnecting() {
        let s = SessionViewModel()
        XCTAssertEqual(s.connection, .connecting)
    }

    func testMarkConnectedGoesOnline() {
        let s = SessionViewModel()
        s.markDisconnected()
        s.markConnected()
        XCTAssertEqual(s.connection, .online)
    }

    func testMarkDisconnectedGoesConnecting() {
        let s = SessionViewModel()
        s.markConnected()
        s.markDisconnected()
        XCTAssertEqual(s.connection, .connecting)
    }

    func testWatchdogFlipsToOfflineWhenStillDown() async throws {
        let s = SessionViewModel()
        s.offlineDelay = .milliseconds(10)
        s.markDisconnected()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(s.connection, .offline)
    }

    func testReconnectBeforeWatchdogStaysOnline() async throws {
        let s = SessionViewModel()
        s.offlineDelay = .milliseconds(50)
        s.markDisconnected()
        s.markConnected()   // recovers before the watchdog fires
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(s.connection, .online)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' -only-testing:yawacTests/SessionConnectionStateTests 2>&1 | grep -E 'error:|Cannot find|** TEST'`
Expected: FAIL — `value of type 'SessionViewModel' has no member 'connection'`.

- [x] **Step 3: Add the connection sub-state + transitions**

In `yawac/ViewModels/SessionViewModel.swift`:

(a) Add the enum + properties near the other published state (after the `totalUnread` property, around line 27):

```swift
    enum Connection { case connecting, online, offline }
    /// Runtime socket health, independent of the pairing `state`.
    /// Drives the sync banner alongside `state`.
    private(set) var connection: Connection = .connecting
    /// How long after a disconnect we wait before declaring `.offline`
    /// (whatsmeow is auto-retrying during this window). Var so tests
    /// can shrink it.
    var offlineDelay: Duration = .seconds(8)
    private var offlineWatchdog: Task<Void, Never>?
```

(b) Add the transition methods (place them next to `armSyncWatchdog()`, around line 108):

```swift
    /// Socket came up (initial connect OR a whatsmeow auto/forced
    /// reconnect — Connected fires every time).
    func markConnected() {
        offlineWatchdog?.cancel()
        offlineWatchdog = nil
        connection = .online
    }

    /// Socket dropped. whatsmeow is already retrying with backoff, so we
    /// show `.connecting` and only escalate to `.offline` if it hasn't
    /// recovered within `offlineDelay`.
    func markDisconnected() {
        connection = .connecting
        offlineWatchdog?.cancel()
        offlineWatchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.offlineDelay)
            guard !Task.isCancelled else { return }
            if self.connection != .online { self.connection = .offline }
        }
    }
```

(c) Wire them into the existing `handle(_:)` cases. Change the `.connected` case (around line 166) to call `markConnected()` and the `.disconnected` case (around line 183) to call `markDisconnected()`:

```swift
        case .connected:
            qrCode = nil
            state = .ready
            markConnected()
            syncing = true
            armSyncWatchdog()
            try? client?.sendPresence(available: true)
```

```swift
        case .disconnected:
            markDisconnected()
```

(d) Also reset connection on logout. In `logout()` (around line 145), after `syncing = false`, add:

```swift
        offlineWatchdog?.cancel()
        offlineWatchdog = nil
        connection = .connecting
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' -only-testing:yawacTests/SessionConnectionStateTests 2>&1 | grep -E 'error:|** TEST'`
Expected: `** TEST SUCCEEDED **`.

- [x] **Step 5: Create + start the ConnectivityMonitor in boot()**

In `SessionViewModel.swift`, add a stored property near `offlineWatchdog`:

```swift
    private var connectivity: ConnectivityMonitor?
```

In `boot()` (around line 118, after `consumeEvents()`), add:

```swift
            let monitor = ConnectivityMonitor(
                isReady: { [weak self] in self?.state == .ready },
                isConnected: { [weak self] in self?.client?.connected ?? false },
                reconnect: { [weak self] _ in self?.client?.forceReconnect() })
            monitor.start()
            self.connectivity = monitor
```

In `logout()`, tear it down — after the `connection = .connecting` line added in Step 3(d):

```swift
        connectivity?.stop()
        connectivity = nil
```

- [x] **Step 6: Verify the app builds and the connection tests still pass**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' -only-testing:yawacTests/SessionConnectionStateTests -only-testing:yawacTests/ConnectivityMonitorTests 2>&1 | grep -E 'error:|** TEST'`
Expected: `** TEST SUCCEEDED **`.

- [x] **Step 7: Commit**

```bash
git add yawac/ViewModels/SessionViewModel.swift yawacTests/SessionConnectionStateTests.swift
git commit -m "session: connection sub-state + own ConnectivityMonitor"
```

---

## Task 5: Banner reflects connection state

**Files:**
- Modify: `yawac/Views/ConversationView.swift`

Manual/visual verification (the banner derivation is in a SwiftUI `View`, exercised in Task 7). No unit test.

- [x] **Step 1: Fold `connection` into `currentSyncState`**

In `yawac/Views/ConversationView.swift`, replace the body of `currentSyncState` (around lines 78-84) with:

```swift
    private var currentSyncState: SyncState {
        switch session.state {
        case .needsPair, .loading: return .connecting
        case .error: return .offline
        case .ready:
            switch session.connection {
            case .offline:    return .offline
            case .connecting: return .connecting
            case .online:     return session.syncing ? .syncing : .idle
            }
        }
    }
```

- [x] **Step 2: Verify the app builds**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild -scheme yawac -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD '`
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 3: Commit**

```bash
git add yawac/Views/ConversationView.swift
git commit -m "banner: reflect runtime connection state (connecting/offline)"
```

---

## Task 6: Resync pins/appstate on reconnect

**Files:**
- Modify: `yawac/ContentView.swift`

The server redelivers the offline message queue automatically once the socket is clean; this task adds the pin/appstate reconcile that `.historySync` alone may miss on a plain reconnect. Manual verification in Task 7.

- [x] **Step 1: Add a `.connected` case to ContentView's event loop**

In `yawac/ContentView.swift`, find the event `switch` (the one handling `.message`, `.historySync`, etc., around lines 80-130). Add a case alongside the others:

```swift
                case .connected:
                    // Reconnect (initial or auto/forced) — re-reconcile
                    // appstate-backed UI that may have changed while we
                    // were dark. The offline message queue is redelivered
                    // by the server as normal .message events.
                    vm.reconcilePinsWithStore()
```

Here `vm` is the `ChatListViewModel` already in scope in that loop (same `vm` that calls `vm.applyIncomingEdit(...)`). If a `case .connected` already exists in this switch, add the `vm.reconcilePinsWithStore()` line to it instead of creating a duplicate case.

- [x] **Step 2: Verify the app builds**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild -scheme yawac -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD '`
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 3: Commit**

```bash
git add yawac/ContentView.swift
git commit -m "resync: reconcile pins/appstate on every reconnect"
```

---

## Task 7: End-to-end manual verification

**Files:** none (verification only).

- [x] **Step 1: Full build + full test suite**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' 2>&1 | grep -E 'error:|** TEST|** BUILD'`
Expected: `** TEST SUCCEEDED **`.

- [x] **Step 2: Launch the app**

Run: `pkill -f 'yawac.app/Contents/MacOS/yawac' 2>/dev/null; sleep 1; open /Users/vadikas/Library/Developer/Xcode/DerivedData/yawac-*/Build/Products/Debug/yawac.app`
Expected: app launches, connects (banner settles to idle).

- [x] **Step 3: Sleep/wake test**

Close the laptop lid (or `pmset sleepnow`) for ~1 minute, then wake.
Expected: within ~2s of wake the banner shows `connecting` then returns to `idle`; new messages sent from the phone during sleep appear shortly after wake (no multi-minute stall).

- [x] **Step 4: Network-change test**

Toggle Wi-Fi off ~10s, then on.
Expected: banner reaches `offline` after ~8s while off; on Wi-Fi return it reconnects (`connecting` → `idle`) without waiting on whatsmeow's backoff.

- [x] **Step 5: Missed-message + pin resync test**

With the app connected, on the phone: send a message AND pin a chat. Sleep the laptop ~30s, wake.
Expected: the message arrives and the chat shows pinned in the sidebar shortly after wake (reconcile-on-reconnect).

- [x] **Step 6: Final commit (if any verification tweaks were needed)**

Only if Steps 3–5 surfaced a fix. Otherwise nothing to commit — the feature is complete.

---

## Self-Review Notes

- **Spec coverage:** Bridge `Reconnect`/`IsConnected` (Task 1) ✓; Swift wrappers (Task 2) ✓; `ConnectivityMonitor` with wake-unconditional / network+active-gated / debounce / startup-path-ignore / ready-gate (Task 3) ✓; `Connection` sub-state + watchdog + monitor ownership (Task 4) ✓; banner wiring (Task 5) ✓; resync-on-reconnect (Task 6) ✓; manual edges incl. half-open-after-sleep, offline-after-8s, unpaired no-op (Tasks 1, 7) ✓.
- **Type consistency:** `ConnectivityMonitor(debounce:isReady:isConnected:reconnect:)`, `.trigger(_:)`, `Reason{.wake,.network,.appActive}`, `start()`/`stop()`; `SessionViewModel.markConnected()`/`markDisconnected()`/`connection`/`offlineDelay`; `WAClient.forceReconnect()`/`connected`; bridge `Reconnect()`/`IsConnected()` → Swift `reconnect()`/`isConnected()`. Names match across tasks.
- **Placeholders:** none — every code step shows full code; commands have expected output.
