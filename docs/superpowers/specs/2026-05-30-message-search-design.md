# Message Search — In-Chat + Global Design Spec

**Date:** 2026-05-30
**Status:** Approved (design)
**Topic:** Ship two new features sharing one FTS5-backed index:
- **In-chat search** — Find bar inside `ConversationView` (⌘F), highlighting +
  ↑/↓ navigation.
- **Global search** — Sidebar `⌘K` field gains a "Messages" section below
  the existing "Chats" section; tapping a hit opens the chat scrolled to
  that message.

## Goal

Today the sidebar `ChatSearchViewModel` only filters chat names + JID
digits. Nothing searches message bodies. Add full-text search over message
content (`text`, `mediaCaption`, `quotedTextSnippet`, `senderPushName`) with
one shared backend that powers both an inline conversation Find bar and a
global sectioned sidebar search.

## Non-goals

- Voice transcription / image OCR search.
- Sender / date / chat-scope filters in the global UI (FTS5 supports it; UI
  defers to v2).
- Diacritic folding (e.g. `a` ↔ `ä`). Defer; revisit if EU users complain.
- Per-chat grouping in global results — flat ranked list v1.
- Filter mode (hide non-matches in conversation) — ⌘F is highlight-only.
- Search across the WhatsApp companion's own search (we drive everything
  from our local store).

## Architecture

One FTS5 virtual table `MessageFTS` lives in the same SQLite file as the
SwiftData store (`~/Library/Application
Support/default.store`). External raw connection (same style as the
existing `SQLiteDedupe`). SwiftData owns `Z*` tables; we own
`MessageFTS`; no triggers, no schema entanglement.

Three new subsystems plus two integration points:

1. **`MessageIndex` (new `Services/MessageIndex.swift`)** — owns the FTS
   table. Single point of SQL. API:
   - `bootstrapIfNeeded() async` — create table if missing; backfill if
     short.
   - `upsert(zpk: Int64, fields: MessageFields)` — write-through on
     persist.
   - `delete(zpk: Int64)` — write-through on revoke / hard-delete.
   - `searchInChat(jid: String, query: String, limit: Int) -> [Hit]`
   - `searchGlobal(query: String, limit: Int) -> [Hit]`
   - `@Observable var progress: BootstrapProgress` (indexed / total, or
     `.done`).
2. **Write-through hooks** — in every Swift-side persist path that
   creates / edits / revokes a `PersistedMessage`, call
   `MessageIndex.upsert(...)` / `.delete(...)` after the SwiftData write
   succeeds. Same call sites that today touch `SQLiteDedupe.upsertPersisted`.
3. **`MessageSearchViewModel` (new
   `ViewModels/MessageSearchViewModel.swift`)** — `@Observable` async query
   layer. Holds the most recent query string, debounced 120 ms, and the
   current result array. Two top-level functions matching the two surfaces.
   Cancels the in-flight task when a new keystroke arrives.

Integration points:

4. **In-chat: `ConversationFindBar` view** + a small `findActive` /
   `findQuery` / `findHits` / `findCurrentIdx` state group on
   `ConversationViewModel`. `MessageRow` reads a `Set<Int64>` of hit Z_PKs
   from `ConversationViewModel` and highlights matching rows.
5. **Global: `ChatSearchViewModel` extension** — gains a
   `messageHits: [MessageIndex.Hit]` property populated by an async
   refresh-on-query routine that calls `MessageIndex.searchGlobal`. Sidebar
   list renders two sections.

## Schema + indexer

### FTS5 table

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS MessageFTS USING fts5(
  text, caption, quoted, sender,
  tokenize = 'unicode61'
);
```

Rowid is `ZPERSISTEDMESSAGE.Z_PK` (Int64, stable across SwiftData
lightweight migrations). Tokenizer is the FTS5 default — case-folding yes,
diacritic-folding no.

### Write-through

`MessageFields` is a value type:

```swift
struct MessageFields {
    let zpk: Int64
    let text: String
    let caption: String
    let quoted: String
    let sender: String
}
```

`upsert`:

```sql
INSERT OR REPLACE INTO MessageFTS(rowid, text, caption, quoted, sender)
VALUES (?, ?, ?, ?, ?);
```

Empty / nil source fields persist as empty strings (FTS5 tolerates them).

`delete`:

```sql
DELETE FROM MessageFTS WHERE rowid = ?;
```

### Query

Whitespace-split the user query; for each token strip FTS5 special chars
(`* " ( ) :` ), then suffix `*` for prefix match; quote each token; join
with space (implicit AND). Empty result → short-circuit to `[]`.

**In-chat:**

```sql
SELECT m.Z_PK, m.ZTIMESTAMP,
       snippet(MessageFTS, -1, '⟦', '⟧', '…', 12)
FROM MessageFTS f
JOIN ZPERSISTEDMESSAGE m ON m.Z_PK = f.rowid
WHERE MessageFTS MATCH ?
  AND m.ZCHATJID = ?
ORDER BY m.ZTIMESTAMP ASC
LIMIT ?;
```

In-chat results are sorted by timestamp ascending so ↑/↓ nav walks the
chat in conversation order. `LIMIT` defaults to 500 (matches existing
`historyLoadLimit`).

**Global:**

```sql
SELECT m.Z_PK, m.ZCHATJID, m.ZTIMESTAMP, m.ZSENDERPUSHNAME,
       snippet(MessageFTS, -1, '⟦', '⟧', '…', 12),
       bm25(MessageFTS) AS rank
FROM MessageFTS f
JOIN ZPERSISTEDMESSAGE m ON m.Z_PK = f.rowid
WHERE MessageFTS MATCH ?
ORDER BY rank ASC, m.ZTIMESTAMP DESC
LIMIT ?;
```

Global limit defaults to 200; UI exposes "Show 50 more" for paging.

`Hit`:

```swift
struct Hit {
    let zpk: Int64
    let chatJID: String
    let timestamp: Int64
    let sender: String
    let snippet: String   // contains ⟦…⟧ markers around hit ranges
}
```

`snippet`'s `⟦…⟧` markers are rendered in the UI as bold ranges (parser is
a one-liner state machine).

### Revoked / deleted messages

Per design decision: **NOT filtered** at the SQL level. Revoked +
locally-deleted messages remain in the index and appear in results. UI
renders them with their existing tombstone preview (`🚫 message deleted` /
`🚫 you deleted this`) so the hit context is obvious.

## Bootstrap

`MessageIndex.bootstrapIfNeeded()` runs once at app launch in a detached
low-priority task:

1. Open the raw SQLite connection. `CREATE VIRTUAL TABLE IF NOT EXISTS`.
2. Read `SELECT COUNT(*) FROM MessageFTS` and
   `SELECT COUNT(*) FROM ZPERSISTEDMESSAGE`.
3. If FTS count ≥ persisted count, exit immediately. (Reconcile pass: same
   check on every launch.)
4. If FTS is short, stream `Z_PK, ZTEXT, ZMEDIACAPTION,
   ZQUOTEDTEXTSNIPPET, ZSENDERPUSHNAME` from ZPERSISTEDMESSAGE ordered by
   `Z_PK ASC`, in batches of 1000. INSERT each batch inside a single
   transaction. After each transaction, update
   `progress = .running(indexed: N, total: M)`.
5. On completion, set `progress = .done`.

`BootstrapProgress`:

```swift
enum BootstrapProgress: Equatable {
    case idle
    case running(indexed: Int, total: Int)
    case done
}
```

### UI surfacing of progress

- **Sidebar chip** — a slim `IndexingChip` view appears above the
  `ChatSearchView` text field whenever progress is `.running`. Renders
  `Indexing… 4 200 / 11 800` with a small spinner. Auto-hides on `.done`.
- **In-chat Find bar** — when `progress != .done` AND the user opens ⌘F,
  the bar shows an inline "Index building — partial results" sub-label
  under the text field.

Search itself works during bootstrap (FTS table just returns whatever's
been indexed so far); the chip/sub-label sets expectations.

## In-chat Find bar

### View

`Views/ConversationFindBar.swift`. Slim horizontal bar that slides down
from the top of `ConversationView`'s content (above the scroll view,
below the headerBar). 36 pt tall. Contents:

```
[× ]  [search field "Find in conversation"]   3 / 17   [↑] [↓]
```

When `findHits` is empty + query non-empty: counter shows `"No matches"`
and ↑/↓ are disabled.
When `findActive` is true but query is empty: counter hidden, ↑/↓ disabled.

### State (on `ConversationViewModel`)

```swift
@Published var findActive: Bool = false
@Published var findQuery: String = ""
@Published var findHits: [MessageIndex.Hit] = []
@Published var findCurrentIdx: Int = 0   // index into findHits
var findHitIDs: Set<Int64> { Set(findHits.map(\.zpk)) }
```

A debounced async pipeline (Combine debounce 120 ms on `findQuery`) calls
`messageIndex.searchInChat(jid: chat.jid, query:, limit: 500)` and writes
results back. `findCurrentIdx` resets to 0 on each new query.

### Keyboard

- ⌘F → toggle `findActive`. On open, focus the find field (use
  `@FocusState`). On close, clear query + hits + restore scroll position
  (`scrollAnchor` snapshot before opening).
- ↓ or ⌘G → `findCurrentIdx = (findCurrentIdx + 1) % findHits.count`,
  then `scrollProxy.scrollTo(hit.zpk, anchor: .center)`.
- ↑ or ⇧⌘G → previous, wraps via `(idx - 1 + count) % count`.
- Esc inside the find field → closes the bar.

Existing shortcut audit: no collision (⌘F isn't bound anywhere; ⌘G isn't
either).

### Highlight rendering

`MessageRow` reads `vm.findHitIDs` and `vm.findHits[vm.findCurrentIdx]`
via the existing view-model environment. If its message Z_PK is in the
set, it applies a yellow `Theme.findHighlight` background tint; if it's
the current hit, it also gets a thicker border. No new diffing — already
participates in `vm.messages` re-renders.

Esc and ⌘F-close both fully clear `findHits` so highlights vanish.

## Global sidebar search

### Layout

`ChatSearchView`'s result list becomes sectioned via SwiftUI `Section`:

```
[search field]

[indexing chip if .running]

CHATS (existing behavior)
  • Chat row
  • Chat row

MESSAGES (N)
  • Message hit row
  • Message hit row
  • Show 50 more   (if more available)
```

The "Messages" section only renders when `query.count >= 2` AND
`messageHits.isEmpty == false`. With < 2 chars, only the Chats section
appears (matches existing behavior).

### Message hit row

```
[16 pt chat avatar]  Chat Name  ·  Sender  ·  12 May
"…matched ⟦snippet⟧ around the term…"
```

`Theme.ui(13)` for the meta line, `Theme.ui(12)` for the snippet (with
bold runs around `⟦…⟧` ranges). Two-line clipping on the snippet.

### Tap behavior

Tap a message hit:
1. Call `ChatListViewModel.selectChat(jid: hit.chatJID)` (existing API).
2. Once `ConversationViewModel` for that chat is up, call a new
   `conversationVM.jumpToMessage(zpk: hit.zpk, flash: true)` method.
   Implementation delegates to the existing private window-loading helper
   used by `jumpToQuoted(_:)` (extract the shared "load older history
   until Z_PK is in the window, then scroll" routine to a private
   `scrollToMessage(zpk:flash:)` and have both `jumpToQuoted` and
   `jumpToMessage` call it). `flash: true` triggers a 1.2-second brief
   background pulse via a published transient highlight ID.

### Cancellation

`ChatSearchViewModel.refreshMessages(query:)` stores the most recent
`Task<Void, Never>`. Each new keystroke cancels the prior and spawns a
new task after the same 120 ms debounce window. Stale results are
discarded by checking `Task.isCancelled` before assigning.

## Performance

Rough budget targets (verified manually post-implementation):

| Surface | Store size | Target |
|---|---|---|
| In-chat ⌘F first hit | 50 k msgs | < 80 ms |
| Global keystroke result | 50 k msgs | < 150 ms |
| Bootstrap indexer | 50 k msgs | < 12 s |
| Bootstrap throughput | per batch (1000 rows) | < 200 ms |

If we miss these on real data, revisit: lower batch size, add explicit
ZPERSISTEDMESSAGE index on Z_PK (already PK), drop snippet from in-chat
query (it's not displayed there).

## Testing

### Unit

- **`MessageIndexTests`** —
  - Bootstrap from a seeded ZPERSISTEDMESSAGE temp DB; FTS count equals
    persisted count after first run.
  - Re-running bootstrap is a no-op (idempotent).
  - `upsert(zpk:)` then re-upsert with new text: query for old term
    returns 0, new term returns 1.
  - `delete(zpk:)` removes the row from results.
  - `searchInChat(jid:)` returns only that chat's hits; cross-chat
    contamination = 0.
  - Prefix-match: `fin*` matches "Finland" but `nlnd` does not.
  - Special-char strip: `foo(bar)` doesn't throw FTS syntax error.

- **`MessageSearchViewModelTests`** —
  - Debounce window (120 ms) coalesces rapid keystrokes (use
    `Task.sleep`).
  - Cancellation: enqueueing a new query before the previous completes
    drops the old result.
  - Empty / whitespace-only query → empty result, no SQL.

- **`ConversationFindBarTests`** (VM only) —
  - `findActive` toggles; opening clears prior state.
  - ↑/↓ wrap at ends.
  - Esc clears `findQuery` AND `findHits`.

### Manual

- Type while bootstrap is still running — sidebar chip visible, in-chat
  banner visible, search returns partial results that grow as indexing
  proceeds.
- Stress: synthesize 50 k messages, time ⌘F first-hit + global keystroke.
- Multilingual: type Finnish word; verify diacritic-free token matches
  (`paivaa` does NOT match `päivää` per the no-folding decision — confirm
  expected).
- Revoked / locally-deleted messages appear in results with their
  tombstone preview rendered.
- Bootstrap interrupted mid-run (force-quit app) — next launch resumes
  from where it left off (count-check sees FTS short).

## Components touched

**New files:**
- `yawac/Services/MessageIndex.swift` — FTS owner, ~300 lines.
- `yawac/ViewModels/MessageSearchViewModel.swift` — debounced async query
  layer.
- `yawac/Views/ConversationFindBar.swift` — in-chat find bar.
- `yawac/Views/IndexingChip.swift` — bootstrap progress chip.
- `yawacTests/MessageIndexTests.swift`
- `yawacTests/MessageSearchViewModelTests.swift`
- `yawacTests/ConversationFindBarTests.swift`

**Modified files:**
- `yawac/ViewModels/ConversationViewModel.swift` — add find-bar state
  group; integrate `MessageIndex.searchInChat`; extend `jumpToQuoted` to
  accept an arbitrary Z_PK + `flash:` flag.
- `yawac/ViewModels/ChatSearchViewModel.swift` — add `messageHits` +
  `refreshMessages(query:)` debounced.
- `yawac/Views/ConversationView.swift` — slot `ConversationFindBar` above
  the scroll view; wire ⌘F.
- `yawac/Views/ChatListView.swift` (or wherever the sidebar search list
  renders) — sectioned layout, render `IndexingChip`, render message
  hits.
- `yawac/Views/MessageRow.swift` — add highlight modifier reading
  `vm.findHitIDs` / `vm.findCurrentIdx`.
- All Swift-side persist paths that touch `PersistedMessage` →
  `MessageIndex.upsert(...)` / `.delete(...)` after the SwiftData write.
- `yawac/Design/Theme.swift` — add `Theme.findHighlight` color (yellow
  tint compatible with dark mode).
- `yawac/yawacApp.swift` — kick `MessageIndex.bootstrapIfNeeded()` in a
  detached task after the model container is ready.

## Risks

- **SwiftData wipes the SQLite file** under store-failure rebuild
  (rare). Our `CREATE VIRTUAL TABLE IF NOT EXISTS` + count-check
  bootstrap handles this transparently — next launch reindexes.
- **Z_PK reuse after `DELETE` cascade** — SwiftData doesn't reuse PKs in
  practice. If it ever does, `INSERT OR REPLACE INTO MessageFTS(rowid,
  ...)` handles it.
- **Write-through call-site coverage** — if a persist path forgets to
  call `MessageIndex.upsert`, that message is invisible in search until
  reconcile. Mitigation: the launch-time count-check + reconcile pass
  picks up drift. Plan task includes a grep audit to enumerate every
  `context.insert(PersistedMessage(...)` / `modelContext.save()` site that
  follows a message mutation.
