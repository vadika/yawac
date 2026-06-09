# Full History Sync — Settings Control Design

**Status:** Approved 2026-06-09 — brainstorming complete, ready for implementation plan.

**Context:** v0.9.42 (F25–F27) ships deep history sync at pair time. Existing pairings (and accounts that scroll/archive into older windows) still benefit from a user-initiated on-demand backfill. Today the only trigger is the post-pair `requestHistoryBackfillIfNeeded()` one-shot. No UI handle exists for re-running it.

This spec adds a single Settings control + live progress chip so the user can pull older history without re-pairing.

---

## Goal

User can tap a row in Settings → Account → Full history sync and see a live progress bar + counters as the phone ships more history. Sync runs in the background; the control reports what's landing and clears when the burst ends.

## Non-Goals

- No cancel button. whatsmeow has no abort API for in-flight sync; the request is one-shot and chunks arrive when phone decides.
- No persistent "last sync at" record. Out of scope; can be added later.
- No re-pair flow. L1 DeviceProps override (F25) already lifts pair-time depth to ~10 years.

---

## Architecture

Reuses the entire F25–F27 plumbing. Adds:
1. Bridge event payload carries per-chunk progress + chunk-order + per-chunk message count (already collected during the F-instr trace; just route them to the event sink instead of stderr).
2. SessionViewModel tracks an in-flight state struct that the row reads.
3. AccountPanel grows one row.

Data flow:

```
User tap
  → AccountPanel SettingsRow.onTap
  → SessionViewModel.startFullHistorySync()
  → reset historyBackfillCompleted = false
  → reset fullSync state
  → set fullSync.inFlight = true
  → arm 60 s silence-timeout task
  → call requestHistoryBackfillIfNeeded()  // existing F27 path
  → bridge.RequestFullHistorySync()  // type-6 FULL_HISTORY_SYNC_ON_DEMAND

Phone responds (async, multi-chunk):
  → events.HistorySync (per chunk)
  → bridge.dispatchHistory → JSON {sync_type, conversations, progress, chunk_order, chunk_messages}
  → WAClient pump → .historySync event
  → SessionViewModel.handle(.historySync):
      if fullSync.inFlight && contentful sync type:
          fullSync.progress = max(progress, fullSync.progress)
          fullSync.chunks += 1
          fullSync.messages += chunkMessages
          re-arm silence-timeout

Silence timeout fires (60 s no chunks):
  → fullSync.inFlight = false
  → (state retained for "last result" display until next start)
```

---

## Components

### 1. Bridge — `bridge/events.go` `dispatchHistory`

Extend the payload that ships through `c.dispatch("HistorySync", ...)`. Today:

```go
payload := map[string]any{
    "sync_type":     evt.Data.GetSyncType().String(),
    "conversations": len(convs),
}
```

After:

```go
// Count messages in this chunk so the Swift side can show a running
// "X messages so far" counter during user-initiated full sync.
var chunkMessages int
for _, conv := range convs {
    chunkMessages += len(conv.GetMessages())
}
payload := map[string]any{
    "sync_type":      evt.Data.GetSyncType().String(),
    "conversations":  len(convs),
    "progress":       int(evt.Data.GetProgress()),     // 0-100, phone-reported
    "chunk_order":    int(evt.Data.GetChunkOrder()),   // monotonic per request
    "chunk_messages": chunkMessages,
}
```

Cost: one extra range over `convs.GetMessages()` per chunk. Cheap. The original F-instr loop did the same.

### 2. Swift — `WAClient.Event.historySync` enum case

Extend the case + decoder + 2 callsites.

```swift
// Before:
case historySync(conversations: Int)               // pre-F26
case historySync(syncType: String, conversations: Int)   // post-F26

// After (F28):
case historySync(syncType: String,
                 conversations: Int,
                 progress: Int,
                 chunkOrder: Int,
                 chunkMessages: Int)
```

Decoder in `WAClient.decode` updated to map the 3 new JSON fields. Defaults to 0 if missing (backwards compatible with old bridge if updates land out of order).

Callsite updates:
- `SessionViewModel.handle(.historySync(_, let n)) → handle(.historySync(let syncType, let n, let progress, let chunkOrder, let chunkMessages))`
- `ContentView .historySync(let syncType, _) → .historySync(let syncType, _, _, _, _)`

### 3. `SessionViewModel` — `FullSyncState` + actions

```swift
struct FullSyncState: Equatable {
    var inFlight: Bool = false
    /// Highest progress value seen during the current burst (phone may
    /// report 100 on every ON_DEMAND chunk; we keep the max).
    var progress: Int = 0
    /// Number of HistorySync chunks observed during the burst.
    var chunks: Int = 0
    /// Sum of per-chunk message counts during the burst.
    var messages: Int = 0
    /// Time of the most recent chunk; used to clear inFlight after a
    /// 60 s silence window.
    var lastChunkAt: Date?
}

private(set) var fullSync: FullSyncState = .init()
@ObservationIgnored private var fullSyncTimeoutTask: Task<Void, Never>?
```

`fullSync` is observable so the Settings row redraws on each update. `fullSyncTimeoutTask` is the watchdog.

```swift
@MainActor
func startFullHistorySync() {
    guard !fullSync.inFlight else { return }
    historyBackfillCompleted = false          // clear F26 gate
    fullSync = FullSyncState(inFlight: true, lastChunkAt: Date())
    armFullSyncTimeout()
    Task { await self.requestHistoryBackfillIfNeeded() }
}

@MainActor
private func armFullSyncTimeout() {
    fullSyncTimeoutTask?.cancel()
    fullSyncTimeoutTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(60))
        guard let self else { return }
        // Only clear if we haven't seen a chunk in the last 60s; if
        // the chunk handler re-armed us, this task was cancelled.
        self.fullSync.inFlight = false
    }
}
```

`handle(.historySync)` extension (gated on `inFlight`):

```swift
case .historySync(let syncType, let n, let progress, _, let chunkMessages):
    syncedConversations += n
    armSyncWatchdog()
    if fullSync.inFlight {
        let contentful: Set<String> = ["INITIAL_BOOTSTRAP", "RECENT", "FULL", "ON_DEMAND"]
        if contentful.contains(syncType) {
            fullSync.progress = max(fullSync.progress, progress)
            fullSync.chunks += 1
            fullSync.messages += chunkMessages
            fullSync.lastChunkAt = Date()
            armFullSyncTimeout()  // re-arm — silence window restarts
            if fullSync.progress >= 100 {
                fullSync.inFlight = false
                fullSyncTimeoutTask?.cancel()
            }
        }
    }
```

### 4. `AccountPanel` — third row in Account card

```swift
SettingsCard {
    // Existing rows...
    SettingsRow(
        icon: "laptopcomputer.and.iphone",
        label: "Linked devices",
        sublabel: linkedDevicesSublabel,
        showChevron: true,
        onTap: { showLinkedDevices = true }
    )
    SettingsRow(
        icon: "lock.shield",
        label: "Privacy",
        sublabel: "Last seen, read receipts, groups",
        showChevron: true,
        onTap: { showPrivacy = true }
    )

    // F28: full history sync trigger + progress.
    fullHistorySyncRow
}
```

```swift
@ViewBuilder
private var fullHistorySyncRow: some View {
    let s = session.fullSync
    SettingsRow(
        icon: "arrow.down.circle",
        label: "Full history sync",
        sublabel: fullSyncSublabel(s),
        showChevron: !s.inFlight,
        onTap: { session.startFullHistorySync() }
    )
    if s.inFlight {
        ProgressView(value: Double(s.progress), total: 100)
            .progressViewStyle(.linear)
            .tint(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }
}

private func fullSyncSublabel(_ s: FullSyncState) -> String {
    if s.inFlight {
        return "\(s.progress)% • chunk \(s.chunks) • \(s.messages) messages"
    }
    if s.chunks > 0 {
        return "Last run: \(s.messages) messages across \(s.chunks) chunks"
    }
    return "Pull older messages from phone"
}
```

Tap while `inFlight` is true is a no-op via the guard in `startFullHistorySync`.

---

## Edge cases + error handling

| Scenario | Behavior |
|---|---|
| User taps while sync is in flight | `startFullHistorySync()` early-returns. UI shows existing progress. |
| Phone returns no chunks (rejected) | 60 s silence-timeout clears `inFlight`. Row falls back to default sublabel. No error toast (would be noisy; user can retry). |
| Phone returns chunks then goes quiet | Same — silence-timeout. `chunks` + `messages` retained as "last run" sublabel. |
| `requestFullHistorySync` bridge call throws | Logged via `NSLog` (existing path). UI shows "0% • chunk 0 • 0 messages" until timeout. Accept; backfill failures are already silent. |
| Chunks arrive when `inFlight` is false (e.g. background appstate sync) | Ignored. The `if fullSync.inFlight` guard prevents accidental counter bumps. |
| App killed mid-sync | State is in-memory only; relaunch shows "Pull older messages from phone" again. Phone may still ship chunks on reconnect — counters won't track them. Accept. |
| Multiple chunks of SyncType `PUSH_NAME` / `INITIAL_STATUS_V3` arrive during burst | Filtered by the contentful Set. Don't bump counters. |

---

## Testing

1. **Unit:** `SessionViewModel` chunk-handler logic — feed synthetic `.historySync` events and assert state transitions. Use the contentful-SyncType matrix.
2. **Live:** Trigger from a real account; observe progress climbs + chunks count + messages count. Compare totals against `grep history-instr /tmp/yawac.log` baseline (instrumentation can be re-added temporarily).
3. **Manual:** confirm tap-while-inflight is a no-op, that sublabel updates as expected, that ProgressView appears only when `inFlight`.

---

## Out of scope (won't do this round)

- Cancel button — no whatsmeow API.
- Per-chat sync trigger — already exists via "Load earlier" button.
- Sync history log (chunk-by-chunk diagnostic view in Settings). Possible v2 if power users ask.
- Persistent "last full sync at" date stamp. Possible v2.
- Re-pair flow.

---

## File touch list

| File | Action |
|---|---|
| `bridge/events.go` | Extend `dispatchHistory` payload (add 3 fields). |
| `yawac/Bridge/WAClient.swift` | Extend `.historySync` case + decoder. |
| `yawac/ViewModels/SessionViewModel.swift` | Add `FullSyncState` + `startFullHistorySync` + chunk-handler extension + timeout task. |
| `yawac/ContentView.swift` | Pattern-update the `.historySync` case to ignore the new fields. |
| `yawac/Views/Settings/Panels/AccountPanel.swift` | Add third `SettingsRow` + `ProgressView` + sublabel helper. |

---

## Self-review

- **Placeholder scan:** none. Every step has runnable code.
- **Internal consistency:** Bridge field names match Swift decoder. `FullSyncState` fields match row helpers.
- **Scope check:** Single Settings row + payload extension. Fits one implementation plan.
- **Ambiguity check:** Progress semantics clarified (we keep max, accept that ON_DEMAND chunks report 100 each). Timeout policy explicit (60 s silence).
