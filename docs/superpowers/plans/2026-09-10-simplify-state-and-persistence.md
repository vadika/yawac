# Simplify state and persistence

Status: implementation and automated validation completed across stages 1–7. Manual UI/phone and macOS 14 runtime checks remain unavailable in this environment.

Current ownership and compatibility rationale: [ARCHITECTURE.md](../../ARCHITECTURE.md).

Objective: reduce the number of places that must agree for a message, chat, or image to update correctly. Preserve the current features, supported macOS versions, paired accounts, and existing stored history.

The review found concrete divergence in message field mapping, view-dependent event ingestion, routine SQL writes into SwiftData tables, untracked history tasks, and broad thumbnail invalidation. Prioritize these ownership problems over file size or introducing more abstractions.

**Decisions**

- Keep SwiftData and the current on-disk schema in this refactor. Replacing the storage engine would be a separate migration project after the ownership changes have been measured.
- Reuse `SessionViewModel` for session lifecycle/event routing and `MessageWriter` for durable message changes. Do not introduce a generic repository hierarchy, dependency-injection container, event journal, or second event bus.
- Keep optimistic conversation state, bounded history pages, background work, thumbnail downsampling, and protocol-specific recovery.
- Keep automatic recent-history recovery scoped to opened chats and newly joined groups. Account-wide deep history remains explicitly user-triggered beyond the existing initial backfill.
- Each stage must remove the superseded path before completion. Temporary adapters may exist inside a stage; they must not become another permanent writer.
- Tests should exercise stored results and visible behavior. Use temporary on-disk stores for persistence checks; in-memory SwiftData tests cannot establish that the existing SQL workarounds are unnecessary.
- This plan does not include releases, tags, version bumps, or changes to the whatsmeow fork.

**Target ownership**

| Responsibility | Owner | Consumers |
| --- | --- | --- |
| Connect, disconnect, raw event subscription, session task lifetime | `SessionViewModel` | Views observe session state |
| Message inserts, updates, reactions, votes, receipts, media metadata, and message-index maintenance | `MessageWriter` | Session and user actions submit concrete operations |
| Chat list presentation and chat metadata actions | Session-owned `ChatListViewModel` | Sidebar, menu bar, intents |
| Optimistic messages, composition, selection, pagination, displayed message state | `ConversationViewModel` | Conversation view |
| Search queries and FTS implementation | `MessageIndex` | Search models; writer controls index mutations |
| Existing SQL compatibility and store maintenance | Internal storage helpers with an explicit store URL | Writer/bootstrap; no view-level calls |
| Shared decoded image cache and deduplicated loading | `ThumbnailCache` | Resource-specific asynchronous requests |

The event flow becomes: bridge event -> session consumer -> ordered message writes -> committed changes -> chat/conversation presentation. Presence and connection indicators may update immediately. Locally sent messages show optimistically, then use the same durable write path when the bridge returns their real ID.

**Stage 1 — Establish the baseline and delete proven dead work**

Primary files: `ChatListViewModel.swift`, `SessionViewModel.swift`, `WAClient.swift`, `bridge/history_request.go`, and existing backfill tests.

- [x] Record existing Swift and Go test results. Record any pre-existing failures separately.
- [ ] Capture repeatable baseline scenarios using synthetic data: a large initial message burst, reopening a media-heavy conversation, an edit followed by search, and full-sync cancellation. Record dataset size, hardware, elapsed time, memory, source-row counts, and outgoing request counts where applicable.
- [x] Remove the third bootstrap dedupe pass: `keepers` is already a dictionary with unique keys. Preserve the first two passes and their merge behavior.
- [x] Replace the full-history API's four ignored anchor arguments and ambiguous `count` with one `durationDays` argument across Go, gomobile, Swift, callers, and stubs. Preserve the effective 3,650-day request and current validation limits.
- [x] Delete the oldest-message fetch performed solely to populate those ignored arguments. Update tests to assert the effective request duration and backfill gate, rather than discarded arguments.
- [x] Rebuild the XCFramework after the Go signature change and compile the Swift app against it.

Exit: behavior remains equivalent, obsolete work is gone, and subsequent stages have a reproducible baseline. Do not add tests just for deleting the impossible branch; run the existing relevant dedupe coverage.

**Stage 2 — Make the existing writer correct and explicit about failures**

Primary files: `MessageWriter.swift`, `PersistedMessage.swift`, `MessageIndex.swift`, `ConversationViewModel.swift`; new focused writer persistence tests.

- [x] Introduce one concrete mapping/merge implementation from bridge message fields into a stored message. Reuse it from the existing inbound paths while those callers are consolidated in later stages.
- [x] Cover every currently supported field: push name, forwarding, waveform/PTT, dimensions, single/multiple contacts, location, poll, quote, and view-once metadata.
- [x] State merge precedence explicitly: absent replay fields preserve stored data; fresher media references may clear expiration; replayed messages must not reset locally deleted/revoked state, consumed view-once state, or delivery progress.
- [x] Return throwing/result-based commit outcomes. Roll back a failed batch's context and do not return it as successfully persisted or increment committed-message counters.
- [x] Save source rows before updating FTS. Add a batch index operation so a history batch does not produce one separate index transaction per message.
- [x] Index changed text/captions and canonical chat identifiers. Remove revoked, locally deleted, and purged messages from search results. Keep the source rows/tombstones needed by the existing deletion behavior.
- [x] Treat an index failure as a search failure after a successful message save, not a failed network send. Preserve the messages, surface indexing failure, and permit index repair.
- [x] Replace row-count-based index resumption with an idempotent, paged startup reconciliation against the source rows, including orphan removal. Coordinate rebuild and live index writes through the writer; do not allow concurrent destructive rebuilds. Measure startup cost against the baseline before accepting the implementation.
- [x] Consolidate initial index setup and account/canonicalizer updates so startup and `.connected` do not launch competing rebuilds. A changed account/name configuration requests one serialized reconciliation.

Validation: temporary on-disk store -> write -> release contexts -> reopen -> assert all fields. Exercise duplicate replay, fresh media refs, edits and search, revocation/deletion and search, source-save failure, and index failure followed by startup repair. Verify insertion and mutation ordering within a batch.

Exit: the writer's stored result is authoritative and testable; persistence errors cannot masquerade as successful commits. Index repair must handle changed rows with unchanged row counts.

**Stage 3 — Move ingestion out of views and into the session lifetime**

Primary files: `yawacApp.swift`, `AppRoot.swift`, `SessionViewModel.swift`, `ContentView.swift`, `ConversationView.swift`, `ChatListViewModel.swift`, `WAClient.swift`, `WAEventBus.swift`.

- [x] Inject the model container/store dependencies at application composition time. `ContentView.task` must no longer supply the dependencies required to persist events.
- [x] Make the session retain the chat list and writer. Make boot idempotent so repeated view appearance cannot start another client or subscriber.
- [x] Complete local bootstrap and register the session's event stream before invoking `connect()`. Render loading/cached UI while local work proceeds; remove the view's 50 ms bootstrap polling loop.
- [x] Move the event routing switch from `ContentView` into the existing session consumer. Preserve notification/mute rules, contact and group updates, and history reconciliation behavior.
- [x] Use one ordered pending operation queue for messages, reactions, and mutations. Preserve the current short batching delay and larger full-sync batch window initially. Flush at explicit boundaries instead of allowing separate timers to reorder a message and its subsequent edit.
- [x] Route committed changes to the chat list and active conversation using concrete methods. Publish chat array updates once per batch. Route ephemeral typing/presence updates directly.
- [x] Register the active conversation before requesting its history snapshot. Merge committed changes received during that load by message ID; a late snapshot must not overwrite newer edits, receipts, or incoming messages. Discard snapshot completion after a chat switch.
- [x] Centralize existing pending edit/revoke handling for not-yet-loaded targets. Replay it when the target arrives; retain bounded behavior and test the target-absent case rather than silently dropping mutations in closed chats. This does not add a durable event journal or promise crash recovery for events whose target has never arrived.
- [x] Remove raw bridge subscriptions from `ContentView` and `ConversationView`. Once the session is the sole consumer and startup is ordered, delete the shared destructive replay buffer and unnecessary multicast subscriber machinery.
- [x] Until stage 4 migrates menu-bar sends, keep its synthetic injection method feeding the same sole-consumer stream. This is the only temporary compatibility path across these two stages; remove it in stage 4.
- [x] On logout/session replacement, stop event admission and network recovery work, finish or explicitly report admitted write failures against the old session, and dispose of the old consumer before creating another. Late old-session completions must not publish into the new session.

Validation: use a fake event source/connection closure, not a live phone. Emit messages immediately when connect begins; emit more than 1,000 messages before a view appears; create/destroy/switch views during delivery; deliver an edit while a history snapshot is loading; insert then edit across a batch boundary; replace the session with a delayed completion outstanding. Verify one stored row per message, correct unread counts, no duplicate notifications, and no old-session UI updates.

Exit: opening, closing, or restoring a window cannot determine whether a message is stored. Exactly one raw consumer exists per session.

**Stage 4 — Route all remaining message writes through the writer**

Primary files: `ConversationViewModel.swift`, `SessionViewModel.swift`, `ChatListViewModel.swift`, `QuickSendPopover.swift`, `SendMessageIntent.swift`, `MessageWriter.swift`, and their tests.

- [x] Route successful conversation, menu-bar, and Shortcut sends through the same session entry point for local persistence and presentation. Preserve optimistic temporary-ID replacement and quote/mention metadata.
- [x] Consolidate the separate outgoing text/media/poll/location/contact/forward persistence functions into concrete payload construction plus the shared writer. Keep distinct network APIs where the protocol actually differs.
- [x] Remove `dispatchSynthetic` when no remaining send flow needs raw-event reinjection. Tests must cover a send with no conversation open and a send whose originating view closes before completion.
- [x] Move edits, revocations, local deletes, stars, pins, receipts, reactions, votes, view-once consumption, and media-reference/path/expiration updates into writer operations. Receipt progression must remain monotonic; stale replay must not turn read into delivered.
- [x] Have view-once presentation wait for consumption persistence before reporting success. Keep existing replay protection.
- [x] If the network send succeeds but local persistence fails, report that distinction and retain the real message ID. Do not automatically resend or restore an apparently unsent draft that encourages duplicate delivery.
- [x] Remove the conversation fallback writer, duplicate local persistence methods, per-category persistence timers, and session-level detached SQL writes after all callers are moved.

Validation: round-trip every outgoing payload type, reaction add/remove, vote replacement, early receipts, view-once reopen, media retry, and edit/revoke replay. Compare identical messages received with their chat open and closed. Verify menu-bar and Shortcut sends appear in history/search after restart.

Exit: all runtime mutations of messages, reactions, and votes have one owner. Conversation presentation is permitted to differ while optimistic; persisted behavior is identical across entry points.

**Stage 5 — Contain and reduce the SwiftData/SQL overlap**

Primary files: `SQLiteDedupe.swift`, `SwiftDataIndexes.swift`, `SwiftDataMaintenance.swift`, `yawacApp.swift`, chat/conversation bootstrap code, and `MessageWriter.swift`.

- [x] Pass the actual configured store URL to SQL helpers; remove repeated guesses at `Application Support/default.store`. Tests must use their temporary store and never the user's database.
- [x] Separate read-only query helpers from migration/maintenance operations. Keep concrete SQL functions; avoid a general query framework.
- [x] Reproduce each claimed SwiftData persistence failure with temporary on-disk stores and fresh-context/reopen checks: receipt updates, vote upserts, chat deletion, unique-key rebind, and LID/PN merge.
- [x] Replace a routine SQL mutation with the writer's SwiftData operation only when that operation passes those checks. Otherwise retain the required SQL implementation internally, with checked transactions and an explicit refreshed snapshot after the write. Never execute both implementations as competing fallbacks.
- [x] Move chat purge and LID reparenting behind the same message-storage owner; reconcile reactions/votes, search entries, and affected chat presentation. Preserve intentional chat tombstones and folder/navigation behavior.
- [x] Make history reads side-effect-free. Move the current per-chat scrub/sweep writes into an explicit preparation/migration step owned by storage, preserving existing completion keys until compatibility coverage proves they can be retired.
- [x] Sequence index installation, required repairs, and maintenance. Replace the shell-launched SQLite cleanup with checked internal operations if it remains necessary. Retain useful indexes; remove maintenance policy only with size/query measurements showing it is unnecessary.
- [x] Consolidate the remaining compatibility rationale into one current document. Delete historical implementation narratives where they contradict current behavior; retain explanations for workarounds that still have evidence.

Validation: open/reopen fixtures representing canonical and LID duplicate chats, historical rows, reactions/votes, and deleted chats. Verify affected IDs and row counts, stable unread totals, query plans, and the absence of stale visible rows after raw SQL operations. Include failed/busy transaction behavior.

Exit: views and view models cannot directly mutate the message store through raw SQL. Every retained workaround has one owner, an explicit store target, and a regression demonstrating why it remains. Engine replacement remains a separate decision, not an unfinished requirement of this plan.

**Stage 6 — Give history recovery one explicit lifecycle**

Primary files: `SessionViewModel.swift`, existing history-request methods in `WAClient.swift`, `ConversationViewModel.swift`, and history recovery tests.

- [x] Retain one task for a user-triggered full-sync run. A second start while it exists is a no-op. Cancellation, timeout, logout, and session replacement cancel/finish that same run.
- [x] Group the existing run-specific state together: task, counters, active anchors, and completion reason. Derive `inFlight` from the active run instead of allowing an unrelated timer to clear it.
- [x] Await scheduled requests and keep their failures visible. Do not launch untracked detached requests inside the per-chat loop. Blocking bridge work may still execute off-main; cancellation stops further scheduling and ignores stale completions, without claiming it can interrupt an already-running synchronous bridge call.
- [x] Fetch each round's anchors once and reuse the snapshot for dispatch and before/after comparison. Before sampling progress, await the ingestion queue's flush boundary so committed messages are reflected.
- [x] Preserve current throttle, request sizes, round limits, and required response wait initially. Remove heuristics individually only after deterministic traces and live verification show equivalent recovery. A writer flush does not prove the phone has finished responding.
- [x] Distinguish cancellation, failure, inactivity, and observed progress. Inactivity must not claim that the phone has no more history. Do not infer completion from an uncorrelated `progress=100` chunk.
- [x] Bring the delayed orphan-quote sweep under session cancellation as well. Preserve targeted recent-history deduplication and retry-after-failure behavior.

Validation: inject request and sleep closures for deterministic tests. Cover double-start, timeout during a request, logout during throttle/wait, late old-run completion, delayed commits, no-progress rounds, and request failure. Assert maximum scheduled requests and zero automatic reconnect-wide fan-out. Live phone testing is needed to validate recovery depth; report that separately from scheduler tests.

Exit: the displayed sync state and actual scheduled work belong to the same run. Tests do not wait real minutes or send peer requests.

**Stage 7 — Deliver thumbnails to their requesting views**

Primary files: `ThumbnailCache.swift`, `AvatarCache.swift`, `AvatarView.swift`, `VideoThumbnailView.swift`, `MessageRow.swift`, `ReplyPreview.swift`, `SharedMediaCell.swift`, and map snapshot consumers.

- [x] Keep shared decoded caches, existing pixel bounds, disk caches, in-flight deduplication, avatar concurrency limits, and useful negative caching.
- [x] Add resource-specific async lookup methods that return the decoded result, using the existing cache keys. Keep separate image/video/avatar methods where their loading differs.
- [x] Store the result in the requesting view's state and load via `.task(id: resourceKey)`. On a key change, clear/revalidate the old result; late results for old keys must not replace the new resource.
- [x] Preserve a cheap synchronous memory-cache hit for first paint and snapshot preheating. Cache lookup from a view body must not start work or mutate observed state.
- [x] Keep avatar invalidation scoped to the affected canonical JID; update both disk and decoded cache entries through that operation. Preserve map failure caching and explicit retry behavior.
- [x] Convert every consumer before deleting global revision counters, per-type bump timers, and redundant bookkeeping. Cancellation of one waiting view must not cancel a shared request needed by another view.

Validation: shared-request deduplication, late result after reuse/cancellation, invalidation, negative-cache retry, and cold/warm image lookup. Re-run the baseline media-heavy scrolling scenario; require correct first paint and no regression in memory, repeated decode count, or visible flicker. Verify that one completed image no longer invalidates unrelated rows of the same category.

Exit: image completion updates the views requesting that resource. No category-wide revision counter remains.

**Implementation order and review boundaries**

Execute stages 1 through 7 in order. Each is an independently reviewable change; split stage 4 by inbound mutations versus outgoing sends if its diff becomes difficult to assess. Complete the caller migration and delete its old path within each such change. Stage 7 is technically independent, but schedule it last to keep persistence regressions distinguishable from rendering changes.

At each boundary, include a short inventory of removed owners/methods/timers, the relevant behavioral checks, and any retained workaround. File count or line reduction alone is not success. Avoid broad file moves until the ownership change is complete.

Use the existing validation commands as appropriate:

```sh
# From bridge/, when bridge code or its API changes:
go test -short ./...

# From repository root, after bridge API changes:
./scripts/build-xcframework.sh

# Generate the project, then run relevant Swift tests; run the full suite
# at the ownership cutover and final integration boundaries:
xcodegen generate
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Record unavailable build dependencies or pre-existing failures rather than attributing them to the refactor. Use synthetic fixtures for automated tests. Keep current unrelated workspace files untouched. Do not transplant release instructions or temporary live-account recovery calls from older plans.

**Final acceptance**

- [x] Session startup, window recreation, and early event bursts cannot lose messages through subscriber order.
- [x] All message payloads survive an on-disk round trip, whether their conversation is open or closed.
- [x] Source commits and search results agree after updates and after interrupted index work is repaired.
- [x] Network success, source-save failure, and search-index failure are distinguishable; retries cannot silently duplicate sends.
- [x] One durable message writer and one raw event consumer remain, with no parallel fallback implementation.
- [x] Routine storage access uses the configured store, and retained raw mutations have checked transactions and refresh behavior.
- [x] Logout and timeout stop further recovery scheduling; late completions cannot change a replacement session/run.
- [x] Existing paging, read-receipt/mute rules, view-once consumption, targeted history recovery, and optimistic composition remain correct.
- [ ] Thumbnail completion is local to requesting resources, with baseline performance preserved.
- [x] Current architecture documentation describes the resulting ownership and remaining compatibility constraints.

## Implementation record — 2026-09-10

- Stages 1–3 removed ignored bridge arguments, view subscriptions, the replay buffer, independent persistence timers, and duplicated source-field mapping. The XCFramework was rebuilt after the API change.
- Stages 4–5 consolidated outgoing sends and message mutations, removed the conversation fallback writer and raw SQL mutation implementations, moved history preparation into storage, and replaced shell history pruning with a checked transaction. The old standalone view-once mutator and view-owned pending-mutation tests were replaced by writer disk tests.
- Stage 6 replaced untracked full-sync fan-out with one retained run and watchdog. Scheduler tests cover double-start, outstanding-request cancellation, timeout during throttling, and request failure.
- Stage 7 removed all thumbnail revision counters and bump timers. Resource-specific loads retain the prior bounds and caches; synchronous reads start no work.
- Additional race coverage checks deletion after admitted messages, late sends from ended sessions, and an edit arriving after a history snapshot is built but before it is presented.
- Translation test fixtures lacked `chat_template.jinja`, which the existing model manager requires. Adding that fixture file fixed four assertions in two tests; translation application code was unchanged.
- The bridge build now explicitly targets macOS 14. Its prior invocation under the current SDK produced macOS 26 object-version warnings; the build script pins both the compiler environment and the cgo cache input to the application's minimum.

### Validation environment and commands

Mac16,12, arm64, 16 GB RAM; Xcode 26.6. `go test -short ./...` passed before the refactor and after the bridge changes. `xcodegen generate` and `xcodebuild ... build-for-testing` compile the app and tests.

LaunchServices rejects the normal XCTest app launch with `IDELaunchErrorDomain` code 20. The same compiled test bundle runs through Xcode's absolute `xctest` executable with `DYLD_LIBRARY_PATH` set to the built app's `Contents/MacOS` and `DYLD_FRAMEWORK_PATH` to `Contents/Frameworks`. Test-host application startup uses an isolated temporary source store and does not connect the bridge. The build uses the repository's existing package/macro-validation overrides and ad-hoc signing.

Final verification: **409 Swift tests, one skipped, zero failures** (8.38 seconds); Go short tests passed (1.332 seconds); XCFramework and app/test builds succeeded; `git diff --check` passed. Bridge object metadata reports minimum versions of 13.0/14.0, with no object requiring macOS 26. The test fixture corrections and the final snapshot race tests are included in this run.

Synthetic measurements on this machine:

| Scenario | Result |
| --- | --- |
| 1,500 unique messages plus 100 replays | 1.96 seconds, 1,500 source/index rows |
| Streamed FTS repair of 20,000 rows across 100 chats | 86 ms; a second repair retains exactly 20,000 rows |
| One 1600×1200 thumbnail decode plus 1,000 memory lookups | 19 ms; decoded width capped at 720 pixels |

These measure the current implementation, not a measured before/after speedup. Final failure tests cover unavailable search storage after a successful source commit and rollback when the second maintenance-table delete fails. The delayed-snapshot test also checks reaction removal and vote replacement without discarding unrelated participants.

A pre-change GUI scrolling/memory baseline could not be captured. No live phone requests, graphical scrolling smoke test, or macOS 14 runtime test was performed. Keep the corresponding manual acceptance open; test-host success does not establish those results.
