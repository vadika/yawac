# v0.8.1 — Disappearing Thread-Through + View-Once Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close two known v0.8.0 gaps — (1) thread chat-level `ephemeralSec` into the six send paths still hardcoded to `0` (reply / edit / forward-text / forward-media / reaction / poll-vote), and (2) auto-replay history on first v0.8.1 boot so pre-v0.8.0 view-once messages get re-classified and 1:1 disappearing timers hydrate without waiting for the next inbound.

**Architecture:** Six bridge funcs gain `ephemeralSec int32` as the last positional arg; bodies wrap via the existing `wrapForChat` helper (v0.8.0 T1). `EditText` accepts the param but defers wrapping per WhatsApp's edit-inherits-original convention. New `RequestFullHistorySync` wraps `whatsmeow.BuildHistorySyncRequest`. `SessionViewModel` gains a one-shot `@AppStorage` gate that fires the request on `.connected`; `ContentView` flips the flag on the first inbound `events.HistorySync`.

**Tech Stack:** Go (whatsmeow `go.mau.fi/whatsmeow`), Swift / SwiftUI / `@Observable`, SwiftData (existing), `@AppStorage`, XCTest, `go test`.

**Test commands:**

```bash
# Go side
cd bridge && go test -short ./...

# Swift side
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

When a task touches only Go code, run only the Go command. When a task touches Swift code, build + test.

**Worktree:** Set up via `superpowers:using-git-worktrees` before starting (branch `worktree-disappearing-backfill-v0.8.1`, base = `main`).

**Spec:** `docs/superpowers/specs/2026-06-05-disappearing-thread-viewonce-backfill-design.md` is the design source of truth; cite it when in doubt.

---

## Milestone A — Bridge (Go) send-path threading

### Task 1: Thread `ephemeralSec` into `SendReaction`

**Files:**
- Modify: `bridge/messages.go` (existing `SendReaction` at line 118)
- Test: `bridge/messages_test.go`

- [ ] **Step 1: Write the failing test**

Append to `bridge/messages_test.go`:

```go
func TestSendReactionEphemeralWrap(t *testing.T) {
	// Build the inner Reaction message + wrap manually, then assert
	// the wrap structure round-trips through wrapForChat as expected.
	// wrapForChat itself is covered by Task 1 of v0.8.0; this test
	// pins the SendReaction signature so the new ephemeralSec param
	// is present and routed.
	c, _ := NewClient(t.TempDir() + "/sr.db")
	defer c.Close()
	_, err := c.SendReaction("1@s.whatsapp.net", "MSG1", "1@s.whatsapp.net", false, "👍", 86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSendReactionSignatureCompiles(t *testing.T) {
	// Compile-time guard: signature must accept ephemeralSec as the
	// last positional arg.
	var _ func(*Client) func(string, string, string, bool, string, int32) (string, error) =
		func(c *Client) func(string, string, string, bool, string, int32) (string, error) {
			return c.SendReaction
		}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run "TestSendReaction" -short
```

Expected: FAIL with type mismatch on `c.SendReaction` (current signature has 5 args; test calls with 6).

- [ ] **Step 3: Modify `SendReaction`**

In `bridge/messages.go`, locate the existing `SendReaction` at line 118. Change the signature to add `ephemeralSec int32` as the last param. Inside the body, build the existing inner `*waE2E.Message`, then route through `wrapForChat`:

```go
func (c *Client) SendReaction(
	chatJID, targetMsgID, targetSenderJID string, targetFromMe bool,
	emoji string,
	ephemeralSec int32,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	target, err := types.ParseJID(targetSenderJID)
	if err != nil {
		return "", fmt.Errorf("parse target sender: %w", err)
	}
	inner := &waE2E.Message{
		ReactionMessage: &waE2E.ReactionMessage{
			Key: &waCommon.MessageKey{
				RemoteJID:   proto.String(chatJID),
				FromMe:      proto.Bool(targetFromMe),
				ID:          proto.String(targetMsgID),
				Participant: proto.String(target.String()),
			},
			Text:              proto.String(emoji),
			SenderTimestampMS: proto.Int64(time.Now().UnixMilli()),
		},
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send reaction: %w", err)
	}
	out := JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()}
	b, _ := json.Marshal(out)
	return string(b), nil
}
```

> **Note for engineer:** preserve the existing inner-build logic verbatim. The body shown above is illustrative — read the actual current implementation (lines 118-ish to ~155) and only insert the `wrapForChat(...)` call between the inner build and `c.wa.SendMessage`. Do NOT change `ReactionMessage` field names if the existing impl uses different ones.

- [ ] **Step 4: Update existing callers in the bridge test suite**

Search for any in-test call sites that pass only 5 args:

```bash
grep -nE "c\.SendReaction\(" bridge/*_test.go
```

Update them to pass `0` for the new last arg.

- [ ] **Step 5: Run tests**

```bash
cd bridge && go test -short ./...
```

Expected: all green (130 baseline + 2 new = 132).

- [ ] **Step 6: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: SendReaction threads ephemeralSec for disappearing-chat retention"
```

---

### Task 2: Thread `ephemeralSec` into `SendTextReply`

**Files:**
- Modify: `bridge/messages.go` (existing `SendTextReply` at line 955)
- Test: `bridge/messages_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestSendTextReplyEphemeralWrap(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/str.db")
	defer c.Close()
	_, err := c.SendTextReply(
		"1@s.whatsapp.net", "hi",
		"QUOTEDMSG", "1@s.whatsapp.net", false,
		"text", "previous",
		`[]`,
		86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSendTextReplySignatureCompiles(t *testing.T) {
	var _ func(*Client) func(string, string, string, string, bool, string, string, string, int32) (string, error) =
		func(c *Client) func(string, string, string, string, bool, string, string, string, int32) (string, error) {
			return c.SendTextReply
		}
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd bridge && go test -run "TestSendTextReply" -short
```

Expected: FAIL (compile — current signature has 8 args; test calls with 9).

- [ ] **Step 3: Modify `SendTextReply`**

In `bridge/messages.go`, find the existing `SendTextReply` (~line 955). Add `ephemeralSec int32` as the last positional arg. Between the inner `ExtendedTextMessage` build (which carries `ContextInfo` for the quote) and the `SendMessage` call, insert `wrapForChat`. Example:

```go
func (c *Client) SendTextReply(
	chatJID, body, quotedID, quotedSenderJID string,
	quotedFromMe bool, quotedKind, quotedSnippet string,
	mentionedJIDsJSON string,
	ephemeralSec int32,
) (string, error) {
	// ... existing parse + mention prep + inner ExtendedTextMessage build ...

	inner := &waE2E.Message{
		ExtendedTextMessage: extMsg, // existing built ExtendedTextMessage with ContextInfo
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	// ... existing return shape ...
}
```

> **Note:** preserve the existing reply-quote `ContextInfo` build verbatim. `wrapForChat` applies on top.

- [ ] **Step 4: Update existing test callers**

```bash
grep -nE "c\.SendTextReply\(" bridge/*_test.go
```

Update any 8-arg callsite to pass `0` as the new last arg.

- [ ] **Step 5: Run tests**

```bash
cd bridge && go test -short ./...
```

Expected: all green (132 + 2 new = 134).

- [ ] **Step 6: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: SendTextReply threads ephemeralSec for disappearing-chat retention"
```

---

### Task 3: Thread `ephemeralSec` into `ForwardText`

**Files:**
- Modify: `bridge/messages.go` (existing `ForwardText` at line 229)
- Test: `bridge/messages_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestForwardTextEphemeralWrap(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ft.db")
	defer c.Close()
	_, err := c.ForwardText("1@s.whatsapp.net", "hi", 86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd bridge && go test -run "TestForwardText" -short
```

Expected: FAIL.

- [ ] **Step 3: Modify `ForwardText`**

Add `ephemeralSec int32` as last positional. Pattern:

```go
func (c *Client) ForwardText(
	chatJID, text string,
	ephemeralSec int32,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	inner := &waE2E.Message{
		ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: proto.String(text),
			ContextInfo: &waE2E.ContextInfo{
				IsForwarded:     proto.Bool(true),
				ForwardingScore: proto.Uint32(1),
			},
		},
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("forward text: %w", err)
	}
	out := JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()}
	b, _ := json.Marshal(out)
	return string(b), nil
}
```

> Preserve the existing forwarding-score handling if the current impl uses a different value.

- [ ] **Step 4: Update existing callers**

```bash
grep -nE "c\.ForwardText\(" bridge/*_test.go
```

- [ ] **Step 5: Run tests**

```bash
cd bridge && go test -short ./...
```

Expected: 135 passing.

- [ ] **Step 6: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: ForwardText threads ephemeralSec for destination chat retention"
```

---

### Task 4: Thread `ephemeralSec` into `ForwardMedia`

**Files:**
- Modify: `bridge/messages.go` (existing `ForwardMedia` at line 257)
- Test: `bridge/messages_test.go`

- [ ] **Step 1: Write failing test**

```go
func TestForwardMediaEphemeralWrap(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/fm.db")
	defer c.Close()
	_, err := c.ForwardMedia(
		"1@s.whatsapp.net",
		`{"kind":"image","url":"u","direct_path":"p","media_key":"AA==","file_enc_sha256":"AA==","file_sha256":"AA==","file_length":1,"mimetype":"image/jpeg"}`,
		"caption", "name.jpg",
		86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd bridge && go test -run "TestForwardMedia" -short
```

- [ ] **Step 3: Modify `ForwardMedia`**

Add `ephemeralSec int32` last. Inside the body, after building the inner `*waE2E.Message` from the deserialized `JMediaRef`, route through `wrapForChat`:

```go
// ... existing parse + JMediaRef unmarshal + per-kind inner build ...
inner := /* existing built *waE2E.Message */
msg := wrapForChat(inner, ephemeralSec, false)
resp, err := c.wa.SendMessage(context.Background(), jid, msg)
// ... existing return ...
```

> Preserve every existing branch of the per-kind switch (Image / Video / Audio / Document / Sticker).

- [ ] **Step 4: Update existing callers**

```bash
grep -nE "c\.ForwardMedia\(" bridge/*_test.go
```

- [ ] **Step 5: Run tests**

```bash
cd bridge && go test -short ./...
```

Expected: 136 passing.

- [ ] **Step 6: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: ForwardMedia threads ephemeralSec for destination chat retention"
```

---

### Task 5: Thread `ephemeralSec` into `EditText` (param accepted, NOT wrapped)

**Files:**
- Modify: `bridge/edit_revoke.go` (existing `EditText` at line 19)
- Test: `bridge/edit_revoke_test.go`

- [ ] **Step 1: Write failing test**

Append to `bridge/edit_revoke_test.go`:

```go
func TestEditTextEphemeralAcceptedNotWrapped(t *testing.T) {
	// EditText accepts ephemeralSec for signature parity with the
	// other five threaded sends, but does NOT wrap. WhatsApp's
	// protocol convention: edits inherit the original message's
	// expiration. This test pins both the signature and the
	// no-op behavior (unpaired-client error path covers signature;
	// the no-wrap behavior is a documented invariant in the spec).
	c, _ := NewClient(t.TempDir() + "/et.db")
	defer c.Close()
	_, err := c.EditText(
		"1@s.whatsapp.net", "MSG1", "fixed body",
		`[]`,
		86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestEditTextSignatureCompiles(t *testing.T) {
	var _ func(*Client) func(string, string, string, string, int32) (string, error) =
		func(c *Client) func(string, string, string, string, int32) (string, error) {
			return c.EditText
		}
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd bridge && go test -run "TestEditText" -short
```

- [ ] **Step 3: Modify `EditText`**

Add `ephemeralSec int32` last. Do NOT wrap — leave the existing `ProtocolMessage{Type: MESSAGE_EDIT, ...}` build untouched. Add a doc comment explaining the deferral:

```go
// EditText edits a previously-sent text message. The ephemeralSec
// parameter is accepted for signature parity with the other five
// threaded sends but is intentionally NOT wrapped via wrapForChat:
// WhatsApp protocol convention is that edits inherit the original
// message's expiration timer, so an additional EphemeralMessage
// wrap is unnecessary (and may be rejected by the server). The
// parameter is reserved for a future protocol-level change.
func (c *Client) EditText(
	chatJID, msgID, newBody, mentionedJIDsJSON string,
	ephemeralSec int32,
) (string, error) {
	_ = ephemeralSec // intentional: see doc comment above
	// ... existing body verbatim ...
}
```

- [ ] **Step 4: Update existing callers**

```bash
grep -nE "c\.EditText\(" bridge/*_test.go
```

- [ ] **Step 5: Run tests**

```bash
cd bridge && go test -short ./...
```

Expected: 138 passing.

- [ ] **Step 6: Commit**

```bash
git add bridge/edit_revoke.go bridge/edit_revoke_test.go
git commit -m "bridge: EditText accepts ephemeralSec (no-op; edits inherit original's expiration)"
```

---

### Task 6: Thread `ephemeralSec` into `SendPollVote`

**Files:**
- Modify: `bridge/polls.go` (existing `SendPollVote` at line 87)
- Test: `bridge/polls_test.go`

- [ ] **Step 1: Write failing test**

```go
func TestSendPollVoteEphemeralWrap(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/spv.db")
	defer c.Close()
	_, err := c.SendPollVote(
		"1@s.whatsapp.net", "POLL1", "1@s.whatsapp.net", false,
		`[]`, `[]`,
		86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd bridge && go test -run "TestSendPollVote" -short
```

- [ ] **Step 3: Modify `SendPollVote`**

Add `ephemeralSec int32` last. Inside the body, after the inner `PollUpdateMessage` is built, wrap via `wrapForChat`:

```go
// ... existing parse + selection prep + inner *waE2E.Message build ...
inner := &waE2E.Message{
	PollUpdateMessage: pollUpdate, // existing built PollUpdateMessage
}
msg := wrapForChat(inner, ephemeralSec, false)
resp, err := c.wa.SendMessage(context.Background(), jid, msg)
// ... existing return ...
```

- [ ] **Step 4: Update existing callers**

```bash
grep -nE "c\.SendPollVote\(" bridge/*_test.go
```

- [ ] **Step 5: Run tests**

```bash
cd bridge && go test -short ./...
```

Expected: 139 passing.

- [ ] **Step 6: Commit**

```bash
git add bridge/polls.go bridge/polls_test.go
git commit -m "bridge: SendPollVote threads ephemeralSec for disappearing-chat retention"
```

---

### Task 7: New `RequestFullHistorySync` bridge func

**Files:**
- Create: `bridge/history_request.go`
- Create: `bridge/history_request_test.go`

- [ ] **Step 1: Write failing tests**

Create `bridge/history_request_test.go`:

```go
package bridge

import (
	"testing"
)

func TestRequestFullHistorySyncUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/hr.db")
	defer c.Close()
	err := c.RequestFullHistorySync(
		"1@s.whatsapp.net", "MSG1", false, 1700000000, 100000)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestRequestFullHistorySyncBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/hr2.db")
	defer c.Close()
	err := c.RequestFullHistorySync(
		"not a jid", "MSG1", false, 1700000000, 100000)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestRequestFullHistorySyncSignatureCompiles(t *testing.T) {
	var _ func(*Client) func(string, string, bool, int64, int32) error =
		func(c *Client) func(string, string, bool, int64, int32) error {
			return c.RequestFullHistorySync
		}
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd bridge && go test -run "TestRequestFullHistorySync" -short
```

Expected: FAIL (compile — undefined `c.RequestFullHistorySync`).

- [ ] **Step 3: Implement**

Create `bridge/history_request.go`:

```go
package bridge

import (
	"context"
	"errors"
	"fmt"
	"time"

	"go.mau.fi/whatsmeow/types"
)

// RequestFullHistorySync builds an on-demand history-sync request
// anchored on a known (chatJID, msgID, fromMe, ts) tuple and sends
// it to the user's own JID. The server replies with one or more
// events.HistorySync; existing applyHistorySync persists their
// messages through the v0.8.0 classifier (isViewOnce +
// ContextInfo.Expiration hint).
//
// count is the requested message count; whatsmeow and the server
// cap below the requested value in practice.
func (c *Client) RequestFullHistorySync(
	beforeChatJID, beforeMsgID string, beforeFromMe bool,
	beforeTSUnix int64,
	count int32,
) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(beforeChatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return fmt.Errorf("parse chat: empty user or server")
	}
	if c.wa.Store == nil || c.wa.Store.ID == nil {
		return errors.New("not logged in")
	}
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{
			Chat:     chat,
			IsFromMe: beforeFromMe,
		},
		ID:        beforeMsgID,
		Timestamp: time.Unix(beforeTSUnix, 0),
	}
	req := c.wa.BuildHistorySyncRequest(info, int(count))
	if req == nil {
		return errors.New("nil history-sync request")
	}
	own := c.wa.Store.ID.ToNonAD()
	if _, err := c.wa.SendMessage(context.Background(), own, req); err != nil {
		return fmt.Errorf("send history-sync request: %w", err)
	}
	return nil
}
```

> **Note for engineer:** confirm `BuildHistorySyncRequest`'s exact signature with `grep -n "func.*BuildHistorySyncRequest" $(go env GOMODCACHE)/github.com/vadika/whatsmeow@*/send.go`. The plan assumes `BuildHistorySyncRequest(lastInfo *types.MessageInfo, count int) *waE2E.Message`. If different, adjust the call.

- [ ] **Step 4: Run tests**

```bash
cd bridge && go test -short ./...
```

Expected: 142 passing (139 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add bridge/history_request.go bridge/history_request_test.go
git commit -m "bridge: RequestFullHistorySync wraps whatsmeow.BuildHistorySyncRequest"
```

---

## Milestone B — Swift bridge wrappers

### Task 8: Rebuild xcframework + update WAClient wrappers

**Files:**
- Modify: `yawac/Bridge/WAClient.swift` (six existing wrappers + one new)

- [ ] **Step 1: Rebuild xcframework**

```bash
./scripts/build-xcframework.sh
```

Expected: completes without error; new gomobile symbols (`sendReaction` selector with new param, etc.) appear in `build/Bridge.xcframework`.

- [ ] **Step 2: Update existing wrappers**

For each of the six existing wrappers — `sendReaction`, `sendTextReply`, `editText`, `forwardText`, `forwardMedia`, `sendPollVote` — perform these edits:

1. Add `nonisolated` keyword if not already present (matches v0.8.0 nonisolated pattern; allows callers from `Task.detached` without `await`).
2. Add `ephemeralSeconds: Int32 = 0` as the last parameter (default-zero keeps existing call sites compiling unchanged).
3. Pass `ephemeralSeconds` to the gomobile call with selector `ephemeralSec:` (matches the Go param name).

Example for `sendReaction`:

```swift
nonisolated func sendReaction(chatJID: String,
                              targetMsgID: String,
                              targetSenderJID: String,
                              targetFromMe: Bool,
                              emoji: String,
                              ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
    var err: NSError?
    let json = go.sendReaction(chatJID,
                               targetMsgID: targetMsgID,
                               targetSenderJID: targetSenderJID,
                               targetFromMe: targetFromMe,
                               emoji: emoji,
                               ephemeralSec: ephemeralSeconds,
                               error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
}
```

Apply the same shape to the other five. Confirm exact gomobile selector names from `build/Bridge.xcframework/macos-arm64_x86_64/Bridge.framework/Versions/A/Headers/Bridge.objc.h`.

- [ ] **Step 3: Add new `requestFullHistorySync` wrapper**

Append:

```swift
nonisolated func requestFullHistorySync(beforeChatJID: String,
                                        beforeMsgID: String,
                                        beforeFromMe: Bool,
                                        beforeTSUnix: Int64,
                                        count: Int32) throws {
    try go.requestFullHistorySync(beforeChatJID,
                                  beforeMsgID: beforeMsgID,
                                  beforeFromMe: beforeFromMe,
                                  beforeTSUnix: beforeTSUnix,
                                  count: count)
}
```

- [ ] **Step 4: Regenerate + build**

```bash
xcodegen generate
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

> **Build-failure recovery:** if a selector name mismatch appears, grep `Bridge.objc.h` for the exact selector and adjust. The selectors for the six existing methods may differ from the spec above if gomobile derived param names differently (e.g. `targetMsgID:` vs `targetMsgIDStr:`).

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "WAClient: six send wrappers thread ephemeralSeconds + requestFullHistorySync wrapper"
```

---

## Milestone C — CVM call-site threading

### Task 9: Thread `ephemeralExpirationSeconds` into reply / edit / reaction / poll-vote sites

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`
- Test: `yawacTests/ConversationViewModelSendDispatchTests.swift`

- [ ] **Step 1: Locate call sites**

```bash
grep -nE "client\.sendReaction\(|client\.sendTextReply\(|client\.editText\(|client\.sendPollVote\(" yawac/ViewModels/ConversationViewModel.swift
```

- [ ] **Step 2: Write failing tests**

Append to `yawacTests/ConversationViewModelSendDispatchTests.swift`:

```swift
@MainActor
func testReplySendThreadsEphemeralExpiration() async {
    let vm = ConversationViewModel.testFixture()
    vm.ephemeralExpirationSeconds = 86400
    // ... existing test fixture setup: simulate a reply target ...
    // Assert that the stubbed sendTextReply receives 86400 as
    // ephemeralSeconds. (Use the same stub-client pattern as the
    // v0.8.0 SendDispatch tests.)
    XCTAssertEqual(stubClient.lastSendTextReplyEphemeralSeconds, 86400)
}

@MainActor
func testEditThreadsEphemeralExpiration() async {
    let vm = ConversationViewModel.testFixture()
    vm.ephemeralExpirationSeconds = 86400
    // ... fire saveEdit on an existing message ...
    XCTAssertEqual(stubClient.lastEditTextEphemeralSeconds, 86400)
}

@MainActor
func testReactionThreadsEphemeralExpiration() async {
    let vm = ConversationViewModel.testFixture()
    vm.ephemeralExpirationSeconds = 604800
    await vm.reactToMessage(id: "M1", senderJID: "1@s.whatsapp.net",
                            fromMe: false, emoji: "👍")
    XCTAssertEqual(stubClient.lastSendReactionEphemeralSeconds, 604800)
}

@MainActor
func testPollVoteThreadsEphemeralExpiration() async {
    let vm = ConversationViewModel.testFixture()
    vm.ephemeralExpirationSeconds = 86400
    // ... fire castVote on an existing poll ...
    XCTAssertEqual(stubClient.lastSendPollVoteEphemeralSeconds, 86400)
}
```

> **Note for engineer:** the existing `ConversationViewModelSendDispatchTests` from v0.8.0 already establishes a stub-client pattern. Extend the stub to capture the new `ephemeralSeconds:` parameter on each of these four methods. The test assertions above are illustrative — adapt to the actual stub shape.

- [ ] **Step 3: Run to verify failure**

```bash
xcodebuild ... test -only-testing:yawacTests/ConversationViewModelSendDispatchTests
```

Expected: FAIL (stub doesn't capture the new param yet, or the four CVM call sites still pass `0` / nothing).

- [ ] **Step 4: Update CVM call sites**

For each of the four sites — reply (in `sendDraft`), saveEdit, reactToMessage, castVote — replace the existing `client.sendXxx(...)` call to add `ephemeralSeconds: ephemeralExpirationSeconds` as the last arg. Example for `sendTextReply` (around line 1159):

```swift
try client.sendTextReply(
    chatJID,
    body: text,
    quotedID: q.id,
    quotedSenderJID: q.senderJID,
    quotedFromMe: q.fromMe,
    quotedKind: q.kind,
    quotedSnippet: q.snippet,
    mentionedJIDs: mentioned,
    ephemeralSeconds: ephemeralExpirationSeconds)
```

For `editText` (around line 1751):

```swift
try client.editText(
    chatJID: chatJID,
    msgID: target.id,
    newBody: newBody,
    mentionedJIDs: mentioned,
    ephemeralSeconds: ephemeralExpirationSeconds)
```

For `sendReaction` (find via grep — likely in `reactToMessage` or similar):

```swift
try client.sendReaction(
    chatJID: chatJID,
    targetMsgID: msgID,
    targetSenderJID: senderJID,
    targetFromMe: fromMe,
    emoji: emoji,
    ephemeralSeconds: ephemeralExpirationSeconds)
```

For `sendPollVote` (in `castVote`):

```swift
try client.sendPollVote(
    chatJID: chatJID,
    pollMsgID: pollMsgID,
    pollSenderJID: pollSenderJID,
    pollFromMe: pollFromMe,
    selectedHashesJSON: selectedHashesJSON,
    pollOptionsJSON: pollOptionsJSON,
    ephemeralSeconds: ephemeralExpirationSeconds)
```

- [ ] **Step 5: Run tests**

```bash
xcodebuild ... test -only-testing:yawacTests/ConversationViewModelSendDispatchTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift yawacTests/ConversationViewModelSendDispatchTests.swift
git commit -m "ConversationViewModel: reply/edit/reaction/poll-vote thread ephemeralExpirationSeconds"
```

---

### Task 10: Thread destination-chat ephemeral into forward sites + helper

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`
- Test: `yawacTests/ConversationViewModelSendDispatchTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@MainActor
func testForwardUsesDestinationChatEphemeral() async {
    // Source chat has 0 ephemeral; destination chat has 86400.
    let vm = ConversationViewModel.testFixture()
    vm.ephemeralExpirationSeconds = 0    // source
    // Configure session.chatList with a destination chat carrying
    // ephemeralExpirationSeconds = 86400 at jid "dst@g.us".
    session.chatList?.chats = [.stub(jid: "dst@g.us",
                                     ephemeralExpirationSeconds: 86400)]
    await vm.forward(messages: [/* a text message */], to: ["dst@g.us"])
    // Stub-client captures the last ephemeralSeconds passed to
    // forwardText. Should be 86400, not 0.
    XCTAssertEqual(stubClient.lastForwardTextEphemeralSeconds, 86400)
}

@MainActor
func testForwardMediaUsesDestinationChatEphemeral() async {
    let vm = ConversationViewModel.testFixture()
    vm.ephemeralExpirationSeconds = 0
    session.chatList?.chats = [.stub(jid: "dst@g.us",
                                     ephemeralExpirationSeconds: 604800)]
    await vm.forward(messages: [/* an image message */], to: ["dst@g.us"])
    XCTAssertEqual(stubClient.lastForwardMediaEphemeralSeconds, 604800)
}
```

> Adapt fixture / stub helpers to existing patterns. `Chat.stub(jid:ephemeralExpirationSeconds:)` may need extending.

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild ... test -only-testing:yawacTests/ConversationViewModelSendDispatchTests
```

- [ ] **Step 3: Add helper + update call sites**

Add private helper:

```swift
private func dstEphemeralSec(_ dstJID: String) -> Int32 {
    session.chatList?.chats.first(where: { $0.jid == dstJID })?
        .ephemeralExpirationSeconds ?? 0
}
```

Locate the forward loop (around lines 347-360). Update both `forwardText` and `forwardMedia` calls:

```swift
// ~line 347
try client.forwardText(
    chatJID: dstJID,
    text: m.text,
    ephemeralSeconds: dstEphemeralSec(dstJID))

// ~line 352
try client.forwardMedia(
    chatJID: dstJID,
    refJSON: refJSON,
    caption: caption,
    fileName: fileName,
    ephemeralSeconds: dstEphemeralSec(dstJID))

// ~line 360 (fallback forwardText)
try client.forwardText(
    chatJID: dstJID,
    text: fallbackText,
    ephemeralSeconds: dstEphemeralSec(dstJID))
```

> **Adapt** the existing exact variable names (`m`, `dstJID`, `refJSON`, etc.) — the snippet above is illustrative.

- [ ] **Step 4: Run tests**

```bash
xcodebuild ... test
```

Expected: PASS, including the two new forward tests.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift yawacTests/ConversationViewModelSendDispatchTests.swift
git commit -m "ConversationViewModel: forward sites use destination chat's ephemeral timer"
```

---

## Milestone D — Session backfill

### Task 11: `SessionViewModel.requestHistoryBackfillIfNeeded` + `.connected` arm

**Files:**
- Modify: `yawac/ViewModels/SessionViewModel.swift`

- [ ] **Step 1: Locate existing `.connected` arm**

```bash
grep -nE "case \.connected|refreshAllAdminApprovalGroups\(\)" yawac/ViewModels/SessionViewModel.swift
```

The v0.7.1 wiring placed `refreshAllAdminApprovalGroups` here. Add the backfill kickoff adjacent.

- [ ] **Step 2: Add `@AppStorage` flag + helper method**

Add to `SessionViewModel`:

```swift
@AppStorage("historyBackfillCompleted") private var historyBackfillCompleted = false
```

> `@AppStorage` works on `@Observable` classes via the `@MainActor` macro; if Swift complains, mark the property `@ObservationIgnored` (same pattern as `lastForegroundRefresh` from v0.7.1 T14).

Add private helper:

```swift
@MainActor
private func requestHistoryBackfillIfNeeded() async {
    guard !historyBackfillCompleted else { return }
    guard let client else { return }
    guard let context = modelContext else { return }
    var d = FetchDescriptor<PersistedMessage>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)])
    d.fetchLimit = 1
    let oldest = (try? context.fetch(d))?.first
    guard let oldest else {
        // First-ever launch — nothing to backfill. Mark complete so
        // the next boot doesn't waste an IQ once a message arrives.
        historyBackfillCompleted = true
        return
    }
    do {
        try await Task.detached { [client] in
            try client.requestFullHistorySync(
                beforeChatJID: oldest.chatJID,
                beforeMsgID: oldest.id,
                beforeFromMe: oldest.fromMe,
                beforeTSUnix: Int64(oldest.timestamp.timeIntervalSince1970),
                count: 100_000)
        }.value
    } catch {
        Logger.bridge.warn("history backfill request failed: \(error)")
        return
    }
    // Flag flipped on first HistorySync arrival — see ContentView event arm.
}
```

> **Adapt** to the actual SessionViewModel structure: `modelContext` may be accessed differently (e.g. via `Environment` injection); `Logger.bridge` may have a different name.

- [ ] **Step 3: Wire into `.connected` arm**

In the existing event-stream switch, add:

```swift
case .connected:
    Task { await self.refreshAllAdminApprovalGroups() }
    Task { await self.requestHistoryBackfillIfNeeded() }
```

Preserve any existing behavior in this arm.

- [ ] **Step 4: Logout handler**

Find the logout / re-link path (`client.logout()` or `session.logout()`):

```bash
grep -nE "func logout|client\.logout|logOut" yawac/ViewModels/SessionViewModel.swift
```

In that handler, before clearing the client / chats, add:

```swift
historyBackfillCompleted = false
```

- [ ] **Step 5: Build**

```bash
xcodebuild ... build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add yawac/ViewModels/SessionViewModel.swift
git commit -m "SessionViewModel: one-shot history backfill on first v0.8.1 boot"
```

---

### Task 12: `ContentView` flips flag on first HistorySync

**Files:**
- Modify: `yawac/ContentView.swift`

- [ ] **Step 1: Locate existing `.historySync` arm**

```bash
grep -nE "case .historySync" yawac/ContentView.swift
```

Should land at line ~139 per spec.

- [ ] **Step 2: Add flag-flip**

Inside the existing `case .historySync(let conversations):` arm (preserving the existing body):

```swift
case .historySync(let conversations):
    if !UserDefaults.standard.bool(forKey: "historyBackfillCompleted") {
        UserDefaults.standard.set(true, forKey: "historyBackfillCompleted")
    }
    // ... existing HistorySync handling (uses conversations) ...
```

> The existing arm likely calls `vm.applyHistorySync(...)` or similar. Preserve it verbatim; only prepend the flag flip.

- [ ] **Step 3: Build**

```bash
xcodebuild ... build
```

- [ ] **Step 4: Commit**

```bash
git add yawac/ContentView.swift
git commit -m "ContentView: flip historyBackfillCompleted on first HistorySync arrival"
```

---

### Task 13: `SessionViewModelBackfillTests`

**Files:**
- Create: `yawacTests/SessionViewModelBackfillTests.swift`

- [ ] **Step 1: Implement tests**

```swift
import XCTest
import SwiftData
@testable import yawac

@MainActor
final class SessionViewModelBackfillTests: XCTestCase {

    func testFirstBootWithPersistedMessageRequestsBackfill() async throws {
        // Reset flag + seed one persisted message.
        UserDefaults.standard.set(false, forKey: "historyBackfillCompleted")
        let container = try ModelContainer(for: PersistedMessage.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let row = PersistedMessage(
            id: "MSG-OLDEST", chatJID: "1@s.whatsapp.net",
            senderJID: "1@s.whatsapp.net", fromMe: false,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            kind: "text", text: "old")
        context.insert(row)
        try context.save()

        let stub = StubHistorySyncClient()
        let svm = SessionViewModel(client: stub, modelContext: context)
        // Fake a .connected event firing the helper directly.
        await svm._test_requestHistoryBackfillIfNeeded()

        XCTAssertEqual(stub.lastBackfillBeforeChatJID, "1@s.whatsapp.net")
        XCTAssertEqual(stub.lastBackfillBeforeMsgID, "MSG-OLDEST")
        XCTAssertEqual(stub.lastBackfillBeforeFromMe, false)
        XCTAssertEqual(stub.lastBackfillBeforeTSUnix, 1700000000)
    }

    func testFlagSetSkipsRequest() async throws {
        UserDefaults.standard.set(true, forKey: "historyBackfillCompleted")
        let stub = StubHistorySyncClient()
        let svm = SessionViewModel(client: stub, modelContext: try memContext())
        await svm._test_requestHistoryBackfillIfNeeded()
        XCTAssertNil(stub.lastBackfillBeforeChatJID)
    }

    func testEmptyPersistedStoreSetsFlag() async throws {
        UserDefaults.standard.set(false, forKey: "historyBackfillCompleted")
        let stub = StubHistorySyncClient()
        let svm = SessionViewModel(client: stub, modelContext: try memContext())
        await svm._test_requestHistoryBackfillIfNeeded()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "historyBackfillCompleted"))
        XCTAssertNil(stub.lastBackfillBeforeChatJID)
    }

    private func memContext() throws -> ModelContext {
        let container = try ModelContainer(for: PersistedMessage.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }
}

final class StubHistorySyncClient: HistorySyncRequesting, @unchecked Sendable {
    var lastBackfillBeforeChatJID: String?
    var lastBackfillBeforeMsgID: String?
    var lastBackfillBeforeFromMe: Bool?
    var lastBackfillBeforeTSUnix: Int64?
    func requestFullHistorySync(beforeChatJID: String,
                                beforeMsgID: String,
                                beforeFromMe: Bool,
                                beforeTSUnix: Int64,
                                count: Int32) throws {
        lastBackfillBeforeChatJID = beforeChatJID
        lastBackfillBeforeMsgID = beforeMsgID
        lastBackfillBeforeFromMe = beforeFromMe
        lastBackfillBeforeTSUnix = beforeTSUnix
    }
}
```

> **Note for engineer:** `SessionViewModel.init(client:modelContext:)` and `_test_requestHistoryBackfillIfNeeded()` are spec-assumed test-affordances. The real `SessionViewModel` may not have a direct `client:` init param — adapt. The cleanest path: extract the test-callable logic into an `internal` method that takes the dependencies as parameters; the production `requestHistoryBackfillIfNeeded()` private method delegates to it.

> If full-VM instantiation is too coupled to test directly, refactor the backfill logic into a separate `HistoryBackfillCoordinator` struct that takes `client`, `modelContext`, and a `flagStore` closure. Test that struct in isolation; SessionViewModel just calls into it.

- [ ] **Step 2: Run tests**

```bash
xcodegen generate
xcodebuild ... test -only-testing:yawacTests/SessionViewModelBackfillTests
```

Expected: 3 PASS.

- [ ] **Step 3: Commit**

```bash
git add yawac/ViewModels/SessionViewModel.swift yawacTests/SessionViewModelBackfillTests.swift
git commit -m "SessionViewModel: backfill gate tests + protocol for stubbability"
```

---

## Milestone E — Release polish

### Task 14: Version bump + ROADMAP update

**Files:**
- Modify: `project.yml`
- Modify: `yawac/Info.plist` (via xcodegen regen)
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Bump version in project.yml**

In `project.yml` (around line 46-47):

```yaml
CFBundleShortVersionString: "0.8.1"
CFBundleVersion: "10"
```

- [ ] **Step 2: Regenerate + verify Info.plist**

```bash
xcodegen generate
grep -A 1 "CFBundleShortVersionString\|CFBundleVersion" yawac/Info.plist | head -8
```

Expected: `0.8.1` and `10`.

- [ ] **Step 3: ROADMAP — strike threaded-send gaps + backfill gap**

In `docs/ROADMAP.md`, find the `Disappearing messages — outbound` section under Important / Communication. Remove the three gap lines:

- "Reply send doesn't thread `ephemeralSeconds`..."
- "Edit / Forward / Reaction send paths likewise un-threaded."
- (Keep the 1:1 cold-read line as it is now satisfied by backfill — change to ✅ and note v0.8.1.)

Find the `View-once enforce` section. Remove:

- "Existing pre-v0.8.0 view-once messages persisted as regular images..."

Add a note line at the bottom of both entries:

```markdown
  **v0.8.1 fix:** reply / edit / forward / reaction / poll-vote now wrap
  in `EphemeralMessage` per the chat's timer. A one-shot history
  backfill on first v0.8.1 boot re-classifies pre-v0.8.0 rows and
  hydrates 1:1 chat timers.
```

- [ ] **Step 4: Final test pass**

```bash
cd bridge && go test -short ./...
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|FAILED" | tail -3
```

Expected: both green.

- [ ] **Step 5: Commit**

```bash
git add project.yml yawac/Info.plist docs/ROADMAP.md
git commit -m "release: 0.8.1 — disappearing thread-through + view-once history backfill"
```

---

## Manual smoke (post-implementation)

Run before tagging. Mirrors spec runbook.

- [ ] Boot v0.8.1 on an account with a 24-hour timer on chat X. Send a reply → recipient phone shows the reply disappearing at 24h.
- [ ] Forward a message into a 7-day chat from a 24h chat → recipient phone shows 7-day expiration on the forwarded copy.
- [ ] Reaction in a disappearing chat → recipient phone applies retention to the reaction itself.
- [ ] Edit a message in a disappearing chat → recipient phone keeps the original message's expiration unchanged.
- [ ] Send poll vote in a disappearing chat → recipient phone applies retention.
- [ ] Verify `~/Library/Containers/dev.vadikas.yawac.yawac/Data/.../Preferences/dev.vadikas.yawac.yawac.plist` contains `historyBackfillCompleted = true` after first connect post-upgrade.
- [ ] Inspect log for `HistorySync` arrival. Open a chat that previously had a pre-v0.8.0 view-once image → bubble should show "Tap to reveal" (NOT the image directly).
- [ ] 1:1 chat with timer set on phone but never observed in yawac → ChatInfoView "Disappearing messages" picker reflects the actual timer post-backfill.
- [ ] Logout → relink different number → `historyBackfillCompleted` resets → fresh backfill fires on next `.connected`.

---

## Closing notes for the engineer

- The bundle is small (14 tasks). Bridge work (T1-T7) is mechanical signature extensions + tests. Swift (T8-T13) follows the v0.7.1/v0.8.0 wrapper pattern.
- **Note for engineer** callouts identify points where upstream whatsmeow signatures or selector names need confirmation. Verify against the actual whatsmeow source before committing.
- For Swift work, several references (`testFixture`, `session.chatList`, `_test_requestHistoryBackfillIfNeeded`) follow patterns established in v0.7.1 + v0.8.0 work — grep the canonical accessor before adding new ones.
- Each task ends with a commit; do not batch. If a task fails to build, fix it before moving on.
- `EditText` deferral is a documented invariant — do NOT add `wrapForChat` to its body even if it looks like it should match the others.
