# Composer Message Types (v0.8.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship four whatsmeow-supported composer message kinds missing from yawac — static location share (plus inbound live-location render), single-contact vCard share, disappearing-messages outbound wrap with per-chat timer UI, and view-once enforcement (inbound lock + outbound toggle).

**Architecture:** Two new bridge funcs (`SendLocation`, `SendContact`) plus a `wrapForChat` helper that wraps any inner `waE2E.Message` in `ViewOnceMessageV2` and/or `EphemeralMessage`. Seven existing send funcs gain ephemeral + view-once params (backwards-compatible: 0 / false routes the old path). `Chat` gains `ephemeralExpirationSeconds`, populated from `JGroup.EphemeralExpirationSeconds` for groups and from a new `EphemeralTimerChanged` event for 1:1s. `PendingAttachment` gains `.location` and `.contact` cases; the composer paperclip menu gains two pickers. `MessageRow` gains two body cases plus a view-once render gate. `ChatInfoView` gains a disappearing-timer row.

**Tech Stack:** Go (whatsmeow `go.mau.fi/whatsmeow`), Swift / SwiftUI / `@Observable`, SwiftData (existing), XCTest, `go test`, MapKit + CoreLocation, MKLocalSearch + CLGeocoder, MKMapSnapshotter.

**Test commands:**

```bash
# Go side
cd bridge && go test -short ./...

# Swift side
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

When a task changes only Go code, run only the Go command. When a task touches Swift code, build + run both.

**Worktree:** Set up via `superpowers:using-git-worktrees` before starting (branch `worktree-message-types-v0.8.0`, base = `main`).

**Spec:** `docs/superpowers/specs/2026-06-03-message-types-design.md` is the design source of truth; cite it when in doubt.

---

## Milestone A — Bridge (Go)

### Task 1: `wrapForChat` helper + tests

**Files:**
- Modify: `bridge/messages.go` (append helper near top, after imports)
- Test: `bridge/messages_test.go` (append)

- [ ] **Step 1: Write the failing test**

Append to `bridge/messages_test.go`:

```go
func TestWrapForChatNoWrap(t *testing.T) {
	inner := &waE2E.Message{
		Conversation: proto.String("hello"),
	}
	out := wrapForChat(inner, 0, false)
	if out != inner {
		t.Fatal("expected unchanged inner when no wrapping requested")
	}
}

func TestWrapForChatEphemeralOnly(t *testing.T) {
	inner := &waE2E.Message{
		Conversation: proto.String("hi"),
	}
	out := wrapForChat(inner, 86400, false)
	if out.EphemeralMessage == nil {
		t.Fatal("expected EphemeralMessage wrap")
	}
	if out.EphemeralMessage.Message == nil {
		t.Fatal("inner should still be set on wrapper")
	}
	if out.ViewOnceMessageV2 != nil {
		t.Fatal("unexpected ViewOnce wrap")
	}
}

func TestWrapForChatViewOnceOnly(t *testing.T) {
	inner := &waE2E.Message{
		ImageMessage: &waE2E.ImageMessage{},
	}
	out := wrapForChat(inner, 0, true)
	if out.ViewOnceMessageV2 == nil {
		t.Fatal("expected ViewOnceMessageV2 wrap")
	}
	if out.EphemeralMessage != nil {
		t.Fatal("unexpected Ephemeral wrap")
	}
}

func TestWrapForChatBothEphemeralOutside(t *testing.T) {
	inner := &waE2E.Message{
		ImageMessage: &waE2E.ImageMessage{},
	}
	out := wrapForChat(inner, 86400, true)
	if out.EphemeralMessage == nil {
		t.Fatal("expected outer EphemeralMessage wrap")
	}
	if out.EphemeralMessage.Message == nil ||
		out.EphemeralMessage.Message.ViewOnceMessageV2 == nil {
		t.Fatalf("expected ViewOnceMessageV2 inside EphemeralMessage; got %+v",
			out.EphemeralMessage.Message)
	}
}
```

Imports needed (add if not present): `google.golang.org/protobuf/proto`, `go.mau.fi/whatsmeow/proto/waE2E`.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run TestWrapForChat -short
```

Expected: FAIL (`undefined: wrapForChat`).

- [ ] **Step 3: Implement `wrapForChat`**

Append to `bridge/messages.go` (after imports + types, before the existing send funcs):

```go
// wrapForChat optionally wraps inner in ViewOnceMessageV2 and then
// EphemeralMessage. ViewOnce wrap is only meaningful for
// ImageMessage / VideoMessage; the UI gates other kinds, but if a
// caller passes viewOnce=true on an unrelated inner we still wrap
// (whatsmeow / WhatsApp may reject; not our enforcement layer).
//
// Nesting order: ViewOnce inside Ephemeral. The outer EphemeralMessage
// is what the server uses for retention; the inner ViewOnceMessageV2
// is what the recipient client uses to gate the reveal flow.
func wrapForChat(inner *waE2E.Message, ephemeralSec int32, viewOnce bool) *waE2E.Message {
	out := inner
	if viewOnce {
		out = &waE2E.Message{
			ViewOnceMessageV2: &waE2E.FutureProofMessage{
				Message: out,
			},
		}
	}
	if ephemeralSec > 0 {
		out = &waE2E.Message{
			EphemeralMessage: &waE2E.FutureProofMessage{
				Message: out,
			},
		}
	}
	return out
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd bridge && go test -run TestWrapForChat -short
```

Expected: PASS (4 subtests).

- [ ] **Step 5: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: wrapForChat helper for ephemeral + view-once wrap"
```

---

### Task 2: `SendLocation` bridge func

**Files:**
- Modify: `bridge/messages.go`
- Test: `bridge/messages_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestSendLocationUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sl.db")
	defer c.Close()
	_, err := c.SendLocation("1234@s.whatsapp.net", 60.17, 24.94, "Senate Square", "Helsinki", 0)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSendLocationBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sl2.db")
	defer c.Close()
	_, err := c.SendLocation("not a jid", 60.17, 24.94, "", "", 0)
	if err == nil {
		t.Fatal("expected parse error")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run TestSendLocation -short
```

Expected: FAIL (compile — `undefined: SendLocation`).

- [ ] **Step 3: Implement `SendLocation`**

Append to `bridge/messages.go`:

```go
// SendLocation sends a static LocationMessage. lat/lng in decimal
// degrees. name + address may be empty. When ephemeralSec > 0,
// wraps in EphemeralMessage. Returns JSON {"id","timestamp"}.
func (c *Client) SendLocation(
	chatJIDStr string,
	lat, lng float64,
	name, address string,
	ephemeralSec int32,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	inner := &waE2E.Message{
		LocationMessage: &waE2E.LocationMessage{
			DegreesLatitude:  proto.Float64(lat),
			DegreesLongitude: proto.Float64(lng),
			Name:             proto.String(name),
			Address:          proto.String(address),
		},
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out := JSendResult{ID: resp.ID, Timestamp: resp.Timestamp.Unix()}
	b, _ := json.Marshal(out)
	return string(b), nil
}
```

> **Note for engineer:** `JSendResult` is the existing send-result
> struct (used by `SendText`, etc.). Confirm exact field names with
> `grep -n "type JSendResult" bridge/messages.go`. If it doesn't
> exist, the existing `SendText` returns whatever shape — match that.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd bridge && go test -run TestSendLocation -short
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: SendLocation for static location share"
```

---

### Task 3: `SendContact` bridge func

**Files:**
- Modify: `bridge/messages.go`
- Test: `bridge/messages_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestSendContactUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sc.db")
	defer c.Close()
	vcard := "BEGIN:VCARD\nVERSION:3.0\nFN:Anna\nTEL;type=CELL;waid=12345:+12345\nEND:VCARD"
	_, err := c.SendContact("1234@s.whatsapp.net", vcard, "Anna", 0)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSendContactBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sc2.db")
	defer c.Close()
	_, err := c.SendContact("not a jid", "BEGIN:VCARD\nEND:VCARD", "X", 0)
	if err == nil {
		t.Fatal("expected parse error")
	}
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd bridge && go test -run TestSendContact -short
```

Expected: FAIL.

- [ ] **Step 3: Implement**

```go
// SendContact sends a single-contact ContactMessage. vcard must be
// a valid VCARD 3.0 payload (built Swift-side via VCardBuilder).
// displayName is the human-readable name. When ephemeralSec > 0,
// wraps in EphemeralMessage.
func (c *Client) SendContact(
	chatJIDStr string,
	vcard, displayName string,
	ephemeralSec int32,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	inner := &waE2E.Message{
		ContactMessage: &waE2E.ContactMessage{
			DisplayName: proto.String(displayName),
			Vcard:       proto.String(vcard),
		},
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out := JSendResult{ID: resp.ID, Timestamp: resp.Timestamp.Unix()}
	b, _ := json.Marshal(out)
	return string(b), nil
}
```

- [ ] **Step 4: Run to verify pass**

```bash
cd bridge && go test -run TestSendContact -short
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/messages.go bridge/messages_test.go
git commit -m "bridge: SendContact for single-contact vCard share"
```

---

### Task 4: `SetDisappearingTimer` + JGroup ephemeral field

**Files:**
- Modify: `bridge/groups.go`
- Test: `bridge/groups_test.go`

- [ ] **Step 1: Write the failing tests**

```go
func TestSetDisappearingTimerUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sd.db")
	defer c.Close()
	err := c.SetDisappearingTimer("1234@g.us", 86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSetDisappearingTimerBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sd2.db")
	defer c.Close()
	err := c.SetDisappearingTimer("not a jid", 86400)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestMapGroupInfoCarriesEphemeralExpiration(t *testing.T) {
	in := &types.GroupInfo{
		JID:       types.NewJID("999", "g.us"),
		GroupName: types.GroupName{Name: "T"},
		GroupEphemeral: types.GroupEphemeral{
			IsEphemeral:       true,
			DisappearingTimer: 86400,
		},
	}
	got := mapGroupInfo(in)
	if got.EphemeralExpirationSeconds != 86400 {
		t.Fatalf("want 86400 got %d", got.EphemeralExpirationSeconds)
	}
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd bridge && go test -run "TestSetDisappearingTimer|TestMapGroupInfoCarriesEphemeral" -short
```

Expected: FAIL.

- [ ] **Step 3: Implement**

Extend `JGroup` (preserve existing fields):

```go
type JGroup struct {
	// ... preserve all existing fields ...
	EphemeralExpirationSeconds int32 `json:"ephemeral_expiration_seconds,omitempty"`
}
```

Extend `mapGroupInfo` (the helper from prior `community-admin` v0.7.1 work):

```go
// In the existing mapGroupInfo body, after the existing field
// assignments, add:
out.EphemeralExpirationSeconds = int32(g.GroupEphemeral.DisappearingTimer)
```

Append `SetDisappearingTimer`:

```go
// SetDisappearingTimer sets the chat-level disappearing-messages timer.
// seconds ∈ {0, 86400 (24h), 604800 (7d), 7776000 (90d)}. Whatsmeow
// handles 1:1 vs group routing internally.
func (c *Client) SetDisappearingTimer(chatJIDStr string, seconds int32) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	timer := time.Duration(seconds) * time.Second
	if err := c.wa.SetDisappearingTimer(context.Background(), jid, timer, 0); err != nil {
		return fmt.Errorf("set disappearing timer: %w", err)
	}
	return nil
}
```

> **Note:** whatsmeow's `SetDisappearingTimer(ctx, chat, timer time.Duration, settingTS time.Time)` — confirm exact signature with `grep -n "func.*SetDisappearingTimer" $(go env GOMODCACHE)/github.com/vadika/whatsmeow@*/send.go`. The 4th arg may be `settingTS time.Time` (pass `time.Now()` or zero value).

- [ ] **Step 4: Run to verify pass**

```bash
cd bridge && go test -short ./...
```

Expected: full suite green.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: SetDisappearingTimer + JGroup carries ephemeral_expiration_seconds"
```

---

### Task 5: Extend existing senders with ephemeral + view-once params

**Files:**
- Modify: `bridge/messages.go`, `bridge/media.go`, `bridge/polls.go`
- Test: `bridge/messages_test.go`, `bridge/media_test.go`

**Important:** This is a signature-breaking change to seven exported funcs. Existing Swift callers also need updating (covered in Task 9). Land Go-side change here; Swift catches up in Milestone B.

- [ ] **Step 1: Locate existing signatures**

```bash
grep -nE "func \(c \*Client\) Send(Text|Image|Video|Audio|VoiceNote|Document|PollCreation)" bridge/*.go
```

- [ ] **Step 2: Write the failing test**

Append to `bridge/messages_test.go`:

```go
func TestSendTextEphemeralWraps(t *testing.T) {
	// Use the test harness pattern from existing send tests; if
	// SendText currently has no wrap-test infrastructure, add a
	// minimal one that captures the *waE2E.Message before it's
	// dispatched (e.g., a small interceptor in NewClient with a
	// test hook).
	//
	// Assert that with ephemeralSec=86400, the dispatched message
	// has EphemeralMessage != nil and the inner carries the
	// Conversation text.
	t.Skip("Wire a send-interceptor or skip if existing tests don't have one; the wrap behaviour is covered by Task 1 wrapForChat tests anyway.")
}
```

If `bridge/messages_test.go` already has an interceptor pattern, exercise it here. If not, this `t.Skip` is acceptable — the underlying `wrapForChat` is covered by Task 1.

- [ ] **Step 3: Update signatures + bodies**

For each of these seven funcs, add the parameters and apply `wrapForChat`:

**`SendText`** in `bridge/messages.go`:

```go
// SendText sends a text message. Caller passes ephemeralSec from
// chat.ephemeralExpirationSeconds; 0 = no wrap.
func (c *Client) SendText(
	chatJID, body, mentionedJIDsJSON string,
	ephemeralSec int32,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	// ... existing parse + mention prep ...
	inner := &waE2E.Message{
		// ... existing inner build (Conversation or ExtendedTextMessage) ...
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	// ... existing return shape ...
}
```

**`SendImage`** in `bridge/media.go`:

```go
func (c *Client) SendImage(
	chatJID, filePath, caption string,
	ephemeralSec int32,
	viewOnce bool,
) (string, error) {
	// ... existing upload + ImageMessage build ...
	inner := &waE2E.Message{
		ImageMessage: imgMsg, // existing built ImageMessage
	}
	msg := wrapForChat(inner, ephemeralSec, viewOnce)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	// ... existing return ...
}
```

**`SendVideo`** — same shape as SendImage; add `ephemeralSec`, `viewOnce`.

**`SendAudio`** in `bridge/media.go`:

```go
func (c *Client) SendAudio(
	chatJID, filePath string,
	ephemeralSec int32,
) (string, error) {
	// ... existing upload + AudioMessage build ...
	inner := &waE2E.Message{AudioMessage: audMsg}
	msg := wrapForChat(inner, ephemeralSec, false)
	// ...
}
```

**`SendVoiceNote`** — add `ephemeralSec` after `waveformB64`.

**`SendDocument`** — add `ephemeralSec`.

**`SendPollCreation`** in `bridge/polls.go` — add `ephemeralSec` as a new last param. Wrap the inner via `wrapForChat(inner, ephemeralSec, false)` before send.

> **Note:** for each func, do NOT change the existing build/upload
> logic; only inject the wrap call between inner build and
> `c.wa.SendMessage`. If a func already wraps in some special way
> (e.g. `ContextInfo` for replies), preserve that wrapping and add
> `wrapForChat` on top.

- [ ] **Step 4: Run full suite to verify nothing broke**

```bash
cd bridge && go test -short ./...
```

Expected: all existing tests still pass (they call with the old shape from Go; if any Go test calls `SendText("a", "b", "c")` it'll now fail to compile — update those call sites to pass `0` as the new last arg).

- [ ] **Step 5: Commit**

```bash
git add bridge/messages.go bridge/media.go bridge/polls.go bridge/messages_test.go bridge/media_test.go
git commit -m "bridge: ephemeral + view-once params on existing senders"
```

---

### Task 6: Classify extension (inbound location_live, contact, view-once)

**Files:**
- Modify: `bridge/messages.go` (`classifyMessage` + dispatch)
- Modify: `bridge/jsonmodels.go` (`JBridgeMessage`)
- Test: `bridge/messages_test.go`

- [ ] **Step 1: Locate**

```bash
grep -nE "func.*classifyMessage|GetLocationMessage|GetContactMessage|GetLiveLocationMessage|ViewOnceMessageV2|type JBridgeMessage" bridge/*.go
```

- [ ] **Step 2: Write the failing test**

```go
func TestClassifyInboundLocation(t *testing.T) {
	m := &waE2E.Message{
		LocationMessage: &waE2E.LocationMessage{
			DegreesLatitude:  proto.Float64(60.17),
			DegreesLongitude: proto.Float64(24.94),
			Name:             proto.String("Senate Square"),
			Address:          proto.String("Helsinki"),
		},
	}
	kind, loc, _, _, _ := classifyForTest(m)
	if kind != "location" {
		t.Fatalf("kind=%s", kind)
	}
	if loc == nil || loc.Lat != 60.17 || loc.Lng != 24.94 {
		t.Fatalf("loc=%+v", loc)
	}
}

func TestClassifyInboundLiveLocation(t *testing.T) {
	m := &waE2E.Message{
		LiveLocationMessage: &waE2E.LiveLocationMessage{
			DegreesLatitude:  proto.Float64(60.17),
			DegreesLongitude: proto.Float64(24.94),
			SequenceNumber:   proto.Int64(42),
		},
	}
	kind, loc, seq, _, _ := classifyForTest(m)
	if kind != "location_live" || seq != 42 {
		t.Fatalf("kind=%s seq=%d", kind, seq)
	}
	_ = loc
}

func TestClassifyInboundContact(t *testing.T) {
	m := &waE2E.Message{
		ContactMessage: &waE2E.ContactMessage{
			DisplayName: proto.String("Anna"),
			Vcard:       proto.String("BEGIN:VCARD\nEND:VCARD"),
		},
	}
	kind, _, _, contact, _ := classifyForTest(m)
	if kind != "contact" {
		t.Fatalf("kind=%s", kind)
	}
	if contact == nil || contact.DisplayName != "Anna" {
		t.Fatalf("contact=%+v", contact)
	}
}

func TestClassifyInboundViewOnce(t *testing.T) {
	m := &waE2E.Message{
		ViewOnceMessageV2: &waE2E.FutureProofMessage{
			Message: &waE2E.Message{
				ImageMessage: &waE2E.ImageMessage{},
			},
		},
	}
	kind, _, _, _, isViewOnce := classifyForTest(m)
	if kind != "image" {
		t.Fatalf("expected unwrap to image, got %s", kind)
	}
	if !isViewOnce {
		t.Fatal("expected isViewOnce=true after unwrap")
	}
}
```

`classifyForTest` is a thin wrapper around the production classify
function exposing the new payload fields. Define it locally in the
test file:

```go
func classifyForTest(m *waE2E.Message) (kind string,
	loc *JLocationPayload, seq int64,
	contact *JContactPayload, isViewOnce bool) {
	// Call classifyMessage and unpack the new return fields.
	return classifyMessage(m)
}
```

- [ ] **Step 3: Run to verify failure**

```bash
cd bridge && go test -run TestClassifyInbound -short
```

Expected: FAIL (compile — new types / signature mismatch).

- [ ] **Step 4: Implement**

In `bridge/jsonmodels.go` add:

```go
type JLocationPayload struct {
	Lat     float64 `json:"lat"`
	Lng     float64 `json:"lng"`
	Name    string  `json:"name,omitempty"`
	Address string  `json:"address,omitempty"`
}

type JContactPayload struct {
	Vcard       string `json:"vcard"`
	DisplayName string `json:"display_name"`
}
```

Extend `JBridgeMessage` (preserve existing fields):

```go
type JBridgeMessage struct {
	// ... existing fields ...
	Location         *JLocationPayload `json:"location,omitempty"`
	LocationSequence int64             `json:"location_sequence,omitempty"`
	Contact          *JContactPayload  `json:"contact,omitempty"`
	IsViewOnce       bool              `json:"is_view_once,omitempty"`
}
```

In `bridge/messages.go`, rewrite `classifyMessage` to return the new payload fields:

```go
// classifyMessage maps an inbound *waE2E.Message to its kind +
// any structured payload (location, contact) + the view-once flag.
// Unwraps ViewOnceMessageV2 / V2Extension transparently and sets
// isViewOnce=true on the envelope.
func classifyMessage(m *waE2E.Message) (
	kind string,
	loc *JLocationPayload,
	locSeq int64,
	contact *JContactPayload,
	isViewOnce bool,
) {
	// Unwrap view-once first.
	if vo := m.GetViewOnceMessageV2(); vo != nil && vo.Message != nil {
		isViewOnce = true
		m = vo.Message
	} else if voe := m.GetViewOnceMessageV2Extension(); voe != nil && voe.Message != nil {
		isViewOnce = true
		m = voe.Message
	}

	switch {
	case m.GetLocationMessage() != nil:
		lm := m.GetLocationMessage()
		return "location", &JLocationPayload{
			Lat:     lm.GetDegreesLatitude(),
			Lng:     lm.GetDegreesLongitude(),
			Name:    lm.GetName(),
			Address: lm.GetAddress(),
		}, 0, nil, isViewOnce
	case m.GetLiveLocationMessage() != nil:
		ll := m.GetLiveLocationMessage()
		return "location_live", &JLocationPayload{
			Lat:  ll.GetDegreesLatitude(),
			Lng:  ll.GetDegreesLongitude(),
		}, ll.GetSequenceNumber(), nil, isViewOnce
	case m.GetContactMessage() != nil:
		cm := m.GetContactMessage()
		return "contact", nil, 0, &JContactPayload{
			Vcard:       cm.GetVcard(),
			DisplayName: cm.GetDisplayName(),
		}, isViewOnce
	case m.GetImageMessage() != nil:
		return "image", nil, 0, nil, isViewOnce
	case m.GetVideoMessage() != nil:
		return "video", nil, 0, nil, isViewOnce
	case m.GetAudioMessage() != nil:
		return "audio", nil, 0, nil, isViewOnce
	case m.GetDocumentMessage() != nil:
		return "document", nil, 0, nil, isViewOnce
	case m.GetStickerMessage() != nil:
		return "sticker", nil, 0, nil, isViewOnce
	}
	// ... preserve any other existing cases (poll, etc.) ...
	return "text", nil, 0, nil, isViewOnce
}
```

> **Important:** the existing `classifyMessage` likely returns `string` only. This rewrites it to return a tuple. Update **every caller** of `classifyMessage` in `bridge/messages.go` (typically inside `dispatchMessage`) to unpack the new fields and populate `JBridgeMessage.Location`, `LocationSequence`, `Contact`, `IsViewOnce`. Preserve every existing kind that the old switch covered.

- [ ] **Step 5: Run to verify pass**

```bash
cd bridge && go test -short ./...
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add bridge/messages.go bridge/jsonmodels.go bridge/messages_test.go
git commit -m "bridge: classify location_live + contact + view-once unwrap"
```

---

### Task 7: `EphemeralTimerChanged` event dispatcher

**Files:**
- Modify: `bridge/events.go`
- Modify: `bridge/jsonmodels.go`
- Test: `bridge/events_dispatch_test.go`

- [ ] **Step 1: Recon**

```bash
grep -nE "dispatchGroupInfo|case \*events.GroupInfo|case \*events.Message|GroupEphemeral|EphemeralSetting|ProtocolMessage" bridge/events.go
```

- [ ] **Step 2: Write failing tests**

Append to `bridge/events_dispatch_test.go`:

```go
func TestDispatchGroupInfoFiresEphemeralTimerChangedOnGroupChange(t *testing.T) {
	c := newTestClient(t)
	captured := captureDispatch(c, func() {
		c.dispatchGroupInfo(&events.GroupInfo{
			JID: types.NewJID("888", "g.us"),
			Ephemeral: &types.GroupEphemeral{
				IsEphemeral:       true,
				DisappearingTimer: 86400,
			},
			Timestamp: time.Unix(1700000000, 0),
		})
	})
	ev := findEvent(captured, "EphemeralTimerChanged")
	if ev == nil {
		t.Fatal("no EphemeralTimerChanged")
	}
	if !strings.Contains(ev.payload, `"seconds":86400`) {
		t.Errorf("payload missing seconds: %s", ev.payload)
	}
}

func TestDispatchEphemeralTimerChangedOnDirectMessage(t *testing.T) {
	c := newTestClient(t)
	captured := captureDispatch(c, func() {
		// Emulate a 1:1 EphemeralSetting carrier message.
		c.dispatchMessage(&events.Message{
			Info: types.MessageInfo{
				MessageSource: types.MessageSource{
					Chat: types.NewJID("12345", "s.whatsapp.net"),
				},
				ID:        "x",
				Timestamp: time.Unix(1700000001, 0),
			},
			Message: &waE2E.Message{
				ProtocolMessage: &waE2E.ProtocolMessage{
					Type: waE2E.ProtocolMessage_EPHEMERAL_SETTING.Enum(),
					EphemeralExpiration: proto.Uint32(604800),
				},
			},
		})
	})
	ev := findEvent(captured, "EphemeralTimerChanged")
	if ev == nil {
		t.Fatal("expected EphemeralTimerChanged on 1:1 EphemeralSetting")
	}
	if !strings.Contains(ev.payload, `"seconds":604800`) {
		t.Errorf("payload: %s", ev.payload)
	}
	// The MessageReceived should be suppressed for this control payload.
	if findEvent(captured, "MessageReceived") != nil {
		t.Error("expected EphemeralSetting carrier message to be suppressed from MessageReceived")
	}
}
```

> **Note:** `findEvent`, `captureDispatch`, `newTestClient` are spec-assumed helpers from the prior community-admin tests; reuse them. If the existing harness uses a different name, adapt.

- [ ] **Step 3: Run to verify failure**

```bash
cd bridge && go test -run "TestDispatchGroupInfoFiresEphemeralTimer|TestDispatchEphemeralTimerChangedOnDirectMessage" -short
```

Expected: FAIL.

- [ ] **Step 4: Implement**

Add type to `bridge/jsonmodels.go`:

```go
type JEphemeralTimerChanged struct {
	ChatJID   string `json:"chat_jid"`
	Seconds   int32  `json:"seconds"`
	ActorJID  string `json:"actor_jid,omitempty"`
	Timestamp int64  `json:"timestamp"`
}
```

In `bridge/events.go`, extend `dispatchGroupInfo` (the existing function from community-admin work) — after the existing dispatchers:

```go
if evt.Ephemeral != nil {
	actor := ""
	if evt.Sender != nil {
		actor = evt.Sender.String()
	}
	payload := JEphemeralTimerChanged{
		ChatJID:   evt.JID.String(),
		Seconds:   int32(evt.Ephemeral.DisappearingTimer),
		ActorJID:  actor,
		Timestamp: evt.Timestamp.Unix(),
	}
	b, _ := json.Marshal(payload)
	c.dispatch("EphemeralTimerChanged", string(b))
}
```

In the `case *events.Message:` arm of the main event switch (likely inside `dispatchMessage` or just before it), short-circuit `ProtocolMessage{EPHEMERAL_SETTING}`:

```go
// Suppress raw EphemeralSetting from chat log; instead emit
// EphemeralTimerChanged.
if pm := evt.Message.GetProtocolMessage(); pm != nil &&
	pm.GetType() == waE2E.ProtocolMessage_EPHEMERAL_SETTING {
	payload := JEphemeralTimerChanged{
		ChatJID:   evt.Info.Chat.String(),
		Seconds:   int32(pm.GetEphemeralExpiration()),
		Timestamp: evt.Info.Timestamp.Unix(),
	}
	b, _ := json.Marshal(payload)
	c.dispatch("EphemeralTimerChanged", string(b))
	return  // do NOT continue into dispatchMessage path
}
```

Place the gate at the start of the message dispatch path so the regular `MessageReceived` event is suppressed for this carrier.

> **Important:** verify with `grep -n "EPHEMERAL_SETTING\|ProtocolMessage_" $(go env GOMODCACHE)/github.com/vadika/whatsmeow@*/proto/waE2E/*.go` that the enum constant name matches. May be `ProtocolMessage_EPHEMERAL_SETTING` or similar.

- [ ] **Step 5: Run + verify**

```bash
cd bridge && go test -short ./...
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add bridge/events.go bridge/jsonmodels.go bridge/events_dispatch_test.go
git commit -m "bridge: emit EphemeralTimerChanged for groups + 1:1 EphemeralSetting"
```

---

## Milestone B — Swift bridge

### Task 8: Swift JSON model additions

**Files:**
- Modify: `yawac/Bridge/JSONModels.swift`

- [ ] **Step 1: Locate**

```bash
grep -nE "struct BridgeGroupModel|struct BridgeMessage|CodingKeys" yawac/Bridge/JSONModels.swift
```

- [ ] **Step 2: Append payload types**

```swift
struct BridgeLocationPayload: Decodable, Hashable {
    let lat: Double
    let lng: Double
    let name: String
    let address: String
}

struct BridgeContactPayload: Decodable, Hashable {
    let vcard: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case vcard
        case displayName = "display_name"
    }
}
```

(Place near the existing payload types — e.g. `BridgeJoinRequest`.)

- [ ] **Step 3: Extend `BridgeMessage`**

Add optional fields + CodingKeys. The exact set on `BridgeMessage` may already be large — preserve everything; add:

```swift
let location: BridgeLocationPayload?
let locationSequence: Int64?
let contact: BridgeContactPayload?
let isViewOnce: Bool?
```

With CodingKeys:

```swift
case location
case locationSequence = "location_sequence"
case contact
case isViewOnce = "is_view_once"
```

If `BridgeMessage` uses a custom `init(from:)`, add `decodeIfPresent` for each. If it uses the synthesized init, just add the properties.

- [ ] **Step 4: Extend `BridgeGroupModel`**

Add:

```swift
var ephemeralExpirationSeconds: Int32 = 0
```

Add a CodingKey case:

```swift
case ephemeralExpirationSeconds = "ephemeral_expiration_seconds"
```

If the struct has a custom `init(from:)`, add `decodeIfPresent(Int32.self, forKey: .ephemeralExpirationSeconds) ?? 0`.

- [ ] **Step 5: No tests** (covered indirectly by VM tests in later tasks).

- [ ] **Step 6: Commit**

```bash
git add yawac/Bridge/JSONModels.swift
git commit -m "bridge models: BridgeLocationPayload/BridgeContactPayload + envelope extensions"
```

---

### Task 9: WAClient wrappers + extended signatures

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`

- [ ] **Step 1: Rebuild xcframework so new gomobile symbols are visible**

```bash
./scripts/build-xcframework.sh
```

(This step is mandatory before adding the new Swift wrappers — otherwise the `go.sendLocation(...)` etc. calls won't compile.)

- [ ] **Step 2: Add new wrappers**

In `yawac/Bridge/WAClient.swift`, append three new wrappers near the existing send wrappers:

```swift
nonisolated func sendLocation(chatJID: String,
                              latitude: Double,
                              longitude: Double,
                              name: String,
                              address: String,
                              ephemeralSeconds: Int32) throws -> SendResult {
    var err: NSError?
    let json = go.sendLocation(chatJID,
                               latitude: latitude,
                               longitude: longitude,
                               name: name,
                               address: address,
                               ephemeralSec: ephemeralSeconds,
                               error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(SendResult.self, from: Data(json.utf8))
}

nonisolated func sendContact(chatJID: String,
                             vcard: String,
                             displayName: String,
                             ephemeralSeconds: Int32) throws -> SendResult {
    var err: NSError?
    let json = go.sendContact(chatJID,
                              vcard: vcard,
                              displayName: displayName,
                              ephemeralSec: ephemeralSeconds,
                              error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(SendResult.self, from: Data(json.utf8))
}

nonisolated func setDisappearingTimer(chatJID: String, seconds: Int32) throws {
    try go.setDisappearingTimer(chatJID, seconds: seconds)
}
```

> **Note:** the gomobile-generated selector names (e.g. `ephemeralSec:` vs `ephemeralSeconds:`) follow Go param names. Confirm against `build/Bridge.xcframework/macos-arm64_x86_64/Bridge.framework/Versions/A/Headers/Bridge.objc.h`. Adjust to match.

- [ ] **Step 3: Update existing send wrappers' signatures**

Each of these gains an `ephemeralSeconds: Int32 = 0` default param (and viewOnce for image/video). Default-zero / default-false routes the old gomobile call shape. Example:

```swift
func sendText(chatJID: String, body: String,
              mentionedJIDs: [String] = [],
              ephemeralSeconds: Int32 = 0) throws -> SendResult {
    let mentionedJSON = try JSONEncoder().encode(mentionedJIDs)
    let mentionedJSONString = String(data: mentionedJSON, encoding: .utf8) ?? "[]"
    var err: NSError?
    let json = go.sendText(chatJID, body: body,
                           mentionedJIDsJSON: mentionedJSONString,
                           ephemeralSec: ephemeralSeconds,
                           error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(SendResult.self, from: Data(json.utf8))
}
```

Repeat for `sendImage` / `sendVideo` (both gain `viewOnce: Bool = false` too), `sendAudio`, `sendVoiceNote`, `sendDocument`, `sendPollCreation`.

- [ ] **Step 4: Build**

```bash
xcodegen generate
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

If any existing caller passed positional args explicitly, defaults keep them compiling; otherwise their callsites are flagged for Task 22 (composer dispatch threading).

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "WAClient: sendLocation/sendContact/setDisappearingTimer + ephemeral params on existing senders"
```

---

### Task 10: `WAClient.Event.ephemeralTimerChanged` case + decode

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`

- [ ] **Step 1: Locate**

```bash
grep -nE "enum Event|case .joinApprovalModeChanged|decode\(kind:" yawac/Bridge/WAClient.swift
```

- [ ] **Step 2: Add case + decode arm**

```swift
// In WAClient.Event enum:
case ephemeralTimerChanged(chatJID: String,
                           seconds: Int32,
                           actorJID: String,
                           timestamp: Int64)
```

In the `decode(kind:payload:)` switch, mirror the `JoinApprovalModeChanged` arm:

```swift
case "EphemeralTimerChanged":
    struct E: Codable {
        let chatJID: String
        let seconds: Int32
        let actorJID: String?
        let timestamp: Int64
        enum CodingKeys: String, CodingKey {
            case chatJID = "chat_jid"
            case seconds
            case actorJID = "actor_jid"
            case timestamp
        }
    }
    if let e = try? dec.decode(E.self, from: data) {
        return .ephemeralTimerChanged(
            chatJID: e.chatJID,
            seconds: e.seconds,
            actorJID: e.actorJID ?? "",
            timestamp: e.timestamp)
    }
```

(Match the existing decode-arm idiom — shared `dec` / `data`, fall through to `.unknown(...)` default.)

- [ ] **Step 3: Build**

```bash
xcodebuild ... build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "WAClient.Event: ephemeralTimerChanged + decode arm"
```

---

## Milestone C — Persistence + UIMessage extensions

### Task 11: `Chat.ephemeralExpirationSeconds`

**Files:**
- Modify: `yawac/Models/Chat.swift`

- [ ] **Step 1: Locate**

```bash
grep -n "struct Chat\|class Chat\|var jid" yawac/Models/Chat.swift
```

- [ ] **Step 2: Add field**

```swift
// At an appropriate spot in Chat:
var ephemeralExpirationSeconds: Int32 = 0
```

If `Chat` has an explicit `init`, update it to default the new field to `0`. If it's Equatable, the synthesized comparison picks it up automatically.

- [ ] **Step 3: Build**

```bash
xcodebuild ... build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add yawac/Models/Chat.swift
git commit -m "Chat: ephemeralExpirationSeconds field (runtime only, hydrated from group + events)"
```

---

### Task 12: `PersistedMessage` view-once + location + contact fields

**Files:**
- Modify: `yawac/Models/PersistedMessage.swift`

- [ ] **Step 1: Add fields to the SwiftData `@Model`**

```swift
// View-once
var isViewOnce: Bool = false
var viewOnceLocked: Bool = false
var viewOnceRevealedAt: Date?

// Location
var locationLat: Double?
var locationLng: Double?
var locationName: String?
var locationAddress: String?
var locationIsLive: Bool = false
var locationSequence: Int64?

// Contact
var contactVCard: String?
var contactDisplayName: String?
```

Add corresponding init defaults if `PersistedMessage` has an explicit `init`. SwiftData usually defaults to property defaults automatically.

> **Migration:** SwiftData handles additive `Optional` / defaulted properties without migration. If the project uses a custom migration plan, add the new fields to the latest schema version per the existing pattern (look for an `enum SchemaV...` near the model).

- [ ] **Step 2: Build**

```bash
xcodebuild ... build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add yawac/Models/PersistedMessage.swift
git commit -m "PersistedMessage: view-once + location + contact fields"
```

---

### Task 13: `UIMessage.Body` cases + `isViewOnce` flag

**Files:**
- Modify: `yawac/Models/Message.swift`

- [ ] **Step 1: Locate**

```bash
grep -nE "enum Body|case text|case media|case poll|case system|struct UIMessage|isViewOnce" yawac/Models/Message.swift
```

- [ ] **Step 2: Add body cases + flag**

Extend `UIMessage.Body`:

```swift
enum Body: Hashable {
    case text(String)
    case media(/* preserve existing assoc values */)
    case poll(/* preserve existing assoc values */)
    case system(String)

    // NEW
    case location(LocationPayload, isLive: Bool, sequence: Int64?)
    case contact(ContactPayload)
}

struct LocationPayload: Hashable {
    let lat: Double
    let lng: Double
    let name: String
    let address: String
}

struct ContactPayload: Hashable {
    let jid: String
    let displayName: String
    let phone: String
    var vcard: String { VCardBuilder.build(jid: jid, name: displayName, phone: phone) }
}
```

> If `LocationPayload`/`ContactPayload` already exist (defined in `ConversationViewModel` per the spec), don't duplicate — import or move them to a shared file. Recommended: place these in `yawac/Models/Message.swift` (this file) so both the VM and UIMessage can consume them.

Add `isViewOnce: Bool = false` to `UIMessage`:

```swift
struct UIMessage: Identifiable, Hashable {
    // ... existing fields ...
    var isViewOnce: Bool = false
}
```

Update the `UIMessage` init-from-`BridgeMessage` to populate the new cases:

```swift
// In the existing kind → body switch:
case "location":
    if let loc = bridgeMsg.location {
        body = .location(
            LocationPayload(lat: loc.lat, lng: loc.lng,
                            name: loc.name, address: loc.address),
            isLive: false, sequence: nil)
    } else {
        body = .system("(location)")
    }
case "location_live":
    if let loc = bridgeMsg.location {
        body = .location(
            LocationPayload(lat: loc.lat, lng: loc.lng,
                            name: loc.name, address: loc.address),
            isLive: true, sequence: bridgeMsg.locationSequence)
    } else {
        body = .system("(live location)")
    }
case "contact":
    if let c = bridgeMsg.contact {
        let jid = VCardBuilder.parseWAID(c.vcard) ?? ""
        let phone = jid.split(separator: "@").first.map(String.init) ?? ""
        body = .contact(
            ContactPayload(jid: jid + "@s.whatsapp.net",
                           displayName: c.displayName, phone: "+" + phone))
    } else {
        body = .system("(contact)")
    }
```

Also populate `isViewOnce`:

```swift
self.isViewOnce = bridgeMsg.isViewOnce ?? false
```

- [ ] **Step 3: Build**

```bash
xcodebuild ... build
```

> **Build-failure recovery:** if `VCardBuilder` doesn't exist yet (lands in Task 14), gate the new switch arms with `// TODO Task 14` and use placeholder empty strings for the jid/phone derivation. Restore on Task 14 commit.

- [ ] **Step 4: Commit**

```bash
git add yawac/Models/Message.swift
git commit -m "UIMessage: .location + .contact body cases + isViewOnce flag"
```

---

## Milestone D — Composer extensions

### Task 14: `VCardBuilder` + tests

**Files:**
- Create: `yawac/Utilities/VCardBuilder.swift`
- Create: `yawacTests/VCardBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import yawac

final class VCardBuilderTests: XCTestCase {

    func testBuildVCardShape() {
        let vcard = VCardBuilder.build(
            jid: "358405551234@s.whatsapp.net",
            name: "Anna Berg",
            phone: "+358405551234")
        XCTAssertTrue(vcard.contains("BEGIN:VCARD"))
        XCTAssertTrue(vcard.contains("VERSION:3.0"))
        XCTAssertTrue(vcard.contains("FN:Anna Berg"))
        XCTAssertTrue(vcard.contains("waid=358405551234"))
        XCTAssertTrue(vcard.contains("+358405551234"))
        XCTAssertTrue(vcard.contains("END:VCARD"))
    }

    func testParseWAIDExtraction() {
        let vcard = """
        BEGIN:VCARD
        VERSION:3.0
        FN:Anna Berg
        TEL;type=CELL;waid=358405551234:+358405551234
        END:VCARD
        """
        let waid = VCardBuilder.parseWAID(vcard)
        XCTAssertEqual(waid, "358405551234")
    }

    func testParseWAIDReturnsNilWhenAbsent() {
        let vcard = "BEGIN:VCARD\nVERSION:3.0\nFN:X\nTEL:+1234\nEND:VCARD"
        XCTAssertNil(VCardBuilder.parseWAID(vcard))
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild ... test -only-testing:yawacTests/VCardBuilderTests
```

Expected: FAIL (compile — undefined).

- [ ] **Step 3: Implement**

```swift
import Foundation

enum VCardBuilder {

    /// Build a VCARD 3.0 carrying the WhatsApp-specific `waid`
    /// parameter so the recipient sees a tappable "Message on
    /// WhatsApp" button. `jid` is the WhatsApp JID; we use its
    /// phone prefix as the `waid` value.
    static func build(jid: String, name: String, phone: String) -> String {
        let phoneDigits = phone.trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        let waid = String(jid.split(separator: "@").first ?? "")
        return """
        BEGIN:VCARD
        VERSION:3.0
        FN:\(name)
        TEL;type=CELL;waid=\(waid):+\(phoneDigits)
        END:VCARD
        """
    }

    /// Pull the `waid` value from a TEL line in a vCard. Returns
    /// nil when the vCard doesn't carry the parameter.
    static func parseWAID(_ vcard: String) -> String? {
        for line in vcard.split(separator: "\n") {
            guard line.lowercased().hasPrefix("tel") else { continue }
            // Look for "waid=<digits>" in the line.
            let parts = line.split(separator: ";")
            for p in parts {
                if let r = p.range(of: "waid=", options: .caseInsensitive) {
                    let after = p[r.upperBound...]
                    // value runs until ':' (start of TEL value)
                    let waid = after.split(separator: ":", maxSplits: 1).first ?? Substring()
                    return String(waid)
                }
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodegen generate
xcodebuild ... test -only-testing:yawacTests/VCardBuilderTests
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add yawac/Utilities/VCardBuilder.swift yawacTests/VCardBuilderTests.swift
git commit -m "VCardBuilder: build + parseWAID for WhatsApp contact share"
```

---

### Task 15: `MapSnapshotCache`

**Files:**
- Create: `yawac/Utilities/MapSnapshotCache.swift`

- [ ] **Step 1: Implement**

```swift
import AppKit
import MapKit

/// Renders + disk-caches a 220×120 @2x map snapshot for a coord.
/// On-disk path: ~/Library/Caches/<bundle>/MapSnapshots/<lat>_<lng>_<zoom>.png
@MainActor
final class MapSnapshotCache {
    static let shared = MapSnapshotCache()
    private init() {}

    private var memory: [String: NSImage] = [:]

    func snapshot(lat: Double, lng: Double,
                  zoom: CLLocationDistance = 1000) async -> NSImage? {
        let key = "\(String(format: "%.6f", lat))_\(String(format: "%.6f", lng))_\(Int(zoom))"
        if let cached = memory[key] { return cached }
        if let disk = readDisk(key: key) {
            memory[key] = disk
            return disk
        }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            latitudinalMeters: zoom, longitudinalMeters: zoom)
        options.size = NSSize(width: 220, height: 120)
        options.scale = 2.0
        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snap = try await snapshotter.start()
            // Composite the snapshot with a pin glyph at the center.
            let composed = composePin(on: snap.image)
            memory[key] = composed
            writeDisk(key: key, image: composed)
            return composed
        } catch {
            return nil
        }
    }

    private func composePin(on base: NSImage) -> NSImage {
        let img = NSImage(size: base.size)
        img.lockFocus()
        base.draw(at: .zero, from: .zero,
                  operation: .copy, fraction: 1.0)
        let pin = NSImage(systemSymbolName: "mappin.and.ellipse",
                          accessibilityDescription: nil)
        let pinSize: CGFloat = 24
        let pinRect = NSRect(
            x: (base.size.width - pinSize) / 2,
            y: (base.size.height - pinSize) / 2,
            width: pinSize, height: pinSize)
        pin?.draw(in: pinRect)
        img.unlockFocus()
        return img
    }

    private var diskRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "yawac"
        return caches
            .appendingPathComponent(bundle)
            .appendingPathComponent("MapSnapshots", isDirectory: true)
    }

    private func readDisk(key: String) -> NSImage? {
        let url = diskRoot.appendingPathComponent("\(key).png")
        return NSImage(contentsOf: url)
    }

    private func writeDisk(key: String, image: NSImage) {
        do {
            try FileManager.default.createDirectory(
                at: diskRoot, withIntermediateDirectories: true)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { return }
            try png.write(to: diskRoot.appendingPathComponent("\(key).png"))
        } catch {
            // Best-effort cache; ignore.
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild ... build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add yawac/Utilities/MapSnapshotCache.swift
git commit -m "MapSnapshotCache: memory + on-disk MKMapSnapshotter cache for location bubbles"
```

---

### Task 16: `LocationPickerSheetModel` + tests

**Files:**
- Create: `yawac/ViewModels/LocationPickerSheetModel.swift`
- Create: `yawacTests/LocationPickerSheetModelTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
import CoreLocation
import MapKit
@testable import yawac

@MainActor
final class LocationPickerSheetModelTests: XCTestCase {

    func testInitialStateAtFallbackCenter() {
        let m = LocationPickerSheetModel()
        XCTAssertEqual(m.selectedCoord.latitude, m.region.center.latitude, accuracy: 0.0001)
    }

    func testUpdateCoordRecordsName() {
        let m = LocationPickerSheetModel()
        m.updateCoord(lat: 60.17, lng: 24.94,
                      name: "Senate Square",
                      address: "Helsinki, Finland")
        XCTAssertEqual(m.resolvedName, "Senate Square")
        XCTAssertEqual(m.resolvedAddress, "Helsinki, Finland")
        XCTAssertEqual(m.selectedCoord.latitude, 60.17, accuracy: 0.0001)
        XCTAssertEqual(m.selectedCoord.longitude, 24.94, accuracy: 0.0001)
    }

    func testStagePayload() {
        let m = LocationPickerSheetModel()
        m.updateCoord(lat: 60.17, lng: 24.94,
                      name: "X", address: "Y")
        let payload = m.buildPayload()
        XCTAssertEqual(payload.lat, 60.17, accuracy: 0.0001)
        XCTAssertEqual(payload.name, "X")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild ... test -only-testing:yawacTests/LocationPickerSheetModelTests
```

Expected: FAIL (compile).

- [ ] **Step 3: Implement**

```swift
import Foundation
import CoreLocation
import MapKit
import Observation

@MainActor
@Observable
final class LocationPickerSheetModel {

    // Fallback center: Helsinki (60.17, 24.94). Replace from user
    // location once permission is granted and a fix arrives.
    var region: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 60.17, longitude: 24.94),
        latitudinalMeters: 5000, longitudinalMeters: 5000)
    var selectedCoord: CLLocationCoordinate2D =
        CLLocationCoordinate2D(latitude: 60.17, longitude: 24.94)

    var query: String = ""
    var searchResults: [MKMapItem] = []
    var resolvedName: String = ""
    var resolvedAddress: String = ""
    var permissionDenied: Bool = false
    var inFlight: Bool = false
    var error: String?

    private var searchDebounce: Task<Void, Never>?
    private var geocodeDebounce: Task<Void, Never>?
    private lazy var locationManager: CLLocationManager = {
        let m = CLLocationManager()
        return m
    }()
    private lazy var geocoder = CLGeocoder()

    func updateCoord(lat: Double, lng: Double, name: String, address: String) {
        selectedCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        resolvedName = name
        resolvedAddress = address
    }

    func onQueryChange() {
        searchDebounce?.cancel()
        searchDebounce = Task { [query, region] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            guard !query.isEmpty else {
                self.searchResults = []
                return
            }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = query
            req.region = region
            do {
                let result = try await MKLocalSearch(request: req).start()
                if Task.isCancelled { return }
                self.searchResults = result.mapItems
            } catch {
                self.searchResults = []
            }
        }
    }

    func pickResult(_ item: MKMapItem) {
        let placemark = item.placemark
        let coord = placemark.coordinate
        let name = item.name ?? ""
        let address = [
            placemark.thoroughfare, placemark.locality,
            placemark.administrativeArea, placemark.country
        ].compactMap { $0 }.joined(separator: ", ")
        updateCoord(lat: coord.latitude, lng: coord.longitude,
                    name: name, address: address)
        region = MKCoordinateRegion(
            center: coord,
            latitudinalMeters: 2000, longitudinalMeters: 2000)
    }

    func useCurrentLocation() async {
        let status = locationManager.authorizationStatus
        if status == .denied || status == .restricted {
            permissionDenied = true
            return
        }
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        // Pull a one-shot location asynchronously.
        guard let loc = locationManager.location else {
            permissionDenied = locationManager.authorizationStatus == .denied
            return
        }
        let coord = loc.coordinate
        region = MKCoordinateRegion(
            center: coord, latitudinalMeters: 1000, longitudinalMeters: 1000)
        selectedCoord = coord
        await reverseGeocode(coord: coord)
    }

    func onPinDrag(to coord: CLLocationCoordinate2D) {
        selectedCoord = coord
        geocodeDebounce?.cancel()
        geocodeDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await self?.reverseGeocode(coord: coord)
        }
    }

    func reverseGeocode(coord: CLLocationCoordinate2D) async {
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coord.latitude,
                           longitude: coord.longitude))
            if let p = placemarks.first {
                resolvedName = p.name ?? ""
                resolvedAddress = [
                    p.thoroughfare, p.locality,
                    p.administrativeArea, p.country
                ].compactMap { $0 }.joined(separator: ", ")
            }
        } catch {
            // Send without name/address.
            resolvedName = ""
            resolvedAddress = ""
        }
    }

    func buildPayload() -> LocationPayload {
        return LocationPayload(
            lat: selectedCoord.latitude,
            lng: selectedCoord.longitude,
            name: resolvedName,
            address: resolvedAddress)
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild ... test -only-testing:yawacTests/LocationPickerSheetModelTests
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/LocationPickerSheetModel.swift yawacTests/LocationPickerSheetModelTests.swift
git commit -m "LocationPickerSheetModel: query/reverse-geocode/current-location state"
```

---

### Task 17: `LocationPickerSheet` view

**Files:**
- Create: `yawac/Views/LocationPickerSheet.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import MapKit

struct LocationPickerSheet: View {
    @Bindable var model: LocationPickerSheetModel
    @Environment(\.dismiss) private var dismiss
    var onSend: (LocationPayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send location").font(.headline)

            TextField("Search", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.query) { _, _ in
                    model.onQueryChange()
                }

            if !model.searchResults.isEmpty {
                List(model.searchResults, id: \.self) { item in
                    Button {
                        model.pickResult(item)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Unnamed")
                                .scaledUI(13)
                            if let addr = item.placemark.title {
                                Text(addr)
                                    .foregroundStyle(.secondary)
                                    .scaledUI(11)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 120)
            }

            Map(coordinateRegion: $model.region,
                interactionModes: [.pan, .zoom],
                annotationItems: [SelectedPin(coord: model.selectedCoord)]) { pin in
                MapAnnotation(coordinate: pin.coord) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.red)
                }
            }
            .frame(height: 220)

            VStack(alignment: .leading, spacing: 2) {
                if !model.resolvedName.isEmpty {
                    Text(model.resolvedName).scaledUI(13)
                }
                if !model.resolvedAddress.isEmpty {
                    Text(model.resolvedAddress)
                        .foregroundStyle(.secondary).scaledUI(11)
                }
            }

            if model.permissionDenied {
                Text("Location access denied — open System Settings → Privacy & Security → Location Services.")
                    .foregroundStyle(.orange)
                    .scaledUI(11)
            }

            if let err = model.error {
                Text(err).foregroundStyle(.red).scaledUI(11)
            }

            HStack {
                Button("Use current location") {
                    Task { await model.useCurrentLocation() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Send") {
                    onSend(model.buildPayload())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct SelectedPin: Identifiable {
    let coord: CLLocationCoordinate2D
    var id: String { "\(coord.latitude),\(coord.longitude)" }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild ... build
```

Expected: BUILD SUCCEEDED.

> If Map(coordinateRegion:annotationItems:) is deprecated on your SDK target, swap to `Map { ... }` with `Annotation { ... }`. macOS 14+ supports both.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/LocationPickerSheet.swift
git commit -m "LocationPickerSheet: MapKit picker + search + current-location button"
```

---

### Task 18: `ContactPickerSheetModel` + tests

**Files:**
- Create: `yawac/ViewModels/ContactPickerSheetModel.swift`
- Create: `yawacTests/ContactPickerSheetModelTests.swift`

- [ ] **Step 1: Tests**

```swift
import XCTest
@testable import yawac

@MainActor
final class ContactPickerSheetModelTests: XCTestCase {

    func testCanSendRequiresSelection() {
        let m = ContactPickerSheetModel(contacts: [])
        XCTAssertFalse(m.canSend)
        m.selectedJID = "1@s.whatsapp.net"
        XCTAssertTrue(m.canSend)
    }

    func testBuildPayloadFromSelection() {
        let contacts = [
            BridgeContact(jid: "358405551234@s.whatsapp.net",
                          name: "Anna", pushName: nil,
                          fullName: nil, businessName: nil)
        ]
        let m = ContactPickerSheetModel(contacts: contacts)
        m.selectedJID = "358405551234@s.whatsapp.net"
        let payload = m.buildPayload()
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.displayName, "Anna")
        XCTAssertEqual(payload?.jid, "358405551234@s.whatsapp.net")
        XCTAssertEqual(payload?.phone, "+358405551234")
        XCTAssertTrue(payload?.vcard.contains("waid=358405551234") ?? false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild ... test -only-testing:yawacTests/ContactPickerSheetModelTests
```

Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

@MainActor
@Observable
final class ContactPickerSheetModel {
    let contacts: [BridgeContact]
    var query: String = ""
    var selectedJID: String?

    init(contacts: [BridgeContact]) {
        self.contacts = contacts
    }

    var canSend: Bool { selectedJID != nil }

    var filtered: [BridgeContact] {
        guard !query.isEmpty else { return contacts }
        let q = query.lowercased()
        return contacts.filter { c in
            c.name.lowercased().contains(q)
                || (c.fullName ?? "").lowercased().contains(q)
        }
    }

    func buildPayload() -> ContactPayload? {
        guard let jid = selectedJID,
              let contact = contacts.first(where: { $0.jid == jid }) else { return nil }
        // Derive phone from JID prefix (E.164 sans "+").
        let phoneDigits = String(jid.split(separator: "@").first ?? "")
        return ContactPayload(
            jid: jid,
            displayName: contact.name,
            phone: "+" + phoneDigits)
    }
}
```

- [ ] **Step 4: Run to verify pass**

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ContactPickerSheetModel.swift yawacTests/ContactPickerSheetModelTests.swift
git commit -m "ContactPickerSheetModel: WA-contacts single-select state"
```

---

### Task 19: `ContactPickerSheet` view

**Files:**
- Create: `yawac/Views/ContactPickerSheet.swift`

- [ ] **Step 1: Implement**

Reuse `ParticipantChipPicker` if it supports single-select; otherwise build a thin list view:

```swift
import SwiftUI

struct ContactPickerSheet: View {
    @Bindable var model: ContactPickerSheetModel
    @Environment(\.dismiss) private var dismiss
    var onSend: (ContactPayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send contact").font(.headline)

            TextField("Search", text: $model.query)
                .textFieldStyle(.roundedBorder)

            List(model.filtered, id: \.jid,
                 selection: $model.selectedJID) { contact in
                Text(contact.name).tag(contact.jid as String?)
            }
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Send") {
                    if let p = model.buildPayload() {
                        onSend(p)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild ... build
```

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/ContactPickerSheet.swift
git commit -m "ContactPickerSheet: single-select WA-contact picker"
```

---

### Task 20: ComposerView paperclip menu + sheet wiring

**Files:**
- Modify: `yawac/Views/ComposerView.swift`

- [ ] **Step 1: Locate menu**

```bash
grep -nE "Menu \{|Attach file|paperclip|sheet\(isPresented" yawac/Views/ComposerView.swift
```

- [ ] **Step 2: Add state + menu items**

Inside the composer view:

```swift
@State private var showLocationPicker = false
@State private var showContactPicker = false
```

Extend the existing paperclip `Menu`:

```swift
Menu {
    Button("Attach file…")   { showFilePicker = true }
    Button("Send location…") { showLocationPicker = true }
    Button("Send contact…")  { showContactPicker = true }
    Button("New poll…")      { showPollSheet = true }
} label: {
    Image(systemName: "paperclip")
}
```

Append sheets to the composer body (mirror existing `.sheet(...)` modifiers):

```swift
.sheet(isPresented: $showLocationPicker) {
    LocationPickerSheet(
        model: LocationPickerSheetModel(),
        onSend: { payload in
            vm.stageLocation(payload)
        }
    )
}
.sheet(isPresented: $showContactPicker) {
    ContactPickerSheet(
        model: ContactPickerSheetModel(contacts: contactsForPicker),
        onSend: { payload in
            vm.stageContact(payload)
        }
    )
}
```

`contactsForPicker` already exists in ChatListView (T21 of v0.7.1 work); lift it to a shared helper or duplicate the pattern from ChatInfoView's local helper. Look at `yawac/Views/ChatListView.swift` `contactsForPicker` for the canonical PN-over-@lid dedup walk.

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild ... build
```

Expected: build fails until `vm.stageLocation` / `vm.stageContact` exist; that's Task 22. Optional: stub them with empty implementations in the VM here, fill in Task 22.

> If you prefer a green commit, add empty stubs to `ConversationViewModel`:
>
> ```swift
> func stageLocation(_ p: LocationPayload) {}
> func stageContact(_ p: ContactPayload) {}
> ```
>
> These are filled out in Task 22.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ComposerView.swift yawac/ViewModels/ConversationViewModel.swift
git commit -m "ComposerView: paperclip menu items + Location/Contact sheet wiring (stubs)"
```

---

### Task 21: Per-chip view-once toggle (image/video)

**Files:**
- Modify: `yawac/Views/ComposerView.swift`
- Modify: `yawac/ViewModels/ConversationViewModel.swift` (add `viewOnce: Bool` to `PendingAttachment.file`)

- [ ] **Step 1: Extend `PendingAttachment`**

In `yawac/ViewModels/ConversationViewModel.swift`:

```swift
enum PendingAttachment: Hashable {
    case file(url: URL, kind: FileKind, viewOnce: Bool)
    // .location and .contact added in Task 22
}
```

Update `stageAttachment` to default `viewOnce: false`:

```swift
func stageAttachment(at url: URL) {
    let kind = attachmentKind(url)
    pendingAttachments.append(.file(url: url, kind: kind, viewOnce: false))
}
```

Add a mutator:

```swift
func toggleViewOnce(at index: Int) {
    guard pendingAttachments.indices.contains(index) else { return }
    if case .file(let u, let k, let v) = pendingAttachments[index],
       (k == .image || k == .video) {
        pendingAttachments[index] = .file(url: u, kind: k, viewOnce: !v)
    }
}
```

- [ ] **Step 2: Extend chip UI**

In `ComposerView.swift` `attachmentChip(_:)` — wrap the existing chip render in a Group that adds an eye-toggle for image/video chips:

```swift
HStack(spacing: 4) {
    chipIconAndLabel(attachment)
    if case .file(_, let kind, let viewOnce) = attachment,
       kind == .image || kind == .video {
        Button {
            if let idx = vm.pendingAttachments.firstIndex(of: attachment) {
                vm.toggleViewOnce(at: idx)
            }
        } label: {
            Image(systemName: viewOnce ? "eye.fill" : "eye")
                .foregroundStyle(viewOnce ? Theme.accent : Theme.textFaint)
        }
        .buttonStyle(.plain)
        .help("Send as view once")
    }
    chipRemoveButton(attachment)
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild ... build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ComposerView.swift yawac/ViewModels/ConversationViewModel.swift
git commit -m "ComposerView: per-chip view-once toggle for image/video"
```

---

### Task 22: `PendingAttachment.location` + `.contact` + `sendOneAttachment` dispatch + tests

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`
- Modify: `yawacTests/ConversationViewModelTests.swift` (or create if missing)

- [ ] **Step 1: Tests**

```swift
import XCTest
@testable import yawac

@MainActor
final class ConversationViewModelSendDispatchTests: XCTestCase {

    func testStageLocationAppendsCase() {
        let vm = ConversationViewModel.testFixture()
        vm.stageLocation(LocationPayload(
            lat: 60, lng: 24, name: "X", address: "Y"))
        guard case .location(let p)? = vm.pendingAttachments.last else {
            return XCTFail("expected .location")
        }
        XCTAssertEqual(p.name, "X")
    }

    func testStageContactAppendsCase() {
        let vm = ConversationViewModel.testFixture()
        vm.stageContact(ContactPayload(
            jid: "1@s.whatsapp.net", displayName: "A", phone: "+1"))
        guard case .contact(let p)? = vm.pendingAttachments.last else {
            return XCTFail("expected .contact")
        }
        XCTAssertEqual(p.displayName, "A")
    }
}
```

> **Note:** `ConversationViewModel.testFixture()` is spec-assumed; if no such factory exists, build a minimal init that takes nullable deps (mirrors how `ChatListViewModel` was tested in v0.7.1). Worst case, scope the assertion to just `.location(_)` matching.

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild ... test -only-testing:yawacTests/ConversationViewModelSendDispatchTests
```

Expected: FAIL.

- [ ] **Step 3: Extend the enum + add stages + dispatch arms**

```swift
enum PendingAttachment: Hashable {
    case file(url: URL, kind: FileKind, viewOnce: Bool)
    case location(LocationPayload)
    case contact(ContactPayload)
}

func stageLocation(_ p: LocationPayload) {
    pendingAttachments.append(.location(p))
}

func stageContact(_ p: ContactPayload) {
    pendingAttachments.append(.contact(p))
}
```

In `sendOneAttachment(_:)` — extend the switch:

```swift
switch attachment {
case .file(let url, let kind, let viewOnce):
    // ... existing dispatch, but pass:
    //     ephemeralSeconds: chat.ephemeralExpirationSeconds
    //     viewOnce: viewOnce
    // through to sendImage/sendVideo/etc.

case .location(let payload):
    do {
        let result = try await Task.detached {
            try self.client.sendLocation(
                chatJID: self.chatJID,
                latitude: payload.lat,
                longitude: payload.lng,
                name: payload.name,
                address: payload.address,
                ephemeralSeconds: self.chat.ephemeralExpirationSeconds)
        }.value
        optimisticInsertLocationBubble(result, payload)
    } catch {
        sendError = (error as NSError).localizedDescription
    }

case .contact(let payload):
    do {
        let result = try await Task.detached {
            try self.client.sendContact(
                chatJID: self.chatJID,
                vcard: payload.vcard,
                displayName: payload.displayName,
                ephemeralSeconds: self.chat.ephemeralExpirationSeconds)
        }.value
        optimisticInsertContactBubble(result, payload)
    } catch {
        sendError = (error as NSError).localizedDescription
    }
}
```

`optimisticInsertLocationBubble` / `optimisticInsertContactBubble` are local helpers mirroring the existing optimistic-bubble pattern in `ConversationViewModel`. Implementation:

```swift
private func optimisticInsertLocationBubble(_ result: SendResult,
                                            _ payload: LocationPayload) {
    let row = PersistedMessage(
        // copy fields from the existing optimistic-insert helper for media
        // — id, chatJID, fromMe=true, timestamp, status=sent, etc.
        kind: "location",
        locationLat: payload.lat,
        locationLng: payload.lng,
        locationName: payload.name,
        locationAddress: payload.address,
        locationIsLive: false)
    // ... existing insert path ...
}

private func optimisticInsertContactBubble(_ result: SendResult,
                                            _ payload: ContactPayload) {
    let row = PersistedMessage(
        kind: "contact",
        contactVCard: payload.vcard,
        contactDisplayName: payload.displayName)
    // ... existing insert path ...
}
```

Also extend `sendDraft()` (the text-only send) to pass `ephemeralSeconds: chat.ephemeralExpirationSeconds` through to `sendText`.

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild ... test -only-testing:yawacTests/ConversationViewModelSendDispatchTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift yawacTests/ConversationViewModelSendDispatchTests.swift
git commit -m "ConversationViewModel: .location/.contact stage + send + ephemeral threading"
```

---

## Milestone E — Inbound render

### Task 23: `locationBubble` in MessageRow

**Files:**
- Modify: `yawac/Views/MessageRow.swift`

- [ ] **Step 1: Add render arm**

In `existingBodyContent` (or wherever the `switch body { ... }` lives), add:

```swift
case .location(let loc, let isLive, _):
    locationBubble(loc, isLive: isLive)
```

Add the helper:

```swift
@ViewBuilder
private func locationBubble(_ loc: LocationPayload, isLive: Bool) -> some View {
    Button {
        if let url = URL(string: "maps://?ll=\(loc.lat),\(loc.lng)") {
            NSWorkspace.shared.open(url)
        }
    } label: {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(Theme.surface)
                AsyncImage(url: nil) { _ in
                    // Use a manual loader so we hit MapSnapshotCache.
                    Color.clear
                }
                MapSnapshotImage(lat: loc.lat, lng: loc.lng)
                if isLive {
                    Text("🔴 LIVE")
                        .scaledMono(10, weight: .semibold)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.red.opacity(0.8), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topTrailing)
                }
            }
            .frame(width: 220, height: 120)
            VStack(alignment: .leading, spacing: 2) {
                if !loc.name.isEmpty {
                    Text(loc.name).scaledUI(13).foregroundStyle(Theme.text)
                }
                if !loc.address.isEmpty {
                    Text(loc.address).scaledUI(11)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(8)
        }
        .frame(width: 220)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
    }
    .buttonStyle(.plain)
}

private struct MapSnapshotImage: View {
    let lat: Double
    let lng: Double
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(lat),\(lng)") {
            image = await MapSnapshotCache.shared.snapshot(lat: lat, lng: lng)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild ... build
```

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/MessageRow.swift
git commit -m "MessageRow: locationBubble with MKMapSnapshotter + LIVE badge"
```

---

### Task 24: `contactBubble` in MessageRow

**Files:**
- Modify: `yawac/Views/MessageRow.swift`

- [ ] **Step 1: Add render arm**

```swift
case .contact(let card):
    contactBubble(card)
```

```swift
@ViewBuilder
private func contactBubble(_ card: ContactPayload) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
            // Reuse the existing avatar component if one exists; otherwise initials placeholder.
            ZStack {
                Circle().fill(Theme.surface).frame(width: 36, height: 36)
                Text(String(card.displayName.prefix(1)))
                    .scaledUI(15, weight: .semibold)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.displayName).scaledUI(13).foregroundStyle(Theme.text)
                Text(card.phone).scaledUI(11).foregroundStyle(Theme.textMuted)
            }
        }
        if VCardBuilder.parseWAID(card.vcard) != nil {
            Divider()
            Button("Message on WhatsApp") {
                // Resolve to a JID — use parseWAID + @s.whatsapp.net suffix.
                if let waid = VCardBuilder.parseWAID(card.vcard) {
                    let jid = "\(waid)@s.whatsapp.net"
                    session.requestSelectChat(jid)
                }
            }
            .buttonStyle(.borderless)
            .scaledUI(12, weight: .medium)
        }
    }
    .padding(10)
    .frame(width: 220)
    .background(Theme.surface)
    .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild ... build
```

> If `session` isn't accessible inside `MessageRow`, lift via `@Environment(\.session)` or pass via init. Mirror how other rows reach `session.contactNames`.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/MessageRow.swift
git commit -m "MessageRow: contactBubble with Message-on-WhatsApp action"
```

---

### Task 25: View-once render gate + `revealViewOnce` + tests

**Files:**
- Modify: `yawac/Views/MessageRow.swift`
- Modify: `yawac/Models/PersistedMessage.swift` (already has the fields from Task 12)
- Create: `yawacTests/ViewOnceRevealTests.swift`

- [ ] **Step 1: Tests**

```swift
import XCTest
import SwiftData
@testable import yawac

@MainActor
final class ViewOnceRevealTests: XCTestCase {

    func testRevealFlipsLockedAndDeletesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewonce-\(UUID()).bin")
        try Data([0xff, 0xd8]).write(to: url)

        let msg = PersistedMessage()
        msg.isViewOnce = true
        msg.viewOnceLocked = false
        msg.mediaPath = url.path

        ViewOnceReveal.reveal(msg)

        XCTAssertTrue(msg.viewOnceLocked)
        XCTAssertNil(msg.mediaPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRevealIdempotentOnSecondCall() {
        let msg = PersistedMessage()
        msg.isViewOnce = true
        msg.viewOnceLocked = true
        msg.mediaPath = nil

        ViewOnceReveal.reveal(msg)
        // No crash; still locked.
        XCTAssertTrue(msg.viewOnceLocked)
    }

    func testRevealNoOpWhenFileMissing() {
        let msg = PersistedMessage()
        msg.isViewOnce = true
        msg.viewOnceLocked = false
        msg.mediaPath = "/tmp/non-existent-\(UUID()).bin"
        ViewOnceReveal.reveal(msg)
        XCTAssertTrue(msg.viewOnceLocked)
        XCTAssertNil(msg.mediaPath)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild ... test -only-testing:yawacTests/ViewOnceRevealTests
```

Expected: FAIL.

- [ ] **Step 3: Implement reveal helper**

Create `yawac/Utilities/ViewOnceReveal.swift`:

```swift
import Foundation

enum ViewOnceReveal {
    /// Lock the message in-place and delete the on-disk media file
    /// (best-effort). Idempotent — calling on an already-locked
    /// message is a no-op.
    @MainActor
    static func reveal(_ msg: PersistedMessage) {
        guard msg.isViewOnce, !msg.viewOnceLocked else {
            // Already locked or never view-once; lock anyway if asked.
            msg.viewOnceLocked = true
            return
        }
        if let path = msg.mediaPath, !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
        msg.mediaPath = nil
        msg.mediaCaption = nil
        msg.viewOnceLocked = true
        msg.viewOnceRevealedAt = Date()
    }
}
```

- [ ] **Step 4: Add render gate in MessageRow**

In `existingBodyContent`, before the regular `switch body` dispatch:

```swift
if message.isViewOnce {
    if message.viewOnceLocked {
        Text("You viewed this once")
            .italic()
            .foregroundStyle(Theme.textMuted)
            .scaledUI(12)
    } else {
        Button {
            // Paint the media inline AND schedule the lock after one
            // paint cycle.
            revealedLocally = true
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                ViewOnceReveal.reveal(message.persisted) // adapt to actual ref
            }
        } label: {
            HStack {
                Image(systemName: "eye")
                Text("Tap to reveal").scaledUI(12)
            }
        }
        .buttonStyle(.borderless)
    }
    // If revealedLocally is true, fall through to render the media
    // bubble below.
    if !revealedLocally && !message.viewOnceLocked {
        return AnyView(EmptyView()) // or guard at top of body
    }
}
```

Add `@State private var revealedLocally = false` on the row view.

The exact control flow integration depends on how `existingBodyContent` is structured. The minimum behavior: when `isViewOnce && !viewOnceLocked`, show "Tap to reveal"; on tap, set `revealedLocally`, render the media, after 100ms call `ViewOnceReveal.reveal(...)`.

- [ ] **Step 5: Run to verify pass**

```bash
xcodebuild ... test -only-testing:yawacTests/ViewOnceRevealTests
xcodebuild ... build
```

Expected: tests + BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add yawac/Utilities/ViewOnceReveal.swift yawac/Views/MessageRow.swift yawacTests/ViewOnceRevealTests.swift
git commit -m "MessageRow: view-once render gate + ViewOnceReveal (lock + delete)"
```

---

## Milestone F — Chat-level wiring

### Task 26: ChatInfoView Disappearing-messages row

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift`

- [ ] **Step 1: Locate**

```bash
grep -nE "JOIN APPROVAL|approval-mode|isCurrentUserAdmin|sectionCard|@State " yawac/Views/ChatInfoView.swift
```

- [ ] **Step 2: Add row**

Between description editor and JOIN APPROVAL section:

```swift
// 1:1 chats: ungated. Groups: admin-only.
if !g.isParent,
   (chat.isGroup ? isCurrentUserAdmin(g) : true) {
    sectionCard(label: "DISAPPEARING MESSAGES") {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { g.ephemeralExpirationSeconds },
                set: { newValue in
                    setDisappearingTimer(newValue)
                }
            )) {
                Text("Off").tag(Int32(0))
                Text("24 hours").tag(Int32(86_400))
                Text("7 days").tag(Int32(604_800))
                Text("90 days").tag(Int32(7_776_000))
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if let err = disappearingError {
                Text(err).foregroundStyle(.red).scaledUI(11)
                    .task(id: err) {
                        try? await Task.sleep(nanoseconds: 6 * 1_000_000_000)
                        disappearingError = nil
                    }
            }
        }
    }
}
```

Add `@State private var disappearingError: String?`.

Add helper:

```swift
private func setDisappearingTimer(_ seconds: Int32) {
    guard let client = session.client else { return }
    let prior = g.ephemeralExpirationSeconds
    g.ephemeralExpirationSeconds = seconds  // optimistic; adapt for value-type
    Task {
        do {
            try await Task.detached {
                try client.setDisappearingTimer(chatJID: g.jid, seconds: seconds)
            }.value
        } catch {
            g.ephemeralExpirationSeconds = prior
            disappearingError = (error as NSError).localizedDescription
        }
    }
}
```

> **Adapt for value-type:** if `g` is a `let BridgeGroupModel`, mutate via the `@State group: BridgeGroupModel?` shadow copy that ChatInfoView already maintains (T24 of v0.7.1). Mirror the approval-mode toggle pattern.

- [ ] **Step 3: Build**

```bash
xcodebuild ... build
```

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "ChatInfoView: disappearing-messages timer row (off/24h/7d/90d)"
```

---

### Task 27: `ChatListViewModel.applyEphemeralTimer` + event routing + tests

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift`
- Modify: `yawacTests/ChatListViewModelTests.swift`

- [ ] **Step 1: Tests**

```swift
func testApplyEphemeralTimerUpdatesChat() {
    let vm = ChatListViewModel.testFixture(chats: [.stub(jid: "g@g.us")])
    vm.applyEphemeralTimer(chatJID: "g@g.us", seconds: 86400)
    XCTAssertEqual(
        vm.chats.first { $0.jid == "g@g.us" }?.ephemeralExpirationSeconds, 86400)
}

func testMergeGroupsHydratesEphemeral() {
    let vm = ChatListViewModel.testFixture(chats: [])
    let bg = BridgeGroupModel.stub(jid: "g@g.us", amAdmin: true, meJID: "me")
    var bgWithTimer = bg
    bgWithTimer.ephemeralExpirationSeconds = 604800
    vm.mergeGroups([bgWithTimer])
    XCTAssertEqual(
        vm.chats.first { $0.jid == "g@g.us" }?.ephemeralExpirationSeconds, 604800)
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild ... test -only-testing:yawacTests/ChatListViewModelTests
```

Expected: FAIL.

- [ ] **Step 3: Add helper**

```swift
func applyEphemeralTimer(chatJID: String, seconds: Int32) {
    updateChat(jid: chatJID) { $0.ephemeralExpirationSeconds = seconds }
}
```

Extend `mergeGroups` to populate the new field on `Chat`:

```swift
// Inside the per-group mapping in mergeGroups:
chat.ephemeralExpirationSeconds = bridgeGroup.ephemeralExpirationSeconds
```

- [ ] **Step 4: Run to verify pass**

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ChatListViewModel.swift yawacTests/ChatListViewModelTests.swift
git commit -m "ChatListViewModel: applyEphemeralTimer + hydrate from mergeGroups"
```

---

### Task 28: `SessionViewModel` routes `EphemeralTimerChanged`

**Files:**
- Modify: `yawac/ViewModels/SessionViewModel.swift`
- Modify: `yawac/ContentView.swift` (or wherever event-fan-out lives)

- [ ] **Step 1: Add event arm**

In the existing event-stream switch (mirror the `.joinApprovalModeChanged` arm from v0.7.1):

```swift
case .ephemeralTimerChanged(let chatJID, let seconds, _, _):
    chatList?.applyEphemeralTimer(chatJID: chatJID, seconds: seconds)
```

- [ ] **Step 2: Build**

```bash
xcodebuild ... build
```

- [ ] **Step 3: Commit**

```bash
git add yawac/ViewModels/SessionViewModel.swift yawac/ContentView.swift
git commit -m "SessionViewModel: route EphemeralTimerChanged → applyEphemeralTimer"
```

---

## Milestone G — Release polish

### Task 29: Info.plist NSLocationWhenInUseUsageDescription + version bump

**Files:**
- Modify: `project.yml`
- Modify: `yawac/Info.plist` (after xcodegen regen)

- [ ] **Step 1: Add Info.plist key**

In `project.yml`, find the `Info.plist properties` block (line ~42) and add:

```yaml
NSLocationWhenInUseUsageDescription: yawac uses your location only when you choose Send current location.
```

Also bump version:

```yaml
CFBundleShortVersionString: "0.8.0"
CFBundleVersion: "9"
```

- [ ] **Step 2: Regenerate + verify**

```bash
xcodegen generate
grep -A 1 "NSLocationWhenInUseUsageDescription\|CFBundleShortVersionString" yawac/Info.plist | head -6
```

Expected: both keys present, version `0.8.0`.

- [ ] **Step 3: Build + test**

```bash
xcodebuild ... build
cd bridge && go test -short ./...
```

Both expected: green.

- [ ] **Step 4: Commit**

```bash
git add project.yml yawac/Info.plist
git commit -m "release: 0.8.0 — composer message types prep"
```

---

### Task 30: README + ROADMAP

**Files:**
- Modify: `README.md`
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: README — Communication bullets**

Add (or update) in the Communication section:

```markdown
- Send **static location** via MapKit picker (search + current location + draggable pin); inbound LiveLocation renders with a live badge.
- Share **single contact** as a WhatsApp-compatible vCard with tappable "Message on WhatsApp" recipient action.
- **Disappearing messages** outbound — chat-level timer (off / 24h / 7d / 90d) set from ChatInfoView; outgoing messages wrap in `EphemeralMessage` automatically.
- **View-once** — incoming reveals once, then locks + deletes on disk; outbound has a per-attachment toggle on image/video chips.
```

- [ ] **Step 2: ROADMAP — flip four items**

In `docs/ROADMAP.md`, change four lines:

```markdown
- ✅ **Location sharing** — static MapKit picker (search + current
  location + drag pin) shipped in v0.8.0. Inbound LiveLocation
  renders with last known coord + "LIVE" badge. Live-location send
  remains deferred.
- ✅ **Contact-card share (vCard)** — WhatsApp-formatted vCard with
  `waid` extension parameter so recipients see a tappable "Message on
  WhatsApp" affordance. Single-contact only; macOS Contacts.app
  integration deferred. Shipped in v0.8.0.
- ✅ **Disappearing messages — outbound** — chat-level timer (off /
  24h / 7d / 90d) set from ChatInfoView; outgoing messages wrap in
  `EphemeralMessage`. Shipped in v0.8.0.
- ✅ **View-once enforce** — incoming view-once reveal once, then
  locks + deletes the on-disk media; outbound per-attachment toggle
  on image/video chips. Shipped in v0.8.0.
```

- [ ] **Step 3: Final test pass**

```bash
cd bridge && go test -short ./...
xcodebuild ... test
```

Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/ROADMAP.md
git commit -m "docs: README + ROADMAP for v0.8.0 message types"
```

---

## Manual smoke (post-implementation)

Run before tagging. Mirrors spec's manual runbook.

- [ ] Compose → paperclip → "Send location" → search "Senate Square" → result row → "Send" → bubble appears with map snapshot. Phone shows same coords within ~3s.
- [ ] Compose → "Use current location" → Core Location prompt → allow → reverse-geocode populates name + address → "Send" → bubble.
- [ ] Compose → "Send contact" → pick "Anna" → "Send" → contact bubble with name + phone + "Message on WhatsApp" button. Tap button → opens chat with Anna.
- [ ] ChatInfoView → "Disappearing messages" → "24 hours" → row updates. Send a text → recipient's chat shows the message disappearing after 24h. Phone reflects timer change.
- [ ] ChatInfoView → "Off" → outbound goes back to unwrapped.
- [ ] Compose → attach image → toggle view-once eye → send → recipient sees "Tap to reveal" → tap → image shows → flips to "You viewed this once" → file deleted from `~/Library/Containers/dev.vadikas.yawac.yawac/Data/Library/Caches/...`.
- [ ] Inbound view-once from phone → bubble has reveal button → tap → image shows → locks.
- [ ] Inbound live-location from phone → bubble renders with "🔴 LIVE" badge; pin moves on each update.
- [ ] Disappearing-timer toggle from phone → yawac picker reflects within ~1s.

---

## Closing notes for the engineer

- The bundle is large (30 tasks). Bridge work (T1-T7) lands first and is testable in isolation. Swift work (T8 onward) follows; build verification needs the xcframework rebuild after T7.
- **Note for engineer** callouts in tasks identify points where upstream whatsmeow type names / field names are inferred from documentation. Verify by reading
  `$(go env GOMODCACHE)/github.com/vadika/whatsmeow@*/proto/waE2E/*.go` before committing.
- For Swift work, several references (`session.client`, `session.requestSelectChat`, `BridgeGroupModel.stub`, etc.) follow patterns established in v0.7.1's community-admin work — grep the canonical accessor before adding new ones.
- Each task ends with a commit; do not batch. If a task fails to build, fix it before moving on.
- View-once delete-on-reveal is permission-free (in-app sandbox caches); MapKit current-location is permission-gated and may surface the macOS prompt the first time.
