# Full History Sync Settings Control (F28) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings → Account → Full history sync row that triggers the F27 deep-history backfill on demand and shows live progress until the phone goes quiet.

**Architecture:** Reuse the existing F27 plumbing (`bridge.RequestFullHistorySync` → type-6 `FULL_HISTORY_SYNC_ON_DEMAND`). Extend the bridge HistorySync event payload with per-chunk progress + counters; route into a new `FullSyncState` struct on `SessionViewModel`. AccountPanel reads the struct and shows a linear `ProgressView` + chunk + message count under the row while `inFlight`. Auto-clears after 60 s of chunk silence.

**Tech Stack:** Go (whatsmeow bridge), Swift / SwiftUI (`@Observable`, `@MainActor`, `ProgressView`), JSON (bridge ↔ Swift event payload).

**Source:** Spec at `docs/superpowers/specs/2026-06-09-full-history-sync-control-design.md`. Backstory in `memory/project_yawac_history_sync_depth.md`.

**Out of scope:** Cancel button, persistent "last sync at" record, per-chat trigger, re-pair flow. See spec § Non-Goals.

---

## File Structure Overview

| Task | File | Action |
|------|------|--------|
| 1 | `bridge/events.go` | Extend `dispatchHistory` payload (3 fields). |
| 2 | `yawac/Bridge/WAClient.swift` | Extend `.historySync` enum case + decoder. |
| 3 | `yawac/ContentView.swift`, `yawac/ViewModels/SessionViewModel.swift` | Pattern-update existing `.historySync` matches. |
| 4 | `yawac/ViewModels/SessionViewModel.swift` | Add `FullSyncState`, `startFullHistorySync`, chunk-handler extension, silence-timeout. |
| 5 | `yawac/Views/Settings/Panels/AccountPanel.swift` | Add third row + ProgressView + sublabel helper. |
| 6 | `project.yml`, `docs/ROADMAP.md`, `yawac/Info.plist` | Release v0.9.43 bump + Shipped entry. |

---

## Sequencing

```
T1 (bridge payload) → T2 (Swift event case) → T3 (callsite patterns)
                                    └──→ T4 (SessionViewModel state) → T5 (AccountPanel UI) → T6 (release)
```

T2 depends on T1 because the JSON keys must match. T3 must follow T2 (build won't pass without pattern updates). T4 + T5 + T6 are sequential after.

---

## Verification Strategy

Per task: build the Go bridge (`./scripts/build-xcframework.sh`) when the bridge changed, then `xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build`. The codebase does not ship Swift unit tests for ViewModels; rely on `go test ./...` for bridge changes and a final live smoke for the Settings row.

Final smoke: launch yawac, open Settings → Account, tap "Full history sync", confirm progress bar appears and counters tick as chunks land. Confirm row returns to idle sublabel after 60 s of silence.

---

## Task 1: Bridge payload extension

**Files:**
- Modify: `bridge/events.go` (the `dispatchHistory` func at line ~174)

The payload that Go ships to Swift through `c.dispatch("HistorySync", payload)` currently carries only `sync_type` + `conversations`. Settings UI needs progress + chunk order + per-chunk message count.

- [ ] **Step 1: Read existing dispatchHistory**

  ```bash
  grep -nA 12 "func (c \*Client) dispatchHistory" bridge/events.go
  ```

  Expected: shows the 10-line function. Note its location for the edit.

- [ ] **Step 2: Replace dispatchHistory with extended payload**

  Edit `bridge/events.go`. Replace:

  ```go
  func (c *Client) dispatchHistory(evt *events.HistorySync) {
  	c.applyHistorySync(evt)
  	convs := evt.Data.GetConversations()
  	payload := map[string]any{
  		"sync_type":     evt.Data.GetSyncType().String(),
  		"conversations": len(convs),
  	}
  	b, _ := json.Marshal(payload)
  	c.dispatch("HistorySync", string(b))
  }
  ```

  With:

  ```go
  func (c *Client) dispatchHistory(evt *events.HistorySync) {
  	c.applyHistorySync(evt)
  	convs := evt.Data.GetConversations()
  	// Count messages inside this chunk so the Swift Settings panel can
  	// show a running "X messages so far" counter during user-initiated
  	// full sync (F28). Same loop the F-instr trace used; cost is one
  	// extra range per chunk, negligible.
  	var chunkMessages int
  	for _, conv := range convs {
  		chunkMessages += len(conv.GetMessages())
  	}
  	payload := map[string]any{
  		"sync_type":      evt.Data.GetSyncType().String(),
  		"conversations":  len(convs),
  		"progress":       int(evt.Data.GetProgress()),
  		"chunk_order":    int(evt.Data.GetChunkOrder()),
  		"chunk_messages": chunkMessages,
  	}
  	b, _ := json.Marshal(payload)
  	c.dispatch("HistorySync", string(b))
  }
  ```

- [ ] **Step 3: Build the bridge**

  ```bash
  go test ./bridge/...
  ```

  Expected: `Go test: 172 passed in 1 packages` (or whatever the current count is — no new failures).

- [ ] **Step 4: Commit**

  ```bash
  git add bridge/events.go
  git commit -m "feat(bridge): ship HistorySync progress + chunk order to Swift (F28)

  dispatchHistory now includes progress (0-100), chunk_order, and
  chunk_messages (per-chunk message count) alongside the existing
  sync_type + conversations fields. Powers the F28 Settings
  control's live progress bar.

  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
  ```

---

## Task 2: Swift event case + decoder

**Files:**
- Modify: `yawac/Bridge/WAClient.swift:43` (the `historySync` enum case)
- Modify: `yawac/Bridge/WAClient.swift:1005-1018` (the `"HistorySync"` decoder branch)

- [ ] **Step 1: Replace the enum case**

  In `yawac/Bridge/WAClient.swift` line 43, replace:

  ```swift
  case historySync(syncType: String, conversations: Int)
  ```

  With:

  ```swift
  case historySync(syncType: String,
                   conversations: Int,
                   progress: Int,
                   chunkOrder: Int,
                   chunkMessages: Int)
  ```

- [ ] **Step 2: Replace the decoder branch**

  In the same file (around line 1005), replace:

  ```swift
  case "HistorySync":
      struct H: Codable {
          let conversations: Int
          let syncType: String?
          enum CodingKeys: String, CodingKey {
              case conversations
              case syncType = "sync_type"
          }
      }
      if let h = try? dec.decode(H.self, from: data) {
          return .historySync(syncType: h.syncType ?? "",
                              conversations: h.conversations)
      }
  ```

  With:

  ```swift
  case "HistorySync":
      struct H: Codable {
          let conversations: Int
          let syncType: String?
          let progress: Int?
          let chunkOrder: Int?
          let chunkMessages: Int?
          enum CodingKeys: String, CodingKey {
              case conversations
              case syncType = "sync_type"
              case progress
              case chunkOrder = "chunk_order"
              case chunkMessages = "chunk_messages"
          }
      }
      if let h = try? dec.decode(H.self, from: data) {
          return .historySync(syncType: h.syncType ?? "",
                              conversations: h.conversations,
                              progress: h.progress ?? 0,
                              chunkOrder: h.chunkOrder ?? 0,
                              chunkMessages: h.chunkMessages ?? 0)
      }
  ```

  All three new fields are optional in the decoder so the Swift side keeps decoding correctly if an older bridge build lands ahead of the matching update.

- [ ] **Step 3: Do NOT build yet — callsites are still broken**

  The two callsites (Task 3) must pattern-match the old shape. Building here yields exhaustiveness errors. Continue to Task 3 before building.

---

## Task 3: Pattern-update callsites

**Files:**
- Modify: `yawac/ViewModels/SessionViewModel.swift:594-596`
- Modify: `yawac/ContentView.swift:190` (the `.historySync(let syncType, _)` arm extended in F26)

- [ ] **Step 1: Update SessionViewModel pattern**

  In `yawac/ViewModels/SessionViewModel.swift` around line 594:

  Before:

  ```swift
  case .historySync(_, let n):
      syncedConversations += n
      armSyncWatchdog()
  ```

  After (just widen the pattern; Task 4 will replace the body):

  ```swift
  case .historySync(_, let n, _, _, _):
      syncedConversations += n
      armSyncWatchdog()
  ```

- [ ] **Step 2: Update ContentView pattern**

  In `yawac/ContentView.swift` around line 190:

  Before:

  ```swift
  case .historySync(let syncType, _):
  ```

  After:

  ```swift
  case .historySync(let syncType, _, _, _, _):
  ```

  No body change here — ContentView already only cares about `syncType`.

- [ ] **Step 3: Regenerate xcframework + build**

  ```bash
  ./scripts/build-xcframework.sh
  xcodegen generate
  xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "^(\*\* BUILD|error:)" | head -3
  ```

  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit T1–T3 together**

  ```bash
  git add bridge/events.go yawac/Bridge/WAClient.swift yawac/ViewModels/SessionViewModel.swift yawac/ContentView.swift
  git commit -m "feat(history): extend HistorySync event with progress + chunk fields (F28)

  - Bridge dispatchHistory ships progress (0-100), chunk_order,
    and chunk_messages on every HistorySync event.
  - Swift Event.historySync case carries the new fields; existing
    callsites pattern-widened (no behavior change yet).

  Wiring for the upcoming Settings → Account → Full history sync
  row + progress bar.

  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
  ```

  (If T1 was committed separately in Task 1, only stage the Swift files here. Adjust accordingly.)

---

## Task 4: SessionViewModel `FullSyncState` + actions

**Files:**
- Modify: `yawac/ViewModels/SessionViewModel.swift`

Add a struct, an observable property, a starter method, a silence-timeout task, and extend the `.historySync` handler.

- [ ] **Step 1: Add the FullSyncState struct + observable property**

  Place near the existing `historyBackfillCompleted` property (around line 35 — the F26 region). Insert:

  ```swift
  /// User-triggered full history sync progress state. Read by the
  /// AccountPanel "Full history sync" row to render a linear
  /// ProgressView + counters while a backfill burst is in flight.
  /// F28.
  struct FullSyncState: Equatable {
      var inFlight: Bool = false
      /// Highest progress value seen during the current burst (phone may
      /// report 100 on every ON_DEMAND chunk; we keep the max).
      var progress: Int = 0
      /// Number of contentful HistorySync chunks observed during the burst.
      var chunks: Int = 0
      /// Sum of per-chunk message counts during the burst.
      var messages: Int = 0
  }

  /// Observable so the Settings row redraws on each chunk.
  private(set) var fullSync: FullSyncState = .init()
  /// Watchdog cleared 60s after the last chunk arrives.
  @ObservationIgnored private var fullSyncTimeoutTask: Task<Void, Never>?
  ```

- [ ] **Step 2: Add startFullHistorySync + arm helper**

  Place near the existing `requestHistoryBackfillIfNeeded` (around line 652 — the F27 region):

  ```swift
  /// User-triggered full history sync. Clears the F26 one-shot gate,
  /// resets counters, and fires the existing FULL_HISTORY_SYNC_ON_DEMAND
  /// path. The 60s silence-timeout (armed on every chunk) clears
  /// inFlight if the phone goes quiet.
  /// F28.
  @MainActor
  func startFullHistorySync() {
      guard !fullSync.inFlight else { return }
      historyBackfillCompleted = false
      fullSync = FullSyncState(inFlight: true)
      armFullSyncTimeout()
      Task { await self.requestHistoryBackfillIfNeeded() }
  }

  @MainActor
  private func armFullSyncTimeout() {
      fullSyncTimeoutTask?.cancel()
      fullSyncTimeoutTask = Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(60))
          guard let self else { return }
          // If a chunk arrived in the last 60s it would have cancelled
          // this task and re-armed a fresh one. Reaching here means
          // silence; clear inFlight so the row falls back to idle.
          self.fullSync.inFlight = false
      }
  }
  ```

- [ ] **Step 3: Extend the .historySync handler**

  Replace the existing `case .historySync(_, let n, _, _, _):` block from Task 3 with:

  ```swift
  case .historySync(let syncType, let n, let progress, _, let chunkMessages):
      syncedConversations += n
      armSyncWatchdog()
      if fullSync.inFlight {
          // Only count chunks that actually carry conversation messages.
          // PUSH_NAME / INITIAL_STATUS_V3 / NON_BLOCKING_DATA arrive
          // alongside but shouldn't bump the counters. Same gate F26
          // uses for the one-shot UserDefaults flag.
          let contentful: Set<String> = [
              "INITIAL_BOOTSTRAP", "RECENT", "FULL", "ON_DEMAND",
          ]
          if contentful.contains(syncType) {
              fullSync.progress = max(fullSync.progress, progress)
              fullSync.chunks += 1
              fullSync.messages += chunkMessages
              armFullSyncTimeout()  // re-arm silence window
              if fullSync.progress >= 100 {
                  fullSync.inFlight = false
                  fullSyncTimeoutTask?.cancel()
              }
          }
      }
  ```

- [ ] **Step 4: Build**

  ```bash
  xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "^(\*\* BUILD|error:)" | head -3
  ```

  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

  ```bash
  git add yawac/ViewModels/SessionViewModel.swift
  git commit -m "feat(session): FullSyncState + startFullHistorySync (F28)

  Observable FullSyncState struct tracks inFlight + progress +
  chunks + messages during a user-triggered backfill. The
  .historySync handler updates state when inFlight and re-arms a
  60s silence-timeout on every contentful chunk.

  startFullHistorySync clears the F26 one-shot gate and routes
  to the existing requestHistoryBackfillIfNeeded path.

  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
  ```

---

## Task 5: AccountPanel row + ProgressView

**Files:**
- Modify: `yawac/Views/Settings/Panels/AccountPanel.swift` (the `accountCard` computed property around line 101)

Add a third `SettingsRow` and an inline `ProgressView` that appears when `inFlight`.

- [ ] **Step 1: Locate accountCard**

  Open `yawac/Views/Settings/Panels/AccountPanel.swift` and confirm `accountCard` lives around line 101. The card body is a `SettingsCard { ... }` containing two `SettingsRow` instances (Linked devices + Privacy).

- [ ] **Step 2: Add the third row + ProgressView**

  Replace `accountCard` with:

  ```swift
  private var accountCard: some View {
      VStack(alignment: .leading, spacing: 10) {
          SettingsSectionLabel("Account")
          SettingsCard {
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
              fullHistorySyncRow
          }
      }
  }

  // MARK: - Full history sync (F28)

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

  private func fullSyncSublabel(_ s: SessionViewModel.FullSyncState) -> String {
      if s.inFlight {
          return "\(s.progress)% • chunk \(s.chunks) • \(s.messages) messages"
      }
      if s.chunks > 0 {
          return "Last run: \(s.messages) messages across \(s.chunks) chunks"
      }
      return "Pull older messages from phone"
  }
  ```

- [ ] **Step 3: Confirm `session` is in scope**

  Check the top of `AccountPanel` for the `@Environment(SessionViewModel.self) private var session` declaration. AccountPanel already reads session for other operations; the binding should already be present. If not, add it under existing `@Environment` declarations.

- [ ] **Step 4: Build**

  ```bash
  xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "^(\*\* BUILD|error:)" | head -3
  ```

  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Live smoke**

  ```bash
  pkill -x yawac 2>/dev/null
  open /tmp/yawac-derived/Build/Products/Debug/yawac.app
  ```

  Open Settings → Account → tap "Full history sync". Verify:
  - Sublabel changes to "0% • chunk 0 • 0 messages" then ticks upward as chunks arrive.
  - Linear ProgressView appears below the row.
  - After 60 s of no new chunks, ProgressView disappears and sublabel switches to "Last run: X messages across N chunks".
  - Tapping again while in flight is a no-op (no second request fired — confirm via `/tmp/yawac.log` if needed).

- [ ] **Step 6: Commit**

  ```bash
  git add yawac/Views/Settings/Panels/AccountPanel.swift
  git commit -m "feat(settings): full history sync row + progress (F28)

  Account card grows a third SettingsRow that fires
  SessionViewModel.startFullHistorySync on tap and shows live
  progress (percent + chunks + messages) under the row via an
  inline linear ProgressView while inFlight. Idle sublabel
  surfaces the last run's totals.

  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
  ```

---

## Task 6: Release v0.9.43

**Files:**
- Modify: `project.yml` (CFBundleShortVersionString + CFBundleVersion)
- Modify: `docs/ROADMAP.md` (Shipped entry)
- Modify: `yawac/Info.plist` (regenerated by xcodegen)

- [ ] **Step 1: Bump version**

  Edit `project.yml`:

  ```yaml
  CFBundleShortVersionString: "0.9.43"
  CFBundleVersion: "58"
  ```

- [ ] **Step 2: Add Shipped entry**

  In `docs/ROADMAP.md`, insert the following block above the existing v0.9.42 entry, directly after the `Kept here for context — flip back to open only if a regression surfaces.` paragraph and the existing `# Shipped (✅)` heading line:

  ```markdown
  - ✅ **Full history sync settings control (F28)** (v0.9.43) —
    Settings → Account → "Full history sync" row that fires the
    F27 deep-history backfill on demand. Bridge `dispatchHistory`
    now ships `progress` (0–100), `chunk_order`, and
    `chunk_messages` alongside the existing `sync_type` +
    `conversations` payload. `SessionViewModel` carries a new
    observable `FullSyncState { inFlight, progress, chunks,
    messages }` updated by every contentful chunk
    (`INITIAL_BOOTSTRAP` / `RECENT` / `FULL` / `ON_DEMAND`); a
    60 s silence-timeout clears the in-flight flag if the phone
    goes quiet. `AccountPanel` shows the row's sublabel ticking
    (`0% • chunk 1 • 50 messages`) and renders a linear
    `ProgressView` underneath while `inFlight`. Spec at
    `docs/superpowers/specs/2026-06-09-full-history-sync-control-design.md`.
  ```

- [ ] **Step 3: Regenerate + build**

  ```bash
  xcodegen generate
  xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "^(\*\* BUILD|error:)" | head -3
  ```

  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit + push + merge + tag**

  ```bash
  git add project.yml docs/ROADMAP.md yawac/Info.plist
  git commit -m "release: 0.9.43 — full history sync settings control (F28)

  Settings → Account → \"Full history sync\" row triggers the
  F27 deep-history backfill on demand and shows live progress
  until the phone goes quiet for 60s.

  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
  ```

  If working on a feature branch, push it then merge to main + tag:

  ```bash
  git push -u origin <feature-branch-name>
  git checkout main
  git pull --ff-only origin main
  git merge <feature-branch-name> --no-ff -m "merge: v0.9.43 full history sync settings control (F28)

  Lands the F28 spec from docs/superpowers/specs/2026-06-09-full-history-sync-control-design.md.

  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
  git tag -a v0.9.43 -m "v0.9.43 — full history sync settings control (F28)"
  git push origin main
  git push origin v0.9.43
  ```

  CI's release workflow takes over from the tag push (see `reference_yawac_release_workflow.md`).

- [ ] **Step 5: Drop the feature branch**

  ```bash
  git branch -D <feature-branch-name>
  git push origin --delete <feature-branch-name>
  ```

---

## Self-Review

**1. Spec coverage:**

| Spec requirement | Task |
|---|---|
| Bridge payload extension (progress, chunk_order, chunk_messages) | T1 |
| Swift `.historySync` enum case carries new fields | T2 |
| Callsite pattern updates | T3 |
| `FullSyncState` struct on `SessionViewModel` | T4 (step 1) |
| `startFullHistorySync` action | T4 (step 2) |
| `armFullSyncTimeout` (60 s watchdog) | T4 (step 2) |
| Chunk-handler extension (contentful gate, max progress, re-arm) | T4 (step 3) |
| Third `SettingsRow` in Account card | T5 (step 2) |
| Inline `ProgressView` under row | T5 (step 2) |
| `fullSyncSublabel` helper (idle / inFlight / lastRun phrasing) | T5 (step 2) |
| Release bump + ROADMAP entry | T6 |

No gaps.

**2. Placeholder scan:** No "TBD" / "implement later" / "similar to". Every code step has runnable content. The feature-branch-name placeholder in T6 step 4 is an intentional variable — implementer picks the name.

**3. Type consistency:**

- `FullSyncState` field names (`inFlight`, `progress`, `chunks`, `messages`) — referenced consistently from T4 + T5.
- `SessionViewModel.startFullHistorySync()` — defined T4 step 2, called T5 step 2 row `onTap`.
- `session.fullSync` access in T5 step 2 — `fullSync` is `private(set) var` in T4 step 1; external read OK.
- `armFullSyncTimeout` — same name in T4 step 2 (definition) and T4 step 3 (call).
- `historyBackfillCompleted` — referenced in T4 step 2; pre-existing on `SessionViewModel` (F26).
- `requestHistoryBackfillIfNeeded` — called from `startFullHistorySync`; pre-existing F27 method.
- Bridge JSON keys (`sync_type`, `conversations`, `progress`, `chunk_order`, `chunk_messages`) — match between T1 Go writer and T2 Swift decoder.

No type mismatches.
