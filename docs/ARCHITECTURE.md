# State, persistence, and image loading

The app keeps SwiftData and the existing store schema. `YawacApp` creates the container with an explicit URL and injects it into `SessionViewModel`.

## Ownership

| Owner | Responsibilities |
| --- | --- |
| `SessionViewModel` | Client lifetime, the sole raw event consumer, ordered admission and batching, successful outgoing sends, history recovery tasks, delivery of committed changes |
| `MessageWriter` | Message/reaction/vote writes, receipts and media state, deletion and identifier repair, checked source commits, source-derived search updates and sidebar previews |
| `ChatListViewModel` | Sidebar values, unread/notification rules, chat metadata and navigation actions |
| `ConversationViewModel` | Composition, optimistic temporary IDs, pagination, visible receipt/reaction state, and history snapshots |
| `MessageIndex` | SQLite FTS queries, batched index transactions, and serialized reconciliation |
| `ThumbnailCache` | Bounded decoded caches and shared per-resource loading tasks |

The session prepares storage and the cached sidebar, registers its stream, and then connects the bridge. Window creation does not start or own ingestion. Messages and durable updates share one queue: normally 50 ms batches, 500 ms during full history sync. A source save must succeed before the session publishes its result. Sidebar previews come from the writer's source snapshot and are applied with the batch, rather than fetched and sorted once per message on the main actor.

## Persistence rules

`PersistedMessage.merge` is the shared incoming/outgoing field mapper. Missing replay fields preserve stored metadata. Replays cannot undo edits, revocation, local deletion, consumed view-once state, or receipt progress. Unknown-target mutations are held in memory with limits of 256 targets and 32 mutations per target. This is bounded out-of-order handling, not a durable event journal.

All send surfaces persist the server's real message ID through the session. A successful network send followed by a source-save failure reports that distinction; the conversation keeps the real ID, and quick-send clears the sent draft. No automatic resend occurs. Session shutdown closes admission, cancels recovery scheduling, and drains admitted writes. Sends completing after admission closes cannot publish or write into the replacement session.

The source save precedes the FTS transaction. Search failure is reported separately and does not turn a successful source commit into a failed send. Repair streams the source rows in a single checked transaction, replacing stale index rows and removing orphans. It does not resume by row count. Startup and account/name changes are serialized; identical account/name configuration does not rebuild twice. Repair uses streaming rather than paged materialization so memory stays bounded while readers retain the old index until commit.

View-once consumption saves the terminal lock before deleting the local media file. History snapshots merge changes committed during their load and discard completions after cancellation or replacement. A stale snapshot cannot restore consumed media paths.

## SQL compatibility and maintenance

The old parallel SQL receipt, poll-vote, chat-delete, and LID-merge writers are removed. Temporary on-disk tests exercise updates, replacement, deletion, unique-key rebinding, and dependent-row reparenting with fresh contexts and reopened containers. They do not reproduce the historical claims that those operations require a SQL fallback under the current single-writer model.

The remaining SQL is confined to explicit-store summary queries, FTS, index installation, and maintenance. History reads perform no source repairs. The writer runs the idempotent historical chat scrub/carrier cleanup before a conversation snapshot; completion markers are set only after saving. Existing completion keys are retained, with a store-specific preparation marker.

B-tree index installation remains because existing stores need those indexes without changing the SwiftData model graph. Startup maintenance retains the existing seven-day CoreData history window, `ANALYZE`, and monthly `VACUUM` policy. The two history-table deletes now run in a checked SQLite transaction rather than a shell process. Tests verify rollback if the second delete fails. Maintenance and initial search setup run before live event admission. No storage-engine migration is implied.

## History and thumbnails

One retained history run owns its worker and silence watchdog. The display derives activity from that run. Timeout or shutdown cancels the worker; an already-running synchronous bridge call may finish, but cancellation prevents another request from being scheduled. The run preserves the 30-round limit, 100 ms throttle, 200/500-message request sizes, 60-second response wait, and inactive-chat pruning. Each round reuses its anchor snapshot for requests and progress comparison, flushing admitted messages before sampling. An inactive round reports what was observed, without claiming the phone has exhausted its history. The delayed orphan-quote sweep is cancelled with the session. Automatic recent recovery remains scoped to opened chats and newly joined groups.

Thumbnail memory lookups are pure. `ResourceThumbnail` and `AvatarView` retain the result of a resource-specific `.task(id:)`; changing a resource or cancelling its view prevents stale presentation. Shared loads survive individual waiter cancellation. There are no category-wide revision counters or bump timers. Pixel bounds, cache budgets, preheating, video disk caching, avatar concurrency limits, and avatar/map negative caching remain. Avatar invalidation updates disk and decoded state once for the canonical JID; older fetches cannot reinstall stale files.

## Validation limits

The refactor is tested with synthetic fixtures, without connecting to a phone or modifying a live account. XCTest can run directly when LaunchServices cannot launch the test host. The implementation plan records commands, test counts, and measurements. Automated checks do not establish media-heavy scrolling quality on a live window, recovery depth against a phone, or runtime compatibility on an actual macOS 14 machine. Those checks remain manual.

Historical feature plans under `docs/superpowers` describe earlier implementations. This document describes current ownership and supersedes their persistence and cache-invalidation narratives.
