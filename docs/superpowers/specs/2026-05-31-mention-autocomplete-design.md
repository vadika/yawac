# @-Mention Autocomplete Design Spec

**Date:** 2026-05-31
**Status:** Approved (design)
**Topic:** Typing `@` in the composer opens a strip above with group
participants (or just the other person in 1:1s). ↑/↓/Tab/Enter pick;
Esc closes. Pick inserts `@DisplayName` plain-text into the composer
plus tracks the selection so the outbound message ships with proper
`ContextInfo.MentionedJID` encoding. A synthetic `@everyone` entry
pings every group participant at once.

## Goal

Today, typing a participant's name with `@` produces plain text that
the recipient sees as un-highlighted literal — no ping, no
notification weighting. Add native-feeling autocomplete in the
composer plus the wire encoding so mentions function as real
WhatsApp mentions on the recipient side.

## Non-goals

- Rich-token / chip rendering inside the composer (NSTextView
  attachment). v1 uses plain text + a parallel tracking list.
- Multi-line cursor tracking. Cursor is assumed at end of typed input;
  editing mid-text mid-mention is acceptable to ignore.
- Mention-specific notifications / sound (system already notifies on
  inbound).
- Mention typing while editing the middle of an inserted display name —
  if the user mangles the substring, the mention silently drops.
- Auto-pinging participants who aren't currently in the group at
  pick-time (we snapshot from `getGroupInfo`).

## Architecture

Three new units:

1. **`MentionPickerViewModel` (new
   `yawac/ViewModels/MentionPickerViewModel.swift`)** — owns
   `candidates`, `filtered`, `selectedIdx`, `triggerRange`,
   `isActive`. Reacts to composer text changes via
   `update(text:, cursor:)` and explicit `commit()` / `cancel()`.
2. **`MentionStrip` view (new
   `yawac/Views/MentionStrip.swift`)** — slim list anchored above the
   composer, gated on `picker.isActive`. Renders one row per filtered
   candidate (avatar + display name); the synthetic `@everyone` row
   sits at the top with a distinct icon.
3. **Outbound encoding** in `ConversationViewModel.sendDraft()` (and
   the edit-message path) + the Go bridge:
   - Composer tracks a parallel `activeMentions: [ActiveMention]` list
     where each entry is `(displayName: String, jid: String)`.
   - On send: scan body for each `@<displayName>` substring; for real
     JIDs, swap for `@<phone>` and append the JID to
     `mentionedJIDs: [String]`. For the sentinel `@everyone` entry,
     keep the body literal and append every group participant's JID.
   - Bridge `SendText` / `SendTextReply` signatures extend to accept
     `mentionedJIDs []string`. When non-empty, the Go side builds an
     `ExtendedTextMessage` with `ContextInfo{MentionedJID: ...}`
     (template exists at `bridge/messages.go:736–744` for the reply
     path).

## Participants source

Fetched on demand via the existing
`client.getGroupInfo(jid: chat.jid)` → `BridgeGroupModel.participants`.
Cached as `groupParticipants: [BridgeParticipantModel]?` on
`ConversationViewModel`. Populated lazily on the first `@` keystroke
per open chat. If a `participantsChanged` event arrives (look for
existing handler; if none, no refresh in v1 — re-open chat to refetch).

**1:1 chats**: skip the bridge call. The picker shows a single
candidate (the other party) with `displayName` from
`chat.name` / `session.displayName(for: chat.jid)`.

**Display name source**: `session.displayName(for: participant.jid)` —
same path used by every other surface. Sorting: alphabetic by
displayName, with the synthetic `@everyone` row pinned to position
zero in group chats only.

## Trigger detection

`MentionPickerViewModel.update(text:, cursor:)` runs after every
composer text change:

- Find the last `@` at or before `cursor` that is preceded by
  whitespace or by string start.
- If found and no whitespace exists between that `@` and `cursor`,
  the substring between (exclusive of `@`, inclusive of cursor) is
  the filter query.
- Set `triggerRange = <range of '@' through cursor>`. Set
  `isActive = true`.
- Filter candidates by
  `displayName.localizedCaseInsensitiveContains(query)` OR
  `phoneDigits(jid).contains(digitsOnly(query))`.
- Special: `query` ∈ `{"all", "everyone", "every", ""}` keeps
  `@everyone` visible at the top (groups only).
- If no qualifying `@` found, or whitespace appears between `@` and
  cursor, set `isActive = false` and `triggerRange = nil`.

Cursor tracking: SwiftUI `TextField` doesn't expose the live cursor
position natively, so the picker treats the cursor as `text.endIndex`
(end of input — the common typing case). Editing in the middle of a
prior `@mention` won't reopen the picker.

## Insertion + parallel mention list

On commit (Tab / Enter / click) with candidate `p`:

```swift
text.replaceSubrange(triggerRange, with: "@\(p.displayName) ")
vm.activeMentions.append(ActiveMention(
    displayName: p.displayName,
    jid: p.jid))            // sentinel "*all*" for @everyone
picker.cancel()             // clear triggerRange, isActive=false
```

The trailing space matters: it terminates the mention token and
prevents the picker from re-opening when the user types the next
character.

`activeMentions` resets when:
- Send succeeds (already paired with `vm.draft = ""`).
- User cancels reply / edit (existing flow).
- User cancels the picker mid-edit (just closes picker; existing
  mentions stay).

If the user edits an inserted `@<DisplayName>` substring (deletes
chars, retypes), the entry stays in `activeMentions` but the body
substring won't match at send time. That mention silently drops —
acceptable trade-off vs the NSTextView complexity of attachments.

## `@everyone` / `@all` semantics

A synthetic candidate appears as the first row of the picker in group
chats only. It matches the typed prefixes `all`, `every`, `everyone`
(case-insensitive) as well as the empty query.

On commit:

```swift
vm.activeMentions.append(ActiveMention(
    displayName: "everyone",
    jid: "*all*"))
text.replaceSubrange(triggerRange, with: "@everyone ")
```

`"*all*"` is the sentinel JID (the `*` makes it impossible as a real
WhatsApp JID).

On send, the encoding loop handles the sentinel:

```swift
for m in activeMentions {
    let needle = "@\(m.displayName)"
    if m.jid == "*all*" {
        if body.contains(needle) {
            mentionedJIDs.append(contentsOf:
                (groupParticipants ?? []).map(\.jid))
        }
        // Body keeps literal "@everyone".
    } else {
        let replacement = "@" + phoneDigits(m.jid)
        if let r = body.range(of: needle) {
            body.replaceSubrange(r, with: replacement)
            mentionedJIDs.append(m.jid)
        }
    }
}
```

WhatsApp clients render `@everyone` highlighted because every
recipient finds their own JID in the message's `MentionedJID` array.

The `@everyone` row is hidden in 1:1 chats (no group context).

## Outbound encoding (real mentions)

In `ConversationViewModel.sendDraft()`, **before** the
`client.sendText` call:

```swift
var body = draft
var mentionedJIDs: [String] = []
for m in activeMentions {
    let needle = "@\(m.displayName)"
    if m.jid == "*all*" {
        if body.contains(needle) {
            mentionedJIDs.append(contentsOf:
                (groupParticipants ?? []).map(\.jid))
        }
    } else {
        let replacement = "@" + phoneDigits(m.jid)
        if let r = body.range(of: needle) {
            body.replaceSubrange(r, with: replacement)
            mentionedJIDs.append(m.jid)
        }
    }
}
// dedupe (a participant could be pinged via @everyone AND directly).
mentionedJIDs = Array(Set(mentionedJIDs))
try client.sendText(chatJID, body, mentionedJIDs: mentionedJIDs)
```

`phoneDigits(jid)`: returns the substring before `@` (e.g.
`"200347423354946"` from `"200347423354946@s.whatsapp.net"`). For
`@lid` JIDs the prefix is the LID number; that's what WhatsApp wants
in the body text.

### Bridge change

`bridge/messages.go`:
- `SendText(jid, body)` → `SendText(jid, body, mentionedJIDs)`.
- When `len(mentionedJIDs) == 0`, behavior is unchanged (plain
  `Conversation` field on `waE2E.Message`).
- When `len(mentionedJIDs) > 0`, build an
  `ExtendedTextMessage{Text: &body, ContextInfo: &ContextInfo{
  MentionedJID: mentionedJIDs}}` and ship that. Match the reply path
  template at lines 736–744 verbatim where possible.
- `SendTextReply(...)` likewise gains `mentionedJIDs []string` (it
  already builds a `ContextInfo`; the change is one line — set
  `ci.MentionedJID = mentionedJIDs`).

`yawac/Bridge/WAClient.swift`:
- `sendText(_ jid, _ body, mentionedJIDs: [String] = [])` — defaulted
  arg keeps existing callers compiling.
- `sendTextReply(...)` likewise.

## Edit-message path

The edit dispatch in `ConversationViewModel` (existing `sendEdit` or
equivalent) currently sends the edited body via some bridge edit
primitive. Extend it the same way as `sendText` if the primitive
takes a body string; the same `mentionedJIDs` extraction loop runs.

If the edit primitive is awkward to extend (the
`RevokeMessage` / `EditMessage` proto shape differs), scope-limit
v1: edits do NOT add new mentions. The picker won't fire during
edits. Existing mentions in the original message body remain
rendered correctly on the recipient side because their `ContextInfo`
is preserved by WhatsApp's edit semantics (the original message's
`MentionedJID` array is not overwritten by an edit unless the edit
message itself carries one).

Decide during implementation. Spec accepts either outcome.

## UI — `MentionStrip`

Slim view, ~32 pt tall per row, anchored above the composer (inside
the same `VStack` that contains `attachmentStrip` and the composer
chrome — so it joins the composer's animated reveal).

Per row:

```
[avatar 20 pt] [@DisplayName Inter Tight 13 pt] [phone 11 pt mono, muted]
```

The synthetic `@everyone` row uses an `Image(systemName: "megaphone")`
in place of the avatar, no phone label.

Selected row gets `Theme.accentSoft` background + `Theme.accentText`
foreground. Tap commits. ↑/↓ move via `picker.move(by:)`; Tab and
Enter commit via `picker.commitSelected()` from the existing
`ComposerView .onKeyPress` plumbing (matching the Escape/UpArrow
pattern at `ComposerView.swift:82–90`). Esc calls `picker.cancel()`.

Max visible rows: 5 (scroll for more).

When the participants fetch is in flight (groups, first `@`), show a
single placeholder row: spinner + "Loading members…". Don't gate
typing — if the user keeps typing past `@`, the filter still applies
once participants arrive.

## Testing

### Unit

- **`MentionPickerViewModelTests`** —
  - `@` at end of empty body → picker opens, full list.
  - `@joh` → filters; first match selected.
  - `@joh ` (trailing space) → picker closes.
  - `hello @` → opens, leading-context whitespace OK.
  - `email@example` → does NOT open (no whitespace before `@`).
  - `@every` / `@all` / `@` shows `@everyone` row in group; hidden in
    1:1.
  - `move(by: +1)` wraps at the end; `-1` wraps at the start.
  - `commitSelected()` invokes the closure with the right participant
    and emits the replacement string.

- **`MentionEncodingTests`** — `sendDraft`-side substitution:
  - `"hi @Natali bye"` + `activeMentions=[(Natali, jid)]` →
    `("hi @<phone> bye", [jid])`.
  - `"hi @Natali @Bob"` two mentions → both swapped, two JIDs.
  - `"hi @Natali"` then user edits to `"hi @Natli"` → mention drops
    (no replacement, no JID).
  - `"hi @everyone"` + sentinel + 5 participants → body unchanged,
    `mentionedJIDs` = all 5.
  - Dedupe: `@everyone + @Bob` where Bob is in the group → Bob
    appears once.

### Manual

- Open a group, type `@`. Strip appears with `@everyone` on top +
  alphabetical participants.
- Type a partial name. List filters.
- Tab and Enter both commit. Click commits. Esc closes without
  insertion.
- Send. Open the chat on a phone — `@Name` renders as a highlighted
  ping; the pinged user's notification weighting reflects the
  mention.
- Pick `@everyone`. Send. Every participant on phones sees `@everyone`
  highlighted and gets the mention notification.
- DM: type `@`. Strip shows just the other party, no `@everyone`.
- Mention a participant, then edit the inserted `@Name` to `@Nam`.
  Send. Recipient sees plain text `@Nam` (no ping).
- Group with > 5 active members: strip scrolls.

## Components touched

**New files:**
- `yawac/ViewModels/MentionPickerViewModel.swift`
- `yawac/Views/MentionStrip.swift`
- `yawacTests/MentionPickerViewModelTests.swift`
- `yawacTests/MentionEncodingTests.swift`

**Modified files:**
- `yawac/ViewModels/ConversationViewModel.swift`
  - Add `groupParticipants: [BridgeParticipantModel]?` cache.
  - Add `activeMentions: [ActiveMention]` (with `struct ActiveMention`
    nested or top-level).
  - Add `picker: MentionPickerViewModel` (or vend it on demand).
  - Modify `sendDraft()` to run the encoding loop + extend
    `client.sendText(...)` call.
- `yawac/Views/ComposerView.swift`
  - Bind the TextField text change to `picker.update(text:, cursor:)`.
  - Hand the `.onKeyPress` handlers (Tab, Enter, ↑, ↓, Esc) to the
    picker when `picker.isActive`. Fall through to send / existing
    behavior when not.
  - Slot `MentionStrip` above the composer chrome in the existing
    composer `VStack`.
- `yawac/Bridge/WAClient.swift`
  - `sendText(_ jid:, _ body:, mentionedJIDs: [String] = [])`.
  - `sendTextReply(..., mentionedJIDs: [String] = [])`.
- `bridge/messages.go`
  - `SendText` + `SendTextReply` accept `mentionedJIDs []string`.
  - When non-empty, build `ExtendedTextMessage{Text:&body,
    ContextInfo:&ContextInfo{MentionedJID:mentionedJIDs}}` instead of
    plain `Conversation`.
- `Bridge.xcframework` — regenerate via `gomobile bind` after Go
  changes.

## Risks

- **`BridgeParticipantModel.jid`** may carry `@lid` for some
  participants (privacy-LID). `phoneDigits(jid)` returns the LID
  number, which is what WhatsApp wants in the body for `@lid`
  mentions; receivers resolve LID→PN on their end. Verify on first
  manual test.
- **Group exit / participant churn** between picker open and send:
  if a participant was kicked while the user was typing, the
  outbound `mentionedJIDs` still includes them. Server will accept
  it; recipients won't see them ping. Acceptable.
- **`@everyone` in a 1000-member group**: `mentionedJIDs` carries
  1000 JIDs. The wire size cost is real; WhatsApp's official client
  caps `@everyone` somewhere. Acceptable for v1 — if we run into a
  size limit, add a confirmation dialog later.
- **Cursor-not-tracked limitation**: typing `hello @Bo|b` (cursor
  after `Bo`) won't reopen the picker for `Bob`. Acceptable v1
  trade-off.
