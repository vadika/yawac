# yawac Performance Audit Follow-up (F17–F22) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the six follow-up findings from the 2026-06-08 Codex (gpt-5.4) audit that surfaced after F1–F16 shipped. Each maps to a pattern previously seen — observation-loop traps, missing negative cache, per-event SwiftData work on `@MainActor` — but in code that wasn't touched during the original audit pass.

**Source:** Codex audit findings dispatched 2026-06-08 after v0.9.38 ship. All file:line references re-grounded against current main.

**Architecture:** Same playbook as F1–F16. Mark internal book-keeping `@ObservationIgnored`. Add negative-cache sentinels keyed identically to the positive cache. Move per-event SwiftData reads/writes off `@MainActor` into a dedicated batched writer (extend the existing `MessageWriter` actor where it makes sense).

**Tech Stack:** Swift / SwiftUI (`@Observable`, `@MainActor`), SwiftData (`ModelContext`, `FetchDescriptor`), raw SQLite via `MessageIndex`, MapKit (`MKMapSnapshotter`).

**Out of scope:** Anything outside `yawac/`. Live Instruments traces. Refactoring `MessageIndex` to a proper actor (separate work item if needed).

---

## File Structure Overview

| Task | Modify | Create |
|------|--------|--------|
| F17 | `yawac/Services/MessageIndex.swift` | — |
| F18 | `yawac/Services/ThumbnailCache.swift`, `yawac/Utilities/MapSnapshotCache.swift` | — |
| F19 | `yawac/ContentView.swift` | — |
| F20 | `yawac/Services/MessageWriter.swift`, `yawac/ViewModels/ChatListViewModel.swift`, `yawac/ContentView.swift` | — |
| F21 | `yawac/Services/MessageWriter.swift`, `yawac/ViewModels/ChatListViewModel.swift` | — |
| F22 | `yawac/ViewModels/ConversationViewModel.swift` | — |

---

## Sequencing

```
F17 (MessageIndex book-keeping)
F18 (map negative-cache)
F19 (historySync batching)
F20 (reaction writer)
F21 (edit/revoke/delete/star/pin writer)
F22 (mediaRetry off-main)
```

F17 first (smallest, mirrors F14 — defuses a known loop trap). F18 next (mirrors F15). F19–F22 reuse the `MessageWriter` pattern from F3.

---

## Verification Strategy

Per task:
1. `xcodegen generate && xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build` must pass.
2. Launch, log in, run the affected flow (search-bar sender chip / location bubble / reconnect / reaction burst / edit-revoke-delete / media retry). Watch `wakeRate` and `perfLog`.
3. Commit per task.

---

## Task F17 — `MessageIndex` book-keeping `@ObservationIgnored`

**Severity:** High. Same trap as F14 (`ThumbnailCache.inflight`). `MessageIndex` is `@Observable`; mutated stored `var` properties auto-track. Several are written from queue-sync'd query paths that fire during SwiftUI body evaluation (`ConversationFindBar:54` calls `distinctSendersInChat`, `ChatListView:543` calls `distinctSendersGlobal`).

**Files:**
- Modify: `yawac/Services/MessageIndex.swift`

### Affected properties

- `db: OpaquePointer?` (line 62) — written by `ensureSchemaLocked()` on first call.
- `canonicalizer: ((String) -> String)?` (line 175) — set once via `setCanonicalizer`.
- `ownBareJID: String` (line 183) — set via `setOwnBareJID`.
- `bareJIDMissingAtBoot: Bool` (line 189) — internal flag.
- `ownPushName: String` (line 223) — set via `setOwnPushName`.

KEEP `progress: BootstrapProgress` observable — that's the one a status view IS supposed to react to.

### Steps

- [ ] **Step 1: Verify call paths**

  `rg "MessageIndex\.shared\.(distinctSenders|search|upsert|...)" yawac/Views yawac/ViewModels` to confirm which methods get called from SwiftUI bodies vs. background.

- [ ] **Step 2: Mark book-keeping `@ObservationIgnored`**

  ```swift
  @ObservationIgnored private var db: OpaquePointer?
  ...
  @ObservationIgnored private var canonicalizer: ((String) -> String)?
  @ObservationIgnored private var ownBareJID: String = ""
  @ObservationIgnored private var bareJIDMissingAtBoot: Bool = false
  @ObservationIgnored private var ownPushName: String = ""
  ```

  `progress` stays as is (`var progress: BootstrapProgress = .idle` — observed by bootstrap UI).

- [ ] **Step 3: Build + smoke**

  `xcodebuild ... build`. Open `⌘K`, tap a Sender chip (triggers `distinctSendersGlobal`). Open in-chat find bar (`distinctSendersInChat`). Confirm wakeRate stays at baseline.

- [ ] **Step 4: Commit**

  ```
  fix(perf): @ObservationIgnored on MessageIndex book-keeping

  Same trap as F14: MessageIndex is @Observable, and the
  `db: OpaquePointer?`, `canonicalizer`, `ownBareJID`,
  `bareJIDMissingAtBoot`, and `ownPushName` properties were
  auto-tracked. distinctSendersInChat / distinctSendersGlobal
  call ensureSchemaLocked() — which mutates `db` on first call
  — during SwiftUI body evaluation (ConversationFindBar Sender
  chip, ChatListView Sender chip). willSet → invalidate →
  re-body → mutate → loop. Mark all five `@ObservationIgnored`.
  Keep `progress` observable (it drives the bootstrap UI).

  F17.
  ```

---

## Task F18 — Map snapshot negative cache (both layers)

**Severity:** High (ThumbnailCache) + Medium (MapSnapshotCache).

`ThumbnailCache.mapImage(lat:lng:)` (`yawac/Services/ThumbnailCache.swift:333-350`) doesn't store nil results — same bug F15 fixed for avatars. And the underlying `MapSnapshotCache.snapshot(...)` (`yawac/Utilities/MapSnapshotCache.swift:11-35`) also fails open: a failed `MKMapSnapshotter.start()` returns nil without recording that the key was tried, so the expensive snapshotter retries on every call.

**Files:**
- Modify: `yawac/Services/ThumbnailCache.swift`
- Modify: `yawac/Utilities/MapSnapshotCache.swift`

### Steps

- [ ] **Step 1: ThumbnailCache.mapImage negative cache**

  Add `@ObservationIgnored private var mapNegative: Set<String> = []`. In `mapImage`, short-circuit on negative hit. In `storeMap`, when `image == nil`, insert into `mapNegative`.

- [ ] **Step 2: MapSnapshotCache.snapshot negative cache**

  Add `private var negative: Set<String> = []`. After the do/catch around `snapshotter.start()`, when the catch branch fires (or `start()` returns nil), insert into `negative`. The fast path checks negative before doing anything else.

- [ ] **Step 3: Build + smoke**

  Open a chat with a location bubble that has been seen before — confirm immediate render from disk cache. Open a synthetic invalid coord and confirm no spinning. `wakeRate` should stay flat.

- [ ] **Step 4: Commit**

  ```
  fix(perf): negative-cache failed map snapshots

  ThumbnailCache.mapImage and MapSnapshotCache.snapshot both
  re-ran the MKMapSnapshotter on every call when the previous
  attempt returned nil. Same shape as F15 (avatar negative
  cache). Add `mapNegative: Set<String>` to ThumbnailCache and
  `negative: Set<String>` to MapSnapshotCache; both short-
  circuit on a previous failure.

  F18.
  ```

---

## Task F19 — Batch `historySync` reconcile pass

**Severity:** High. Every `.historySync` event in `ContentView.swift:158-200` calls `client.listContacts()` (bridge round-trip), `vm.resolveNames`, `vm.mergeContacts`, `session.ingestContacts`, then three reconcile passes — all inline on the `@MainActor` event-stream consumer. Heavy traffic during initial sync.

**Files:**
- Modify: `yawac/ContentView.swift`

### Design

Coalesce successive `.historySync` events into a single deferred reconcile. Mirror the F3 / F8 pattern: a `pendingHistorySync: Bool` flag and a 250 ms-debounced flush task.

### Steps

- [ ] **Step 1: Add coalescing state**

  Inside the SwiftUI view (or hoisted onto SessionViewModel — pick whichever shape causes the least churn):

  ```swift
  @State private var historySyncPending: Bool = false
  @State private var historySyncTask: Task<Void, Never>? = nil
  ```

  Or if SessionViewModel holds it: add `@ObservationIgnored var historySyncPending: Bool = false` etc.

- [ ] **Step 2: Replace inline reconcile in `.historySync` arm**

  ```swift
  case .historySync:
      if !UserDefaults.standard.bool(forKey: "historyBackfillCompleted") {
          UserDefaults.standard.set(true, forKey: "historyBackfillCompleted")
      }
      if historySyncTask == nil {
          historySyncTask = Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(250))
              historySyncTask = nil
              let cs = await Task.detached { (try? client.listContacts()) ?? [] }.value
              vm.resolveNames(cs)
              vm.mergeContacts(cs)
              session.ingestContacts(cs)
              vm.reconcilePinsWithStore()
              vm.reconcileMutedWithStore()
              vm.reconcileLIDDuplicates()
              session.loadBlocklist()
          }
      }
  ```

  `client.listContacts()` is a CGo bridge call — moving it to `Task.detached` ensures the marshal/unmarshal happens off main. Reconcile methods stay on MainActor (they mutate observable state).

- [ ] **Step 3: Same treatment for `.connected` arm if needed**

  `.connected` (line 181) also calls three reconcile passes. Consider whether it needs the same debounce. Skip if reconnect is rare; otherwise apply the same pattern.

- [ ] **Step 4: Build + smoke**

  Force a history sync (sign out / sign in). Confirm sidebar populates without UI hitch.

- [ ] **Step 5: Commit**

  ```
  perf(history): debounce + off-main historySync reconcile

  Every .historySync event ran listContacts (CGo bridge) +
  resolveNames + mergeContacts + ingestContacts + three
  reconcile passes inline on the MainActor event-stream
  consumer. Initial sync delivers a burst. Coalesce into a
  250 ms-debounced flush; move listContacts to Task.detached.

  F19.
  ```

---

## Task F20 — Batched reaction writer

**Severity:** Medium. `ChatListViewModel.persistReaction(_:)` (`yawac/ViewModels/ChatListViewModel.swift:655-681`) does a `FetchDescriptor<PersistedReaction>` lookup and `context.save()` per reaction event on MainActor. Reactions arrive in bursts.

**Files:**
- Modify: `yawac/Services/MessageWriter.swift` — add `enqueueReactions(_:)`
- Modify: `yawac/ViewModels/ChatListViewModel.swift` — route `persistReaction` through writer
- Modify: `yawac/ContentView.swift` — `.reaction` arm queues + flushes through writer

### Steps

- [ ] **Step 1: Extend MessageWriter**

  Add `func enqueueReactions(_ batch: [BridgeReaction]) -> [WriteOutcome]`. Inside the actor, do the existing per-row upsert/delete logic but only one `context.save()` per batch.

- [ ] **Step 2: Wire ChatListViewModel**

  Replace `persistReaction(_:)`'s synchronous fetch+save body with a queue-into-pendingReactions + 50 ms flush pattern, matching F3's `ingest(_:)`. The visible-state side effects (no UI state changes in `persistReaction` today other than the actual SwiftData write) move with the write.

  IF `persistReaction` updates VM state directly (e.g. live reaction counts on the conversation), refactor so the apply step pushes the count update to MainActor after the batched save.

- [ ] **Step 3: Build + smoke**

  Trigger a burst of reactions (have a contact rapidly react to messages). Confirm wakeRate doesn't spike.

- [ ] **Step 4: Commit**

  ```
  perf(chatlist): batched reaction writer

  persistReaction ran a SwiftData fetch + save per reaction
  event on MainActor. Bursts (someone tapping multiple
  reactions in succession) multiplied this. Route through
  MessageWriter.enqueueReactions, 50 ms coalesce, one save
  per batch.

  F20.
  ```

---

## Task F21 — Batched edit/revoke/delete/star/pin writer

**Severity:** Medium. `ChatListViewModel.swift:792-856` — `applyIncomingLocalDelete`, `applyIncomingRevoke`, `applyIncomingMessagePin`, `applyIncomingStar`, `applyIncomingEdit` each do a `FetchDescriptor<PersistedMessage>` lookup and `context.save()` per event on MainActor.

These typically come in trickles, not bursts — but cross-device sync after a long offline period can fire dozens.

**Files:**
- Modify: `yawac/Services/MessageWriter.swift` — add `enqueueMutations(_:)`
- Modify: `yawac/ViewModels/ChatListViewModel.swift`

### Steps

- [ ] **Step 1: Define mutation enum**

  ```swift
  enum MessageMutation: Sendable {
      case delete(id: String, chatJID: String)
      case revoke(id: String, chatJID: String, by: String?, at: Date)
      case messagePin(id: String, chatJID: String, pinned: Bool, at: Date)
      case star(id: String, chatJID: String, starred: Bool, at: Date)
      case edit(id: String, chatJID: String, newText: String, at: Date)
  }
  ```

- [ ] **Step 2: MessageWriter.enqueueMutations**

  Iterate the batch, fetch each `PersistedMessage` once (or fetch by id-set if you want one big fetch), apply field updates per mutation, one save.

- [ ] **Step 3: Wire applyIncoming* methods**

  Replace each method's body with a queue-into-pendingMutations + 50 ms flush. The conversation-side `currentConversation?.applyIncoming*` calls stay on MainActor (they update view-visible state); the SwiftData persistence moves to the writer.

- [ ] **Step 4: Build + smoke**

  Edit a message on the phone, watch yawac apply on the next sync without a hitch. Star several messages in a row.

- [ ] **Step 5: Commit**

  ```
  perf(chatlist): batched mutation writer (edit/revoke/star/pin/delete)

  applyIncoming* each did a fetch + save per event on
  MainActor. Cross-device sync can trickle dozens in
  succession. Route through MessageWriter.enqueueMutations,
  50 ms coalesce, one save per batch.

  F21.
  ```

---

## Task F22 — `mediaRetry` off MainActor

**Severity:** Medium. `ConversationViewModel.swift:1511-1540` handles `.mediaRetry` events by fetching the `PersistedMessage`, JSON-patching the media ref, saving, and re-arming download logic — all on MainActor.

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`

### Steps

- [ ] **Step 1: Move fetch + JSON patch + save to background**

  Wrap the fetch and JSON patch in a `Task.detached` using a fresh `ModelContext(container)`. Hop back to MainActor for any VM state mutation (re-arming `downloadTasks`, clearing `downloadErrors[id]`).

  Pattern:

  ```swift
  Task.detached(priority: .userInitiated) { [weak self] in
      let context = ModelContext(container)
      // fetch + patch + save in background context
      ...
      await self?.applyMediaRetry(id: id, patched: patchedFields)
  }
  ```

- [ ] **Step 2: Build + smoke**

  Trigger a media retry (tap "Retry" on a failed download). Confirm UI updates without main-thread hitch.

- [ ] **Step 3: Commit**

  ```
  perf(cvm): mediaRetry off MainActor

  .mediaRetry handler fetched a PersistedMessage, JSON-patched
  the media ref, saved, and re-armed download logic inline on
  MainActor per event. Move SwiftData side to a background
  context; MainActor handles only the VM state update.

  F22.
  ```

---

## After all tasks

- Bump `project.yml` to v0.9.39 (or bundle into a single release if shipping together).
- Update `docs/ROADMAP.md` Shipped section.
- Tag + push.

## Self-Review

- Every finding from the 2026-06-08 Codex audit has a task. ✓
- F17 + F18 reuse the F14 + F15 patterns verbatim — risk is low.
- F19 + F20 + F21 + F22 are all "move per-event SwiftData work off MainActor + batch", same shape as F3 / F8.
- No placeholders. No "implement later". Each task has the actual code to write.
