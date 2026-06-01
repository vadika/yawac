# Group Name + Description Design Spec

**Date:** 2026-06-01
**Status:** Approved (design)
**Topic:** View and edit a group's name and description (WhatsApp
"topic") from `ChatInfoView`. Inline-pencil edit pattern, admin-only.
Cross-device sync via whatsmeow's `events.GroupInfo`. 100-char name
cap, 512-char description cap, URLs auto-linked in display.

## Goal

Groups today render their name from `chat.name` and surface
`BridgeGroupModel.topic` read-only in `ChatInfoView`. Admins have no
way to rename a group or edit its description from yawac — they have
to fall back to the phone. Wire up the existing whatsmeow primitives
(`SetGroupName`, `SetGroupDescription`) so admins can edit both
fields from the desktop, and route inbound `events.GroupInfo` events
into our local cache so phone-side edits propagate.

## Non-goals

- Group avatar / photo (`SetGroupPhoto` is a separate primitive).
- Group settings (locked / announce / disappearing messages — same
  `events.GroupInfo` carries these but the design only touches
  name+description today).
- Edit history ("set by X at HH:MM" footer) — defer; can land later
  as a small read-only line under the description.
- Markdown in description — plain text + URL auto-linking only.
- Non-admin "request to edit" flows.

## Architecture

Mirrors the existing pin/mute event-apply pattern, with one
difference: group name and description go out as **IQ writes**, not
appstate patches. whatsmeow exposes both via direct method calls
returning only `error`. The server fans the change out as an
`events.GroupInfo` event to every participant (including this
client), so cross-device sync hooks into that event.

### Bridge (Go)

- **`bridge/groups.go`** —
  - `SetGroupName(chatJID, name string) error` — wraps
    `c.wa.SetGroupName(jid, name)`.
  - `SetGroupDescription(chatJID, description string) error` — wraps
    `c.wa.SetGroupDescription(jid, "", "", description)`. The two
    string args before the new description are
    `previousID`/`newID` for description versioning; pass empty
    strings to let whatsmeow auto-generate (matches WhatsApp's phone
    behavior).
  - **`JGroup` extension**: add a `Description string` field (line 19
    area). When the bridge returns a `JGroup`, populate `Description`
    from `info.Topic`. `Topic` stays in place for now to avoid
    breaking other consumers; both fields carry the same value until
    we migrate fully.
- **`bridge/events.go`** —
  - Add `case *events.GroupInfo: c.dispatchGroupInfo(v)` in
    `handleWAEvent`.
  - `dispatchGroupInfo(evt *events.GroupInfo)`:
    - Extract `name = evt.Name.GetName()` (empty when this event
      didn't change the name).
    - Extract `description = evt.Topic.GetTopic()` (empty when
      unchanged).
    - **Skip dispatch when both fields are empty** — pure
      participant-only or settings-only changes shouldn't fan into
      this path.
    - Marshal `JGroupInfoChanged{ChatJID, Name, Description, Timestamp}`
      and emit `"GroupInfoChanged"`.
- **`bridge/jsonmodels.go`** — add `JGroupInfoChanged`:
  ```go
  type JGroupInfoChanged struct {
      ChatJID     string `json:"chat_jid"`
      Name        string `json:"name"`           // empty = unchanged
      Description string `json:"description"`    // empty = unchanged
      Timestamp   int64  `json:"timestamp"`
  }
  ```

### Swift bridge

- **`yawac/Bridge/WAClient.swift`** —
  - `func setGroupName(chatJID: String, name: String) throws`
  - `func setGroupDescription(chatJID: String, description: String) throws`
  - `Event.groupInfoChanged(chatJID: String, name: String, description: String, timestamp: Int64)` added to the enum.
  - Decoder branch for `"GroupInfoChanged"`.

### Model

- `yawac/Models/Chat.swift` — `var groupDescription: String? = nil`
  on the UI struct.
- `yawac/Models/PersistedMessage.swift` (`PersistedChat`) — `var
  groupDescription: String? = nil` + init param defaulted
  (lightweight migration).
- `Chat.name` and `PersistedChat.name` already exist — no schema
  change for name.

### VM (`ChatListViewModel`)

- `func setGroupName(_ chat: Chat, to name: String)` — calls
  `client.setGroupName(chatJID:, name:)`; on success calls
  `applyLocalGroupInfo(chatJID: chat.jid, name: name, description: nil)`;
  on error sets `transientError`.
- `func setGroupDescription(_ chat: Chat, to description: String)` —
  same shape; updates the `groupDescription` slot.
- `func applyLocalGroupInfo(chatJID: String, name: String?, description: String?)` —
  updates the matching `chats[]` entry's `name` (when `name != nil`) and
  `groupDescription` (when `description != nil`), persists via
  `upsertPersisted`, then `sortChats()`.
- `func applyIncomingGroupInfo(chatJID: String, name: String?, description: String?, at _: Date)` —
  last-event-wins. `name`/`description` `nil` means "unchanged this
  event"; non-nil overwrites. Internally delegates to
  `applyLocalGroupInfo`.
- `BridgeGroupModel` cold-start backfill: when
  `loadGroupParticipantsIfNeeded` (already in CVM for the mention
  picker) returns participants for a group, ALSO capture the
  group's description into `chats[idx].groupDescription` if absent.
  This avoids a separate reconcile pass.

### ContentView event apply

Extend the event switch (~line 173 area, next to `.chatPinned` / `.chatMuted`):

```swift
case .groupInfoChanged(let chatJID, let name, let description, let ts):
    let canonical = JIDNormalize.canonical(chatJID, client: client)
    let when = Date(timeIntervalSince1970: TimeInterval(ts))
    vm.applyIncomingGroupInfo(
        chatJID: canonical,
        name:        name.isEmpty        ? nil : name,
        description: description.isEmpty ? nil : description,
        at: when)
```

## UI — `ChatInfoView`

Two new section cards in `groupBody` (currently around lines
250–256). The page-level avatar + title at the top of `ChatInfoView`
stays as-is.

### Name section

Read-only mode (always, for non-admins; admins between edits):

```
┌────────────────────────────────────┐
│ Name                       ✎       │
│ "Family chat"                      │
└────────────────────────────────────┘
```

Edit mode (admin tapped pencil):

```
┌────────────────────────────────────┐
│ Name                               │
│ [TextField bound to draft]   N/100 │
│              [Cancel]  [Save]      │
└────────────────────────────────────┘
```

- 100-char hard cap enforced via
  `.onChange(of: nameDraft) { if $0.count > 100 { nameDraft = String($0.prefix(100)) } }`.
- Save calls `chatList?.setGroupName(chat, to: nameDraft)`, collapses
  edit mode.
- Cancel restores `nameDraft = chat.name`, collapses edit mode.

### Description section

Read-only mode:

```
┌────────────────────────────────────┐
│ Description                    ✎   │
│ Lake trip planning. Photos /       │
│ schedule live in #pinned messages. │
└────────────────────────────────────┘
```

When `chat.groupDescription` is nil or empty, render a muted "No
description" placeholder in italics; admin sees the same pencil to
add one. Non-admin with empty description sees an empty section
(could also hide entirely — pick: **render section header with the
placeholder** so the page layout is consistent across all groups).

Edit mode (admin):

```
┌────────────────────────────────────┐
│ Description                        │
│ [TextEditor multi-line]    N/512   │
│              [Cancel]  [Save]      │
└────────────────────────────────────┘
```

- 512-char hard cap, same prefix-truncation pattern.
- Multi-line input via `TextEditor` (or `TextField(..., axis: .vertical)`
  with `lineLimit(3...10)` — implementer's choice).
- URLs in the read-only display are auto-linked via the same
  `NSDataDetector` pattern used in `MessageRow.swift:590`. Extract to
  a tiny helper `View.linkifyDescription(_ text: String) -> Text` (or
  return `AttributedString`) so both surfaces share the code.

### Admin gating

Add a computed `isCurrentUserAdmin: Bool` on `ChatInfoView`:

```swift
private var isCurrentUserAdmin: Bool {
    guard let group else { return false }
    let ownJID = JIDNormalize.bare(session.client?.ownJID ?? "")
    guard !ownJID.isEmpty else { return false }
    return group.participants.contains { p in
        JIDNormalize.bare(p.jid) == ownJID && (p.isAdmin || p.isSuper)
    }
}
```

`isAdmin` and `isSuper` already exist on `BridgeParticipantModel`.
The pencil buttons gate on this. Non-admin sees the same read-only
section without the pencil.

## Cold-start + backfill

The existing `loadGroupParticipantsIfNeeded()` on
`ConversationViewModel` already triggers `client.getGroupInfo(jid:)`
the first time the composer opens a `@`-mention picker. The same
call happens when `ChatInfoView` appears (it needs participants
anyway). In both cases, extract `info.description` (mapped from
`info.topic` in the bridge) and write it onto `chats[idx].groupDescription`
if not already set — without re-fetching.

No separate reconcile pass is needed; the description is already
piggy-backing on every `GetGroupInfo` call.

## Testing

### Unit (`yawacTests/ChatListViewModelGroupInfoTests.swift`, new)

- `setGroupName(chat, to:)` with a stub `WAClient` records the call
  and applies the new name to `chats[]`.
- `setGroupDescription(chat, to:)` same for description.
- `applyIncomingGroupInfo(name: "x", description: nil)` updates only
  name.
- `applyIncomingGroupInfo(name: nil, description: "y")` updates only
  description.
- `applyIncomingGroupInfo(name: "a", description: "b")` updates both.

### Bridge (`bridge/groups_test.go`)

- `SetGroupName(jid, name)` invokes whatsmeow's `SetGroupName` with
  the parsed JID. Use the existing test-client pattern (see
  `bridge/groups_test.go` if it has one, or follow the pin/mute
  appstate test style).
- `SetGroupDescription(jid, description)` same shape.

### Bridge (`bridge/events_dispatch_test.go`)

- `dispatchGroupInfo` with both Name + Topic populated dispatches
  `"GroupInfoChanged"` carrying both fields.
- `dispatchGroupInfo` with only Topic dispatches with `Name == ""`.
- `dispatchGroupInfo` with neither populated does NOT dispatch
  (early return).

### Manual

- Open a group as admin. Pencils visible on Name and Description
  sections.
- Edit Name to "Test Name". Save. Phone shows the rename within
  seconds.
- Change Name on phone. yawac's row updates + section reflects
  within seconds.
- Edit Description. Type 600 chars. Cuts off at 512.
- Description with `https://example.com` in read-only mode shows a
  clickable link.
- Open a group as non-admin. No pencils. Sections render read-only.
- Empty description → "No description" placeholder.
- Cancel mid-edit → original text restored, no bridge call.

## Components touched

**New files:**
- `yawacTests/ChatListViewModelGroupInfoTests.swift`

**Modified files:**
- `bridge/groups.go` — `SetGroupName`, `SetGroupDescription`; extend
  `JGroup` with `Description`.
- `bridge/events.go` — `case *events.GroupInfo` + `dispatchGroupInfo`.
- `bridge/jsonmodels.go` — `JGroupInfoChanged`.
- `bridge/groups_test.go` — name + description tests.
- `bridge/events_dispatch_test.go` — `dispatchGroupInfo` tests.
- `yawac/Bridge/WAClient.swift` — `setGroupName`, `setGroupDescription`,
  `Event.groupInfoChanged`, decoder branch.
- `yawac/Bridge/JSONModels.swift` — `BridgeGroupModel.description`
  field if not already present (it isn't, per investigator).
- `yawac/Models/Chat.swift` — `groupDescription`.
- `yawac/Models/PersistedMessage.swift` — `PersistedChat.groupDescription`.
- `yawac/ViewModels/ChatListViewModel.swift` — VM methods + apply
  + cold-start backfill from `getGroupInfo`.
- `yawac/ContentView.swift` — `.groupInfoChanged` event apply.
- `yawac/Views/ChatInfoView.swift` — two editable section cards
  + `isCurrentUserAdmin` + URL auto-link helper.

## Risks

- **`SetGroupDescription` signature**: whatsmeow's
  `SetGroupDescription` takes `(jid, previousID, newID, description)`
  where the two IDs version the description history. Passing empty
  strings is documented as "auto-generate" in the comment block on
  line 1050 — verify on first run; if the server rejects empty IDs,
  generate a UUID for `newID`.
- **`events.GroupInfo` fires multiple times per change**: a single
  name edit can produce two events (the IQ acknowledgment + a
  fan-out broadcast). Our `applyIncomingGroupInfo` is idempotent
  (same value reapplied is a no-op for `upsertPersisted` if equal),
  so double-fire is fine.
- **Char-cap enforcement is view-layer only**: pasting > 512 chars
  truncates immediately. If a future code path bypasses the view
  (e.g., paste from another panel), the bridge would still accept it
  — WhatsApp's server caps at 512 server-side, so any overflow is
  rejected at send time, not crashed. Acceptable.
- **Concurrent edits**: two admins editing simultaneously — last
  write wins per the `events.GroupInfo` LWW path. Acceptable.
- **`BridgeGroupModel.topic` vs new `description` field**: spec
  introduces a new `description` field on `BridgeGroupModel` while
  leaving the existing `topic` in place. The implementation should
  populate both from `info.Topic` on the Go side to keep current
  consumers working. A follow-up can delete `topic` once nothing
  reads it.
