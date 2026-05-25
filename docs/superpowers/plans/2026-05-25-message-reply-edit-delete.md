# Reply / Edit / Delete Messages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship reply-to-message, edit-own-text (15-min window), revoke-own-message (48-h window), and local "delete for me" — right-click triggered, tombstone bubbles, clickable quote-jumps, `edited` tag.

**Architecture:** Three-layer wiring mirroring the existing reactions path. Bridge (Go) gains three send funcs + two event types + a `JQuoted` payload extension. Swift gains a `MessageLifecycle` helper, four new fields on `PersistedMessage`, `replyTarget`/`editTarget` state on `ConversationViewModel`, and chip UI on `ComposerView`. `MessageRow` becomes state-driven (tombstone / quoted-strip / edited tag). `ConversationView` wraps in a `ScrollViewReader` for quote-jump.

**Tech Stack:** Go (`whatsmeow` `BuildEdit` / `BuildRevoke`, `ContextInfo` proto), Swift (`@Observable @MainActor`, SwiftData lightweight migration, `ScrollViewReader`).

**Reference design:** [`docs/superpowers/specs/2026-05-25-message-reply-edit-delete-design.md`](../specs/2026-05-25-message-reply-edit-delete-design.md).

**Build cadence:** rebuild `Bridge.xcframework` once after all Go tasks (T1–T6) land, not after every Go task.

---

## Task 1: Bridge JSON shapes

**Files:**
- Modify: `bridge/jsonmodels.go`

Extend `JMessage` with full `Quoted *JQuoted` (replacing the thin `QuotedID` field; nothing reads it yet). Add `JMessageEdited`, `JMessageRevoked`.

- [ ] **Step 1: Edit `bridge/jsonmodels.go`**

Replace the `QuotedID string` field on `JMessage` with `Quoted *JQuoted`. Add the new structs.

```go
type JMessage struct {
    ID             string   `json:"id"`
    ChatJID        string   `json:"chat_jid"`
    SenderJID      string   `json:"sender_jid"`
    SenderPushName string   `json:"sender_push_name,omitempty"`
    FromMe         bool     `json:"from_me"`
    Timestamp      int64    `json:"timestamp"`
    Kind           string   `json:"kind"`
    Text           string   `json:"text,omitempty"`
    Media          *JMedia  `json:"media,omitempty"`
    Poll           *JPoll   `json:"poll,omitempty"`
    Quoted         *JQuoted `json:"quoted,omitempty"`
}

type JQuoted struct {
    MessageID string `json:"message_id"`
    SenderJID string `json:"sender_jid"`
    FromMe    bool   `json:"from_me"`
    Kind      string `json:"kind"`
    Snippet   string `json:"snippet"`
}

type JMessageEdited struct {
    ChatJID   string `json:"chat_jid"`
    MessageID string `json:"message_id"`
    NewText   string `json:"new_text"`
    Timestamp int64  `json:"timestamp"`
}

type JMessageRevoked struct {
    ChatJID   string `json:"chat_jid"`
    MessageID string `json:"message_id"`
    RevokedBy string `json:"revoked_by"`
    Timestamp int64  `json:"timestamp"`
}
```

- [ ] **Step 2: Verify Go still builds**

Run: `cd bridge && go build ./...`
Expected: PASS.

If the build fails because the deleted `QuotedID` was being assigned anywhere, remove those assignments (search via `grep -n QuotedID bridge/`). Nothing in tree should populate it yet — it was a placeholder.

- [ ] **Step 3: Commit**

```bash
git add bridge/jsonmodels.go
git commit -m "bridge: JQuoted + edit/revoke event payloads"
```

---

## Task 2: `SendTextReply` bridge func

**Files:**
- Modify: `bridge/messages.go`
- Test: `bridge/messages_test.go`

- [ ] **Step 1: Add the failing test**

Append to `bridge/messages_test.go`:

```go
func TestSendTextReplyRejectsBadJID(t *testing.T) {
    c := &Client{}
    _, err := c.SendTextReply("not-a-jid", "hi",
        "ABCD1234", "12345@s.whatsapp.net", false,
        "text", "hello")
    if err == nil {
        t.Fatal("expected error for bad chat jid")
    }
}

func TestSendTextReplyClosedClient(t *testing.T) {
    c := &Client{} // wa is nil
    _, err := c.SendTextReply("12345@s.whatsapp.net", "hi",
        "ABCD1234", "12345@s.whatsapp.net", false,
        "text", "hello")
    if err == nil {
        t.Fatal("expected error for closed client")
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd bridge && go test -run TestSendTextReply -v ./...`
Expected: FAIL — `c.SendTextReply undefined`.

- [ ] **Step 3: Implement**

Append to `bridge/messages.go`:

```go
// SendTextReply sends a text message that quotes another message.
// quotedKind is one of text/image/video/audio/document/sticker.
// quotedSnippet is what other clients will render if they cannot
// resolve the stanza-id back to the original.
func (c *Client) SendTextReply(
    chatJID, body string,
    quotedID, quotedSenderJID string,
    quotedFromMe bool,
    quotedKind, quotedSnippet string,
) (string, error) {
    if c.wa == nil {
        return "", errors.New("client closed")
    }
    chat, err := types.ParseJID(chatJID)
    if err != nil {
        return "", fmt.Errorf("parse chat: %w", err)
    }
    if chat.User == "" || chat.Server == "" {
        return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
    }
    senderForCtx := quotedSenderJID
    if quotedFromMe {
        if c.wa.Store != nil && c.wa.Store.ID != nil {
            senderForCtx = c.wa.Store.ID.ToNonAD().String()
        }
    } else {
        if _, err := types.ParseJID(quotedSenderJID); err != nil {
            return "", fmt.Errorf("parse quoted sender: %w", err)
        }
    }
    ctx := &waE2E.ContextInfo{
        StanzaID:      proto.String(quotedID),
        Participant:   proto.String(senderForCtx),
        QuotedMessage: stubQuoted(quotedKind, quotedSnippet),
    }
    msg := &waE2E.Message{
        ExtendedTextMessage: &waE2E.ExtendedTextMessage{
            Text:        proto.String(body),
            ContextInfo: ctx,
        },
    }
    resp, err := c.wa.SendMessage(context.Background(), chat, msg)
    if err != nil {
        return "", fmt.Errorf("send: %w", err)
    }
    out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
    return string(out), nil
}

func stubQuoted(kind, snippet string) *waE2E.Message {
    switch kind {
    case "image":
        return &waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String(snippet)}}
    case "video":
        return &waE2E.Message{VideoMessage: &waE2E.VideoMessage{Caption: proto.String(snippet)}}
    case "audio":
        return &waE2E.Message{AudioMessage: &waE2E.AudioMessage{}}
    case "document":
        return &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{FileName: proto.String(snippet)}}
    case "sticker":
        return &waE2E.Message{StickerMessage: &waE2E.StickerMessage{}}
    default: // "text" and unknown kinds
        return &waE2E.Message{Conversation: proto.String(snippet)}
    }
}
```

- [ ] **Step 4: Tests pass**

Run: `cd bridge && go test -run TestSendTextReply -v ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: SendTextReply + stubQuoted helper"
```

---

## Task 3: `EditText` + `RevokeMessage`

**Files:**
- Create: `bridge/edit_revoke.go`
- Create: `bridge/edit_revoke_test.go`

- [ ] **Step 1: Write the failing tests**

Create `bridge/edit_revoke_test.go`:

```go
package bridge

import "testing"

func TestEditTextClosedClient(t *testing.T) {
    c := &Client{}
    if _, err := c.EditText("12@s.whatsapp.net", "ABC", "new"); err == nil {
        t.Fatal("expected error")
    }
}

func TestEditTextRejectsBadJID(t *testing.T) {
    c := &Client{}
    if _, err := c.EditText("not-a-jid", "ABC", "new"); err == nil {
        t.Fatal("expected error")
    }
}

func TestEditTextRejectsEmptyBody(t *testing.T) {
    c := &Client{}
    if _, err := c.EditText("12@s.whatsapp.net", "ABC", ""); err == nil {
        t.Fatal("expected error for empty body")
    }
}

func TestRevokeMessageClosedClient(t *testing.T) {
    c := &Client{}
    if _, err := c.RevokeMessage("12@s.whatsapp.net", "ABC", "", true); err == nil {
        t.Fatal("expected error")
    }
}

func TestRevokeMessageRejectsPeerOwnedV1(t *testing.T) {
    c := &Client{}
    _, err := c.RevokeMessage("12@s.whatsapp.net", "ABC", "55@s.whatsapp.net", false)
    if err == nil {
        t.Fatal("expected error for non-own message in v1")
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `cd bridge && go test -run "TestEditText|TestRevokeMessage" -v ./...`
Expected: FAIL — undefined funcs.

- [ ] **Step 3: Implement**

Create `bridge/edit_revoke.go`:

```go
package bridge

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"

    waE2E "go.mau.fi/whatsmeow/proto/waE2E"
    "go.mau.fi/whatsmeow/types"
    "google.golang.org/protobuf/proto"
)

// EditText replaces the text of a previously-sent message. The
// 15-minute server window is NOT enforced here — the UI hides the
// menu item past 15 min and the server rejects late edits. Returns
// JSON of JSendResult carrying the edit envelope id (UI keeps the
// original msgID for display).
func (c *Client) EditText(chatJID, msgID, newBody string) (string, error) {
    if c.wa == nil {
        return "", errors.New("client closed")
    }
    if newBody == "" {
        return "", errors.New("empty body")
    }
    chat, err := types.ParseJID(chatJID)
    if err != nil {
        return "", fmt.Errorf("parse chat: %w", err)
    }
    if chat.User == "" || chat.Server == "" {
        return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
    }
    newMsg := &waE2E.Message{Conversation: proto.String(newBody)}
    edit := c.wa.BuildEdit(chat, types.MessageID(msgID), newMsg)
    resp, err := c.wa.SendMessage(context.Background(), chat, edit)
    if err != nil {
        return "", fmt.Errorf("send edit: %w", err)
    }
    out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
    return string(out), nil
}

// RevokeMessage sends a REVOKE protocol message. V1 supports only
// targetFromMe=true (revoking my own messages). Group-admin revoke
// of other users' messages is out of scope.
func (c *Client) RevokeMessage(
    chatJID, msgID, targetSenderJID string,
    targetFromMe bool,
) (string, error) {
    if c.wa == nil {
        return "", errors.New("client closed")
    }
    if !targetFromMe {
        return "", errors.New("only own messages")
    }
    chat, err := types.ParseJID(chatJID)
    if err != nil {
        return "", fmt.Errorf("parse chat: %w", err)
    }
    if chat.User == "" || chat.Server == "" {
        return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
    }
    var sender types.JID
    if c.wa.Store != nil && c.wa.Store.ID != nil {
        sender = c.wa.Store.ID.ToNonAD()
    } else {
        sender = chat
    }
    revoke := c.wa.BuildRevoke(chat, sender, types.MessageID(msgID))
    resp, err := c.wa.SendMessage(context.Background(), chat, revoke)
    if err != nil {
        return "", fmt.Errorf("send revoke: %w", err)
    }
    out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
    return string(out), nil
}
```

- [ ] **Step 4: Tests pass**

Run: `cd bridge && go test -run "TestEditText|TestRevokeMessage" -v ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/edit_revoke.go bridge/edit_revoke_test.go
git commit -m "bridge: EditText + RevokeMessage (v1: own-only)"
```

---

## Task 4: Dispatch incoming edits + revokes

**Files:**
- Modify: `bridge/messages.go`
- Test: `bridge/messages_test.go`

Whatsmeow delivers edits + revokes as `events.Message` with a `ProtocolMessage` inside.

- [ ] **Step 1: Write the failing tests**

Append to `bridge/messages_test.go`:

```go
func TestDispatchRevokeEmitsMessageRevoked(t *testing.T) {
    c := newTestClient(t)
    chat, _ := types.ParseJID("12345@s.whatsapp.net")
    sender, _ := types.ParseJID("67890@s.whatsapp.net")
    revokeKey := &waCommon.MessageKey{ID: proto.String("MSG-TO-REVOKE")}
    evt := &events.Message{
        Info: types.MessageInfo{
            MessageSource: types.MessageSource{Chat: chat, Sender: sender},
            ID:            "REVOKE-ENVELOPE",
            Timestamp:     time.Unix(1700000000, 0),
        },
        Message: &waE2E.Message{
            ProtocolMessage: &waE2E.ProtocolMessage{
                Type: waE2E.ProtocolMessage_REVOKE.Enum(),
                Key:  revokeKey,
            },
        },
    }
    c.dispatchMessage(evt)
    kind, payload := c.lastDispatched()
    if kind != "MessageRevoked" {
        t.Fatalf("kind = %q want MessageRevoked", kind)
    }
    var got JMessageRevoked
    if err := json.Unmarshal([]byte(payload), &got); err != nil {
        t.Fatal(err)
    }
    if got.MessageID != "MSG-TO-REVOKE" {
        t.Errorf("MessageID = %q", got.MessageID)
    }
    if got.RevokedBy != sender.String() {
        t.Errorf("RevokedBy = %q", got.RevokedBy)
    }
}

func TestDispatchEditEmitsMessageEdited(t *testing.T) {
    c := newTestClient(t)
    chat, _ := types.ParseJID("12345@s.whatsapp.net")
    sender, _ := types.ParseJID("67890@s.whatsapp.net")
    editKey := &waCommon.MessageKey{ID: proto.String("MSG-EDITED")}
    evt := &events.Message{
        Info: types.MessageInfo{
            MessageSource: types.MessageSource{Chat: chat, Sender: sender},
            ID:            "EDIT-ENVELOPE",
            Timestamp:     time.Unix(1700000050, 0),
        },
        Message: &waE2E.Message{
            ProtocolMessage: &waE2E.ProtocolMessage{
                Type: waE2E.ProtocolMessage_MESSAGE_EDIT.Enum(),
                Key:  editKey,
                EditedMessage: &waE2E.Message{
                    Conversation: proto.String("new text"),
                },
            },
        },
    }
    c.dispatchMessage(evt)
    kind, payload := c.lastDispatched()
    if kind != "MessageEdited" {
        t.Fatalf("kind = %q want MessageEdited", kind)
    }
    var got JMessageEdited
    if err := json.Unmarshal([]byte(payload), &got); err != nil {
        t.Fatal(err)
    }
    if got.MessageID != "MSG-EDITED" || got.NewText != "new text" {
        t.Errorf("got = %+v", got)
    }
}
```

If `newTestClient` / `lastDispatched` helpers don't exist on `*Client`, add them in `events_dispatch_test.go` (or wherever sink stubs already live — check `bridge/events_dispatch_test.go` first). The stub sink must record `kind` + `payload` of the last `dispatch` call. Add these imports to the test file: `time`, `encoding/json`, `proto "google.golang.org/protobuf/proto"`, `waCommon "go.mau.fi/whatsmeow/proto/waCommon"`, `waE2E`, `"go.mau.fi/whatsmeow/types"`, `"go.mau.fi/whatsmeow/types/events"`.

- [ ] **Step 2: Run to confirm failure**

Run: `cd bridge && go test -run "TestDispatch(Revoke|Edit)" -v ./...`
Expected: FAIL.

- [ ] **Step 3: Implement — add the protocol branch**

In `bridge/messages.go::dispatchMessage`, add immediately after the existing `EncReactionMessage` block (before the `PollUpdateMessage` branch):

```go
if pm := evt.Message.GetProtocolMessage(); pm != nil {
    switch pm.GetType() {
    case waE2E.ProtocolMessage_REVOKE:
        key := pm.GetKey()
        if key == nil {
            return
        }
        b, _ := json.Marshal(JMessageRevoked{
            ChatJID:   evt.Info.Chat.String(),
            MessageID: key.GetID(),
            RevokedBy: evt.Info.Sender.String(),
            Timestamp: evt.Info.Timestamp.Unix(),
        })
        c.dispatch("MessageRevoked", string(b))
        return
    case waE2E.ProtocolMessage_MESSAGE_EDIT:
        key := pm.GetKey()
        if key == nil {
            return
        }
        b, _ := json.Marshal(JMessageEdited{
            ChatJID:   evt.Info.Chat.String(),
            MessageID: key.GetID(),
            NewText:   extractText(pm.GetEditedMessage()),
            Timestamp: evt.Info.Timestamp.Unix(),
        })
        c.dispatch("MessageEdited", string(b))
        return
    }
}
```

Add helper in the same file (or alongside `classifyMessage`):

```go
func extractText(m *waE2E.Message) string {
    if m == nil {
        return ""
    }
    if t := m.GetConversation(); t != "" {
        return t
    }
    if e := m.GetExtendedTextMessage(); e != nil {
        return e.GetText()
    }
    return ""
}
```

- [ ] **Step 4: Tests pass**

Run: `cd bridge && go test -run "TestDispatch(Revoke|Edit)" -v ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: dispatch MessageEdited + MessageRevoked"
```

---

## Task 5: Populate `Quoted` on inbound messages

**Files:**
- Modify: `bridge/messages.go`
- Test: `bridge/messages_test.go`

- [ ] **Step 1: Add the failing test**

Append to `bridge/messages_test.go`:

```go
func TestDispatchReplyPopulatesQuoted(t *testing.T) {
    c := newTestClient(t)
    chat, _ := types.ParseJID("12345@s.whatsapp.net")
    sender, _ := types.ParseJID("67890@s.whatsapp.net")
    evt := &events.Message{
        Info: types.MessageInfo{
            MessageSource: types.MessageSource{Chat: chat, Sender: sender},
            ID:            "REPLY-MSG",
            Timestamp:     time.Unix(1700000100, 0),
        },
        Message: &waE2E.Message{
            ExtendedTextMessage: &waE2E.ExtendedTextMessage{
                Text: proto.String("yes please"),
                ContextInfo: &waE2E.ContextInfo{
                    StanzaID:    proto.String("ORIG-ID"),
                    Participant: proto.String("99999@s.whatsapp.net"),
                    QuotedMessage: &waE2E.Message{
                        Conversation: proto.String("dinner at 7?"),
                    },
                },
            },
        },
    }
    c.dispatchMessage(evt)
    kind, payload := c.lastDispatched()
    if kind != "Message" {
        t.Fatalf("kind = %q", kind)
    }
    var got JMessage
    if err := json.Unmarshal([]byte(payload), &got); err != nil {
        t.Fatal(err)
    }
    if got.Quoted == nil {
        t.Fatal("Quoted nil")
    }
    if got.Quoted.MessageID != "ORIG-ID" {
        t.Errorf("MessageID = %q", got.Quoted.MessageID)
    }
    if got.Quoted.Kind != "text" {
        t.Errorf("Kind = %q", got.Quoted.Kind)
    }
    if got.Quoted.Snippet != "dinner at 7?" {
        t.Errorf("Snippet = %q", got.Quoted.Snippet)
    }
}
```

- [ ] **Step 2: Run, fail**

Run: `cd bridge && go test -run TestDispatchReplyPopulatesQuoted -v ./...`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `bridge/messages.go::dispatchMessage`, after the existing block that fills `jm.Text` and BEFORE the media block, add:

```go
if ctx := contextInfoFromMessage(evt.Message); ctx != nil && ctx.GetStanzaID() != "" {
    jm.Quoted = &JQuoted{
        MessageID: ctx.GetStanzaID(),
        SenderJID: ctx.GetParticipant(),
        FromMe:    isFromMe(c, ctx.GetParticipant()),
        Kind:      classifyMessage(ctx.GetQuotedMessage()),
        Snippet:   extractSnippet(ctx.GetQuotedMessage()),
    }
}
```

Add helpers (same file):

```go
func contextInfoFromMessage(m *waE2E.Message) *waE2E.ContextInfo {
    if e := m.GetExtendedTextMessage(); e != nil {
        return e.GetContextInfo()
    }
    if im := m.GetImageMessage(); im != nil {
        return im.GetContextInfo()
    }
    if vm := m.GetVideoMessage(); vm != nil {
        return vm.GetContextInfo()
    }
    if am := m.GetAudioMessage(); am != nil {
        return am.GetContextInfo()
    }
    if dm := m.GetDocumentMessage(); dm != nil {
        return dm.GetContextInfo()
    }
    if sm := m.GetStickerMessage(); sm != nil {
        return sm.GetContextInfo()
    }
    return nil
}

func extractSnippet(m *waE2E.Message) string {
    if m == nil {
        return ""
    }
    if t := m.GetConversation(); t != "" {
        return truncateRunes(t, 120)
    }
    if e := m.GetExtendedTextMessage(); e != nil {
        return truncateRunes(e.GetText(), 120)
    }
    if im := m.GetImageMessage(); im != nil {
        if c := im.GetCaption(); c != "" {
            return truncateRunes(c, 120)
        }
        return "[image]"
    }
    if vm := m.GetVideoMessage(); vm != nil {
        if c := vm.GetCaption(); c != "" {
            return truncateRunes(c, 120)
        }
        return "[video]"
    }
    if am := m.GetAudioMessage(); am != nil {
        _ = am
        return "[audio]"
    }
    if dm := m.GetDocumentMessage(); dm != nil {
        if n := dm.GetFileName(); n != "" {
            return truncateRunes(n, 120)
        }
        return "[document]"
    }
    if sm := m.GetStickerMessage(); sm != nil {
        _ = sm
        return "[sticker]"
    }
    return ""
}

func truncateRunes(s string, n int) string {
    runes := []rune(s)
    if len(runes) <= n {
        return s
    }
    return string(runes[:n]) + "…"
}

func isFromMe(c *Client, jid string) bool {
    if c == nil || c.wa == nil || c.wa.Store == nil || c.wa.Store.ID == nil {
        return false
    }
    return c.wa.Store.ID.ToNonAD().String() == jid
}
```

- [ ] **Step 4: Test passes**

Run: `cd bridge && go test -run TestDispatchReplyPopulatesQuoted -v ./...`
Expected: PASS.

- [ ] **Step 5: Confirm full test pkg still passes**

Run: `cd bridge && go test ./...`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: populate JQuoted on inbound replies"
```

---

## Task 6: History sync — populate Quoted

**Files:**
- Modify: `bridge/history.go`

- [ ] **Step 1: Locate the WebMessageInfo → JMessage converter**

Open `bridge/history.go`. Find the function that builds `JMessage` from `*waE2E.WebMessageInfo` (look for `JMessage{` literal).

- [ ] **Step 2: Add the same `Quoted` population**

After the existing block that fills `Text` / `Media`, add:

```go
if ctx := contextInfoFromMessage(wmi.GetMessage()); ctx != nil && ctx.GetStanzaID() != "" {
    jm.Quoted = &JQuoted{
        MessageID: ctx.GetStanzaID(),
        SenderJID: ctx.GetParticipant(),
        FromMe:    isFromMe(c, ctx.GetParticipant()),
        Kind:      classifyMessage(ctx.GetQuotedMessage()),
        Snippet:   extractSnippet(ctx.GetQuotedMessage()),
    }
}
```

If the converter doesn't have a `*Client` in scope, thread it through (the call site in `history.go` already has the client). Helpers from Task 5 are reused.

- [ ] **Step 3: Verify build**

Run: `cd bridge && go test ./...`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add bridge/history.go
git commit -m "bridge: populate JQuoted on history-sync messages"
```

---

## Task 7: Rebuild `Bridge.xcframework`

**Files:**
- Modify: `build/Bridge.xcframework` (regenerated, gitignored)

- [ ] **Step 1: Build**

Run: `./scripts/build-xcframework.sh`
Expected: SUCCESS. ~5–15 min if not cached.

- [ ] **Step 2: Verify new symbols exist in generated header**

Run: `grep -nE 'SendTextReply|EditText|RevokeMessage' build/Bridge.xcframework/macos-*/Bridge.framework/Headers/*.h`
Expected: each symbol appears as an Objective-C method on `BridgeClient`.

If missing: confirm `gomobile bind` flags include the bridge package and rerun.

No commit — `build/` is gitignored.

---

## Task 8: Persisted-message fields + Message model

**Files:**
- Modify: `yawac/Models/PersistedMessage.swift`
- Modify: `yawac/Models/Message.swift`

- [ ] **Step 1: Extend `PersistedMessage`**

Add the new defaulted fields and update the initializer:

```swift
// New fields
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

Add the matching parameters to `init(...)` (all defaulted) so existing call sites keep compiling.

- [ ] **Step 2: Extend `Message` (transient model)**

Open `yawac/Models/Message.swift`. Add the same nine fields to the struct (and to its init). Update any `Message(from: PersistedMessage)` initializer (search for `init(from persisted` in `Models/`) to copy them across. Update the reverse `PersistedMessage(from: Message)` if it exists.

- [ ] **Step 3: Verify build**

```bash
xcodegen generate
xcodebuild -project yawac.xcodeproj -scheme yawac \
    -destination 'platform=macOS' build \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add yawac/Models/PersistedMessage.swift yawac/Models/Message.swift
git commit -m "model: reply/edit/revoke/local-delete fields"
```

---

## Task 9: Swift — `MessageLifecycle`

**Files:**
- Create: `yawac/Services/MessageLifecycle.swift`
- Test: `yawacTests/MessageLifecycleTests.swift`
- Modify: `project.yml` (if needed — usually XcodeGen picks up the file by directory glob; check after generate)

- [ ] **Step 1: Write the failing test**

Create `yawacTests/MessageLifecycleTests.swift`:

```swift
import XCTest
@testable import yawac

final class MessageLifecycleTests: XCTestCase {
    private func msg(fromMe: Bool, kind: String, ageSec: TimeInterval,
                    revokedAt: Date? = nil, locallyDeleted: Bool = false) -> Message {
        Message(id: "X",
                chatJID: "1@s.whatsapp.net",
                senderJID: "1@s.whatsapp.net",
                fromMe: fromMe,
                timestamp: Date().addingTimeInterval(-ageSec),
                kind: kind,
                text: "hi",
                revokedAt: revokedAt,
                locallyDeleted: locallyDeleted)
    }

    func testCanEditOwnRecentText() {
        XCTAssertTrue(MessageLifecycle.canEdit(msg(fromMe: true, kind: "text", ageSec: 60)))
    }

    func testCannotEditOldText() {
        XCTAssertFalse(MessageLifecycle.canEdit(msg(fromMe: true, kind: "text", ageSec: 16 * 60)))
    }

    func testCannotEditPeerMessage() {
        XCTAssertFalse(MessageLifecycle.canEdit(msg(fromMe: false, kind: "text", ageSec: 60)))
    }

    func testCannotEditNonText() {
        XCTAssertFalse(MessageLifecycle.canEdit(msg(fromMe: true, kind: "image", ageSec: 60)))
    }

    func testCannotEditRevoked() {
        XCTAssertFalse(MessageLifecycle.canEdit(msg(fromMe: true, kind: "text", ageSec: 60, revokedAt: Date())))
    }

    func testCanRevokeOwnRecent() {
        XCTAssertTrue(MessageLifecycle.canRevoke(msg(fromMe: true, kind: "text", ageSec: 3600)))
    }

    func testCannotRevokePastWindow() {
        XCTAssertFalse(MessageLifecycle.canRevoke(msg(fromMe: true, kind: "text", ageSec: 49 * 3600)))
    }

    func testCannotRevokeForeign() {
        XCTAssertFalse(MessageLifecycle.canRevoke(msg(fromMe: false, kind: "text", ageSec: 60)))
    }
}
```

`Message` has the new fields (added in Task 8). The fixture init must pass them.

- [ ] **Step 2: Implement**

Create `yawac/Services/MessageLifecycle.swift`:

```swift
import Foundation

enum MessageLifecycle {
    static let editWindow:   TimeInterval = 15 * 60
    static let revokeWindow: TimeInterval = 48 * 60 * 60

    static func canEdit(_ m: Message, now: Date = .init()) -> Bool {
        guard m.fromMe else { return false }
        guard m.kind == "text" else { return false }
        guard m.revokedAt == nil, m.locallyDeleted == false else { return false }
        return now.timeIntervalSince(m.timestamp) <= editWindow
    }

    static func canRevoke(_ m: Message, now: Date = .init()) -> Bool {
        guard m.fromMe else { return false }
        guard m.revokedAt == nil, m.locallyDeleted == false else { return false }
        return now.timeIntervalSince(m.timestamp) <= revokeWindow
    }
}
```

- [ ] **Step 3: xcodegen + run tests**

```bash
xcodegen generate
xcodebuild -project yawac.xcodeproj -scheme yawac \
    -destination 'platform=macOS' test \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    -only-testing:yawacTests/MessageLifecycleTests
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add yawac/Services/MessageLifecycle.swift yawacTests/MessageLifecycleTests.swift
git commit -m "yawac: MessageLifecycle helper + tests"
```

---

## Task 10: WAClient — new methods + events

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`

- [ ] **Step 1: Add the three send methods**

Insert near the existing `sendReaction` declaration:

```swift
func sendTextReply(_ chatJID: String, _ body: String,
                   quotedID: String, quotedSenderJID: String,
                   quotedFromMe: Bool, quotedKind: String,
                   quotedSnippet: String) throws -> BridgeSendResult {
    var err: NSError?
    let json = go.sendTextReply(
        chatJID, body: body,
        quotedID: quotedID, quotedSenderJID: quotedSenderJID,
        quotedFromMe: quotedFromMe, quotedKind: quotedKind,
        quotedSnippet: quotedSnippet, error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
}

func editText(_ chatJID: String, _ msgID: String, _ newBody: String) throws -> BridgeSendResult {
    var err: NSError?
    let json = go.editText(chatJID, msgID: msgID, newBody: newBody, error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
}

func revokeMessage(_ chatJID: String, _ msgID: String,
                   _ targetSenderJID: String, _ targetFromMe: Bool) throws -> BridgeSendResult {
    var err: NSError?
    let json = go.revokeMessage(chatJID, msgID: msgID,
                                targetSenderJID: targetSenderJID,
                                targetFromMe: targetFromMe, error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
}
```

The exact Objective-C selector names (e.g., `sendTextReply:body:quotedID:...`) depend on gomobile's generator. Run a quick `grep -n sendTextReply build/Bridge.xcframework/macos-*/Bridge.framework/Headers/*.h` to confirm spelling; adjust the call accordingly.

- [ ] **Step 2: Add Event cases**

In the `Event` enum:

```swift
case messageEdited(chatJID: String, messageID: String, newText: String, timestamp: Int64)
case messageRevoked(chatJID: String, messageID: String, revokedBy: String, timestamp: Int64)
```

- [ ] **Step 3: Decode in `decode(kind:payload:)`**

Add cases:

```swift
case "MessageEdited":
    struct E: Codable {
        let chatJID: String; let messageID: String
        let newText: String; let timestamp: Int64
        enum CodingKeys: String, CodingKey {
            case chatJID = "chat_jid"
            case messageID = "message_id"
            case newText = "new_text"
            case timestamp
        }
    }
    if let e = try? dec.decode(E.self, from: data) {
        return .messageEdited(chatJID: e.chatJID, messageID: e.messageID,
                              newText: e.newText, timestamp: e.timestamp)
    }
case "MessageRevoked":
    struct R: Codable {
        let chatJID: String; let messageID: String
        let revokedBy: String; let timestamp: Int64
        enum CodingKeys: String, CodingKey {
            case chatJID = "chat_jid"
            case messageID = "message_id"
            case revokedBy = "revoked_by"
            case timestamp
        }
    }
    if let r = try? dec.decode(R.self, from: data) {
        return .messageRevoked(chatJID: r.chatJID, messageID: r.messageID,
                               revokedBy: r.revokedBy, timestamp: r.timestamp)
    }
```

- [ ] **Step 4: Extend `BridgeMessage` mirror with `quoted`**

Find `BridgeMessage` (likely in `yawac/Bridge/WAClient.swift` or a sibling file). Add:

```swift
let quoted: Quoted?

struct Quoted: Decodable, Equatable {
    let messageID: String
    let senderJID: String
    let fromMe: Bool
    let kind: String
    let snippet: String
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case senderJID = "sender_jid"
        case fromMe = "from_me"
        case kind
        case snippet
    }
}
```

If `BridgeMessage` is auto-decoded via CodingKeys, add `case quoted` to its `CodingKeys`.

- [ ] **Step 5: Build**

```bash
xcodegen generate
xcodebuild -project yawac.xcodeproj -scheme yawac \
    -destination 'platform=macOS' build \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "WAClient: reply/edit/revoke methods + events"
```

---

## Task 11: ConversationViewModel — targets, mutual exclusion, cancel

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`
- Test: `yawacTests/ConversationViewModelTests.swift` (create if absent)

- [ ] **Step 1: Write the failing tests**

Create or append to `yawacTests/ConversationViewModelTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class CVMReplyEditTargetTests: XCTestCase {
    private func makeCVM() -> ConversationViewModel {
        // Use the same constructor existing tests use. If no test
        // helper exists, build the minimum: stub WAClient + session.
        // Adjust to match the actual init signature in this repo.
        // Placeholder:
        ConversationViewModel.testStub()
    }

    func testStartReplyClearsEditTarget() {
        let vm = makeCVM()
        vm.editTarget = Message.fixture(id: "A")
        vm.startReply(to: Message.fixture(id: "B"))
        XCTAssertNil(vm.editTarget)
        XCTAssertEqual(vm.replyTarget?.id, "B")
    }

    func testStartEditClearsReplyTarget() {
        let vm = makeCVM()
        vm.replyTarget = Message.fixture(id: "A")
        vm.startEdit(Message.fixture(id: "B", fromMe: true, kind: "text"))
        XCTAssertNil(vm.replyTarget)
        XCTAssertEqual(vm.editTarget?.id, "B")
    }

    func testCancelComposeClearsBoth() {
        let vm = makeCVM()
        vm.replyTarget = Message.fixture(id: "A")
        vm.editTarget = nil
        vm.cancelCompose()
        XCTAssertNil(vm.replyTarget)
        XCTAssertNil(vm.editTarget)
    }
}
```

If `ConversationViewModel.testStub()` and `Message.fixture(...)` don't exist, add them in a `yawacTests/Support/Fixtures.swift` file with the minimal hand-written stubs needed.

- [ ] **Step 2: Run, expect failure**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
    -destination 'platform=macOS' test \
    -only-testing:yawacTests/CVMReplyEditTargetTests \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL — properties/methods undefined.

- [ ] **Step 3: Implement**

Add to `ConversationViewModel`:

```swift
var replyTarget: Message?
var editTarget: Message?

func startReply(to msg: Message) {
    editTarget = nil
    replyTarget = msg
}

func startEdit(_ msg: Message) {
    replyTarget = nil
    editTarget = msg
}

func cancelCompose() {
    replyTarget = nil
    editTarget = nil
}
```

- [ ] **Step 4: Tests pass**

Run the same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift yawacTests/
git commit -m "CVM: reply/edit targets + mutual exclusion"
```

---

## Task 12: CVM — sendText honors reply, saveEdit, deleteForMe, deleteForEveryone

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`

- [ ] **Step 1: Locate existing `sendText`**

Open `yawac/ViewModels/ConversationViewModel.swift`, find the existing `sendText(...)` (currently around line 561 per repo). It calls `client.sendText(chatJID, body)`.

- [ ] **Step 2: Branch on `replyTarget`**

Replace the send call with:

```swift
let result: BridgeSendResult
if let q = replyTarget {
    let snippet = Self.snippet(for: q)
    result = try client.sendTextReply(
        chatJID, body,
        quotedID: q.id,
        quotedSenderJID: q.senderJID,
        quotedFromMe: q.fromMe,
        quotedKind: q.kind,
        quotedSnippet: snippet)
} else {
    result = try client.sendText(chatJID, body)
}
```

Clear `replyTarget = nil` after `result` is returned (before persisting the local row). Persist the local row with `quotedMessageID`/`quotedSenderJID`/`quotedFromMe`/`quotedTextSnippet`/`quotedKind` populated from `q` when applicable.

Add `Self.snippet(for: Message) -> String` mirroring the bridge's logic: if `kind == "text"` first 120 chars of `text ?? ""`; for media kinds return caption or `[image]` etc.

- [ ] **Step 3: Add `saveEdit`**

```swift
func saveEdit(_ newBody: String) async {
    guard let m = editTarget else { return }
    let trimmed = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != m.text else {
        cancelCompose(); return
    }
    do {
        _ = try await Task.detached { [client, chatJID = self.chatJID, id = m.id] in
            try client.editText(chatJID, id, trimmed)
        }.value
        applyLocalEdit(messageID: m.id, newText: trimmed, at: .init())
        editTarget = nil
    } catch {
        notifyError("Edit not accepted")
    }
}

private func applyLocalEdit(messageID: String, newText: String, at: Date) {
    guard let idx = messages.firstIndex(where: { $0.id == messageID }) else {
        pendingEdits[messageID] = (text: newText, ts: at)
        return
    }
    messages[idx].text = newText
    messages[idx].editedAt = at
    persistEdit(messageID: messageID, newText: newText, editedAt: at)
}
```

(`Task.detached` because `client.editText` is synchronous over gomobile; keep the UI responsive.)

- [ ] **Step 4: Add `deleteForEveryone`**

```swift
func deleteForEveryone(_ msg: Message) async {
    do {
        _ = try await Task.detached { [client, chatJID = self.chatJID, id = msg.id,
                                        sender = msg.senderJID, fromMe = msg.fromMe] in
            try client.revokeMessage(chatJID, id, sender, fromMe)
        }.value
        applyLocalRevoke(messageID: msg.id, by: msg.senderJID, at: .init())
    } catch {
        notifyError("Couldn't delete for everyone")
    }
}

private func applyLocalRevoke(messageID: String, by jid: String, at: Date) {
    guard let idx = messages.firstIndex(where: { $0.id == messageID }) else {
        pendingRevokes[messageID] = (by: jid, ts: at)
        return
    }
    messages[idx].revokedAt = at
    messages[idx].revokedBy = jid
    messages[idx].text = nil
    persistRevoke(messageID: messageID, revokedBy: jid, revokedAt: at)
}
```

- [ ] **Step 5: Add `deleteForMe`**

```swift
func deleteForMe(_ msg: Message) {
    guard let idx = messages.firstIndex(where: { $0.id == msg.id }) else { return }
    messages[idx].locallyDeleted = true
    persistLocallyDeleted(messageID: msg.id, value: true)
}
```

- [ ] **Step 6: Add `notifyError`**

Use whatever toast/banner channel CVM already exposes for transient failures (search the file for an existing `errorBanner` / `transientError` / `inlineWarning`). If none exists, add an `@Published var transientError: String?` and have the view show it.

- [ ] **Step 7: Persist helpers**

```swift
private func persistEdit(messageID: String, newText: String, editedAt: Date) {
    guard let ctx = modelContext else { return }
    let row = try? ctx.fetch(FetchDescriptor<PersistedMessage>(
        predicate: #Predicate { $0.id == messageID })).first
    row?.text = newText
    row?.editedAt = editedAt
    try? ctx.save()
}

private func persistRevoke(messageID: String, revokedBy: String, revokedAt: Date) {
    guard let ctx = modelContext else { return }
    let row = try? ctx.fetch(FetchDescriptor<PersistedMessage>(
        predicate: #Predicate { $0.id == messageID })).first
    row?.revokedAt = revokedAt
    row?.revokedBy = revokedBy
    row?.text = nil
    try? ctx.save()
}

private func persistLocallyDeleted(messageID: String, value: Bool) {
    guard let ctx = modelContext else { return }
    let row = try? ctx.fetch(FetchDescriptor<PersistedMessage>(
        predicate: #Predicate { $0.id == messageID })).first
    row?.locallyDeleted = value
    try? ctx.save()
}
```

Match the actual `ModelContext` access pattern used elsewhere in the CVM (the file already does this for messages — copy that idiom).

- [ ] **Step 8: Build**

```bash
xcodegen generate
xcodebuild -project yawac.xcodeproj -scheme yawac \
    -destination 'platform=macOS' build \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift
git commit -m "CVM: send-reply, save-edit, revoke, delete-for-me"
```

---

## Task 13: CVM — pending stashes + inbound event apply

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`
- Modify: `yawac/ContentView.swift` (event loop)
- Test: `yawacTests/ConversationViewModelTests.swift`

- [ ] **Step 1: Failing test for stash**

Append to `yawacTests/ConversationViewModelTests.swift`:

```swift
@MainActor
final class CVMPendingStashTests: XCTestCase {
    func testIncomingEditAppliesWhenRowPresent() async {
        let vm = ConversationViewModel.testStub()
        vm.messages = [Message.fixture(id: "M1", text: "old")]
        vm.applyIncomingEdit(chatJID: vm.chatJID, messageID: "M1",
                             newText: "new", at: Date())
        XCTAssertEqual(vm.messages[0].text, "new")
        XCTAssertNotNil(vm.messages[0].editedAt)
    }

    func testIncomingEditStashesWhenRowMissing() async {
        let vm = ConversationViewModel.testStub()
        vm.applyIncomingEdit(chatJID: vm.chatJID, messageID: "M1",
                             newText: "new", at: Date())
        vm.messages = [Message.fixture(id: "M1", text: "old")]
        vm.replayPendingForLoadedRows()
        XCTAssertEqual(vm.messages[0].text, "new")
    }

    func testStashLRUCap() async {
        let vm = ConversationViewModel.testStub()
        for i in 0..<300 {
            vm.applyIncomingEdit(chatJID: vm.chatJID,
                                 messageID: "M\(i)", newText: "x", at: Date())
        }
        XCTAssertLessThanOrEqual(vm.pendingEditsCount, 256)
    }
}
```

- [ ] **Step 2: Implement**

Add to `ConversationViewModel`:

```swift
private var pendingEdits:   OrderedDict<String, (text: String, ts: Date)> = .init(cap: 256)
private var pendingRevokes: OrderedDict<String, (by: String, ts: Date)>   = .init(cap: 256)

var pendingEditsCount: Int { pendingEdits.count }

func applyIncomingEdit(chatJID: String, messageID: String, newText: String, at: Date) {
    guard chatJID == self.chatJID else { return }
    if let idx = messages.firstIndex(where: { $0.id == messageID }) {
        messages[idx].text = newText
        messages[idx].editedAt = at
        persistEdit(messageID: messageID, newText: newText, editedAt: at)
    } else {
        pendingEdits[messageID] = (newText, at)
    }
}

func applyIncomingRevoke(chatJID: String, messageID: String, revokedBy: String, at: Date) {
    guard chatJID == self.chatJID else { return }
    if let idx = messages.firstIndex(where: { $0.id == messageID }) {
        messages[idx].revokedAt = at
        messages[idx].revokedBy = revokedBy
        messages[idx].text = nil
        persistRevoke(messageID: messageID, revokedBy: revokedBy, revokedAt: at)
    } else {
        pendingRevokes[messageID] = (revokedBy, at)
    }
}

func replayPendingForLoadedRows() {
    for i in messages.indices {
        let id = messages[i].id
        if let p = pendingEdits.removeValue(forKey: id) {
            messages[i].text = p.text
            messages[i].editedAt = p.ts
            persistEdit(messageID: id, newText: p.text, editedAt: p.ts)
        }
        if let r = pendingRevokes.removeValue(forKey: id) {
            messages[i].revokedAt = r.ts
            messages[i].revokedBy = r.by
            messages[i].text = nil
            persistRevoke(messageID: id, revokedBy: r.by, revokedAt: r.ts)
        }
    }
}
```

Add a tiny `OrderedDict` (LRU) in `yawac/Services/OrderedDict.swift`:

```swift
struct OrderedDict<Key: Hashable, Value> {
    private var map: [Key: Value] = [:]
    private var order: [Key] = []
    let cap: Int
    init(cap: Int) { self.cap = cap }
    var count: Int { map.count }
    subscript(key: Key) -> Value? {
        get { map[key] }
        set {
            if let v = newValue {
                if map[key] == nil { order.append(key) }
                map[key] = v
                if order.count > cap, let oldest = order.first {
                    order.removeFirst()
                    map.removeValue(forKey: oldest)
                }
            } else {
                map.removeValue(forKey: key)
                if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
            }
        }
    }
    mutating func removeValue(forKey k: Key) -> Value? {
        if let idx = order.firstIndex(of: k) { order.remove(at: idx) }
        return map.removeValue(forKey: k)
    }
}
```

- [ ] **Step 3: Wire `ContentView.swift` event loop**

In the existing event-handling switch, add:

```swift
case .messageEdited(let chatJID, let messageID, let newText, let ts):
    cvm.applyIncomingEdit(chatJID: chatJID, messageID: messageID,
                          newText: newText, at: Date(timeIntervalSince1970: TimeInterval(ts)))
case .messageRevoked(let chatJID, let messageID, let revokedBy, let ts):
    cvm.applyIncomingRevoke(chatJID: chatJID, messageID: messageID,
                            revokedBy: revokedBy, at: Date(timeIntervalSince1970: TimeInterval(ts)))
```

- [ ] **Step 4: Call `replayPendingForLoadedRows()` after `loadHistory()`**

In `ConversationView.task`, after the existing `await cvm.loadHistory()`, call `cvm.replayPendingForLoadedRows()`.

- [ ] **Step 5: Tests pass**

```bash
xcodebuild test ... -only-testing:yawacTests/CVMPendingStashTests ...
```

- [ ] **Step 6: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift yawac/ContentView.swift yawac/Services/OrderedDict.swift yawacTests/ConversationViewModelTests.swift
git commit -m "CVM: pending edit/revoke stashes + apply"
```

---

## Task 14: CVM — quoted-source ingest from incoming messages

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`
- Modify: `yawac/ViewModels/ChatListViewModel.swift` (persistMessage)

- [ ] **Step 1: Copy `quoted` into `Message` and `PersistedMessage` on ingest**

In `ConversationViewModel.ingest(...)` and `ChatListViewModel.persistMessage(...)`, when constructing the `Message` / `PersistedMessage` from a `BridgeMessage`, populate:

```swift
quotedMessageID:   bm.quoted?.messageID,
quotedSenderJID:   bm.quoted?.senderJID,
quotedFromMe:      bm.quoted?.fromMe ?? false,
quotedTextSnippet: bm.quoted?.snippet,
quotedKind:        bm.quoted?.kind,
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild ... build ...
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift yawac/ViewModels/ChatListViewModel.swift
git commit -m "ingest: persist quoted fields on inbound messages"
```

---

## Task 15: Composer — quote chip + edit chip

**Files:**
- Modify: `yawac/Views/ComposerView.swift`

- [ ] **Step 1: Read current ComposerView**

Open `yawac/Views/ComposerView.swift`. Note where the `TextField` and Send button live; identify where to insert the chip stack above them.

- [ ] **Step 2: Add chip subviews**

```swift
@ViewBuilder
private var replyChip: some View {
    if let q = cvm.replyTarget {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().frame(width: 3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(quotedSenderName(q))
                    .font(.caption.weight(.semibold))
                Text(q.quotedDisplayText ?? "")
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                cvm.cancelCompose()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.quaternary, in: .rect(cornerRadius: 6))
    }
}

@ViewBuilder
private var editChip: some View {
    if cvm.editTarget != nil {
        HStack {
            Image(systemName: "pencil")
            Text("Editing message").font(.caption)
            Spacer()
            Button {
                cvm.cancelCompose()
                draft = ""
            } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
        }
        .padding(8)
        .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 6))
    }
}
```

`quotedSenderName(_:)` reuses whatever contact-name resolver the row already uses (search for `senderDisplayName(` or `contactNames[`).

- [ ] **Step 3: Stack chips above the `TextField`**

Wrap the existing composer body in a `VStack(spacing: 6) { replyChip; editChip; existingContent }`.

- [ ] **Step 4: Esc + Send/Save handling**

- Add `.onKeyPress(.escape) { cvm.cancelCompose(); return .handled }` on the `TextField`.
- Send button label: `cvm.editTarget != nil ? "Save" : "Send"`.
- In the existing send-button action, branch:

```swift
if cvm.editTarget != nil {
    await cvm.saveEdit(draft)
    draft = ""
} else {
    await cvm.sendText(draft)
    draft = ""
}
```

- Pre-fill `draft` when `editTarget` changes:

```swift
.onChange(of: cvm.editTarget) { _, new in
    if let m = new { draft = m.text ?? "" }
}
```

- Disable Send button while editing if `draft == original.text`.

- [ ] **Step 5: Build + smoke**

```bash
xcodegen generate
xcodebuild ... build ...
```

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/ComposerView.swift
git commit -m "composer: reply quote chip + edit chip"
```

---

## Task 16: MessageRow — context menu, tombstone, quoted strip, edited tag

**Files:**
- Modify: `yawac/Views/MessageRow.swift`

- [ ] **Step 1: Compute menu items**

In the existing `.contextMenu { ... }` body for a row, replace with:

```swift
// Reply — always (except revoked/locally-deleted/system)
if msg.revokedAt == nil, !msg.locallyDeleted, msg.kind != "system" {
    Button("Reply") { cvm.startReply(to: msg) }
}

// Copy
if let t = msg.text, !t.isEmpty, msg.revokedAt == nil, !msg.locallyDeleted {
    Button("Copy text") { NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string) }
}

Divider()

if MessageLifecycle.canEdit(msg) {
    Button("Edit") { cvm.startEdit(msg) }
}
if MessageLifecycle.canRevoke(msg) {
    Button("Delete for everyone", role: .destructive) {
        Task { await cvm.deleteForEveryone(msg) }
    }
}
if !msg.locallyDeleted, msg.revokedAt == nil {
    Button("Delete for me", role: .destructive) {
        cvm.deleteForMe(msg)
    }
}
```

- [ ] **Step 2: Bubble state branches**

In the bubble content builder, branch at the top:

```swift
if msg.revokedAt != nil {
    tombstoneBubble(text: msg.fromMe ? "You deleted this message"
                                     : "This message was deleted")
} else if msg.locallyDeleted {
    tombstoneBubble(text: "You deleted this for yourself")
} else {
    // existing bubble content goes here, with the additions below
}
```

`tombstoneBubble` returns an italic muted Text in the standard bubble shape. No reactions, no Translate footer.

- [ ] **Step 3: Quoted strip**

Inside the non-tombstone branch, render above the main content when `msg.quotedMessageID != nil`:

```swift
Button {
    if let id = msg.quotedMessageID { cvm.jumpToQuoted(id: id) }
} label: {
    HStack(alignment: .top, spacing: 6) {
        Rectangle().frame(width: 3).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
            Text(quotedSenderName(for: msg))
                .font(.caption.weight(.semibold))
            Text(msg.quotedTextSnippet ?? "")
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)
        }
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .background(.quaternary, in: .rect(cornerRadius: 4))
}
.buttonStyle(.plain)
```

`quotedSenderName(for:)` falls back to the JID's user part if no contact name is known.

- [ ] **Step 4: Edited tag**

Where the timestamp is rendered, after the time string:

```swift
if msg.editedAt != nil {
    Text(" · edited")
        .help("Edited \(msg.editedAt!.formatted(.relative(presentation: .named)))")
}
```

- [ ] **Step 5: Build**

```bash
xcodegen generate
xcodebuild ... build ...
```

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/MessageRow.swift
git commit -m "MessageRow: tombstone + quoted strip + edited tag + menu"
```

---

## Task 17: ConversationView — scroll-to-quoted + flash

**Files:**
- Modify: `yawac/Views/ConversationView.swift`
- Modify: `yawac/ViewModels/ConversationViewModel.swift`

- [ ] **Step 1: Add VM hooks**

```swift
var pendingScrollToID: String?
var highlightedID: String?

func jumpToQuoted(id: String) {
    if messages.contains(where: { $0.id == id }) {
        pendingScrollToID = id
    } else {
        Task { await loadHistory(until: id) }
    }
}

func didFinishScroll(to id: String) {
    highlightedID = id
    Task {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if highlightedID == id { highlightedID = nil }
    }
}
```

`loadHistory(until:)` — extend existing `loadHistory` to page back up to 2000 rows or until the row appears, then set `pendingScrollToID = id`. On exhaustion, set a transient toast "Original not available".

- [ ] **Step 2: Wrap list in `ScrollViewReader`**

In `ConversationView` body, wrap the `List`/`LazyVStack` in:

```swift
ScrollViewReader { proxy in
    // existing list
    .onChange(of: cvm.pendingScrollToID) { _, id in
        guard let id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .center) }
        cvm.didFinishScroll(to: id)
        cvm.pendingScrollToID = nil
    }
}
```

Make sure each row has `.id(msg.id)`.

- [ ] **Step 3: Flash highlight**

In `MessageRow`, add:

```swift
.background(
    cvm.highlightedID == msg.id
        ? Color.accentColor.opacity(0.18)
        : Color.clear
)
.animation(.easeOut(duration: 0.3), value: cvm.highlightedID)
```

- [ ] **Step 4: Build**

```bash
xcodegen generate
xcodebuild ... build ...
```

- [ ] **Step 5: Commit**

```bash
git add yawac/Views/ConversationView.swift yawac/ViewModels/ConversationViewModel.swift
git commit -m "conversation: jump-to-quoted + flash highlight"
```

---

## Task 18: Sidebar preview reflects revoke + local delete + edit

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift`

- [ ] **Step 1: Recompute preview on edit/revoke/local-delete**

The chat list already derives `lastMessageText` in `persistMessage`. Add a helper that re-derives a preview for any state:

```swift
private func previewText(for m: PersistedMessage) -> String {
    if m.revokedAt != nil { return "🚫 message deleted" }
    if m.locallyDeleted   { return "🚫 you deleted this" }
    return m.text ?? "" // existing fallback (caption / kind label) goes here
}
```

Use it everywhere the sidebar last-line is computed (`persistMessage`, plus new `applyEdit`/`applyRevoke`/`applyLocalDelete` hooks the CVM can call after mutating a row).

Expose:

```swift
func refreshPreview(chatJID: String)
```

…that re-queries the latest message row and updates the chat's `lastMessageText`/`lastTimestamp`. The CVM calls this after each mutate.

- [ ] **Step 2: Wire CVM → chat list refresh**

Add `weak var chatList: ChatListViewModel?` if not already present (the conversation view-model already has a session back-ref via the `SessionViewModel.chatList` shortcut — reuse it). After `applyLocalEdit`, `applyLocalRevoke`, `deleteForMe`, call `session.chatList?.refreshPreview(chatJID: chatJID)`.

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild ... build ...
```

- [ ] **Step 4: Commit**

```bash
git add yawac/ViewModels/ChatListViewModel.swift yawac/ViewModels/ConversationViewModel.swift
git commit -m "sidebar: preview reflects revoke/edit/local-delete"
```

---

## Task 19: Translation cache invalidation on edit

**Files:**
- Modify: `yawac/Services/TranslationStore.swift` (or wherever cache key is built)
- Modify: `yawac/Views/MessageRow.swift`

- [ ] **Step 1: Key cache on `id + editedAt`**

Find the cache key used by `TranslationStore` (likely `msg.id`). Change to `"\(msg.id)#\(msg.editedAt?.timeIntervalSince1970 ?? 0)"`. Touch every call site that reads/writes the cache.

- [ ] **Step 2: Suppress translate footer on tombstone**

In `MessageRow`, where the Translate footer is rendered, gate it on `msg.revokedAt == nil && !msg.locallyDeleted`.

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild ... build ...
```

- [ ] **Step 4: Commit**

```bash
git add yawac/Services/TranslationStore.swift yawac/Views/MessageRow.swift
git commit -m "translation: invalidate on edit, skip tombstones"
```

---

## Task 20: Manual UI smoke + golden-path verification

**Files:** none (verification only)

- [ ] **Step 1: Run the app**

```bash
xcodegen generate && open yawac.xcodeproj
```

Run from Xcode. Use a paired account.

- [ ] **Step 2: Smoke checklist**

For each, verify on yawac AND on the WhatsApp companion (mobile):

- [ ] Send a text reply quoting your own text. Both clients render quote strip with snippet.
- [ ] Send a text reply quoting an image. Quote strip shows `[image]` or the caption.
- [ ] Send a text reply quoting peer text in a group.
- [ ] Edit own text within 15 min. Bubble updates inline, `edited` tag appears. Peer sees same.
- [ ] Try editing >15 min old: `Edit` menu item is hidden.
- [ ] Right-click peer text: `Edit` and `Delete for everyone` are hidden.
- [ ] Delete for everyone within 48 h. Local bubble becomes "You deleted this message". Peer sees "This message was deleted".
- [ ] Try revoking >48 h old: menu item hidden.
- [ ] Delete for me on a foreign message: tombstone "You deleted this for yourself" locally only; peer unaffected.
- [ ] Click a quoted strip → list scrolls to original, flashes briefly.
- [ ] Click a quoted strip whose source is past the current loaded window → history pages in then scrolls.
- [ ] Sidebar last-message reflects revoke / local delete with 🚫 prefix.
- [ ] Receiving an edit from peer: bubble updates, `edited` tag appears, no notification raised.
- [ ] Receiving a revoke from peer: bubble becomes tombstone, no notification raised.
- [ ] Out-of-order: switch chat, have peer edit a recent message, switch back — edit is applied (replayed from stash).
- [ ] Quit + relaunch: `editedAt`, `revokedAt`, `locallyDeleted` persist.
- [ ] Translation footer is hidden on tombstone bubbles. After editing a foreign message that had a cached translation, the cache is dropped (clicking Translate re-fetches).

- [ ] **Step 3: If a step fails**

Open the relevant file, write the smallest fix, run only the tests it touches, commit, and re-verify the failing step.

- [ ] **Step 4: Mark task complete and announce**

No commit. The feature is shipped when every smoke item above passes.

---

## Wrap-up

After Task 20:

- Run full test suites once more:

```bash
cd bridge && go test ./...
xcodebuild -project yawac.xcodeproj -scheme yawac \
    -destination 'platform=macOS' test \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

- Push to `main`. The release workflow will publish a new edge cask build automatically.

- Out-of-scope items (recorded in spec): edit/revoke of media, admin revoke, edit history, undo for "Delete for me", reply-with-media, editing media captions.
