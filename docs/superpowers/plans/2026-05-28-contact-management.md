# Contact & Chat Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four chat-level actions — add-to-contacts (synced to phone), delete chat (all-device clear), block/unblock, and archive — surfaced from the sidebar context menu and the conversation header menu, with a collapsible Archived section, a blocked banner, and a Settings blocked-contacts list.

**Architecture:** Mirror the existing pin/star end-to-end pattern. Go bridge gains five methods (`ArchiveChat`, `DeleteChat`, `SetContactName`, `SetBlocked`, `ListBlocked`) built on whatsmeow appstate (`BuildArchive`/`BuildDeleteChat`/hand-built ContactAction) + blocklist IQ (`UpdateBlocklist`/`GetBlocklist`), plus four inbound dispatched events. Swift gains `archivedAt` on the chat model, an in-memory blocklist on `SessionViewModel`, action handlers on `ChatListViewModel`, and UI in the sidebar/header/settings.

**Tech Stack:** Go (gomobile bridge over a vadika/whatsmeow fork), Swift + SwiftUI + SwiftData, XcodeGen, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-28-contact-management-design.md`

---

## File Structure

**Go (bridge/):**
- `appstate.go` (modify) — add `messageKeyOrNil`, `ArchiveChat`, `DeleteChat`, `buildContactPatch`, `SetContactName`.
- `blocklist.go` (create) — `SetBlocked`, `ListBlocked`.
- `events.go` (modify) — `handleWAEvent` cases + `dispatchArchive`/`dispatchDeleteChat`/`dispatchContact`/`dispatchBlocklist`.
- `jsonmodels.go` (modify) — `JChatArchived`, `JChatDeleted`, `JContactUpdated`, `JBlockChange`, `JBlocklistChanged`.
- `appstate_test.go` (create), `blocklist_test.go` (create), `events_dispatch_test.go` (modify).

**Swift (yawac/):**
- `Bridge/WAClient.swift` (modify) — `Event` cases, wrappers, decode cases.
- `Models/Chat.swift` (modify) — `archivedAt`.
- `Models/PersistedMessage.swift` (modify) — `PersistedChat.archivedAt`.
- `ViewModels/ChatListViewModel.swift` (modify) — archive/delete/addContact + applyIncoming*.
- `ViewModels/SessionViewModel.swift` (modify) — blocklist state + `deletedChatJID`.
- `Services/SQLiteDedupe.swift` (modify) — `purgeChat`.
- `ContentView.swift` (modify) — route new events + deselect-on-delete.
- `Views/ChatListView.swift` (modify) — Archived section + context menu + dialogs.
- `Views/ConversationView.swift` (modify) — header menu + blocked banner + dialogs.
- `Views/ContactNameSheet.swift` (create) — name-entry sheet.
- `Views/SettingsView.swift` (modify) — Blocked contacts section.

**Swift tests (yawacTests/):**
- `BridgeClientTests.swift` (modify) — decode new events.
- `ChatListBlockArchiveTests.swift` (create) — applyIncoming archive/contact.
- `SessionBlocklistTests.swift` (create) — blocklist set logic.

---

## Task 1: Go bridge — archive + delete chat

**Files:**
- Modify: `bridge/appstate.go`
- Create: `bridge/appstate_test.go`

- [ ] **Step 1: Write the failing test**

Create `bridge/appstate_test.go`:

```go
package bridge

import (
	"strings"
	"testing"
)

func TestMessageKeyOrNilEmptyID(t *testing.T) {
	if k := messageKeyOrNil("12345@s.whatsapp.net", "", false); k != nil {
		t.Fatalf("want nil for empty id, got %+v", k)
	}
}

func TestMessageKeyOrNilPopulated(t *testing.T) {
	k := messageKeyOrNil("12345@s.whatsapp.net", "MID1", true)
	if k == nil {
		t.Fatal("want non-nil key")
	}
	if k.GetRemoteJID() != "12345@s.whatsapp.net" || k.GetID() != "MID1" || !k.GetFromMe() {
		t.Fatalf("bad key: remote=%s id=%s fromMe=%v",
			k.GetRemoteJID(), k.GetID(), k.GetFromMe())
	}
}

func TestArchiveChatBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/a.db")
	defer c.Close()
	err := c.ArchiveChat("abc:def@x", true, 0, "", false)
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}

func TestDeleteChatBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/d.db")
	defer c.Close()
	err := c.DeleteChat("abc:def@x", 0, "", false)
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd bridge && go test ./... -run 'TestMessageKeyOrNil|TestArchiveChatBadJID|TestDeleteChatBadJID' -v`
Expected: FAIL — compile error, `messageKeyOrNil`/`ArchiveChat`/`DeleteChat` undefined.

- [ ] **Step 3: Write minimal implementation**

In `bridge/appstate.go`, replace the import block with:

```go
import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)
```

Append to `bridge/appstate.go`:

```go
// messageKeyOrNil builds a *waCommon.MessageKey for archive/delete message
// ranges, or nil when no last-message id is known. whatsmeow's
// newMessageRange is zero-safe and substitutes time.Now() for a zero
// timestamp, so passing nil here is valid for empty chats.
func messageKeyOrNil(chatJID, lastMsgID string, fromMe bool) *waCommon.MessageKey {
	if lastMsgID == "" {
		return nil
	}
	return &waCommon.MessageKey{
		RemoteJID: proto.String(chatJID),
		FromMe:    proto.Bool(fromMe),
		ID:        proto.String(lastMsgID),
	}
}

// ArchiveChat archives or unarchives a chat. whatsmeow's BuildArchive uses
// WAPatchRegularLow (version 3) and auto-unpins the chat when archiving.
// lastTS/lastMsgID/fromMe anchor the archive to the chat's last message;
// pass 0/""/false when unknown.
func (c *Client) ArchiveChat(chatJID string, archived bool, lastTS int64, lastMsgID string, fromMe bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	ts := time.Time{}
	if lastTS > 0 {
		ts = time.Unix(lastTS, 0)
	}
	patch := appstate.BuildArchive(chat, archived, ts, messageKeyOrNil(chatJID, lastMsgID, fromMe))
	return c.wa.SendAppState(context.Background(), patch)
}

// DeleteChat clears a conversation on every device. whatsmeow's
// BuildDeleteChat uses WAPatchRegularHigh (version 6); we never delete media
// server-side (deleteMedia=false).
func (c *Client) DeleteChat(chatJID string, lastTS int64, lastMsgID string, fromMe bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	ts := time.Time{}
	if lastTS > 0 {
		ts = time.Unix(lastTS, 0)
	}
	patch := appstate.BuildDeleteChat(chat, ts, messageKeyOrNil(chatJID, lastMsgID, fromMe), false)
	return c.wa.SendAppState(context.Background(), patch)
}
```

Note: `waSyncAction` is imported now but first used in Task 2; Go tolerates this only once it IS used. If Task 1 is built/committed alone, temporarily omit `waSyncAction` and `proto` from the import block, then re-add them in Task 2. Since `proto` IS used here (`proto.String`/`proto.Bool`), keep `proto`; drop only `waSyncAction` until Task 2.

Corrected Task-1 import block (add `waSyncAction` in Task 2):

```go
import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd bridge && go test ./... -run 'TestMessageKeyOrNil|TestArchiveChatBadJID|TestDeleteChatBadJID' -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add bridge/appstate.go bridge/appstate_test.go
git commit -m "bridge: archive + delete chat appstate methods"
```

---

## Task 2: Go bridge — synced contact name

**Files:**
- Modify: `bridge/appstate.go`
- Modify: `bridge/appstate_test.go`

- [ ] **Step 1: Write the failing test**

Append to `bridge/appstate_test.go`:

```go
import (
	// keep existing "strings", "testing"; add:
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/types"
)

func TestBuildContactPatchNoFirstName(t *testing.T) {
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	p := buildContactPatch(jid, "Alice Smith", "")
	if p.Type != appstate.WAPatchCriticalUnblockLow {
		t.Fatalf("type=%v want critical_unblock_low", p.Type)
	}
	if len(p.Mutations) != 1 {
		t.Fatalf("mutations=%d want 1", len(p.Mutations))
	}
	m := p.Mutations[0]
	if len(m.Index) != 2 || m.Index[0] != appstate.IndexContact || m.Index[1] != jid.String() {
		t.Fatalf("bad index %v", m.Index)
	}
	if m.Version != 2 {
		t.Fatalf("version=%d want 2", m.Version)
	}
	ca := m.Value.GetContactAction()
	if ca.GetFullName() != "Alice Smith" || ca.GetFirstName() != "" || !ca.GetSaveOnPrimaryAddressbook() {
		t.Fatalf("bad action %+v", ca)
	}
}

func TestBuildContactPatchWithFirstName(t *testing.T) {
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	p := buildContactPatch(jid, "Alice Smith", "Alice")
	if p.Mutations[0].Value.GetContactAction().GetFirstName() != "Alice" {
		t.Fatal("first name not set")
	}
}

func TestSetContactNameBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/c.db")
	defer c.Close()
	err := c.SetContactName("abc:def@x", "X", "")
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}
```

(Merge these imports into the existing single `import (...)` block in the test file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd bridge && go test ./... -run 'TestBuildContactPatch|TestSetContactNameBadJID' -v`
Expected: FAIL — `buildContactPatch`/`SetContactName` undefined.

- [ ] **Step 3: Write minimal implementation**

In `bridge/appstate.go` add `"go.mau.fi/whatsmeow/proto/waSyncAction"` to the import block, then append:

```go
// buildContactPatch constructs the appstate patch that saves a contact name,
// synced to the phone address book. whatsmeow ships no helper for the
// "contact" index, so we assemble it directly (modeled on appstate.BuildPin).
// Version 2 is the WhatsApp contact-action version; if the server rejects the
// patch in live testing, this is the value to revisit (see spec).
func buildContactPatch(target types.JID, fullName, firstName string) appstate.PatchInfo {
	action := &waSyncAction.ContactAction{
		FullName:                 proto.String(fullName),
		SaveOnPrimaryAddressbook: proto.Bool(true),
	}
	if firstName != "" {
		action.FirstName = proto.String(firstName)
	}
	return appstate.PatchInfo{
		Type: appstate.WAPatchCriticalUnblockLow,
		Mutations: []appstate.MutationInfo{{
			Index:   []string{appstate.IndexContact, target.String()},
			Version: 2,
			Value:   &waSyncAction.SyncActionValue{ContactAction: action},
		}},
	}
}

// SetContactName saves a display name for jid, synced to the phone address
// book and the user's other linked devices.
func (c *Client) SetContactName(jid, fullName, firstName string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	target, err := types.ParseJID(jid)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	return c.wa.SendAppState(context.Background(), buildContactPatch(target, fullName, firstName))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd bridge && go test ./... -run 'TestBuildContactPatch|TestSetContactNameBadJID' -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add bridge/appstate.go bridge/appstate_test.go
git commit -m "bridge: synced add-to-contacts via ContactAction patch"
```

---

## Task 3: Go bridge — block / unblock / list blocked

**Files:**
- Create: `bridge/blocklist.go`
- Create: `bridge/blocklist_test.go`

- [ ] **Step 1: Write the failing test**

Create `bridge/blocklist_test.go`:

```go
package bridge

import (
	"strings"
	"testing"
)

func TestSetBlockedBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/b.db")
	defer c.Close()
	err := c.SetBlocked("abc:def@x", true)
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}

func TestListBlockedUnconnectedErrors(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/b2.db")
	defer c.Close()
	// Not connected → GetBlocklist's IQ cannot complete; expect an error
	// rather than a bogus empty success.
	if _, err := c.ListBlocked(); err == nil {
		t.Fatal("want error from unconnected ListBlocked")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd bridge && go test ./... -run 'TestSetBlockedBadJID|TestListBlockedUnconnectedErrors' -v`
Expected: FAIL — `SetBlocked`/`ListBlocked` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `bridge/blocklist.go`:

```go
package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// SetBlocked blocks or unblocks a user via the WhatsApp blocklist IQ
// (UpdateBlocklist). The change propagates to the user's other devices.
func (c *Client) SetBlocked(jid string, blocked bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	target, err := types.ParseJID(jid)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	action := events.BlocklistChangeActionUnblock
	if blocked {
		action = events.BlocklistChangeActionBlock
	}
	_, err = c.wa.UpdateBlocklist(context.Background(), target, action)
	return err
}

// ListBlocked returns a JSON array of the JID strings the user has blocked,
// fetched from the server (GetBlocklist).
func (c *Client) ListBlocked() (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	list, err := c.wa.GetBlocklist(context.Background())
	if err != nil {
		return "", fmt.Errorf("get blocklist: %w", err)
	}
	out := make([]string, 0, len(list.JIDs))
	for _, j := range list.JIDs {
		out = append(out, j.String())
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd bridge && go test ./... -run 'TestSetBlockedBadJID|TestListBlockedUnconnectedErrors' -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add bridge/blocklist.go bridge/blocklist_test.go
git commit -m "bridge: block/unblock + list blocked via blocklist IQ"
```

---

## Task 4: Go bridge — inbound events

**Files:**
- Modify: `bridge/jsonmodels.go`
- Modify: `bridge/events.go`
- Modify: `bridge/events_dispatch_test.go`

- [ ] **Step 1: Write the failing test**

Append to `bridge/events_dispatch_test.go` (the file already imports `encoding/json`, `testing`, `time`, `types`, `events`; add `waSyncAction` and `proto`):

```go
// add to the import block:
//   "go.mau.fi/whatsmeow/proto/waSyncAction"
//   "google.golang.org/protobuf/proto"

func TestArchiveJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ar.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	c.dispatchArchive(&events.Archive{
		JID:       jid,
		Timestamp: time.Unix(7, 0),
		Action:    &waSyncAction.ArchiveChatAction{Archived: proto.Bool(true)},
	})
	e := sink.wait(t, "ChatArchived", time.Second)
	var j JChatArchived
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.ChatJID != "12345@s.whatsapp.net" || !j.Archived || j.Timestamp != 7 {
		t.Fatalf("bad archive: %+v", j)
	}
}

func TestDeleteChatJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/dc.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	c.dispatchDeleteChat(&events.DeleteChat{JID: jid, Timestamp: time.Unix(9, 0)})
	e := sink.wait(t, "ChatDeleted", time.Second)
	var j JChatDeleted
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.ChatJID != "12345@s.whatsapp.net" || j.Timestamp != 9 {
		t.Fatalf("bad delete: %+v", j)
	}
}

func TestContactJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/co.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	c.dispatchContact(&events.Contact{
		JID:    jid,
		Action: &waSyncAction.ContactAction{FullName: proto.String("Bob"), FirstName: proto.String("B")},
	})
	e := sink.wait(t, "ContactUpdated", time.Second)
	var j JContactUpdated
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.JID != "12345@s.whatsapp.net" || j.FullName != "Bob" || j.FirstName != "B" {
		t.Fatalf("bad contact: %+v", j)
	}
}

func TestBlocklistJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/bl.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	c.dispatchBlocklist(&events.Blocklist{
		Action: events.BlocklistActionDefault,
		Changes: []events.BlocklistChange{
			{JID: jid, Action: events.BlocklistChangeActionBlock},
		},
	})
	e := sink.wait(t, "BlocklistChanged", time.Second)
	var j JBlocklistChanged
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if len(j.Changes) != 1 || j.Changes[0].JID != "12345@s.whatsapp.net" || j.Changes[0].Action != "block" {
		t.Fatalf("bad blocklist: %+v", j)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd bridge && go test ./... -run 'TestArchiveJSON|TestDeleteChatJSON|TestContactJSON|TestBlocklistJSON' -v`
Expected: FAIL — `dispatchArchive` etc. and the `J*` types undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `bridge/jsonmodels.go`:

```go
type JChatArchived struct {
	ChatJID   string `json:"chat_jid"`
	Archived  bool   `json:"archived"`
	Timestamp int64  `json:"timestamp"`
}

type JChatDeleted struct {
	ChatJID   string `json:"chat_jid"`
	Timestamp int64  `json:"timestamp"`
}

type JContactUpdated struct {
	JID       string `json:"jid"`
	FullName  string `json:"full_name"`
	FirstName string `json:"first_name"`
}

type JBlockChange struct {
	JID    string `json:"jid"`
	Action string `json:"action"`
}

type JBlocklistChanged struct {
	Action  string         `json:"action"`
	Changes []JBlockChange `json:"changes"`
}
```

In `bridge/events.go`, add to the `handleWAEvent` type switch (after the `*events.Pin` case):

```go
		case *events.Archive:
			c.dispatchArchive(v)
		case *events.DeleteChat:
			c.dispatchDeleteChat(v)
		case *events.Contact:
			c.dispatchContact(v)
		case *events.Blocklist:
			c.dispatchBlocklist(v)
```

Append the dispatch helpers to `bridge/events.go`:

```go
// dispatchArchive surfaces app-state archive/unarchive events (a chat
// (un)archived from the phone or another companion device).
func (c *Client) dispatchArchive(evt *events.Archive) {
	archived := false
	if a := evt.Action; a != nil {
		archived = a.GetArchived()
	}
	b, _ := json.Marshal(JChatArchived{
		ChatJID:   evt.JID.String(),
		Archived:  archived,
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("ChatArchived", string(b))
}

// dispatchDeleteChat surfaces app-state delete-chat events (a conversation
// cleared on the phone or another companion device).
func (c *Client) dispatchDeleteChat(evt *events.DeleteChat) {
	b, _ := json.Marshal(JChatDeleted{
		ChatJID:   evt.JID.String(),
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("ChatDeleted", string(b))
}

// dispatchContact surfaces app-state contact-name changes so a name saved
// on the phone shows up locally.
func (c *Client) dispatchContact(evt *events.Contact) {
	full, first := "", ""
	if a := evt.Action; a != nil {
		full = a.GetFullName()
		first = a.GetFirstName()
	}
	b, _ := json.Marshal(JContactUpdated{
		JID:       evt.JID.String(),
		FullName:  full,
		FirstName: first,
	})
	c.dispatch("ContactUpdated", string(b))
}

// dispatchBlocklist surfaces blocklist changes. When Action == "modify"
// the Changes list is empty and the Swift side re-fetches the whole list.
func (c *Client) dispatchBlocklist(evt *events.Blocklist) {
	changes := make([]JBlockChange, 0, len(evt.Changes))
	for _, ch := range evt.Changes {
		changes = append(changes, JBlockChange{
			JID:    ch.JID.String(),
			Action: string(ch.Action),
		})
	}
	b, _ := json.Marshal(JBlocklistChanged{
		Action:  string(evt.Action),
		Changes: changes,
	})
	c.dispatch("BlocklistChanged", string(b))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd bridge && go test ./... -v`
Expected: PASS — all bridge tests, including the four new dispatch tests.

- [ ] **Step 5: Commit**

```bash
git add bridge/jsonmodels.go bridge/events.go bridge/events_dispatch_test.go
git commit -m "bridge: dispatch archive/delete/contact/blocklist events"
```

---

## Task 5: Rebuild Bridge.xcframework + regenerate project

**Files:** none edited (build artifacts in `build/` are gitignored).

- [ ] **Step 1: Rebuild the gomobile framework**

Run: `./scripts/build-xcframework.sh`
Expected: produces `build/Bridge.xcframework` (no errors; may take minutes).

- [ ] **Step 2: Verify the new selectors are exported**

Run: `grep -rhoE "(ArchiveChat|DeleteChat|SetContactName|SetBlocked|ListBlocked)[A-Za-z:]*" build/Bridge.xcframework/*/Bridge.framework/Headers/*.h | sort -u`
Expected: lines showing the five new methods (e.g. `archiveChat:archived:lastTS:lastMsgID:fromMe:error:`, `setBlocked:blocked:error:`, `listBlocked:`, etc.). Note the exact Swift selectors here — they feed Task 6. If a selector name differs from what Task 6 predicts, use the one printed here.

- [ ] **Step 3: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: `Created project at .../yawac.xcodeproj`.

- [ ] **Step 4: Confirm the app still builds against the new framework**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (no Swift changes yet — this just confirms the regenerated framework links).

- [ ] **Step 5: Commit**

No source changes to commit (build artifacts gitignored). Skip the commit for this task.

---

## Task 6: Swift bridge wrappers + event decode

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`
- Modify: `yawacTests/BridgeClientTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `yawacTests/BridgeClientTests.swift` (inside the class):

```go
// NOTE: this is Swift, shown in a swift block below — placed here for ordering.
```

```swift
    func testDecodeChatArchived() {
        let e = WAClient.decode(kind: "ChatArchived",
            payload: #"{"chat_jid":"a@s.whatsapp.net","archived":true,"timestamp":7}"#)
        guard case let .chatArchived(jid, archived, ts) = e else {
            return XCTFail("not chatArchived: \(e)")
        }
        XCTAssertEqual(jid, "a@s.whatsapp.net")
        XCTAssertTrue(archived)
        XCTAssertEqual(ts, 7)
    }

    func testDecodeChatDeleted() {
        let e = WAClient.decode(kind: "ChatDeleted",
            payload: #"{"chat_jid":"a@s.whatsapp.net","timestamp":9}"#)
        guard case let .chatDeleted(jid, ts) = e else {
            return XCTFail("not chatDeleted: \(e)")
        }
        XCTAssertEqual(jid, "a@s.whatsapp.net")
        XCTAssertEqual(ts, 9)
    }

    func testDecodeContactUpdated() {
        let e = WAClient.decode(kind: "ContactUpdated",
            payload: #"{"jid":"a@s.whatsapp.net","full_name":"Bob","first_name":"B"}"#)
        guard case let .contactUpdated(jid, full, first) = e else {
            return XCTFail("not contactUpdated: \(e)")
        }
        XCTAssertEqual(jid, "a@s.whatsapp.net")
        XCTAssertEqual(full, "Bob")
        XCTAssertEqual(first, "B")
    }

    func testDecodeBlocklistChanged() {
        let e = WAClient.decode(kind: "BlocklistChanged",
            payload: #"{"action":"","changes":[{"jid":"a@s.whatsapp.net","action":"block"}]}"#)
        guard case let .blocklistChanged(action, changes) = e else {
            return XCTFail("not blocklistChanged: \(e)")
        }
        XCTAssertEqual(action, "")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].jid, "a@s.whatsapp.net")
        XCTAssertEqual(changes[0].action, "block")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test -only-testing:yawacTests/BridgeClientTests CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: FAIL — `.chatArchived`/`.chatDeleted`/`.contactUpdated`/`.blocklistChanged` are not members of `WAClient.Event`.

- [ ] **Step 3: Write minimal implementation**

In `yawac/Bridge/WAClient.swift`, add to the `Event` enum (after `case messagePinned(...)`):

```swift
        case chatArchived(chatJID: String, archived: Bool, timestamp: Int64)
        case chatDeleted(chatJID: String, timestamp: Int64)
        case contactUpdated(jid: String, fullName: String, firstName: String)
        case blocklistChanged(action: String, changes: [(jid: String, action: String)])
```

Add the wrapper methods (place near `pinChat`):

```swift
    func archiveChat(chatJID: String, archived: Bool,
                     lastTS: Int64, lastMsgID: String, fromMe: Bool) throws {
        try go.archiveChat(chatJID, archived: archived,
                           lastTS: lastTS, lastMsgID: lastMsgID, fromMe: fromMe)
    }

    func deleteChat(chatJID: String, lastTS: Int64,
                    lastMsgID: String, fromMe: Bool) throws {
        try go.deleteChat(chatJID, lastTS: lastTS, lastMsgID: lastMsgID, fromMe: fromMe)
    }

    func setContactName(jid: String, fullName: String, firstName: String) throws {
        try go.setContactName(jid, fullName: fullName, firstName: firstName)
    }

    nonisolated func setBlocked(jid: String, blocked: Bool) throws {
        try go.setBlocked(jid, blocked: blocked)
    }

    nonisolated func listBlocked() throws -> [String] {
        var err: NSError?
        let json = go.listBlocked(&err)
        if let err { throw err }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
```

(Use the exact selector names printed in Task 5 Step 2 if they differ from the above.)

Add decode cases to `WAClient.decode(kind:payload:)` before `default:`:

```swift
        case "ChatArchived":
            struct A: Codable {
                let chatJID: String; let archived: Bool; let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case archived, timestamp
                }
            }
            if let a = try? dec.decode(A.self, from: data) {
                return .chatArchived(chatJID: a.chatJID, archived: a.archived, timestamp: a.timestamp)
            }
        case "ChatDeleted":
            struct D: Codable {
                let chatJID: String; let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case timestamp
                }
            }
            if let d = try? dec.decode(D.self, from: data) {
                return .chatDeleted(chatJID: d.chatJID, timestamp: d.timestamp)
            }
        case "ContactUpdated":
            struct C: Codable {
                let jid: String; let fullName: String; let firstName: String
                enum CodingKeys: String, CodingKey {
                    case jid
                    case fullName = "full_name"
                    case firstName = "first_name"
                }
            }
            if let c = try? dec.decode(C.self, from: data) {
                return .contactUpdated(jid: c.jid, fullName: c.fullName, firstName: c.firstName)
            }
        case "BlocklistChanged":
            struct Ch: Codable { let jid: String; let action: String }
            struct B: Codable { let action: String; let changes: [Ch] }
            if let b = try? dec.decode(B.self, from: data) {
                return .blocklistChanged(action: b.action,
                                         changes: b.changes.map { ($0.jid, $0.action) })
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test -only-testing:yawacTests/BridgeClientTests CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/WAClient.swift yawacTests/BridgeClientTests.swift
git commit -m "WAClient: wrappers + decode for archive/delete/contact/blocklist"
```

---

## Task 7: Swift data model — archivedAt

**Files:**
- Modify: `yawac/Models/Chat.swift`
- Modify: `yawac/Models/PersistedMessage.swift`
- Modify: `yawac/ViewModels/ChatListViewModel.swift`

- [ ] **Step 1: Add `archivedAt` to the in-memory model**

In `yawac/Models/Chat.swift`, add below the `pinnedAt` property:

```swift
    /// Server-synced archive (WhatsApp app-state). nil = not archived.
    var archivedAt: Date? = nil
```

- [ ] **Step 2: Add `archivedAt` to PersistedChat**

In `yawac/Models/PersistedMessage.swift`, in `PersistedChat`, add below `var pinnedAt: Date? = nil`:

```swift
    var archivedAt: Date? = nil
```

and add the init parameter (after `pinnedAt: Date? = nil`):

```swift
         pinnedAt: Date? = nil,
         archivedAt: Date? = nil) {
```

and the assignment in the init body (after `self.pinnedAt = pinnedAt`):

```swift
        self.archivedAt = archivedAt
```

- [ ] **Step 3: Hydrate + persist `archivedAt` in ChatListViewModel**

In `yawac/ViewModels/ChatListViewModel.swift`:

In `loadChats()`, in the `Chat(...)` construction (the `.map { row -> Chat in ... }` block), add the trailing argument after `pinnedAt: row.pinnedAt`:

```swift
                    pinnedAt: row.pinnedAt,
                    archivedAt: row.archivedAt)
```

In `upsertPersisted(_:preview:)`, in the existing-row branch add after `existing.pinnedAt = c.pinnedAt`:

```swift
            existing.archivedAt = c.archivedAt
```

and in the new-row `PersistedChat(...)` call add after `pinnedAt: c.pinnedAt`:

```swift
                pinnedAt: c.pinnedAt,
                archivedAt: c.archivedAt)
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (SwiftData light-migrates the new optional column automatically.)

- [ ] **Step 5: Commit**

```bash
git add yawac/Models/Chat.swift yawac/Models/PersistedMessage.swift yawac/ViewModels/ChatListViewModel.swift
git commit -m "model: add archivedAt to Chat + PersistedChat"
```

---

## Task 8: ChatListViewModel — archive / delete / addContact handlers

**Files:**
- Modify: `yawac/Services/SQLiteDedupe.swift`
- Modify: `yawac/ViewModels/ChatListViewModel.swift`
- Create: `yawacTests/ChatListBlockArchiveTests.swift`

- [ ] **Step 1: Write the failing test**

Create `yawacTests/ChatListBlockArchiveTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class ChatListBlockArchiveTests: XCTestCase {

    private func makeVM() -> ChatListViewModel {
        // nil client + nil context: loadChats no-ops; we seed chats directly
        // and exercise the in-memory reconcile paths.
        ChatListViewModel(client: nil, context: nil)
    }

    private func chat(_ jid: String, name: String) -> Chat {
        Chat(jid: jid, name: name, lastMessage: "", lastTimestamp: 0, unread: 0)
    }

    func testApplyIncomingArchiveSetsAndClears() {
        let vm = makeVM()
        vm.chats = [chat("1@s.whatsapp.net", name: "A")]
        vm.applyIncomingArchive(chatJID: "1@s.whatsapp.net", archived: true)
        XCTAssertNotNil(vm.chats[0].archivedAt)
        vm.applyIncomingArchive(chatJID: "1@s.whatsapp.net", archived: false)
        XCTAssertNil(vm.chats[0].archivedAt)
    }

    func testApplyIncomingContactRenames() {
        let vm = makeVM()
        vm.chats = [chat("1@s.whatsapp.net", name: "1@s.whatsapp.net")]
        vm.applyIncomingContact(jid: "1@s.whatsapp.net", fullName: "Alice")
        XCTAssertEqual(vm.chats[0].name, "Alice")
    }

    func testApplyIncomingContactIgnoresEmptyName() {
        let vm = makeVM()
        vm.chats = [chat("1@s.whatsapp.net", name: "Keep")]
        vm.applyIncomingContact(jid: "1@s.whatsapp.net", fullName: "")
        XCTAssertEqual(vm.chats[0].name, "Keep")
    }

    func testApplyIncomingDeleteRemovesFromList() {
        let vm = makeVM()
        vm.chats = [chat("1@s.whatsapp.net", name: "A"), chat("2@s.whatsapp.net", name: "B")]
        vm.applyIncomingDelete(chatJID: "1@s.whatsapp.net")
        XCTAssertEqual(vm.chats.map(\.jid), ["2@s.whatsapp.net"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test -only-testing:yawacTests/ChatListBlockArchiveTests CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: FAIL — `applyIncomingArchive`/`applyIncomingContact`/`applyIncomingDelete` undefined.

- [ ] **Step 3a: Add a durable chat purge to SQLiteDedupe**

In `yawac/Services/SQLiteDedupe.swift`, add inside the `enum SQLiteDedupe` (after `collapseLIDRows`):

```swift
    /// Hard-deletes a chat and all its messages directly via SQLite.
    /// SwiftData's `ModelContext.delete + save` does not reliably persist
    /// deletions of these unique-key rows in our setup (see collapseLIDRows),
    /// so a user-initiated chat delete goes straight to the store. Returns
    /// true when both deletes ran.
    static func purgeChat(jid: String) -> Bool {
        let supportDir: URL
        do {
            supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false)
        } catch {
            return false
        }
        let storeURL = supportDir.appendingPathComponent("default.store")
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return false
        }
        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK, let db else {
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        let okMsgs = execStep(db: db,
            sql: "DELETE FROM ZPERSISTEDMESSAGE WHERE ZCHATJID = ?;", args: [jid])
        let okChat = execStep(db: db,
            sql: "DELETE FROM ZPERSISTEDCHAT WHERE ZJID = ?;", args: [jid])
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
        return okMsgs && okChat
    }
```

- [ ] **Step 3b: Add the handlers to ChatListViewModel**

In `yawac/ViewModels/ChatListViewModel.swift`, append (after `applyLocalPin`):

```swift
    // MARK: - Archive / delete / contact

    /// Latest persisted message metadata for `chatJID`, used to anchor the
    /// archive/delete app-state patch. Returns zero values when unknown.
    private func lastMessageMeta(_ chatJID: String) -> (id: String, ts: Int64, fromMe: Bool) {
        guard let context else { return ("", 0, false) }
        var d = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == chatJID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        d.fetchLimit = 1
        guard let row = try? context.fetch(d).first else { return ("", 0, false) }
        return (row.id, Int64(row.timestamp.timeIntervalSince1970), row.fromMe)
    }

    /// Toggle archive state. Sends the app-state patch (server fans out to
    /// peer devices) and updates the row on success; peer echoes converge
    /// via `applyIncomingArchive`.
    func archiveChat(_ chat: Chat, archived: Bool) {
        guard let client else { return }
        let last = lastMessageMeta(chat.jid)
        Task { @MainActor in
            do {
                try client.archiveChat(chatJID: chat.jid, archived: archived,
                                       lastTS: last.ts, lastMsgID: last.id, fromMe: last.fromMe)
                self.applyLocalArchive(chatJID: chat.jid, archivedAt: archived ? Date() : nil)
            } catch {
                NSLog("[yawac/archiveChat] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    func applyIncomingArchive(chatJID: String, archived: Bool) {
        applyLocalArchive(chatJID: chatJID, archivedAt: archived ? Date() : nil)
    }

    private func applyLocalArchive(chatJID: String, archivedAt: Date?) {
        if let idx = chats.firstIndex(where: { $0.jid == chatJID }) {
            chats[idx].archivedAt = archivedAt
            upsertPersisted(chats[idx])
        } else if let context {
            let descriptor = FetchDescriptor<PersistedChat>(
                predicate: #Predicate { $0.jid == chatJID })
            if let row = try? context.fetch(descriptor).first {
                row.archivedAt = archivedAt
                try? context.save()
            }
        }
    }

    /// Delete a chat locally and on every device. Sends the DeleteChat
    /// app-state patch, then removes the local rows.
    func deleteChat(_ chat: Chat) {
        let last = lastMessageMeta(chat.jid)
        if let client {
            Task { @MainActor in
                do {
                    try client.deleteChat(chatJID: chat.jid, lastTS: last.ts,
                                          lastMsgID: last.id, fromMe: last.fromMe)
                } catch {
                    NSLog("[yawac/deleteChat] failed jid=%@ err=%@",
                          chat.jid, String(describing: error))
                }
            }
        }
        removeChatLocally(chat.jid)
        session?.deletedChatJID = chat.jid
    }

    func applyIncomingDelete(chatJID: String) {
        removeChatLocally(chatJID)
        session?.deletedChatJID = chatJID
    }

    private func removeChatLocally(_ chatJID: String) {
        chats.removeAll { $0.jid == chatJID }
        if let context {
            let msgs = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.chatJID == chatJID })
            if let rows = try? context.fetch(msgs) {
                for r in rows { context.delete(r) }
            }
            let chatDesc = FetchDescriptor<PersistedChat>(
                predicate: #Predicate { $0.jid == chatJID })
            if let row = try? context.fetch(chatDesc).first {
                context.delete(row)
            }
            try? context.save()
        }
        // SwiftData delete of unique-key rows is unreliable here, so purge
        // directly so the chat doesn't resurrect on next launch.
        _ = SQLiteDedupe.purgeChat(jid: chatJID)
    }

    /// Save a contact name (synced to the phone). Updates the local name on
    /// success; peer echoes converge via `applyIncomingContact`.
    func addContact(_ chat: Chat, fullName: String, firstName: String) {
        guard let client, !fullName.isEmpty else { return }
        Task { @MainActor in
            do {
                try client.setContactName(jid: chat.jid, fullName: fullName, firstName: firstName)
                self.applyIncomingContact(jid: chat.jid, fullName: fullName)
            } catch {
                NSLog("[yawac/addContact] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    func applyIncomingContact(jid: String, fullName: String) {
        guard !fullName.isEmpty else { return }
        let bare = JIDNormalize.bare(jid)
        session?.contactNames[bare] = fullName
        if let idx = chats.firstIndex(where: { $0.jid == bare }) {
            chats[idx].name = fullName
            upsertPersisted(chats[idx])
            sortChats()
        }
    }
```

`removeChatLocally` references `SQLiteDedupe.purgeChat`; both must compile together (Steps 3a + 3b in one edit pass). `deletedChatJID` is defined on `SessionViewModel` in Task 9 — for this task to build, do Task 9's Step 3 property addition first OR add it now. To keep tasks independently buildable, add the property now in `yawac/ViewModels/SessionViewModel.swift` (it is also covered by Task 9):

```swift
    /// Set by ChatListViewModel when a chat is deleted so ContentView can
    /// clear the detail selection if that chat was open. Consumed + cleared
    /// by ContentView via `.onChange`.
    var deletedChatJID: String?
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test -only-testing:yawacTests/ChatListBlockArchiveTests CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add yawac/Services/SQLiteDedupe.swift yawac/ViewModels/ChatListViewModel.swift yawac/ViewModels/SessionViewModel.swift yawacTests/ChatListBlockArchiveTests.swift
git commit -m "ChatListVM: archive/delete/addContact handlers + durable purge"
```

---

## Task 9: SessionViewModel — blocklist state

**Files:**
- Modify: `yawac/ViewModels/SessionViewModel.swift`
- Create: `yawacTests/SessionBlocklistTests.swift`

- [ ] **Step 1: Write the failing test**

Create `yawacTests/SessionBlocklistTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class SessionBlocklistTests: XCTestCase {

    func testApplyChangesBlockThenUnblock() {
        let s = SessionViewModel()
        s.applyBlocklistChange(action: "",
            changes: [(jid: "1@s.whatsapp.net", action: "block")])
        XCTAssertTrue(s.isBlocked("1@s.whatsapp.net"))
        s.applyBlocklistChange(action: "",
            changes: [(jid: "1@s.whatsapp.net", action: "unblock")])
        XCTAssertFalse(s.isBlocked("1@s.whatsapp.net"))
    }

    func testIsBlockedStripsDeviceSuffix() {
        let s = SessionViewModel()
        s.applyBlocklistChange(action: "",
            changes: [(jid: "1@s.whatsapp.net", action: "block")])
        // A device-suffixed JID for the same user resolves to blocked.
        XCTAssertTrue(s.isBlocked("1:23@s.whatsapp.net"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test -only-testing:yawacTests/SessionBlocklistTests CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: FAIL — `applyBlocklistChange`/`isBlocked` undefined.

- [ ] **Step 3: Write minimal implementation**

In `yawac/ViewModels/SessionViewModel.swift`, add the stored property (near `var totalUnread`):

```swift
    /// JIDs (bare) the user has blocked. Seeded from the server via
    /// `loadBlocklist()` on connect; updated by BlocklistChanged events.
    private(set) var blockedJIDs: Set<String> = []
```

(If `deletedChatJID` was not already added in Task 8, add it here too — see Task 8 Step 3.)

Add the methods (anywhere in the class body, e.g. after `displayName(for:)`):

```swift
    func isBlocked(_ jid: String) -> Bool {
        blockedJIDs.contains(JIDNormalize.bare(jid))
    }

    /// Refetch the full blocklist from the server (off-main, since the
    /// gomobile IQ blocks) and replace the local set.
    func loadBlocklist() {
        guard let client else { return }
        Task { @MainActor [weak self] in
            let jids = await Task.detached { try? client.listBlocked() }.value ?? []
            self?.blockedJIDs = Set(jids.map { JIDNormalize.bare($0) })
        }
    }

    /// Block/unblock a user. Updates the local set on success.
    func setBlocked(_ jid: String, blocked: Bool) {
        guard let client else { return }
        let bare = JIDNormalize.bare(jid)
        Task { @MainActor [weak self] in
            do {
                try await Task.detached { try client.setBlocked(jid: bare, blocked: blocked) }.value
                if blocked { self?.blockedJIDs.insert(bare) }
                else { self?.blockedJIDs.remove(bare) }
            } catch {
                NSLog("[yawac/blocklist] setBlocked failed jid=%@ err=%@",
                      bare, String(describing: error))
            }
        }
    }

    /// Apply an inbound BlocklistChanged event. A "modify" action (or an
    /// empty change list) means "re-sync everything".
    func applyBlocklistChange(action: String, changes: [(jid: String, action: String)]) {
        if action == "modify" || changes.isEmpty {
            loadBlocklist()
            return
        }
        for ch in changes {
            let bare = JIDNormalize.bare(ch.jid)
            switch ch.action {
            case "block":   blockedJIDs.insert(bare)
            case "unblock": blockedJIDs.remove(bare)
            default:        break
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test -only-testing:yawacTests/SessionBlocklistTests CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/SessionViewModel.swift yawacTests/SessionBlocklistTests.swift
git commit -m "SessionVM: in-memory blocklist state + change application"
```

---

## Task 10: ContentView — route new events

**Files:**
- Modify: `yawac/ContentView.swift`

- [ ] **Step 1: Route the four new events + blocklist load**

In `yawac/ContentView.swift`, inside the `.task { ... for await event in stream { switch event {` block:

Replace the existing `.connected` case body with:

```swift
                case .connected:
                    vm.reconcilePinsWithStore()
                    session.loadBlocklist()
```

In the existing `.historySync` case, add at the end (after `vm.reconcilePinsWithStore()`):

```swift
                    session.loadBlocklist()
```

Add these cases before `default:`:

```swift
                case .chatArchived(let chatJID, let archived, _):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingArchive(chatJID: canonical, archived: archived)
                case .chatDeleted(let chatJID, _):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    vm.applyIncomingDelete(chatJID: canonical)
                case .contactUpdated(let jid, let fullName, _):
                    let canonical = JIDNormalize.canonical(jid, client: client)
                    vm.applyIncomingContact(jid: canonical, fullName: fullName)
                case .blocklistChanged(let action, let changes):
                    session.applyBlocklistChange(action: action, changes: changes)
```

- [ ] **Step 2: Clear the detail selection when the open chat is deleted**

Add a new `.onChange` modifier on the `NavigationSplitView` (next to the existing `.onChange(of: session.pendingChatSelection)`):

```swift
        .onChange(of: session.deletedChatJID) { _, jid in
            guard let jid else { return }
            if selectedChat == jid { selectedChat = nil }
            session.deletedChatJID = nil
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add yawac/ContentView.swift
git commit -m "ContentView: route archive/delete/contact/blocklist + deselect on delete"
```

---

## Task 11: Sidebar — Archived section + context menu + dialogs

**Files:**
- Create: `yawac/Views/ContactNameSheet.swift`
- Modify: `yawac/Views/ChatListView.swift`

- [ ] **Step 1: Create the contact name-entry sheet**

Create `yawac/Views/ContactNameSheet.swift`:

```swift
import SwiftUI

/// Modal for saving / editing a contact's display name. Calls `onSave(full,
/// first)` with trimmed values; first name is optional.
struct ContactNameSheet: View {
    let initialName: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fullName: String
    @State private var firstName: String

    init(initialName: String, onSave: @escaping (String, String) -> Void) {
        self.initialName = initialName
        self.onSave = onSave
        _fullName = State(initialValue: initialName)
        _firstName = State(initialValue: "")
    }

    private var trimmedFull: String {
        fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save contact")
                .font(Theme.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 6) {
                Text("Full name")
                    .font(Theme.ui(11)).foregroundStyle(Theme.textFaint)
                TextField("Full name", text: $fullName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("First name (optional)")
                    .font(Theme.ui(11)).foregroundStyle(Theme.textFaint)
                TextField("First name", text: $firstName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if !trimmedFull.isEmpty {
                        onSave(trimmedFull,
                               firstName.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedFull.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Theme.sidebarBg)
    }
}
```

- [ ] **Step 2: Wire the Archived section + expanded context menu + dialogs into ChatListView**

In `yawac/Views/ChatListView.swift`:

(a) Add the session environment + dialog state below the existing `@FocusState`:

```swift
    @Environment(SessionViewModel.self) private var session
    @State private var archivedExpanded = false
    @State private var pendingDelete: Chat?
    @State private var pendingBlock: Chat?
    @State private var contactEditing: Chat?
```

(b) Extend the `Row` enum with an archived header case and its id:

```swift
    private enum Row: Hashable, Identifiable {
        case section(id: String, label: String, count: Int)
        case archivedHeader(count: Int)
        case chat(Chat, indent: CGFloat)
        case suggestion(PhoneSuggestion)
        var id: String {
            switch self {
            case .section(let id, _, _): return "sec:" + id
            case .archivedHeader:        return "sec:archived-header"
            case .chat(let c, let i):    return "row:\(c.jid)#\(Int(i))"
            case .suggestion(let s):     return "sug:" + s.jid
            }
        }
    }
```

(c) In `displayRows()`, add an `archived` bucket. Change the declaration line `var pinned: [Chat] = []` to also declare:

```swift
        var archived: [Chat] = []
```

Replace the bucket-assignment loop's first lines so archived chats are pulled out (only when not searching — during search archived chats should still surface):

```swift
        for c in chats {
            if search.query.isEmpty, c.archivedAt != nil {
                archived.append(c)
                continue
            }
            if c.pinnedAt != nil {
                pinned.append(c)
                continue
            }
            if c.isCommunityParent {
                communities.append(c)
            } else if let parent = c.communityParentJID, !parent.isEmpty {
                subsByParent[parent, default: []].append(c)
            } else if c.isGroup {
                standaloneGroups.append(c)
            } else {
                directChats.append(c)
            }
        }
```

Then, immediately after `let s = scope` and before the pinned block, insert the archived header block:

```swift
        let archivedVisible: [Chat] = archived.filter { c in
            switch s {
            case .all:         return true
            case .chats:       return !c.isGroup && !c.isCommunityParent
            case .groups:      return c.isGroup && !c.isCommunityParent
            case .communities: return c.isCommunityParent
            }
        }
        if !archivedVisible.isEmpty {
            out.append(.archivedHeader(count: archivedVisible.count))
            if archivedExpanded {
                for a in archivedVisible {
                    out.append(.chat(a, indent: 0))
                }
            }
        }
```

(d) In `body`, in the `ForEach(displayRows())` switch, add the archived header case:

```swift
                        case .archivedHeader(let count):
                            archivedHeaderRow(count: count)
```

(e) Attach the dialogs + sheet to the `ScrollView` (the one wrapping the `LazyVStack`). Add after its closing `}` modifiers:

```swift
            .confirmationDialog(
                "Delete chat with \(pendingDelete?.name ?? "")?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { chat in
                Button("Delete", role: .destructive) {
                    vm.deleteChat(chat); pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("This clears the conversation on all your devices.")
            }
            .confirmationDialog(
                "Block \(pendingBlock?.name ?? "")?",
                isPresented: Binding(get: { pendingBlock != nil },
                                     set: { if !$0 { pendingBlock = nil } }),
                presenting: pendingBlock
            ) { chat in
                Button("Block", role: .destructive) {
                    session.setBlocked(chat.jid, blocked: true); pendingBlock = nil
                }
                Button("Cancel", role: .cancel) { pendingBlock = nil }
            }
            .sheet(item: $contactEditing) { chat in
                ContactNameSheet(initialName: chat.name == chat.jid ? "" : chat.name) { full, first in
                    vm.addContact(chat, fullName: full, firstName: first)
                }
            }
```

(f) Replace the `.contextMenu { ... }` in `chatRowButton` with:

```swift
        .contextMenu {
            Button(chat.pinnedAt != nil ? "Unpin chat" : "Pin chat") {
                vm.pinChat(chat, pinned: chat.pinnedAt == nil)
            }
            Button(chat.archivedAt != nil ? "Unarchive" : "Archive") {
                vm.archiveChat(chat, archived: chat.archivedAt == nil)
            }
            if !chat.isGroup && !chat.isCommunityParent {
                Button("Add to contacts…") { contactEditing = chat }
                if session.isBlocked(chat.jid) {
                    Button("Unblock") { session.setBlocked(chat.jid, blocked: false) }
                } else {
                    Button("Block…") { pendingBlock = chat }
                }
            }
            Divider()
            Button("Delete chat…", role: .destructive) { pendingDelete = chat }
        }
```

(g) Add the `archivedHeaderRow` builder (next to `sectionLabel`):

```swift
    @ViewBuilder
    private func archivedHeaderRow(count: Int) -> some View {
        Button { archivedExpanded.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                Text("Archived")
                    .font(Theme.ui(13, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text("\(count)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
                Image(systemName: archivedExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ContactNameSheet.swift yawac/Views/ChatListView.swift
git commit -m "sidebar: Archived section + archive/delete/block/add-contact menu"
```

---

## Task 12: Conversation header menu + blocked banner

**Files:**
- Modify: `yawac/Views/ConversationView.swift`

- [ ] **Step 1: Add dialog/sheet state**

In `yawac/Views/ConversationView.swift`, add near the existing `@State` declarations:

```swift
    @State private var pendingDelete: Chat?
    @State private var pendingBlock: Chat?
    @State private var contactEditing: Chat?
```

- [ ] **Step 2: Add the `⋯` menu to the header bar**

In `headerBar`, insert before the info `Button` (after `Spacer()`):

```swift
            if let chat = session.chatList?.chats.first(where: { $0.jid == chatJID }) {
                Menu {
                    Button(chat.pinnedAt != nil ? "Unpin chat" : "Pin chat") {
                        session.chatList?.pinChat(chat, pinned: chat.pinnedAt == nil)
                    }
                    Button(chat.archivedAt != nil ? "Unarchive" : "Archive") {
                        session.chatList?.archiveChat(chat, archived: chat.archivedAt == nil)
                    }
                    if !chat.isGroup && !chat.isCommunityParent {
                        Button("Add to contacts…") { contactEditing = chat }
                        if session.isBlocked(chat.jid) {
                            Button("Unblock") { session.setBlocked(chat.jid, blocked: false) }
                        } else {
                            Button("Block…") { pendingBlock = chat }
                        }
                    }
                    Divider()
                    Button("Delete chat…", role: .destructive) { pendingDelete = chat }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                        .padding(7)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Chat actions")
            }
```

- [ ] **Step 3: Add the blocked banner**

Add the builder (next to `pinnedBanner`):

```swift
    @ViewBuilder
    private var blockedBanner: some View {
        if session.isBlocked(chatJID) {
            HStack(spacing: 10) {
                Image(systemName: "nosign")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                Text("You blocked this contact")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Unblock") { session.setBlocked(chatJID, blocked: false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.surfaceAlt)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
        }
    }
```

In `body`, render it right after `pinnedBanner(vm)`:

```swift
                    pinnedBanner(vm)
                    blockedBanner
```

- [ ] **Step 4: Attach dialogs + sheet**

Attach to the outer `Group` in `body` (after its existing modifiers):

```swift
        .confirmationDialog(
            "Delete chat with \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { chat in
            Button("Delete", role: .destructive) {
                session.chatList?.deleteChat(chat); pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This clears the conversation on all your devices.")
        }
        .confirmationDialog(
            "Block \(pendingBlock?.name ?? "")?",
            isPresented: Binding(get: { pendingBlock != nil },
                                 set: { if !$0 { pendingBlock = nil } }),
            presenting: pendingBlock
        ) { chat in
            Button("Block", role: .destructive) {
                session.setBlocked(chat.jid, blocked: true); pendingBlock = nil
            }
            Button("Cancel", role: .cancel) { pendingBlock = nil }
        }
        .sheet(item: $contactEditing) { chat in
            ContactNameSheet(initialName: chat.name == chat.jid ? "" : chat.name) { full, first in
                session.chatList?.addContact(chat, fullName: full, firstName: first)
            }
        }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/ConversationView.swift
git commit -m "conversation: header actions menu + blocked banner"
```

---

## Task 13: Settings — blocked contacts section

**Files:**
- Modify: `yawac/Views/SettingsView.swift`

- [ ] **Step 1: Add the session environment + Blocked section**

In `yawac/Views/SettingsView.swift`, add below the existing `@Environment(TranslationViewModel.self)`:

```swift
    @Environment(SessionViewModel.self) private var session
```

Add a new `Section` inside the `Form` (after the "Never translate" section):

```swift
            Section("Blocked contacts") {
                if session.blockedJIDs.isEmpty {
                    Text("No blocked contacts.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.blockedJIDs.sorted(), id: \.self) { jid in
                        HStack {
                            Text(session.displayName(for: jid))
                            Spacer()
                            Button("Unblock") {
                                session.setBlocked(jid, blocked: false)
                            }
                        }
                    }
                }
            }
```

Update the existing `.onAppear` to also refresh the blocklist:

```swift
        .onAppear {
            translation.model.refreshState()
            session.loadBlocklist()
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Confirm SettingsView gets the session in the environment**

Verify (read-only) that wherever `SettingsView()` is instantiated (Settings scene in `yawac/yawacApp.swift`), the `SessionViewModel` is injected via `.environment(...)`. If it is not, add `.environment(session)` to the `SettingsView()` usage so the new `@Environment` resolves at runtime.

Run: `grep -rn "SettingsView()" yawac/`
Expected: shows the call site; ensure a `.environment(<sessionVM>)` is attached there (add it if missing).

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add yawac/Views/SettingsView.swift yawac/yawacApp.swift
git commit -m "settings: blocked contacts list with unblock"
```

---

## Task 14: Manual verification (live device)

**Files:** none.

These exercise real WhatsApp sync and can't be unit-tested. Run the app paired to a phone.

- [ ] **Step 1: Build + launch**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` then launch the built app.

- [ ] **Step 2: Archive round-trip**

Right-click a chat → Archive. It moves under the "Archived (N)" row; expand to see it. Unarchive it from the same menu (expanded row → right-click → Unarchive). Archive a chat on the phone → it appears under Archived in yawac within a few seconds. Tail `/tmp/yawac.log` for the `ChatArchived` dispatch if it doesn't.

- [ ] **Step 3: Delete**

Right-click a chat → "Delete chat…" → confirm. The row disappears; the conversation pane clears if it was open. Verify on the phone that the conversation is cleared. Relaunch yawac → the chat stays gone (durable purge worked).

- [ ] **Step 4: Block / unblock**

Open a 1:1 chat → header `⋯` → "Block…" → confirm. The blocked banner appears above the composer. Open Settings → "Blocked contacts" → the user is listed; click Unblock → banner clears. Block on the phone → yawac reflects it (banner + Settings) after the `BlocklistChanged` event / re-fetch.

- [ ] **Step 5: Add to contacts (confirms the contact-patch version)**

Open an unsaved 1:1 chat → "Add to contacts…" → enter a full name → Save. The sidebar row + header retitle immediately. **On the phone**, confirm the saved name appears in the WhatsApp chat / contact within ~30s. If it does NOT land on the phone, the `Version: 2` in `buildContactPatch` (bridge/appstate.go) is wrong — adjust and rebuild the xcframework (see spec note).

- [ ] **Step 6: Group scoping**

Right-click a group → confirm only Pin/Archive/Delete are offered (no Block, no Add-to-contacts). 1:1 chats show all four.

---

## Self-Review

**Spec coverage:**
- Add-to-contacts (synced ContactAction) → Tasks 2, 6, 8, 11, 12. ✓
- Delete chat (DeleteChat appstate + all-device clear + local purge) → Tasks 1, 6, 8, 10, 11, 12. ✓
- Block/unblock (UpdateBlocklist/GetBlocklist) → Tasks 3, 6, 9, 10, 11, 12, 13. ✓
- Archive (BuildArchive + collapsible section) → Tasks 1, 6, 7, 8, 10, 11, 12. ✓
- Inbound events (Archive/DeleteChat/Contact/Blocklist) → Tasks 4, 6, 10. ✓
- Both surfaces (sidebar + header) → Tasks 11, 12. ✓
- Confirmations (Delete + Block) → Tasks 11, 12. ✓
- Blocked banner → Task 12. ✓
- Settings blocked list → Task 13. ✓
- 1:1-only scoping for Block/Add-contact → Tasks 11, 12. ✓
- Contact-patch version risk verified live → Task 14 Step 5. ✓

**Type consistency:** `archivedAt: Date?` used consistently (Chat, PersistedChat, applyLocalArchive). Bridge methods `ArchiveChat`/`DeleteChat`/`SetContactName`/`SetBlocked`/`ListBlocked` ↔ Swift `archiveChat`/`deleteChat`/`setContactName`/`setBlocked`/`listBlocked`. Event kinds `ChatArchived`/`ChatDeleted`/`ContactUpdated`/`BlocklistChanged` match between Go dispatch, Swift decode, and ContentView routing. `deletedChatJID` defined in SessionViewModel (Task 8/9), consumed in ContentView (Task 10). `applyBlocklistChange(action:changes:)` signature matches between SessionVM (Task 9) and ContentView (Task 10) and the test (Task 9).

**Placeholder scan:** No TBD/TODO. Every code step shows complete code. The one runtime unknown (contact-patch `Version`) has a concrete starting value (2) and an explicit live-verification step.

**Note on import ordering (Task 1→2):** Task 1 adds `proto` + `waCommon` to `appstate.go`; `waSyncAction` is added in Task 2 (first use). If executing strictly task-by-task and Go's unused-import check fires, follow Task 1 Step 3's "Corrected import block" guidance.
