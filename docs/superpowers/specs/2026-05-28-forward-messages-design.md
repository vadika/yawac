# Forward messages — design

**Date:** 2026-05-28
**Status:** Approved (pending implementation plan)

## Problem

There's a disabled "Forward" item in the message context menu. Users want to
select one or more messages and forward them to another chat or group — the
standard WhatsApp action.

## Scope (agreed)

- **Destination:** one chat per forward action (picker is single-select).
- **Message types:** text and media (image / video / audio / document /
  sticker). Polls and system messages are out of scope.
- **Selection:** both single-message and multi-message. Right-click → Forward
  on any message enters selection mode with that message preselected; the user
  adds more, then picks a destination.
- **Forwarded tag:** persist an `isForwarded` flag and render a "Forwarded"
  label on both sent and received bubbles whose `ContextInfo.IsForwarded` is set.
- **Media by reference:** forward media by re-sending the stored media proto
  (URL / directPath / mediaKey / SHA / length / mimetype) — no re-download or
  re-upload, the way real clients forward. WhatsApp media is content-addressed
  and encrypted by `mediaKey`, so the same blob is reusable across chats.

## Key findings (from code exploration)

- whatsmeow has **no** high-level forward helper. Forwarding = set
  `ContextInfo.IsForwarded = true` (+ `ForwardingScore`) on a reconstructed
  `waE2E.Message` and call `SendMessage`.
- Plain `Conversation` text carries no `ContextInfo`; forwarded text must use
  `ExtendedTextMessage` so the forwarded flag travels.
- The send/quote patterns in `bridge/messages.go` (`SendText`,
  `SendTextReply`, `SendReaction`) and the media protos in `bridge/media.go`
  (`MediaRef`: URL, DirectPath, MediaKey, FileEncSHA256, FileSHA256,
  FileLength, Mimetype) are the building blocks.
- The destination picker reuses `ChatSearchViewModel` for filtering.

## Approach

In-conversation selection mode owned by `ConversationViewModel`, plus a
dedicated lightweight destination picker sheet. (Rejected: a single
select-inside-the-sheet flow — duplicates message rendering and breaks
"select in context"; reusing `NavigationSplitView` selection — conflates
navigation with an action.)

## Components

### 1. Data model

- `PersistedMessage.isForwarded: Bool = false`
- `UIMessage.isForwarded: Bool = false`

Both optional/defaulted → SwiftData light migration. Hydrated in
`ConversationViewModel`'s history-load paths alongside `starredAt` / `pinnedAt`;
set on outgoing forwards we persist.

### 2. Bridge (`bridge/messages.go`, `bridge/jsonmodels.go`)

- `JMessage` gains `is_forwarded bool`. `dispatchMessage` populates it from
  `contextInfoFromMessage(evt.Message).GetIsForwarded()` (the same
  `ContextInfo` it already reads for quotes).
- `ForwardText(chatJID, text string) (string, error)` — builds
  `&waE2E.Message{ExtendedTextMessage: {Text, ContextInfo:{IsForwarded:true,
  ForwardingScore:1}}}` → `SendMessage`. Returns `JSendResult` JSON.
- `ForwardMedia(chatJID, refJSON, kind, caption string) (string, error)` —
  decode `MediaRef`; reconstruct the matching
  `waE2E.{Image,Video,Audio,Document,Sticker}Message` from the ref fields
  (+ caption where the type supports it); set its
  `ContextInfo.IsForwarded=true, ForwardingScore=1`; `SendMessage`. **No
  re-upload.** Returns `JSendResult` JSON. Bad JID / bad ref JSON → error.

### 3. WAClient (`yawac/Bridge/WAClient.swift`)

- `func forwardText(_ chatJID:, text:) throws -> BridgeSendResult`
- `func forwardMedia(_ chatJID:, refJSON:, kind:, caption:) throws -> BridgeSendResult`
- `JMessage.is_forwarded` decoded into `BridgeMessage` → `UIMessage.isForwarded`.

### 4. ConversationViewModel

- `var forwardSelecting = false`
- `var forwardSelection: Set<String> = []`
- `func canForward(_ m: UIMessage) -> Bool` — text → true; media → true iff
  `mediaRefJSON != nil` OR a non-empty caption exists; poll/system → false;
  revoked / locally-deleted → false.
- `func beginForward(_ m: UIMessage)` — `forwardSelecting = true`; insert
  `m.id` if `canForward`.
- `func toggleForward(_ id: String)` — add/remove (only if forwardable).
- `func cancelForward()` — clear set + exit mode.
- `func executeForward(to chatJID: String) async` — for each selected id in
  chronological order:
  - text → `forwardText(dest, text)`
  - media with `mediaRefJSON` → `forwardMedia(dest, ref, kind, caption)`
  - media without ref but with caption → `forwardText(dest, caption)`
  - persist each as an outgoing `PersistedMessage(isForwarded: true)` under the
    destination JID (existing outgoing-persist path)
  - on error, append a system bubble (existing failure pattern)
  Then `cancelForward()`.

`ForwardingScore` is fixed at 1 in v1 (no forward-chain count carry).

### 5. UI

**MessageRow** — new params `selecting`, `selected`, `selectable`,
`onToggleSelect`. In `selecting` mode: leading checkmark circle (filled when
selected); the row tap toggles selection and the normal double-click /
right-click / link handlers are suppressed; non-`selectable` rows render dimmed
and ignore taps. "Forwarded" tag: when `message.isForwarded`, an italic
`arrowshape.turn.up.right` + "Forwarded" line above `bodyView`, styled like the
existing `· edited` footer treatment.

**ConversationView** — pass selection params into each `MessageRow` from `vm`.
When `vm.forwardSelecting`, replace the composer with a bottom bar: "N
selected" · **Forward** (disabled if 0) · **Cancel**. Forward → present
`.sheet` with `ForwardPickerView`. Selection mode resets on chat switch
(`.task(id: chatJID)`).

**ForwardPickerView** (new, `yawac/Views/ForwardPickerView.swift`) — a search
`TextField` + a flat `List` of chats (avatar + name + last message), filtered
via `ChatSearchViewModel`; single tap → `onPick(jid)`. Title "Forward to…",
Cancel. No scope tabs / community nesting. On pick →
`await vm.executeForward(to: jid)`, dismiss, brief "Forwarded" confirmation.

**MessageContextMenu** — enable the Forward row (drop `disabled: true`);
`onForward()` → `vm.beginForward(msg)`.

## Data flow

```
right-click Forward ─► CVM.beginForward(msg)  (forwardSelecting=true, preselect)
  tap rows ─► CVM.toggleForward(id)
  bottom bar Forward ─► ForwardPickerView sheet
    pick chat ─► CVM.executeForward(to: jid)
      for id in selection (chronological):
        text          → WAClient.forwardText  → bridge ForwardText  → SendMessage(IsForwarded)
        media+ref      → WAClient.forwardMedia → bridge ForwardMedia → SendMessage(IsForwarded, no re-upload)
        media+caption  → WAClient.forwardText (caption)
        persist outgoing PersistedMessage(isForwarded:true) under dest JID
      cancelForward()
inbound .message ─► JMessage.is_forwarded (ContextInfo.IsForwarded)
                    → UIMessage.isForwarded → "Forwarded" tag
```

## Edge cases

- Forwarding to the current chat is allowed.
- Multi-pick where every candidate is non-forwardable → Forward stays disabled.
- Selection mode cancels on chat switch.
- Revoked / locally-deleted / system / poll rows are not selectable.
- Media with no ref and no caption → not selectable.

## Testing

- **Bridge:** `ForwardText` / `ForwardMedia` bad-JID and bad-ref-JSON error
  paths (pattern: `reactions_send_test.go`).
- **Swift (XCTest, like `CVMReplyEditTargetTests`):** `beginForward` enters
  mode + preselects; `toggleForward` add/remove; `canForward` matrix (text yes,
  media+ref yes, media+caption yes, media no-ref/no-caption no, system no);
  `cancelForward` clears.
- **Manual:** forward text + image to another chat → "Forwarded" tag on the
  sent bubble and on the phone; multi-select 2–3 → forward; media with caption
  but no ref → text-only forward.

## Out of scope

- Multiple destinations in one action.
- Poll forwarding.
- Forward-chain `ForwardingScore` counting ("forwarded many times").
- Adding a caption/comment when forwarding.
