# Connectivity state, resync after sleep/disconnect — design

**Date:** 2026-05-28
**Status:** Approved (pending implementation plan)

## Problem

Three observed symptoms after the laptop sleeps or the network drops:

1. **Stale after sleep/wake** — messages stop flowing for a while after waking.
2. **No UI feedback when offline** — the app gives no clear signal whether it's
   connected, reconnecting, or dead.
3. **Missed messages after reconnect** — messages/state that changed while
   offline don't appear until something forces a resync.

The app does *eventually* recover (the user did not report "needs restart"), so
reconnection is functioning — it's just slow, silent, and incomplete.

## What already exists (and why this isn't a from-scratch retry scheme)

whatsmeow already handles the hard parts:

- **Auto-reconnect** is on by default (`NewClient` sets `EnableAutoReconnect: true`).
  On an unexpected disconnect it retries with backoff `AutoReconnectErrors × 2s`
  and re-fires `events.Connected` on success.
- **Keepalive** ping loop runs every 20–30s with a 10s response deadline, and
  forces a reconnect after `KeepAliveMaxFailTime = 3 min` of failed pings.
- On reconnect it **refetches appstate** incrementally and the server
  **redelivers the offline message queue**.

The gaps are in yawac, not whatsmeow:

- The `.disconnected` event handler is a no-op (`break`), so the UI never
  reflects a disconnect/reconnect window. The `offline` banner state only shows
  on `.error` (a pairing/boot failure), never on a runtime drop.
- No sleep/wake handling. After macOS wake the socket is often **half-open**:
  whatsmeow still thinks it's connected (`IsConnected()` returns true), so it
  doesn't reconnect until keepalive finally fails — up to ~3 min later. During
  that window the server believes we're online and may not queue messages,
  which is the root of both symptom #1 and #3.
- No network-path monitoring, so a Wi-Fi/VPN change waits on backoff rather than
  reconnecting promptly.
- `reconcilePinsWithStore()` (pin/appstate reconcile) runs only on
  `.historySync`, which may not fire on a plain reconnect.

## Approach

Swift-side **ConnectivityMonitor** that accelerates recovery on three OS signals,
plus accurate connection state surfaced in the banner, plus a resync hook on
reconnect. We lean on whatsmeow's existing keepalive/backoff — we only
*accelerate* recovery and *surface* state. No continuous polling.

Rejected alternatives:
- **Continuous health-check polling** (timer every ~5s): duplicates whatsmeow's
  keepalive and burns a wakeup every 5s; the half-open case is already covered
  by forcing reconnect on wake.
- **Go-side monitoring**: sleep/wake and network-path signals are AppKit /
  Network.framework events that Go can't observe, so the monitor must be Swift.

## Components

### 1. Bridge: `Reconnect()` + `IsConnected()` (`bridge/client.go`)

```go
// Reconnect forces a clean socket cycle. Calls whatsmeow's
// Disconnect/Connect directly (NOT the bridge Connect wrapper) so the
// event handler + prekey loop registered on first Connect aren't
// duplicated. Disconnect sets whatsmeow's expectedDisconnect flag so
// its own auto-reconnect goroutine won't race us.
func (c *Client) Reconnect() error {
    if c.wa == nil { return errors.New("client closed") }
    if c.wa.Store.ID == nil { return nil }   // unpaired → QR flow owns connect
    c.wa.Disconnect()
    return c.wa.Connect()
}

func (c *Client) IsConnected() bool {
    return c.wa != nil && c.wa.IsConnected()
}
```

Critical: the bridge's existing `Connect()` wrapper re-runs `AddEventHandler`
every call. Reconnecting through it would double-register the handler and
duplicate every event. `Reconnect()` therefore uses whatsmeow's own
`Disconnect()`/`Connect()` — handlers are registered on the `Client`, not the
socket, so they persist across cycles. The prekey top-up loop and QR pump
started on first `Connect()` are likewise left untouched.

### 2. `WAClient` bridge surface (`yawac/Bridge/WAClient.swift`)

- `nonisolated func forceReconnect()` — wraps `go.reconnect()`, runs off-main
  (gomobile calls block).
- `nonisolated var connected: Bool` — wraps `go.isConnected()`.

### 3. `ConnectivityMonitor` (new — `yawac/Services/ConnectivityMonitor.swift`)

- Owns an `NWPathMonitor` (background queue) + `NotificationCenter` observers for
  `NSWorkspace.didWakeNotification` and `NSApplication.didBecomeActiveNotification`.
- Each signal calls `trigger(reason:)`. A single debounce `Task` (~2s) coalesces
  bursts (wake + network + active commonly fire together) into one reconnect.
- Decision at debounce fire:
  - **Wake** in the window → reconnect **unconditionally** (post-sleep socket is
    half-open; `connected` returns a stale `true`).
  - **Network / active** only → reconnect **only if** `!client.connected`.
- `NWPathMonitor` fires once at startup with the current path — the monitor
  ignores that first callback so a healthy boot connection isn't churned.
- Gated on `state == .ready`: never forces a reconnect mid-pairing (QR on screen)
  or before boot.

### 4. `SessionViewModel` connection sub-state

```swift
enum Connection { case connecting, online, offline }
private(set) var connection: Connection = .connecting
private var offlineWatchdog: Task<Void, Never>?
```

- `.connected` → `connection = .online`; cancel watchdog. (Fires on every
  whatsmeow reconnect, not just the first.)
- `.disconnected` → `connection = .connecting`; arm an ~8s watchdog → if still
  not online, `connection = .offline`. (Replaces today's no-op `break`.)
- Owns the `ConnectivityMonitor`, created in `boot()` after the client and torn
  down in `logout()`.

### 5. Banner wiring (`ConversationView.currentSyncState`)

Fold `connection` in ahead of the existing pairing-derived logic:

- `connection == .offline` → `.offline`
- `connection == .connecting` && `state == .ready` → `.connecting`
- else → existing syncing / idle logic.

A sleep→wake cycle reads `connecting` → brief `syncing` → `idle`. A real outage
that doesn't recover settles on `offline` after ~8s.

### 6. Resync on reconnect

Run `chatList?.reconcilePinsWithStore()` on `.connected` (in addition to the
current `.historySync` site). The server redelivers the offline message queue
automatically once the socket is clean — that fixes "missed messages." The pin /
appstate reconcile covers state that changed while we were dark.

## Data flow

```
NSWorkspace.didWake ─┐
NWPathMonitor change ─┼─► ConnectivityMonitor.trigger(reason)
NSApp.didBecomeActive ┘            │ (debounce ~2s, coalesce)
                                   ▼
                         wake? → always reconnect
                         else → reconnect if !connected
                                   │
                                   ▼
                       WAClient.forceReconnect() (off-main)
                                   │
                                   ▼
                       bridge Reconnect(): wa.Disconnect(); wa.Connect()
                                   │
                          events.Connected ──► SessionViewModel.handle
                                   │                 │
                                   │                 ├─ connection = .online
                                   │                 ├─ syncing = true (existing)
                                   │                 └─ reconcilePinsWithStore()
                                   ▼
                          server redelivers offline queue → .message events
```

Disconnect path:

```
events.Disconnected ──► SessionViewModel.handle
                          ├─ connection = .connecting
                          └─ arm 8s watchdog ──► connection = .offline (if still down)
```

## Edge cases

- **Unpaired:** `Reconnect()` no-ops on `Store.ID == nil`; the monitor also gates
  on `state == .ready`.
- **Reconnect throws:** whatsmeow's own backoff remains the fallback; we log,
  stay `.connecting`, watchdog flips to `.offline`.
- **Trigger burst:** debounced to a single reconnect.
- **Mid-pairing:** no forced reconnect while the QR code is on screen.
- **Healthy boot:** first `NWPathMonitor` callback ignored; network/active
  triggers gate on `!connected`, so a working connection is never churned.

## Testing

- **Manual:** sleep ~1 min → wake → messages flow within ~2s; banner
  `connecting` → `idle`. Toggle Wi-Fi off/on → reconnect. Pull ethernet 10s+ →
  banner reaches `offline`, recovers on replug.
- **Unit:** `ConnectivityMonitor` coalesces N triggers into one reconnect call
  (inject a fake reconnect closure + call `trigger` manually — no real sleep).
  Bridge `Reconnect()` returns nil without connecting when `Store.ID == nil`.

## Out of scope

- Manual "Reconnect" button (whatsmeow + the three triggers cover recovery).
- Continuous health-check polling.
- Reworking whatsmeow's backoff or keepalive constants.
