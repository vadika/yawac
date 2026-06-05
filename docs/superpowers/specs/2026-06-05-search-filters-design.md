# v0.8.4 — Search Filters

**Date:** 2026-06-05
**Status:** Approved (design)
**Topic:** Add 3 filters × 2 surfaces (in-chat ⌘F find bar +
global ⌘K Messages section): filter by sender, kind, and date
range. FTS5 schema bumps to add `kind`; existing rows backfilled
on first v0.8.4 boot.

## Goal

Both search surfaces today accept only a query string. Common
WhatsApp / messaging UX gap: filter by who, by message-type, by
date. Six filter knobs to add (sender / kind / date × in-chat /
global). Single shared `MessageIndex` powers both surfaces; one
schema bump + one query-extension covers everything.

## Non-goals

- Multi-sender filter (single sender per query).
- Multi-kind filter (single kind per query).
- Free-text date ("last week"); fixed presets (Today / 7d / 30d /
  90d / Custom).
- Saved filter presets across launches.
- Filter-by-link-domain or filter-by-attachment-file-type.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ ConversationFindBar (⌘F):                                    │
│   query field + sender/kind/date filter chips                │
│                                                              │
│ ChatListView ⌘K Messages section:                            │
│   query field + chat/sender/kind filter chips                │
└─────────────────────────────────────────────────────────────┘
              │ MessageIndex.search(...)
              ▼
┌─────────────────────────────────────────────────────────────┐
│ MessageIndex (FTS5):                                         │
│   schema v2: + `kind UNINDEXED` column                       │
│   searchInChat(jid, query, sender?, kind?, dateRange?)       │
│   searchGlobal(query, chat?, sender?, kind?, dateRange?)     │
└─────────────────────────────────────────────────────────────┘
```

**Schema migration:** `MessageFTS` adds a `kind UNINDEXED` column.
Since FTS5 doesn't support `ALTER TABLE ADD COLUMN`, the migration
is drop + recreate + re-bootstrap from `ZPERSISTEDMESSAGE`. A
`@AppStorage("messageIndexSchemaVersion")` flag gates the
migration (current = 1; bump to 2 on this release).

`MessageIndex.bootstrapIfNeeded()` already exists and runs on
launch; extend its bootstrap detection to also force-rerun when
schema version differs.

## Components

### MessageIndex schema v2

```sql
CREATE VIRTUAL TABLE MessageFTS USING fts5(
    msgid UNINDEXED, chatjid UNINDEXED, ts UNINDEXED,
    kind UNINDEXED,  -- NEW
    text, caption, quoted, sender,
    tokenize = 'unicode61'
);
```

`MessageFields` struct (caller passes via `upsert`) gains:

```swift
let kind: String   // text | image | video | audio | document |
                   // voice | poll | location | contact | sticker
```

`PersistedMessage.indexFields` (the converter) extends to populate
`kind` from `PersistedMessage.kind`.

### Migration on launch

`MessageIndex.ensureSchemaLocked()` checks
`@AppStorage("messageIndexSchemaVersion")`. If < 2:

```swift
sqlite3_exec(db, "DROP TABLE IF EXISTS MessageFTS;", nil, nil, nil)
// then run the new CREATE VIRTUAL TABLE with kind column
// then schedule bootstrap (existing path)
@AppStorage = 2
```

### Extended query API

```swift
struct SearchFilters {
    var sender: String?     // exact JID match
    var kind: String?       // exact kind match
    var fromTimestamp: Int64? // ts >= this (inclusive)
    var toTimestamp: Int64?   // ts <= this (inclusive)
}

func searchInChat(jid: String, query: String,
                  filters: SearchFilters = .init(),
                  limit: Int = 500) -> [Hit]

func searchGlobal(query: String,
                  filters: SearchFilters = .init(),
                  chatJID: String? = nil,
                  limit: Int = 200) -> [Hit]
```

SQL composition: append `AND sender = ?`, `AND kind = ?`, `AND ts
>= ?`, `AND ts <= ?`, `AND chatjid = ?` conditionally. Bind
params in order.

### ChatSearchViewModel (in-chat, ⌘F) + MessageSearchViewModel (global, ⌘K)

Both gain matching `filters: SearchFilters` published state. Setting any filter re-runs the existing debounced search.

### UI — filter chips strip

Both find bars get a horizontal filter chip strip below the query
field, three chips:

```
[ Sender ▼ ]  [ Kind ▼ ]  [ Date ▼ ]
```

Each chip:
- When no filter set: shows label + dropdown icon.
- When filter set: shows selected value + "×" clear button.

**Sender picker** (in-chat: list of message senders in the
current chat; global: `session.contactNames` filtered to known
senders).

**Kind picker** — fixed list: Text / Image / Video / Audio / Voice
/ Document / Location / Contact / Poll / Sticker.

**Date picker** — preset menu: Today / Last 7 days / Last 30 days
/ Last 90 days / Custom… (opens a date-range sheet with two
`DatePicker`s).

Global ⌘K also gets a **Chat** chip (filter to a specific chat).

### Filter chip rendering

```swift
private struct FilterChip<Value: Hashable>: View {
    let label: String
    let selectedLabel: String?
    let onClear: () -> Void
    let picker: () -> AnyView

    var body: some View {
        HStack(spacing: 4) {
            picker()
            if let sel = selectedLabel {
                Text(sel)
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            } else {
                Text(label).foregroundStyle(Theme.textMuted)
                Image(systemName: "chevron.down")
                    .scaledIcon(9, weight: .medium)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            Theme.surface,
            in: Capsule()
        )
    }
}
```

Picker is a `Menu` for sender/kind/date-preset; "Custom date…"
opens a sheet.

## Bootstrap re-population strategy

`MessageIndex.bootstrapIfNeeded()` already walks
`ZPERSISTEDMESSAGE` and `upsert`s rows. Extend `MessageFields`
build to read `pm.kind`. On schema v2 migration, drop the
existing FTS table → bootstrap walks the full
`ZPERSISTEDMESSAGE` table again. Acceptable one-time cost; runs
in `Task.detached(priority: .utility)`.

## Error handling

| Surface | Pattern |
|---|---|
| Schema migration fails | Existing bootstrap error path (`Logger.search.error`); search returns empty until next launch. |
| Filter picker UI | Inline no-op on missing data (e.g. no senders in current chat → menu disabled). |
| Custom date sheet | Validate `fromDate <= toDate`; disable Apply otherwise. |

## Testing

### MessageIndex

- `searchInChat(jid:, query:, filters: senderFilter)` → only matches with that sender.
- `searchInChat(jid:, query:, filters: kindFilter)` → only matches with that kind.
- `searchInChat(jid:, query:, filters: dateRange)` → only matches within range.
- Combined filters → AND semantics.
- Migration: open v1 schema → boot triggers drop+recreate; old rows re-bootstrap with `kind` populated.

### ViewModels

- `ChatSearchViewModel.filters = ...` re-fires search with new
  filters; results respect filters.
- `MessageSearchViewModel.filters.chat` filters global hits to a
  specific chat.

### Manual smoke

- ⌘F → query "hello", filter Sender = Anna → only Anna's messages
  with "hello" listed.
- ⌘F → filter Kind = Image → only image messages with the query
  match in caption.
- ⌘F → Date "Last 7 days" → only recent matches.
- ⌘K → filter Chat = "Project X" → only matches in that chat.
- Clear filter → results return to broader set.
- Custom date sheet → from = today-30 / to = today → only that
  range.

## Files touched

**New:**

- `yawac/Views/SearchFilterChips.swift` — three reusable
  filter-chip components (sender / kind / date) used by both
  ConversationFindBar and ChatListView ⌘K section.
- `yawac/Views/DateRangeSheet.swift` — custom date picker sheet.
- `yawacTests/SearchFiltersTests.swift` — MessageIndex filter
  tests + VM tests.

**Modified:**

- `yawac/Services/MessageIndex.swift` — schema v2 (kind column),
  migration gate, `SearchFilters` struct, extended `searchInChat`
  + `searchGlobal` SQL composition.
- `yawac/Models/PersistedMessage.swift` — `indexFields` populates
  `kind`.
- `yawac/ViewModels/ChatSearchViewModel.swift` — `filters` state.
- `yawac/ViewModels/MessageSearchViewModel.swift` — `filters`
  state.
- `yawac/Views/ConversationFindBar.swift` — filter chip strip.
- `yawac/Views/ChatListView.swift` — filter chip strip in ⌘K
  Messages section.
- `project.yml` — bump `CFBundleShortVersionString` 0.8.3 → 0.8.4,
  `CFBundleVersion` 12 → 13.
- `docs/ROADMAP.md` — strike Search filter gaps.
