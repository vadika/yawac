# Reply / Edit / Delete Messages — Design

**Status:** approved 2026-05-25.
**Goal:** Let user reply to any message, edit own text within WhatsApp's 15-min window, and delete own messages — either revoked-for-everyone (server-side, ~48 h window) or hidden-for-me (local-only).

## Scope (v1)

- **Reply:** text replies that quote text or media. Outgoing and incoming.
- **Edit:** edit own text messages within 15 min. Display `· edited` tag next to timestamp on bubbles.
- **Delete for everyone (revoke):** revoke own messages within ~48 h. Bubble becomes a tombstone.
- **Delete for me (local-only):** hide any message locally without touching the network. Tombstone in place.

## Out of scope (v1)

- Edit or revoke of media messages.
- Admin revoke of other people's messages in groups.
- Multi-version edit history. Only the latest text is kept.
- Undo for "Delete for me".
- Reply-with-media (the reply itself carrying an image/video).
- Editing media captions.

## Trigger UX

Right-click context menu on every bubble. No hover toolbar (rejected for noise).
Menu items computed per message; only-eligible items shown:

```
Reply                                    [always for non-tombstone, non-system]
─────────────
Copy text                                [if text and not tombstone]
─────────────
Edit                                     [fromMe && kind=="text" && age<15min && !revoked && !locallyDeleted]
Delete for everyone                      [fromMe && age<48h && !revoked && !locallyDeleted]
Delete for me                            [!locallyDeleted && !revoked]
```

Window constants live in one place (`MessageLifecycle.swift`).

## Architecture

Three layers wired the same way each feature uses, mirroring the existing reactions path.

### Layer 1 — Go bridge

New exported funcs in `bridge/messages.go` (or a new `bridge/edit_revoke.go`):

```go
func (c *Client) SendTextReply(
    chatJID, body string,
    quotedID, quotedSenderJID string,
    quotedFromMe bool,
    quotedKind, quotedSnippet string,
) (string, error)

func (c *Client) EditText(
    chatJID, msgID, newBody string,
) (string, error)

func (c *Client) RevokeMessage(
    chatJID, msgID, targetSenderJID string,
    targetFromMe bool,
) (string, error)
```

Returns are JSON of the existing `JSendResult`. Errors map to `errors.New(...)` so Swift can show toasts.

#### `SendTextReply` proto shape

```go
ctx := &waE2E.ContextInfo{
    StanzaID:      proto.String(quotedID),
    Participant:   proto.String(quotedSenderJID),
    QuotedMessage: stubQuoted(quotedKind, quotedSnippet),
}
msg := &waE2E.Message{
    ExtendedTextMessage: &waE2E.ExtendedTextMessage{
        Text:        proto.String(body),
        ContextInfo: ctx,
    },
}
```

`stubQuoted` returns the minimum `*waE2E.Message` that other clients can render
as a quote preview. WhatsApp servers do not strictly validate the stub matches
the original — clients use the stanza-id to look up the real source.

| `quotedKind` | Stub |
|---|---|
| `text` | `{Conversation: snippet}` |
| `image` | `{ImageMessage: {Caption: snippet}}` |
| `video` | `{VideoMessage: {Caption: snippet}}` |
| `audio` | `{AudioMessage: {}}` |
| `document` | `{DocumentMessage: {FileName: snippet}}` |
| `sticker` | `{StickerMessage: {}}` |
| default | `{Conversation: snippet}` |

#### `EditText`

```go
chat, _ := types.ParseJID(chatJID)
newMsg := &waE2E.Message{Conversation: proto.String(newBody)}
edit := c.wa.BuildEdit(chat, types.MessageID(msgID), newMsg)
resp, err := c.wa.SendMessage(ctx, chat, edit)
```

The bridge does not enforce the 15-min window — UI does. Server returns an error
if exceeded; bridge propagates it.

#### `RevokeMessage`

```go
chat, _ := types.ParseJID(chatJID)
var sender types.JID
if targetFromMe {
    sender = c.wa.Store.ID.ToNonAD()
} else {
    sender, _ = types.ParseJID(targetSenderJID)
}
revoke := c.wa.BuildRevoke(chat, sender, types.MessageID(msgID))
resp, err := c.wa.SendMessage(ctx, chat, revoke)
```

V1 only allows `targetFromMe == true`. If false, return
`errors.New("only own messages")` until admin-revoke ships.

#### Inbound events

Extend `bridge/messages.go::dispatchMessage`. Before the existing kind
classification:

```go
if pm := evt.Message.GetProtocolMessage(); pm != nil {
    switch pm.GetType() {
    case waE2E.ProtocolMessage_REVOKE:
        c.dispatch("MessageRevoked", marshal(JMessageRevoked{
            ChatJID:   evt.Info.Chat.String(),
            MessageID: pm.GetKey().GetID(),
            RevokedBy: evt.Info.Sender.String(),
            Timestamp: evt.Info.Timestamp.Unix(),
        }))
        return
    case waE2E.ProtocolMessage_MESSAGE_EDIT:
        edited := pm.GetEditedMessage()
        c.dispatch("MessageEdited", marshal(JMessageEdited{
            ChatJID:   evt.Info.Chat.String(),
            MessageID: pm.GetKey().GetID(),
            NewText:   extractText(edited),
            Timestamp: evt.Info.Timestamp.Unix(),
        }))
        return
    }
}
```

`extractText` covers `Conversation` and `ExtendedTextMessage.Text`. Edits to
media captions are out of scope; if we ever see a media-caption edit we drop
the event (logged at stderr) — does not break the row.

#### `JMessage` extension

```go
type JMessage struct {
    // ...existing fields...
    Quoted *JQuoted `json:"quoted,omitempty"`
}

type JQuoted struct {
    MessageID string `json:"message_id"`
    SenderJID string `json:"sender_jid"`
    FromMe    bool   `json:"from_me"`
    Kind      string `json:"kind"`
    Snippet   string `json:"snippet"`
}
```

Populate in `dispatchMessage` from `ExtendedTextMessage.GetContextInfo()` and
from the `ContextInfo` of any captioned media (image/video/document) — replies
can come back as either text quoting media, or media quoting text. `Kind` is
derived from `classifyMessage(QuotedMessage)`. `Snippet` is the first ~120
chars of the original text, or a kind-name placeholder for media.

Also extend `bridge/history.go`'s WebMessageInfo → JMessage converter
identically, so history sync surfaces quoted fields.

### Layer 2 — Swift bridge

`yawac/Bridge/WAClient.swift`:

```swift
nonisolated func sendTextReply(
    _ chatJID: String, _ body: String,
    quotedID: String, quotedSenderJID: String,
    quotedFromMe: Bool, quotedKind: String, quotedSnippet: String
) throws -> BridgeSendResult

nonisolated func editText(
    _ chatJID: String, _ msgID: String, _ newBody: String
) throws -> BridgeSendResult

nonisolated func revokeMessage(
    _ chatJID: String, _ msgID: String,
    _ targetSenderJID: String, _ targetFromMe: Bool
) throws -> BridgeSendResult
```

New events surfaced via the existing `Event` enum:

```swift
case messageEdited(MessageEditedPayload)   // {chatJID, messageID, newText, timestamp}
case messageRevoked(MessageRevokedPayload) // {chatJID, messageID, revokedBy, timestamp}
```

New event-payload struct mirrors `JReaction` style: `Decodable, Equatable`.

`JMessage` Swift mirror gains a nested optional `quoted: Quoted?` with fields
matching `JQuoted`.

### Layer 3 — Swift model

`PersistedMessage` lightweight migration (all defaulted optionals):

```swift
var quotedMessageID: String? = nil
var quotedSenderJID: String? = nil
var quotedFromMe: Bool = false
var quotedTextSnippet: String? = nil
var quotedKind: String? = nil

var editedAt: Date? = nil
var revokedAt: Date? = nil
var revokedBy: String? = nil

var locallyDeleted: Bool = false
```

Single new file `yawac/Services/MessageLifecycle.swift`:

```swift
enum MessageLifecycle {
    static let editWindow:   TimeInterval = 15 * 60
    static let revokeWindow: TimeInterval = 48 * 60 * 60

    static func canEdit(_ m: Message,  now: Date = .init()) -> Bool
    static func canRevoke(_ m: Message, now: Date = .init()) -> Bool
}
```

### Layer 4 — ViewModels

`ConversationViewModel` additions:

```swift
var replyTarget: Message?   // mutually exclusive with editTarget
var editTarget:  Message?

func sendText(_ body: String) async   // honors replyTarget
func saveEdit(_ body: String) async   // uses editTarget
func cancelCompose()                  // clears both + composer text iff editing

func startReply(to msg: Message)      // also clears editTarget
func startEdit(_ msg: Message)        // also clears replyTarget
func deleteForEveryone(_ msg: Message) async
func deleteForMe(_ msg: Message)

func jumpToQuoted(id: String)

var pendingScrollToID: String?        // bumped → ScrollViewReader reacts
var highlightedID: String?            // bubble flashes briefly
```

Mutual-exclusion rule: starting reply clears edit and vice versa.

Pending stashes (for out-of-order edits/revokes):

```swift
private var pendingEdits:   [String: MessageEditedPayload]   = [:]
private var pendingRevokes: [String: MessageRevokedPayload]  = [:]
// LRU-capped at 256
```

`ChatListViewModel.persistMessage` honors revoked / locally-deleted state when
deriving `lastMessageText` for the sidebar.

### Layer 5 — Views

#### `ComposerView`

Top stack above the `TextField`, mutually exclusive:

```
┌─ Replying to Alice ──────────────────┐
│  Sure, let's meet at 3pm tomorrow…   │ × cancel
└───────────────────────────────────────┘
```

or

```
┌─ Editing message ─────────── × cancel ┐
└───────────────────────────────────────┘
```

- Esc key → `cvm.cancelCompose()`.
- Send button label: `Send` → `Save` while editing.
- Send disabled when editing if body is unchanged from original.

#### `MessageRow`

Context menu items computed per message (table above).

Bubble render states:

| State | Render |
|---|---|
| `revokedAt != nil` | Italic muted tombstone. `fromMe` → "You deleted this message". Else → "This message was deleted". No reactions, no Translate footer; menu offers only "Delete for me". |
| `locallyDeleted` | Italic muted tombstone: "You deleted this for yourself". |
| `quotedMessageID != nil` | Quoted strip (left accent bar, sender name, snippet) above main bubble. Strip is a `Button` → `cvm.jumpToQuoted(id:)`. |
| `editedAt != nil` | Append ` · edited` to the timestamp line. `.help("Edited <relative>")`. |

#### `ConversationView`

- Wrap row list in `ScrollViewReader`.
- `.onChange(of: cvm.pendingScrollToID)`: if id present in current rows, `proxy.scrollTo(id, anchor: .center)`, set `highlightedID = id`, clear after 1.2 s. If absent, extend `loadHistory(until:)` to page until id found or 2000 rows scanned; toast "Original not available" on exhaustion.

## Error handling

| Path | Failure | UI |
|---|---|---|
| `SendTextReply` send fails | Network / server reject | Toast "Reply not sent". Composer keeps quote chip + text for retry. Local row NOT persisted. |
| `EditText` server reject | >15 min, server clock drift, etc. | Toast "Edit not accepted". Bubble unchanged. Composer keeps edit chip + text. |
| `RevokeMessage` server reject | Outside ~48 h window, etc. | Toast "Couldn't delete for everyone". Row unchanged. |
| Incoming edit for unknown msg id | Out-of-order or pre-history | Stash in `pendingEdits[id]`, reapply when row appears via `loadHistory` or live event. LRU cap 256. |
| Incoming revoke for unknown msg id | Same | Stash in `pendingRevokes[id]` symmetrically. |
| Quote scroll target absent | Out of loaded window | Page back via `loadHistory(until: id)` until found or 2000 rows scanned. Toast on exhaust. |
| Window-guard race (clicked Edit at 14:59, sent at 15:01) | Server rejects | Standard toast. Acceptable. |
| Reply quoted-source is locally deleted | Snippet already captured at send time | Quote renders fine; no special handling. |

## Persistence migration

SwiftData lightweight migration — every new field is defaulted, so existing
stores upgrade transparently. No new tables. `compositeKey` patterns
unchanged on `PersistedReaction` / `PersistedPollVote`.

`PersistedChat.lastMessageText` is re-derived by `ChatListViewModel` so the
sidebar reflects revoke/locally-deleted state when the last message changes.

## History sync

Existing `bridge/history.go` WebMessageInfo converter populates the same new
fields (`Quoted` from `ContextInfo`; revoke handling reuses the pending stash
for the case where a revoke replays before its target).

## Notifications

- Incoming revoke does NOT raise a notification.
- Incoming edit does NOT raise a notification.

## Translation

- Revoked / locally-deleted rows skip the Translate footer entirely.
- Translation cache keys on `id + editedAt` so an edit invalidates prior
  translation.

## Testing

### Go bridge (no live whatsmeow)

- `messages_test.go`: `SendTextReply` rejects bad JIDs (text quote + media
  quote variants).
- New `edit_revoke_test.go`: `EditText` rejects empty body, bad JID.
  `RevokeMessage` rejects `targetFromMe == false` for v1.
- `messages_test.go` extend `dispatchMessage`:
  - feed `events.Message{ProtocolMessage{Type: REVOKE, Key{ID}}}` → assert
    `MessageRevoked` dispatched with correct id.
  - feed `events.Message{ProtocolMessage{Type: MESSAGE_EDIT, EditedMessage}}`
    → assert `MessageEdited` dispatched with extracted text.
  - feed `events.Message{ExtendedTextMessage{ContextInfo{StanzaID, QuotedMessage}}}`
    → assert `JMessage.Quoted` populated.

### Swift (XCTest, no UI)

- `ConversationViewModelTests`:
  - `startReply` + `startEdit` mutual exclusion.
  - `cancelCompose` clears both targets + composer text iff editing.
  - Incoming `.messageEdited` updates row `text` + `editedAt`.
  - Incoming `.messageRevoked` clears text/media + sets `revokedAt`/`revokedBy`.
- `MessageLifecycleTests`: `canEdit`, `canRevoke` boundary cases.
- `PendingStashTests`: stash + replay when row appears; LRU eviction past 256.
- `SidebarPreviewTests`: revoked-as-last-message → preview tombstone string.

### Manual UI smoke (checklist in plan)

- Send reply (text→text, text→image, image→text). Render in both clients.
- Edit own text within 15 min → bubble updates, "edited" tag appears.
- Edit beyond 15 min: menu item hidden.
- Revoke own within 48 h → bubble becomes tombstone; remote client also shows tombstone.
- Revoke beyond 48 h: menu item hidden.
- "Delete for me" → local tombstone only; restart app → still tombstone.
- Click quoted strip → list scrolls + highlights original.
- Click quoted strip when source past loaded window → history pages in and scrolls.

## File touch list

| File | Change |
|---|---|
| `bridge/messages.go` | New `SendTextReply`, extend `dispatchMessage` for PROTOCOL REVOKE / MESSAGE_EDIT, extend `JMessage` populate with `Quoted`. |
| `bridge/edit_revoke.go` | NEW — `EditText`, `RevokeMessage`. |
| `bridge/jsonmodels.go` | Add `JQuoted`, `JMessageEdited`, `JMessageRevoked`. Extend `JMessage`. |
| `bridge/history.go` | Populate `Quoted` from WebMessageInfo `ContextInfo`. |
| `bridge/messages_test.go` | New table-driven cases. |
| `bridge/edit_revoke_test.go` | NEW — bridge-level tests. |
| `yawac/Bridge/WAClient.swift` | New `sendTextReply`, `editText`, `revokeMessage`; new `Event` cases + payloads; extend `JMessage` mirror. |
| `yawac/Models/PersistedMessage.swift` | Defaulted new fields. |
| `yawac/Services/MessageLifecycle.swift` | NEW — windows + `canEdit` / `canRevoke`. |
| `yawac/ViewModels/ConversationViewModel.swift` | `replyTarget`, `editTarget`, action funcs, stashes, scroll plumbing. |
| `yawac/ViewModels/ChatListViewModel.swift` | Re-derive sidebar preview on edit/revoke/local-delete. |
| `yawac/Views/ComposerView.swift` | Quote chip / edit chip; Esc handling; Save vs Send. |
| `yawac/Views/MessageRow.swift` | Context menu items per state; tombstone render; quoted strip; edited tag. |
| `yawac/Views/ConversationView.swift` | `ScrollViewReader`, jump-to-quoted, highlight flash. |
| `yawacTests/` | New XCTest files for VM + lifecycle + stashes + sidebar. |
| `project.yml` | Add new Swift sources, regenerate via `xcodegen`. |
