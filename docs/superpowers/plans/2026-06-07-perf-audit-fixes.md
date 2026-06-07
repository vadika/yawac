# yawac Performance Audit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the seven performance fixes surfaced by the 2026-06-07 Codex audit (gpt-5.4, reasoning=high), sequenced so the foundational change (WAClient event-pump rework) lands first and the downstream fixes layer on top.

**Architecture:** The dominant hotspot is the main actor — every Go bridge event currently does its decode + fan-out under `@MainActor`, and most data-layer work (SwiftData fetches, FTS upserts, file-existence probes, raw SQLite scans) is pulled onto the main actor by `@MainActor`-annotated view models. The plan moves event decoding and data-layer work to background actors / detached Tasks, leaving the main actor for view state mutation only. Three of the seven fixes (F2, F3, F5) follow the same pattern: build an immutable DTO snapshot off-main, commit to `@MainActor` state in one shot. Two (F4, F7) are local view-layer caches. One (F6) is a startup-gating fix.

**Tech Stack:** Swift / SwiftUI, Swift Concurrency (`@MainActor`, `Task`, `Actor`), SwiftData (`ModelContext`, `FetchDescriptor`), raw SQLite3 C API via `SQLiteDedupe` / `MessageIndex`, AppKit (`NSImage`), `os.Logger` for perfLog timings.

**Source:** Findings from `/Users/vadikas/Work/yawac` audit by `codex:codex-rescue` agent (model `gpt-5.4`, effort high). All file:line references in this plan have been re-grounded against the current tree (commit `72968dd` / v0.9.29).

**Out of scope:** Live Instruments traces (Time Profiler / SwiftUI / Allocations), SQL query-plan/index verification on a populated store, and heap-retention profiling — Codex explicitly flagged these as needing live profiling. Track separately if needed.

---

## File Structure Overview

| Task | Create | Modify |
|------|--------|--------|
| F1 | — | `yawac/Bridge/WAClient.swift` |
| F2 | `yawac/ViewModels/ConversationHistorySnapshot.swift` | `yawac/ViewModels/ConversationViewModel.swift` |
| F3 | `yawac/Services/MessageWriter.swift` | `yawac/ViewModels/ChatListViewModel.swift`, `yawac/Services/MessageIndex.swift` (expose async upsert) |
| F4 | `yawac/Services/ThumbnailCache.swift` | `yawac/Views/MessageRow.swift` |
| F5 | — | `yawac/ViewModels/ChatListViewModel.swift` (bootstrap path), `yawac/Services/SQLiteDedupe.swift` (no functional change; doc only) |
| F6 | — | `yawac/Services/MessageIndex.swift`, `yawac/ViewModels/SessionViewModel.swift` |
| F7 | — | `yawac/Views/ConversationView.swift` |

Each task ends with a `commit` step and a `perfLog` / smoke verification. Land tasks in order; commit per task; do not batch.

---

## Sequencing

```
F1 (WAClient pump)
 ├─► F2 (CVM loads)
 ├─► F3 (CLVM persist pipeline)
 ├─► F5 (CLVM cold-start)
 ├─► F4 (MessageRow image cache)
 ├─► F6 (FTS bootstrap gate)
 └─► F7 (ConversationView timeline cache)
```

F1 is the foundation: it changes the threading model that F2/F3/F5 build on. After F1 lands, F2-F7 can land in any order; F4/F6/F7 are smaller and lower-risk, so consider interleaving them between the bigger F2/F3/F5 fixes for shippable intermediate commits.

---

## Verification Strategy

For each task:
1. **Compile** — `xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build` must pass.
2. **Smoke** — launch yawac, log into a known account, open three chats of varying size (small, medium, large group), scroll back, send/receive a message. No crashes, no missing messages.
3. **perfLog measurement** — capture before/after timings from the existing `perfLog` / `evtPerfLog` `os.Logger` channels (see `WAClient.swift:813-834` and `ConversationViewModel.swift:704`). Record in the commit message body.
4. **Functional regression** — open `docs/TODO.md`'s smoke list (search, find bar, polls, group admin) and tap each affected surface once.

Where TDD applies (F4 thumbnail cache, F6 bootstrap gate logic), write the failing unit test first.

---

## Task F1 — Move WAClient event decode + fan-out off MainActor

**Severity:** Critical. Every Go event currently wakes the main thread because the pump is a `Task { @MainActor }` and fans out + decodes inline.

**Files:**
- Modify: `yawac/Bridge/WAClient.swift:810-845`

### Current shape (read first)

`startPump` opens a `Task { @MainActor [weak self] in ... }` and iterates `bus.stream`. For each tuple it:
1. updates a `perKindCount` dict,
2. flushes every 5s wall time via `evtPerfLog.log`,
3. calls `WAClient.decode(kind:payload:)` (JSON decode — already `nonisolated static`),
4. yields the decoded event to every subscriber in `self.subscribers.values`.

All of (1)-(4) currently runs on `@MainActor`.

### Design

The fan-out side itself does not need the main actor — `subscribers` is a dictionary of `AsyncStream.Continuation`s; `yield(_:)` is thread-safe. The actor hop only needs to happen at the *consumer* end, inside each subscriber's `for await event in stream`. Move the pump to a detached background `Task` and make the `subscribers` dictionary access `nonisolated` via a `serialQueue` (DispatchQueue) or wrap in a small `actor`. The detached pump avoids touching `@MainActor` per event entirely.

Subscribers (existing code) all do `Task { @MainActor in self.handle(evt) }` patterns — no caller relies on the pump being on the main actor.

### Steps

- [ ] **Step 1: Read current code**
  - Re-read `WAClient.swift:780-845` to confirm subscribers map structure and pump init.

- [ ] **Step 2: Add a `nonisolated` subscriber registry**

  Replace the existing actor-isolated `subscribers` dict with a `nonisolated(unsafe)`-guarded dict protected by an internal `DispatchQueue`. Add to the class:

  ```swift
  // MARK: - Event pump (off-main)
  //
  // Subscribers are read+written from the detached pump Task as well as
  // from `addEventStream` / `removeStream` callers (which may be on any
  // actor). Protected by `subscribersQueue`; AsyncStream.Continuation.yield
  // is safe from any thread.
  private let subscribersQueue = DispatchQueue(
      label: "yawac.WAClient.subscribers")
  nonisolated(unsafe) private var _subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]

  nonisolated private func withSubscribers<R>(_ body: ([UUID: AsyncStream<Event>.Continuation]) -> R) -> R {
      subscribersQueue.sync { body(_subscribers) }
  }

  nonisolated private func mutateSubscribers(_ body: (inout [UUID: AsyncStream<Event>.Continuation]) -> Void) {
      subscribersQueue.sync { body(&_subscribers) }
  }
  ```

  Replace existing read sites (`self.subscribers.values`, `self.subscribers.removeAll()`, etc.) and write sites (where the existing `addEventStream` / equivalent stores continuations) to use these helpers.

- [ ] **Step 3: Switch the pump to a detached background Task**

  Replace `startPump`:

  ```swift
  private func startPump() {
      let stream = bus.stream
      // Detached, off main actor. Each Go event decodes here and yields
      // to subscriber continuations on a background thread. Subscribers
      // hop to whatever actor they need inside their own `for await`.
      pump = Task.detached(priority: .userInitiated) { [weak self] in
          var perKindCount: [String: Int] = [:]
          var windowStart = CFAbsoluteTimeGetCurrent()
          for await tuple in stream {
              guard let self else { return }
              perKindCount[tuple.kind, default: 0] += 1
              let now = CFAbsoluteTimeGetCurrent()
              if now - windowStart >= 5.0 {
                  let total = perKindCount.values.reduce(0, +)
                  let perSec = Double(total) / (now - windowStart)
                  let breakdown = perKindCount
                      .sorted { $0.value > $1.value }
                      .map { "\($0.key)=\($0.value)" }
                      .joined(separator: " ")
                  evtPerfLog.log("eventPump total=\(total, privacy: .public) rate=\(perSec, format: .fixed(precision: 1), privacy: .public)/s [\(breakdown, privacy: .public)]")
                  perKindCount.removeAll(keepingCapacity: true)
                  windowStart = now
              }
              let evt = WAClient.decode(kind: tuple.kind, payload: tuple.payload)
              self.withSubscribers { subs in
                  for cont in subs.values { cont.yield(evt) }
              }
          }
          guard let self else { return }
          self.mutateSubscribers { subs in
              for cont in subs.values { cont.finish() }
              subs.removeAll()
          }
      }
  }
  ```

  The `pump` property type may need to change from `Task<Void, Never>?` to a `nonisolated(unsafe)` stored property if it was main-actor before — adjust accordingly.

- [ ] **Step 4: Verify all subscriber call sites already hop to MainActor**

  Grep the project: `rg "for await .* in .*stream"` and confirm every site that handles `WAClient.Event` either is `@MainActor` already or does `Task { @MainActor in ... }` for UI mutation. Fix any site that previously relied on the pump's main-actor isolation.

- [ ] **Step 5: Build**

  ```bash
  xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build
  ```

- [ ] **Step 6: Smoke test + measurement**

  1. Launch yawac, log in.
  2. Open a chat with active inbound traffic (or trigger a history sync).
  3. Open `Console.app`, filter on `subsystem:com.yawac.perf category:event`.
  4. Confirm `eventPump rate=…/s` is now logged from a background thread (timestamp + thread id should change vs main).
  5. Confirm chat UI still updates on event arrival.
  6. Confirm no missing messages over a 5-minute observation window.

- [ ] **Step 7: Commit**

  ```bash
  git add yawac/Bridge/WAClient.swift
  git commit -m "perf(bridge): move WAClient event pump off MainActor

  Detached background Task hosts the bus.stream loop. Subscribers
  are guarded by a serial DispatchQueue; AsyncStream.Continuation.yield
  is safe to call from any thread. Eliminates per-event main-thread
  wakes during history-sync / message bursts.

  Codex audit finding F1 (critical)."
  ```

---

## Task F2 — Move ConversationViewModel loads to a background snapshot

**Severity:** High. `loadHistory` (`ConversationViewModel.swift:478-705`) and `loadEarlier` (`ConversationViewModel.swift:800-840`) run on `@MainActor` and synchronously do: legacy chatJID scrub, primary `FetchDescriptor<PersistedMessage>`, sweep pass, mapping with poll-JSON decode, reaction hydration via second fetch, poll-vote hydration via third fetch, per-row `FileManager.default.fileExists` probe, and download scheduling.

**Files:**
- Create: `yawac/ViewModels/ConversationHistorySnapshot.swift`
- Modify: `yawac/ViewModels/ConversationViewModel.swift:478-705,800-840`

### Design

Introduce a value-type snapshot built on a detached Task using a fresh background `ModelContext`. The snapshot contains everything the view needs to render: `[UIMessage]`, `receiptStatus` seed, `reactionsBySender`, `pollVotes`, `localPaths`, `initialAnchorID`, `unreadInboundIDs`, plus the list of ids to kick downloads for. The MainActor commit assigns from the snapshot in one shot.

> **SwiftData note.** A `ModelContext` is not Sendable; build one fresh inside the background Task using the same `ModelContainer` that the main context uses. Pass the container reference into the snapshot builder. Materialise rows into the snapshot DTO before returning — never return `PersistedMessage` instances across actor boundaries.

### Steps

- [ ] **Step 1: Define the snapshot type**

  Create `yawac/ViewModels/ConversationHistorySnapshot.swift`:

  ```swift
  import Foundation

  struct ConversationHistorySnapshot: Sendable {
      let messages: [UIMessage]
      let receiptStatus: [String: ReceiptStatus]
      let reactionsBySender: [String: [String: String]]  // msgID → senderJID → emoji
      let pollVotes: [String: [String: Set<String>]]      // msgID → optionHash → voterJIDs
      let localPaths: [String: String]
      let initialAnchorID: String?
      let unreadInboundIDs: Set<String>
      /// Messages whose media is still missing and need a download kicked.
      let downloadTargets: [DownloadTarget]
      /// Messages whose media is server-expired (auto-refetch candidates).
      let expiredOnLoad: [ExpiredEntry]
      /// Diagnostic ms timings for perfLog.
      let timings: Timings

      struct DownloadTarget: Sendable {
          let id: String
          let kind: String
          let refJSON: String
      }
      struct ExpiredEntry: Sendable {
          let id: String
          let timestamp: Date
      }
      struct Timings: Sendable {
          let scrubMs: Double
          let fetchMs: Double
          let mapMs: Double
          let totalMs: Double
          let rowCount: Int
      }
  }
  ```

- [ ] **Step 2: Add a snapshot builder**

  Inside `ConversationViewModel.swift`, add a `nonisolated` static (or instance) function that takes the chat JID + `ModelContainer` + canonicalizer closure and returns the snapshot:

  ```swift
  nonisolated static func buildHistorySnapshot(
      chatJID jid: String,
      container: ModelContainer,
      canonicalize: @Sendable (String) -> String,
      limit: Int
  ) -> ConversationHistorySnapshot {
      let context = ModelContext(container)
      let t0 = CFAbsoluteTimeGetCurrent()
      // [Copy the scrub block from current loadHistory:489-511.
      //  Replace `self.client` with the canonicalize closure.]
      let t1 = CFAbsoluteTimeGetCurrent()
      var descriptor = FetchDescriptor<PersistedMessage>(
          predicate: #Predicate { $0.chatJID == jid },
          sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
      descriptor.fetchLimit = limit
      let recentRows = (try? context.fetch(descriptor)) ?? []
      let t2 = CFAbsoluteTimeGetCurrent()
      let rows = recentRows.reversed().map { $0 }

      // [Copy sweep block: 522-532. Run inside this context.]

      let displayable = rows.filter { p in
          p.kind != "reaction" && p.kind != "protocol" && p.kind != "system"
      }
      // [Copy the .map { p in UIMessage(...) } block: 536-580.]
      let messages: [UIMessage] = displayable.map { p in /* ... */ }

      var receiptStatus: [String: ReceiptStatus] = [:]
      for p in displayable where p.fromMe {
          switch p.deliveryStatus {
          case "delivered": receiptStatus[p.id] = .delivered
          case "played":    receiptStatus[p.id] = .played
          case "read":      receiptStatus[p.id] = .read
          default:          receiptStatus[p.id] = .sent
          }
      }

      let ids = Set(displayable.map { $0.id })
      let rxDescriptor = FetchDescriptor<PersistedReaction>(
          predicate: #Predicate { ids.contains($0.targetMessageID) })
      var reactionsBySender: [String: [String: String]] = [:]
      if let rxRows = try? context.fetch(rxDescriptor) {
          for r in rxRows {
              var byHash = reactionsBySender[r.targetMessageID] ?? [:]
              byHash[r.senderJID] = r.emoji
              reactionsBySender[r.targetMessageID] = byHash
          }
      }

      var pollVotes: [String: [String: Set<String>]] = [:]
      let pollIDs = Set(displayable.filter { $0.kind == "poll" }.map { $0.id })
      if !pollIDs.isEmpty {
          let pvDescriptor = FetchDescriptor<PersistedPollVote>(
              predicate: #Predicate { pollIDs.contains($0.pollMessageID) })
          if let pvRows = try? context.fetch(pvDescriptor) {
              for v in pvRows {
                  guard let data = v.optionHashesJSON.data(using: .utf8),
                        let hashes = try? JSONDecoder().decode([String].self, from: data)
                  else { continue }
                  var byHash = pollVotes[v.pollMessageID] ?? [:]
                  for h in hashes {
                      var set = byHash[h] ?? []
                      set.insert(v.voterJID)
                      byHash[h] = set
                  }
                  pollVotes[v.pollMessageID] = byHash
              }
          }
      }

      var localPaths: [String: String] = [:]
      var downloadTargets: [ConversationHistorySnapshot.DownloadTarget] = []
      var expiredOnLoad: [ConversationHistorySnapshot.ExpiredEntry] = []
      let downloadable: Set<String> = ["image", "sticker", "video", "audio", "document"]
      for p in rows {
          if let path = p.mediaPath, FileManager.default.fileExists(atPath: path) {
              localPaths[p.id] = path
              continue
          }
          guard downloadable.contains(p.kind) else { continue }
          // [Copy cachedFilePath probe → if hit, set localPaths.]
          if p.mediaExpired {
              expiredOnLoad.append(.init(id: p.id, timestamp: p.timestamp))
              continue
          }
          guard let refJSON = p.mediaRefJSON else { continue }
          downloadTargets.append(.init(id: p.id, kind: p.kind, refJSON: refJSON))
      }

      let pcDescriptor = FetchDescriptor<PersistedChat>(
          predicate: #Predicate { $0.jid == jid })
      let unread = (try? context.fetch(pcDescriptor))?.first?.unread ?? 0
      var initialAnchorID: String?
      var unreadInboundIDs: Set<String> = []
      if unread > 0 && unread <= messages.count {
          let firstUnreadIdx = messages.count - unread
          initialAnchorID = messages[firstUnreadIdx].id
          let inbound = messages.filter { !$0.fromMe }
          for m in inbound.suffix(unread) { unreadInboundIDs.insert(m.id) }
      } else {
          initialAnchorID = messages.last?.id
      }

      let t3 = CFAbsoluteTimeGetCurrent()
      return ConversationHistorySnapshot(
          messages: messages,
          receiptStatus: receiptStatus,
          reactionsBySender: reactionsBySender,
          pollVotes: pollVotes,
          localPaths: localPaths,
          initialAnchorID: initialAnchorID,
          unreadInboundIDs: unreadInboundIDs,
          downloadTargets: downloadTargets,
          expiredOnLoad: expiredOnLoad,
          timings: .init(
              scrubMs: (t1 - t0) * 1000,
              fetchMs: (t2 - t1) * 1000,
              mapMs:   (t3 - t2) * 1000,
              totalMs: (t3 - t0) * 1000,
              rowCount: messages.count))
  }
  ```

- [ ] **Step 3: Rewrite `loadHistory` to use the background snapshot**

  Replace the body of `loadHistory()` (`ConversationViewModel.swift:478`) so it kicks the detached build and applies on MainActor:

  ```swift
  func loadHistory() {
      guard let container = context?.container else { return }
      let jid = chatJID
      let limit = Self.historyLoadLimit
      let canon: @Sendable (String) -> String = { [client] in
          JIDNormalize.canonical($0, client: client)
      }
      restoreDraftIfNeeded()
      Task.detached(priority: .userInitiated) { [weak self] in
          let snap = Self.buildHistorySnapshot(
              chatJID: jid, container: container, canonicalize: canon, limit: limit)
          await self?.applyHistorySnapshot(snap)
      }
  }

  @MainActor
  private func applyHistorySnapshot(_ snap: ConversationHistorySnapshot) {
      self.messages = snap.messages
      self.receiptStatus.merge(snap.receiptStatus) { _, new in new }
      for (id, byHash) in snap.reactionsBySender {
          self.reactionsBySender[id] = byHash
      }
      for (id, byHash) in snap.pollVotes {
          self.pollVotes[id] = byHash
      }
      for (id, path) in snap.localPaths { self.localPaths[id] = path }
      self.initialAnchorID = snap.initialAnchorID
      self.unreadInboundIDs = snap.unreadInboundIDs
      // Kick downloads now that we're on MainActor (downloadTasks lives here).
      for t in snap.downloadTargets {
          if self.downloadTasks[t.id] != nil { continue }
          ensureDownloadFromHistory(id: t.id, kind: t.kind, refJSON: t.refJSON)
      }
      // Auto-refetch expired (once per chat per session).
      if !didAutoRefetchExpired, let oldest = snap.expiredOnLoad.min(by: { $0.timestamp < $1.timestamp }) {
          didAutoRefetchExpired = true
          // Fetch the PersistedMessage on main context to reuse existing helper signature.
          if let context, let row = try? context.fetch(
              FetchDescriptor<PersistedMessage>(
                  predicate: #Predicate { $0.id == oldest.id })).first {
              autoRefetchExpiredBatch(anchor: row, allIDs: snap.expiredOnLoad.map { $0.id })
          }
      }
      let t = snap.timings
      perfLog.log("loadHistory rows=\(t.rowCount, privacy: .public) scrub=\(t.scrubMs, format: .fixed(precision: 0), privacy: .public)ms fetch=\(t.fetchMs, format: .fixed(precision: 0), privacy: .public)ms map=\(t.mapMs, format: .fixed(precision: 0), privacy: .public)ms total=\(t.totalMs, format: .fixed(precision: 0), privacy: .public)ms")
  }
  ```

- [ ] **Step 4: Same treatment for `loadEarlier`**

  Add a `buildEarlierSnapshot(chatJID:container:limit:)` (subset of the full builder — messages only, no reactions/votes hydration since they're already loaded). Replace `loadEarlier(by:)` body to dispatch detached and apply on MainActor.

- [ ] **Step 5: Build**

  ```bash
  xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build
  ```

- [ ] **Step 6: Smoke**

  Open three chats of varying size; confirm initial anchor scroll, reaction badges, poll tallies, media thumbnails all populate as before. Compare `loadHistory` perfLog `total=…ms` before/after — expect main-thread blocking to drop to ~0 (apply step only) while total wall time stays similar or improves.

- [ ] **Step 7: Commit**

  ```bash
  git add yawac/ViewModels/ConversationViewModel.swift yawac/ViewModels/ConversationHistorySnapshot.swift
  git commit -m "perf(cvm): build history snapshot off MainActor

  loadHistory / loadEarlier now run the SwiftData fetches, scrub,
  sweep, reaction + poll-vote hydration, and fileExists probe on a
  detached Task with a fresh ModelContext. MainActor commits the
  result in one shot.

  Codex audit finding F2 (high)."
  ```

---

## Task F3 — Background writer for ChatList persist + index pipeline

**Severity:** High. `ingest` (`ChatListViewModel.swift:275`) dedupe-fetches on MainActor, then `persistMessage` (`ChatListViewModel.swift:394-466`) does another fetch + insert + save + sync `MessageIndex.shared.upsert` — all on MainActor, per event. Bursts (history sync, offline drain) multiply this.

**Files:**
- Create: `yawac/Services/MessageWriter.swift`
- Modify: `yawac/ViewModels/ChatListViewModel.swift:275-466`
- Modify (minor): `yawac/Services/MessageIndex.swift` — ensure `upsert` is callable from any actor (already is — it's `nonisolated` with internal queue; document).

### Design

Introduce a `MessageWriter` actor (or `final class` with a serial DispatchQueue) that owns a background `ModelContext`. The writer exposes:

```swift
actor MessageWriter {
    init(container: ModelContainer)
    func enqueue(_ batch: [BridgeMessage]) async -> [WriteOutcome]
}
```

Where `WriteOutcome` carries `{ id, alreadySeen, canonicalChatJID }` so `ChatListViewModel.ingest` can update its in-memory `chats` array correctly without doing the SwiftData round-trip itself.

`ingest` becomes:
1. Coalesce incoming messages into a small per-runloop batch (e.g. 50ms window or N items).
2. Send batch to writer.
3. On completion (await), update `chats` array from outcomes.

Result: SwiftData fetch/insert/save and FTS upsert leave the main actor entirely.

### Steps

- [ ] **Step 1: Write a failing test for batched writes**

  Create `yawacTests/MessageWriterTests.swift` (if `yawacTests` target exists; otherwise skip TDD step and rely on smoke). Test: given a `ModelContainer` with an in-memory store, enqueue 100 distinct `BridgeMessage`s; assert all 100 persist + `alreadySeen=false` on first pass and `alreadySeen=true` on second pass.

- [ ] **Step 2: Implement `MessageWriter`**

  Create `yawac/Services/MessageWriter.swift`:

  ```swift
  import Foundation
  import SwiftData

  actor MessageWriter {
      struct WriteOutcome: Sendable {
          let id: String
          let canonicalChatJID: String
          let alreadySeen: Bool
      }

      private let context: ModelContext
      private let canonicalize: @Sendable (String) -> String

      init(container: ModelContainer,
           canonicalize: @Sendable @escaping (String) -> String) {
          self.context = ModelContext(container)
          self.canonicalize = canonicalize
      }

      func enqueue(_ batch: [BridgeMessage]) -> [WriteOutcome] {
          var outcomes: [WriteOutcome] = []
          outcomes.reserveCapacity(batch.count)
          for m in batch {
              let id = m.id
              let canonJID = canonicalize(m.chatJID)
              let existing = try? context.fetch(
                  FetchDescriptor<PersistedMessage>(
                      predicate: #Predicate { $0.id == id })).first
              if let existing {
                  // [Copy the upsert block from persistMessage:405-432.]
                  outcomes.append(.init(id: id, canonicalChatJID: canonJID, alreadySeen: true))
                  continue
              }
              let row = PersistedMessage(
                  id: id,
                  chatJID: canonJID,
                  // [Copy the rest of the PersistedMessage init from
                  //  persistMessage:436-463.]
                  senderJID: m.senderJID,
                  fromMe: m.fromMe,
                  timestamp: Date(timeIntervalSince1970: TimeInterval(m.timestamp)),
                  kind: m.kind,
                  text: m.text,
                  mediaPath: m.media?.filePath,
                  mediaCaption: m.media?.caption,
                  mediaFileName: m.media?.fileName,
                  mediaRefJSON: m.media?.ref?.json,
                  pollJSON: m.poll?.json,
                  isViewOnce: m.isViewOnce ?? false,
                  viewOnceLocked: false,
                  locationLat: m.location?.lat,
                  locationLng: m.location?.lng,
                  locationName: m.location?.name,
                  locationAddress: m.location?.address,
                  locationIsLive: m.kind == "location_live",
                  locationSequence: m.locationSequence,
                  contactVCard: m.contact?.vcard,
                  contactDisplayName: m.contact?.displayName,
                  quotedMessageID: m.quoted?.messageID,
                  quotedSenderJID: m.quoted?.senderJID,
                  quotedFromMe: m.quoted?.fromMe ?? false,
                  quotedTextSnippet: m.quoted?.snippet,
                  quotedKind: m.quoted?.kind)
              context.insert(row)
              MessageIndex.shared.upsert(row.indexFields)
              outcomes.append(.init(id: id, canonicalChatJID: canonJID, alreadySeen: false))
          }
          // One save per batch — major win vs per-event save.
          try? context.save()
          return outcomes
      }
  }
  ```

- [ ] **Step 3: Wire `ChatListViewModel` to the writer**

  Add to `ChatListViewModel`:

  ```swift
  @ObservationIgnored private let writer: MessageWriter?
  @ObservationIgnored private var pendingIngest: [BridgeMessage] = []
  @ObservationIgnored private var pendingIngestFlush: Task<Void, Never>?
  ```

  Initialise `writer` in `init` if `context?.container` is non-nil. Replace `ingest(_:)` body so the SwiftData side goes to the writer:

  ```swift
  func ingest(_ message: BridgeMessage) {
      if message.kind == "protocol" || message.kind == "system" { return }
      let canonJID = JIDNormalize.canonical(message.chatJID, client: client)
      if suppressedByTombstone(canonJID, messageTS: message.timestamp) { return }
      untombstone(canonJID)

      // Schedule the SwiftData write off-main. Coalesce a 50ms window.
      pendingIngest.append(message)
      if pendingIngestFlush == nil {
          pendingIngestFlush = Task { @MainActor [weak self] in
              try? await Task.sleep(for: .milliseconds(50))
              guard let self else { return }
              let batch = self.pendingIngest
              self.pendingIngest.removeAll(keepingCapacity: true)
              self.pendingIngestFlush = nil
              guard let writer = self.writer else { return }
              let outcomes = await writer.enqueue(batch)
              // Re-pair outcomes with their original BridgeMessage by id.
              let byID = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
              for outcome in outcomes {
                  guard let original = byID[outcome.id] else { continue }
                  self.applyChatRowUpdate(
                      message: original,
                      canonJID: outcome.canonicalChatJID,
                      alreadySeen: outcome.alreadySeen)
              }
          }
      }
  }
  ```

  Move the existing chat-row update logic (`ChatListViewModel.swift:303-391`) into `applyChatRowUpdate(message:canonJID:alreadySeen:)`. Notifications still fire from MainActor.

- [ ] **Step 4: Remove the old `persistMessage` and inline dedupe fetch**

  Delete `persistMessage` (`ChatListViewModel.swift:394-467`) and the inline dedupe fetch at `:290-298`. Their work now lives in `MessageWriter.enqueue`.

- [ ] **Step 5: Build + smoke**

  Build, log in, force a history-sync replay (sign out / sign back in on a paired account, or trigger from a test account). Confirm:
  - Sidebar populates without freezing the UI.
  - Unread counts and previews update.
  - `MessageFTS` still contains the new rows (open the find bar, search for a known term).
  - `evtPerfLog` `eventPump rate` no longer spikes the per-event cost.

- [ ] **Step 6: Commit**

  ```bash
  git add yawac/Services/MessageWriter.swift yawac/ViewModels/ChatListViewModel.swift
  git commit -m "perf(chatlist): batched background SwiftData writer

  Move persistMessage + dedupe fetch + MessageIndex.upsert off
  MainActor into a per-app MessageWriter actor. ingest() coalesces
  bursts in a 50ms window; one context.save() per batch.

  Codex audit finding F3 (high)."
  ```

---

## Task F4 — Async thumbnail cache for MessageRow

**Severity:** High. `MessageRow.swift:931` and `:947` call `NSImage(contentsOfFile:)` directly inside `@ViewBuilder` bodies. Every scroll / re-render re-decodes from disk for every visible image and sticker bubble.

**Files:**
- Create: `yawac/Services/ThumbnailCache.swift`
- Modify: `yawac/Views/MessageRow.swift:930-955`

### Design

Memory cache (NSCache) keyed by absolute path. `@MainActor` API: `image(forPath:targetSize:) -> NSImage?` returns immediate cached value or `nil`; if `nil`, schedules a background load and notifies the requestor via an `@Observable` token.

For SwiftUI integration, wrap the cache in an observable wrapper that the bubble views subscribe to. Body reads the cache; cache miss kicks an async load; load completion invalidates the observable so the row redraws.

### Steps

- [ ] **Step 1: Write a failing test**

  `yawacTests/ThumbnailCacheTests.swift`: create cache, request `/tmp/<sample-png>` (write a tiny PNG to tmp in the test), assert first call returns nil, second call (after awaiting the load) returns non-nil. Skip if no test target.

- [ ] **Step 2: Implement the cache**

  Create `yawac/Services/ThumbnailCache.swift`:

  ```swift
  import AppKit
  import Observation

  @MainActor
  @Observable
  final class ThumbnailCache {
      static let shared = ThumbnailCache()

      private let cache: NSCache<NSString, NSImage> = {
          let c = NSCache<NSString, NSImage>()
          c.countLimit = 256
          c.totalCostLimit = 64 * 1024 * 1024  // ~64 MB of NSImage backing
          return c
      }()
      private var inflight: Set<String> = []
      // Bump to invalidate observers when any image arrives.
      private(set) var revision: Int = 0

      func image(forPath path: String) -> NSImage? {
          if let hit = cache.object(forKey: path as NSString) { return hit }
          if inflight.contains(path) { return nil }
          inflight.insert(path)
          Task.detached(priority: .userInitiated) { [weak self] in
              let img = NSImage(contentsOfFile: path)
              await self?.store(path: path, image: img)
          }
          return nil
      }

      private func store(path: String, image: NSImage?) {
          inflight.remove(path)
          guard let image else { return }
          let cost = Int(image.size.width * image.size.height * 4)  // rough bytes
          cache.setObject(image, forKey: path as NSString, cost: cost)
          revision &+= 1
      }
  }
  ```

- [ ] **Step 3: Replace `imageBubble` and `stickerBubble`**

  In `MessageRow.swift`:

  ```swift
  @ViewBuilder
  private func imageBubble(path: String?) -> some View {
      let cache = ThumbnailCache.shared
      _ = cache.revision  // subscribe to cache invalidations
      if let p = path, let img = cache.image(forPath: p) {
          Image(nsImage: img)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: 320, maxHeight: 240)
              .clipShape(.rect(cornerRadius: 8))
              .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
      } else if path != nil {
          // Path known, decoding in flight — show a placeholder same size as
          // the bubble so the layout doesn't jump on arrival.
          RoundedRectangle(cornerRadius: 8)
              .fill(Theme.textMuted.opacity(0.15))
              .frame(maxWidth: 320, maxHeight: 240)
      } else {
          downloadingPlaceholder("photo")
      }
  }

  @ViewBuilder
  private func stickerBubble(path: String?) -> some View {
      let cache = ThumbnailCache.shared
      _ = cache.revision
      if let p = path, let img = cache.image(forPath: p) {
          Image(nsImage: img)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: 160, maxHeight: 160)
      } else if path != nil {
          RoundedRectangle(cornerRadius: 8)
              .fill(Theme.textMuted.opacity(0.1))
              .frame(maxWidth: 160, maxHeight: 160)
      } else {
          downloadingPlaceholder("face.smiling")
      }
  }
  ```

- [ ] **Step 4: Build + smoke**

  Scroll through a chat with many images and stickers; confirm first paint shows a brief placeholder then resolves, and subsequent scrolls of the same row are instant. Open `Instruments → Time Profiler` briefly if available to verify `NSImage(contentsOfFile:)` no longer dominates the SwiftUI body samples.

- [ ] **Step 5: Commit**

  ```bash
  git add yawac/Services/ThumbnailCache.swift yawac/Views/MessageRow.swift
  git commit -m "perf(ui): async thumbnail cache for image+sticker bubbles

  Replace inline NSImage(contentsOfFile:) in MessageRow with an
  NSCache-backed ThumbnailCache. Body reads the cache; misses kick
  a background decode + invalidation. Eliminates per-scroll re-decode.

  Codex audit finding F4 (high)."
  ```

---

## Task F5 — Move ChatListViewModel cold-start work off MainActor

**Severity:** High. `ChatListViewModel.init` calls `loadChats()` synchronously. `loadChats` runs a `FetchDescriptor<PersistedChat>` and `SQLiteDedupe.latestMessagePerChat()` (full message-table scan) on MainActor before the first sidebar paint.

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift:18-22, 101-258`
- Touch (doc only): `yawac/Services/SQLiteDedupe.swift:80-129` (no functional change — already safe to call off-main)

### Design

Build a `ChatListBootstrap` snapshot off the main actor (mirror of F2 pattern), then publish to `chats` in one MainActor commit. While bootstrap is in flight, sidebar shows an empty state or a `ProgressView`.

### Steps

- [ ] **Step 1: Extract bootstrap into a `nonisolated static` builder**

  Add to `ChatListViewModel.swift`:

  ```swift
  struct ChatListBootstrap: Sendable {
      let chats: [Chat]
      let keepers: [String: PersistedChat.Snapshot]  // see step 2
      let deleteIDs: [PersistentIdentifier]
  }

  nonisolated static func buildBootstrap(
      container: ModelContainer,
      tombstones: Set<String>,
      mentionResolver: @Sendable (String) -> String
  ) -> ChatListBootstrap {
      let context = ModelContext(container)
      // [Copy loadChats:103-194 logic verbatim; substitute self.session?.displayName
      //  with the mentionResolver closure for previews; collect IDs of duplicate
      //  rows to delete on the main context (SwiftData refuses to persist
      //  deletes from a background context for this store — see SQLiteDedupe
      //  rationale comments).]
      // ...
      return .init(chats: chats, keepers: keepersSnapshot, deleteIDs: deleteIDs)
  }
  ```

  `PersistedChat.Snapshot` is a small `Sendable` struct holding the fields the eventual `chats` build needs (jid, name, lastTimestamp, lastMessageText, unread, isCommunityParent, communityParentJID, isDefaultSubGroup, pinnedAt, archivedAt, mutedUntil, groupDescription). Define alongside `PersistedChat` or in this file.

- [ ] **Step 2: Defer load in `init`**

  ```swift
  init(client: WAClient?, context: ModelContext? = nil) {
      self.client = client
      self.context = context
      // Sidebar shows empty state until snapshot lands.
      self.bootstrapping = true
      Task { [weak self] in
          await self?.runBootstrap()
      }
  }

  @ObservationIgnored private(set) var bootstrapping: Bool = false

  private func runBootstrap() async {
      guard let container = context?.container else {
          bootstrapping = false
          return
      }
      let tombstones = Set(deletedChats.keys)
      let resolver: @Sendable (String) -> String = { [weak session] jid in
          session?.displayName(for: jid) ?? jid
      }
      let snap = await Task.detached(priority: .userInitiated) {
          Self.buildBootstrap(container: container,
                              tombstones: tombstones,
                              mentionResolver: resolver)
      }.value
      await MainActor.run {
          self.chats = snap.chats
          self.bootstrapping = false
          // Apply deletes on the main context (SwiftData persistence quirk).
          if let context = self.context {
              for id in snap.deleteIDs {
                  if let row = context.model(for: id) as? PersistedChat {
                      context.delete(row)
                  }
              }
              try? context.save()
          }
      }
  }
  ```

- [ ] **Step 3: Sidebar empty/loading state**

  In `ContentView.swift` or the sidebar view, render a `ProgressView()` while `chatListVM.bootstrapping == true && chatListVM.chats.isEmpty`. Keep the rest of the sidebar UI untouched.

- [ ] **Step 4: Build + smoke**

  Cold-launch yawac. Confirm:
  - App window paints within ~250ms (vs current ~few seconds on big stores).
  - Sidebar shows ProgressView briefly, then snaps to the full chat list.
  - No duplicate-chat regression (the same in-memory dedupe still happens during bootstrap).
  - Tombstoned chats remain hidden.

- [ ] **Step 5: Commit**

  ```bash
  git add yawac/ViewModels/ChatListViewModel.swift
  git commit -m "perf(chatlist): bootstrap off MainActor on cold start

  Move loadChats's SwiftData scan + raw SQLiteDedupe aggregation
  off MainActor into a Task.detached. Sidebar shows a ProgressView
  while the snapshot builds; one MainActor commit publishes chats.

  Codex audit finding F5 (high)."
  ```

---

## Task F6 — Gate MessageIndex.forceRebootstrap on real state change

**Severity:** Medium. `SessionViewModel.handle(.connected)` (`SessionViewModel.swift:525-530`) triggers `MessageIndex.shared.forceRebootstrap()` on the first `.connected` per session, but the *trigger condition* is `didRebootstrapMessageIndex == false` (always true on first connect). The rebootstrap deletes every `MessageFTS` row and re-walks `ZPERSISTEDMESSAGE` in 1000-row pages.

The intent (per the inline comment) is to fix the case where the setters (own JID, canonicalizer) arrive too late for the initial bootstrap. We should only rebuild when the inputs have actually changed since the last full bootstrap.

**Files:**
- Modify: `yawac/Services/MessageIndex.swift:415-477`
- Modify: `yawac/ViewModels/SessionViewModel.swift:525-530`

### Design

Stash a fingerprint of `{ownPushName, ownBareJID, canonicalizerVersion}` after each successful full bootstrap. On `.connected`, compute the current fingerprint and only call `forceRebootstrap` if it differs.

For canonicalizer version: the canonicalizer is currently captured as a closure with no version. Add a static counter or a one-line version constant in `JIDNormalize` that we bump on every behavior change (and embed in the fingerprint as a string).

### Steps

- [ ] **Step 1: Write a failing test**

  `yawacTests/MessageIndexBootstrapGateTests.swift`: simulate two consecutive `.connected` events with identical fingerprint; assert `forceRebootstrap` only runs once. Skip if no test target — verify by perfLog.

- [ ] **Step 2: Add fingerprint state to `MessageIndex`**

  ```swift
  private static let bootstrapFingerprintKey = "yawac.MessageIndex.lastBootstrapFingerprint"

  func currentFingerprint() -> String {
      let pn  = ownPushName ?? ""
      let jid = ownBareJID  ?? ""
      let ver = JIDNormalize.canonicalVersion
      return "\(ver)|\(pn)|\(jid)"
  }

  func rebootstrapIfFingerprintChanged() async {
      let fp = currentFingerprint()
      let last = UserDefaults.standard.string(forKey: Self.bootstrapFingerprintKey)
      guard fp != last else { return }
      await forceRebootstrap()
      UserDefaults.standard.set(fp, forKey: Self.bootstrapFingerprintKey)
  }
  ```

  Add `static let canonicalVersion = "2026-06-07-v1"` to `JIDNormalize`. Bump the date whenever canonical logic changes (track manually).

- [ ] **Step 3: Use the gated call in `SessionViewModel`**

  Replace `SessionViewModel.swift:525-530`:

  ```swift
  if !didRebootstrapMessageIndex {
      didRebootstrapMessageIndex = true
      Task.detached(priority: .utility) {
          await MessageIndex.shared.rebootstrapIfFingerprintChanged()
      }
  }
  ```

- [ ] **Step 4: Build + smoke**

  Launch twice in a row without changing accounts. After the second launch's `.connected`, confirm in the unified log (filter `category:bootstrap` if present, or grep for `runBootstrap` calls) that the second session does **not** call `forceRebootstrap`. Sign out + back in: confirm fingerprint changes and rebootstrap runs.

- [ ] **Step 5: Commit**

  ```bash
  git add yawac/Services/MessageIndex.swift yawac/ViewModels/SessionViewModel.swift
  git commit -m "perf(fts): gate forceRebootstrap on fingerprint change

  Stash {canonicalVersion, ownPushName, ownBareJID} after each full
  bootstrap. On .connected, only rebuild MessageFTS if the
  fingerprint differs from the persisted value. Avoids deleting
  + repopulating the entire FTS table on every reconnect.

  Codex audit finding F6 (medium)."
  ```

---

## Task F7 — Cache sectioned timeline in ConversationViewModel

**Severity:** Medium. `ConversationView.swift:73-77` recomputes `messageRevisionToken` by reducing all messages on every body eval. `:89-105` rebuilds the entire `[TimelineItem]` array from scratch before feeding `ForEach`.

**Files:**
- Modify: `yawac/Views/ConversationView.swift:73-105, 416`
- Modify: `yawac/ViewModels/ConversationViewModel.swift` (add cached state)

### Design

Move `timeline()` into the view model as an `@Observable` cached array. The cache rebuilds only when one of the inputs (`messages`, `localPaths.count`, starred count) genuinely changes. Use `didSet` on `messages` to invalidate; for cheap incremental rebuilds use a sentinel that the view reads.

`messageRevisionToken` is consumed by `ChatInfoView` only — change the contract to read the cached array's count or a generation number, also stored on the VM.

### Steps

- [ ] **Step 1: Add cache to ConversationViewModel**

  ```swift
  /// Cached date-sectioned timeline. Built lazily; invalidated by
  /// `bumpTimelineGeneration()` whenever inputs change (messages,
  /// localPaths, starred set).
  @ObservationIgnored private var cachedTimeline: [TimelineItem] = []
  @ObservationIgnored private var cachedTimelineGen: Int = -1
  /// Bumped whenever any input that timeline cares about changes.
  private(set) var timelineGeneration: Int = 0

  func timeline() -> [TimelineItem] {
      if cachedTimelineGen == timelineGeneration {
          return cachedTimeline
      }
      let cal = Calendar.current
      var out: [TimelineItem] = []
      out.reserveCapacity(messages.count + 32)
      var lastDay: DateComponents?
      for m in messages {
          let day = cal.dateComponents([.year, .month, .day], from: m.timestamp)
          if day != lastDay {
              if let header = cal.date(from: day) {
                  out.append(.dateHeader(header))
              }
              lastDay = day
          }
          out.append(.message(m))
      }
      cachedTimeline = out
      cachedTimelineGen = timelineGeneration
      return out
  }

  func invalidateTimeline() {
      timelineGeneration &+= 1
  }
  ```

- [ ] **Step 2: Invalidate on real state changes**

  Sites that mutate `messages`, `localPaths`, or starred state:
  - `applyHistorySnapshot` (from F2) — at end, call `invalidateTimeline()`.
  - `loadEarlier` (background version, F2) — same.
  - Inbound message arrival (existing `handle(_:)` patch site) — call after insertion.
  - Star / unstar (`starMessage`) — call after.
  - Download completion (`localPaths[id] = path`) — call after.
  - Reaction / revoke / edit handlers — call after.

  Audit all `self.messages.append`, `self.messages.insert`, `self.messages[i] = ...`, `self.localPaths[id] = ...`, and `m.starredAt = ...` sites in `ConversationViewModel.swift` and add the `invalidateTimeline()` call. (A handful of sites.)

- [ ] **Step 3: View consumes the cached timeline**

  In `ConversationView.swift:73-77`, replace `messageRevisionToken` with the VM's generation:

  ```swift
  private var messageRevisionToken: Int {
      vm?.timelineGeneration ?? 0
  }
  ```

  At `:89-105`, remove the local `timeline()` function; call `vm.timeline()` instead at `:416`:

  ```swift
  ForEach(vm.timeline()) { item in
      // ... unchanged ...
  }
  ```

- [ ] **Step 4: Build + smoke**

  Open a large chat. Confirm:
  - Scrolling does not trigger timeline rebuilds (set a breakpoint in `timeline()`'s rebuild branch; it should not fire during scroll).
  - Sending a message updates the list with one rebuild.
  - Date headers still appear correctly.
  - `ChatInfoView` media/files panel still refreshes when downloads complete.

- [ ] **Step 5: Commit**

  ```bash
  git add yawac/Views/ConversationView.swift yawac/ViewModels/ConversationViewModel.swift
  git commit -m "perf(ui): cache sectioned timeline in ConversationViewModel

  timeline() now returns a cached [TimelineItem] keyed by a
  generation counter that is bumped only when messages /
  localPaths / starred state actually change. Removes the O(n)
  rebuild that ran on every ConversationView body evaluation.

  Codex audit finding F7 (medium)."
  ```

---

## After all tasks

- [ ] **Verify the whole release in one pass**

  - `xcodebuild test -scheme yawac -destination 'platform=macOS'` (if test target exists)
  - Launch, log in with the heaviest paired account available, exercise: cold start, chat switching across 10 chats, scrolling back in a large chat, sending a message, receiving a media message, search via `⌘F` and `⌘K`.
  - Capture before/after perfLog summaries from `Console.app` (filter `subsystem:com.yawac.perf`) and paste into the release notes.

- [ ] **Bump version**

  - `yawac/Resources/Info.plist`: bump `CFBundleShortVersionString` to next minor (e.g. `0.9.30`).
  - `docs/ROADMAP.md`: add a Shipped entry summarising the seven perf fixes and referencing this plan.
  - `docs/superpowers/specs/`: no spec needed (perf fixes); link this plan from ROADMAP.

- [ ] **Final release commit**

  ```bash
  git commit -m "release: 0.9.30 — perf audit landings (F1–F7)"
  ```

---

## Self-Review Notes

**Spec coverage:** Each Codex finding (F1–F7) has a task; no findings dropped.

**Type consistency:**
- `ConversationHistorySnapshot` (F2) — used only by `loadHistory` apply path; types match `ConversationViewModel` properties.
- `MessageWriter.WriteOutcome` (F3) — surface matches `ChatListViewModel.applyChatRowUpdate`.
- `ChatListBootstrap.Snapshot` (F5) — define alongside `PersistedChat`; ensure fields match the `Chat` row build in `loadChats`.
- `JIDNormalize.canonicalVersion` (F6) — string constant; tracked manually.

**Placeholder scan:** All steps contain runnable code or concrete commands. No "TBD", "implement later", or "similar to Task N". The few `// [Copy ... from line N]` markers reference precise line ranges in the current tree and the engineer can paste verbatim.

**Risk notes:**
- F1 changes the threading model used by every subscriber. Audit all `for await event in stream` sites before landing.
- F3 changes write-path ordering — bursts now flush 50ms later than today. If any code path expects same-runloop persistence after `ingest` returns, it will break. The existing `dirtyChatJIDs` debounce is already async, so this is consistent.
- F5 sidebar empty state must not regress the cold-start "select first chat" flow. If `SessionViewModel` auto-selects a chat at startup, the selection logic must wait for `bootstrapping == false`.
- F6 fingerprint string format will reset on first deploy — that's expected (one final rebootstrap, then never again unless inputs change).
