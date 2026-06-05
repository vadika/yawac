# v0.8.2 — Group Admin Polish (Announce + Locked) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire two whatsmeow group-admin RPCs (`SetGroupAnnounce`, `SetGroupLocked`) plus matching event handlers, model fields, ChatInfoView toggle rows, and ComposerView gating for announce-mode non-admins.

**Architecture:** Mirror v0.7.1 T26 approval-mode pattern verbatim. Two bridge funcs + two events + two model fields + two ChatInfoView sectionCards + ComposerView gate.

**Tech Stack:** Same as v0.8.1.

**Test commands:** Same as v0.8.1.

**Spec:** `docs/superpowers/specs/2026-06-05-group-admin-polish-design.md`.

**Worktree:** `worktree-group-admin-polish-v0.8.2` off `main`.

---

## Milestone A — Bridge

### Task 1: `SetGroupAnnounce` + `SetGroupLocked` bridge funcs + tests

**Files:** `bridge/groups.go`, `bridge/groups_test.go`.

- [ ] **Step 1:** Append failing tests to `bridge/groups_test.go`:

```go
func TestSetGroupAnnounceUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sga.db")
	defer c.Close()
	err := c.SetGroupAnnounce("1234@g.us", true)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSetGroupAnnounceBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sga2.db")
	defer c.Close()
	err := c.SetGroupAnnounce("not a jid", true)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestSetGroupLockedUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sgl.db")
	defer c.Close()
	err := c.SetGroupLocked("1234@g.us", true)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSetGroupLockedBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sgl2.db")
	defer c.Close()
	err := c.SetGroupLocked("not a jid", true)
	if err == nil {
		t.Fatal("expected parse error")
	}
}
```

- [ ] **Step 2:** `cd bridge && go test -run "TestSetGroup(Announce|Locked)" -short` → FAIL.

- [ ] **Step 3:** Implement. Append to `bridge/groups.go` (place near `SetGroupJoinApprovalMode`):

```go
// SetGroupAnnounce toggles announcement-mode on a group. When on,
// only admins can send messages.
func (c *Client) SetGroupAnnounce(chatJIDStr string, on bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	if jid.User == "" || jid.Server == "" {
		return fmt.Errorf("parse jid: empty user or server")
	}
	if err := c.wa.SetGroupAnnounce(context.Background(), jid, on); err != nil {
		return fmt.Errorf("set group announce: %w", err)
	}
	return nil
}

// SetGroupLocked toggles edit-locked-mode on a group. When on,
// only admins can edit name / description / avatar.
func (c *Client) SetGroupLocked(chatJIDStr string, on bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	if jid.User == "" || jid.Server == "" {
		return fmt.Errorf("parse jid: empty user or server")
	}
	if err := c.wa.SetGroupLocked(context.Background(), jid, on); err != nil {
		return fmt.Errorf("set group locked: %w", err)
	}
	return nil
}
```

- [ ] **Step 4:** Run → PASS (4 new tests).

- [ ] **Step 5:** Commit:

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: SetGroupAnnounce + SetGroupLocked toggle wrappers"
```

---

### Task 2: `JGroup` carries `is_announce` + `is_locked` via `mapGroupInfo`

**Files:** `bridge/groups.go`, `bridge/groups_test.go`.

- [ ] **Step 1:** Failing test:

```go
func TestMapGroupInfoCarriesAnnounceLocked(t *testing.T) {
	in := &types.GroupInfo{
		JID:           types.NewJID("999", "g.us"),
		GroupName:     types.GroupName{Name: "T"},
		GroupAnnounce: types.GroupAnnounce{IsAnnounce: true},
		GroupLocked:   types.GroupLocked{IsLocked: true},
	}
	got := mapGroupInfo(in)
	if !got.IsAnnounce {
		t.Fatalf("want IsAnnounce true, got %+v", got)
	}
	if !got.IsLocked {
		t.Fatalf("want IsLocked true, got %+v", got)
	}
}
```

- [ ] **Step 2:** Run → FAIL (undefined fields).

- [ ] **Step 3:** Extend `JGroup`:

```go
type JGroup struct {
    // ... preserve every existing field ...
    IsAnnounce bool `json:"is_announce,omitempty"`
    IsLocked   bool `json:"is_locked,omitempty"`
}
```

Extend `mapGroupInfo` body (alongside existing field assignments):

```go
out.IsAnnounce = g.GroupAnnounce.IsAnnounce
out.IsLocked   = g.GroupLocked.IsLocked
```

- [ ] **Step 4:** Run → PASS.

- [ ] **Step 5:** Commit:

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: JGroup carries is_announce + is_locked; mapGroupInfo populates"
```

---

### Task 3: `GroupAnnounceChanged` + `GroupLockedChanged` dispatchers

**Files:** `bridge/events.go`, `bridge/jsonmodels.go`, `bridge/events_dispatch_test.go`.

- [ ] **Step 1:** Failing tests append to `bridge/events_dispatch_test.go`:

```go
func TestDispatchGroupInfoFiresGroupAnnounceChanged(t *testing.T) {
	c := newTestClient(t)
	captured := captureDispatch(c, func() {
		c.dispatchGroupInfo(&events.GroupInfo{
			JID:       types.NewJID("888", "g.us"),
			Announce:  &types.GroupAnnounce{IsAnnounce: true},
			Timestamp: time.Unix(1700000000, 0),
		})
	})
	ev := findEvent(captured, "GroupAnnounceChanged")
	if ev == nil {
		t.Fatal("no GroupAnnounceChanged")
	}
	if !strings.Contains(ev.payload, `"on":true`) {
		t.Errorf("payload missing on=true: %s", ev.payload)
	}
}

func TestDispatchGroupInfoFiresGroupLockedChanged(t *testing.T) {
	c := newTestClient(t)
	captured := captureDispatch(c, func() {
		c.dispatchGroupInfo(&events.GroupInfo{
			JID:       types.NewJID("888", "g.us"),
			Locked:    &types.GroupLocked{IsLocked: false},
			Timestamp: time.Unix(1700000000, 0),
		})
	})
	ev := findEvent(captured, "GroupLockedChanged")
	if ev == nil {
		t.Fatal("no GroupLockedChanged")
	}
	if !strings.Contains(ev.payload, `"on":false`) {
		t.Errorf("payload missing on=false: %s", ev.payload)
	}
}
```

Adapt `newTestClient`, `captureDispatch`, `findEvent` helper names per v0.7.1 / v0.8.0 harness.

- [ ] **Step 2:** Run → FAIL.

- [ ] **Step 3:** Add payload types to `bridge/jsonmodels.go`:

```go
type JGroupAnnounceChanged struct {
    ChatJID   string `json:"chat_jid"`
    On        bool   `json:"on"`
    ActorJID  string `json:"actor_jid,omitempty"`
    Timestamp int64  `json:"timestamp"`
}

type JGroupLockedChanged struct {
    ChatJID   string `json:"chat_jid"`
    On        bool   `json:"on"`
    ActorJID  string `json:"actor_jid,omitempty"`
    Timestamp int64  `json:"timestamp"`
}
```

In `bridge/events.go` `dispatchGroupInfo`, after existing arms (next to the v0.8.0 `EphemeralTimerChanged` block):

```go
if evt.Announce != nil {
    payload := JGroupAnnounceChanged{
        ChatJID:   evt.JID.String(),
        On:        evt.Announce.IsAnnounce,
        ActorJID:  actorJIDOf(evt.Sender),
        Timestamp: evt.Timestamp.Unix(),
    }
    b, _ := json.Marshal(payload)
    c.dispatch("GroupAnnounceChanged", string(b))
}
if evt.Locked != nil {
    payload := JGroupLockedChanged{
        ChatJID:   evt.JID.String(),
        On:        evt.Locked.IsLocked,
        ActorJID:  actorJIDOf(evt.Sender),
        Timestamp: evt.Timestamp.Unix(),
    }
    b, _ := json.Marshal(payload)
    c.dispatch("GroupLockedChanged", string(b))
}
```

`actorJIDOf` is the existing helper for nil-safe sender extraction (or inline `actor := ""; if evt.Sender != nil { actor = evt.Sender.String() }`).

- [ ] **Step 4:** Run → PASS.

- [ ] **Step 5:** Commit:

```bash
git add bridge/events.go bridge/jsonmodels.go bridge/events_dispatch_test.go
git commit -m "bridge: emit GroupAnnounceChanged + GroupLockedChanged on GroupInfo"
```

---

## Milestone B — Swift

### Task 4: Rebuild xcframework + WAClient wrappers + Event cases

**Files:** `yawac/Bridge/WAClient.swift`.

- [ ] **Step 1:** Rebuild xcframework:

```bash
./scripts/build-xcframework.sh
```

- [ ] **Step 2:** Add two new wrappers to `WAClient.swift` (near `setGroupJoinApprovalMode`):

```swift
nonisolated func setGroupAnnounce(chatJID: String, on: Bool) throws {
    try go.setGroupAnnounce(chatJID, on: on)
}

nonisolated func setGroupLocked(chatJID: String, on: Bool) throws {
    try go.setGroupLocked(chatJID, on: on)
}
```

Confirm exact selectors via `grep -nE "setGroupAnnounce|setGroupLocked" build/Bridge.xcframework/macos-arm64_x86_64/Bridge.framework/Versions/A/Headers/Bridge.objc.h`.

- [ ] **Step 3:** Add two Event cases:

```swift
case groupAnnounceChanged(chatJID: String, on: Bool,
                          actorJID: String, timestamp: Int64)
case groupLockedChanged(chatJID: String, on: Bool,
                        actorJID: String, timestamp: Int64)
```

- [ ] **Step 4:** Add decode arms (mirror `joinApprovalModeChanged`):

```swift
case "GroupAnnounceChanged":
    struct A: Codable {
        let chatJID: String
        let on: Bool
        let actorJID: String?
        let timestamp: Int64
        enum CodingKeys: String, CodingKey {
            case chatJID = "chat_jid"
            case on
            case actorJID = "actor_jid"
            case timestamp
        }
    }
    if let a = try? dec.decode(A.self, from: data) {
        return .groupAnnounceChanged(
            chatJID: a.chatJID, on: a.on,
            actorJID: a.actorJID ?? "",
            timestamp: a.timestamp)
    }

case "GroupLockedChanged":
    // identical shape, return .groupLockedChanged
```

- [ ] **Step 5:** xcodegen generate + build → BUILD SUCCEEDED.

- [ ] **Step 6:** Commit:

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "WAClient: setGroupAnnounce + setGroupLocked + Event cases"
```

---

### Task 5: `BridgeGroupModel` two new fields + `Chat` runtime fields

**Files:** `yawac/Bridge/JSONModels.swift`, `yawac/Models/Chat.swift`.

- [ ] **Step 1:** In `BridgeGroupModel`, add (with matching CodingKeys + decoder + convenience init):

```swift
let isAnnounce: Bool   // wire key "is_announce"
let isLocked: Bool     // wire key "is_locked"
```

Use `decodeIfPresent(Bool.self, forKey: ...) ?? false` in the manual decoder; defaults to `false` in convenience init.

- [ ] **Step 2:** In `Chat.swift`:

```swift
var isAnnounce: Bool = false
var isLocked: Bool = false
```

- [ ] **Step 3:** Build → BUILD SUCCEEDED.

- [ ] **Step 4:** Commit:

```bash
git add yawac/Bridge/JSONModels.swift yawac/Models/Chat.swift
git commit -m "models: BridgeGroupModel + Chat carry isAnnounce + isLocked"
```

---

### Task 6: `ChatListViewModel.applyGroupAnnounce` + `applyGroupLocked` + `mergeGroups` hydration + tests

**Files:** `yawac/ViewModels/ChatListViewModel.swift`, `yawacTests/ChatListViewModelGroupAnnounceLockedTests.swift` (new).

- [ ] **Step 1:** Write failing tests:

```swift
import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelGroupAnnounceLockedTests: XCTestCase {

    func testApplyGroupAnnounceUpdatesChat() {
        let vm = ChatListViewModel(client: nil, context: nil)
        vm.chats = [Chat(jid: "g@g.us", name: "g", isGroup: true)]
        vm.applyGroupAnnounce(chatJID: "g@g.us", on: true)
        XCTAssertTrue(vm.chats.first?.isAnnounce ?? false)
        vm.applyGroupAnnounce(chatJID: "g@g.us", on: false)
        XCTAssertFalse(vm.chats.first?.isAnnounce ?? true)
    }

    func testApplyGroupLockedUpdatesChat() {
        let vm = ChatListViewModel(client: nil, context: nil)
        vm.chats = [Chat(jid: "g@g.us", name: "g", isGroup: true)]
        vm.applyGroupLocked(chatJID: "g@g.us", on: true)
        XCTAssertTrue(vm.chats.first?.isLocked ?? false)
    }

    func testApplyOnUnknownChatNoOp() {
        let vm = ChatListViewModel(client: nil, context: nil)
        vm.applyGroupAnnounce(chatJID: "unknown@g.us", on: true)
        XCTAssertTrue(vm.chats.isEmpty)
    }
}
```

Adapt `Chat` initializer to whatever the model exposes; if there's a `.stub(jid:)` factory elsewhere, use it.

- [ ] **Step 2:** Run → FAIL.

- [ ] **Step 3:** Implement helpers (mirror `applyIncomingJoinApprovalMode`):

```swift
func applyGroupAnnounce(chatJID: String, on: Bool) {
    let key = JIDNormalize.canonical(chatJID, client: client)
    if let idx = chats.firstIndex(where: { $0.jid == key }) {
        chats[idx].isAnnounce = on
    }
}

func applyGroupLocked(chatJID: String, on: Bool) {
    let key = JIDNormalize.canonical(chatJID, client: client)
    if let idx = chats.firstIndex(where: { $0.jid == key }) {
        chats[idx].isLocked = on
    }
}
```

In `mergeGroups`, on the per-group field-copy path (both the existing-chat update branch AND the fresh-insert branch), add:

```swift
chat.isAnnounce = g.isAnnounce
chat.isLocked   = g.isLocked
```

- [ ] **Step 4:** Run → PASS.

- [ ] **Step 5:** Commit:

```bash
git add yawac/ViewModels/ChatListViewModel.swift yawacTests/ChatListViewModelGroupAnnounceLockedTests.swift
git commit -m "ChatListViewModel: applyGroupAnnounce + applyGroupLocked + mergeGroups hydration"
```

---

### Task 7: `ContentView` event routing

**File:** `yawac/ContentView.swift`.

- [ ] **Step 1:** Locate existing `.joinApprovalModeChanged` arm:

```bash
grep -nE "case \.joinApprovalModeChanged" yawac/ContentView.swift
```

- [ ] **Step 2:** Add two new arms next to it:

```swift
case .groupAnnounceChanged(let chatJID, let on, _, _):
    vm.applyGroupAnnounce(chatJID: chatJID, on: on)

case .groupLockedChanged(let chatJID, let on, _, _):
    vm.applyGroupLocked(chatJID: chatJID, on: on)
```

- [ ] **Step 3:** Build → BUILD SUCCEEDED.

- [ ] **Step 4:** Commit:

```bash
git add yawac/ContentView.swift
git commit -m "ContentView: route GroupAnnounceChanged + GroupLockedChanged"
```

---

## Milestone C — UI

### Task 8: ChatInfoView two toggle rows + helpers

**File:** `yawac/Views/ChatInfoView.swift`.

- [ ] **Step 1:** Locate the existing JOIN APPROVAL section (~line 837 per recon).

- [ ] **Step 2:** Add two `@State` vars near other errors:

```swift
@State private var announceError: String?
@State private var lockedError: String?
```

- [ ] **Step 3:** Add two sectionCards between JOIN APPROVAL and the next section (admin + group gate):

```swift
if isCurrentUserAdmin(g) && !g.isParent {
    sectionCard(label: "ADMINS ONLY — SEND MESSAGES") {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Restrict messages to admins")
                    .scaledUI(13).foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { (group?.isAnnounce ?? g.isAnnounce) },
                    set: { newValue in
                        applyAnnounceToggle(newValue, chatJID: g.jid)
                    }
                )).labelsHidden()
            }
            if let err = announceError {
                Text(err).foregroundStyle(.red).scaledUI(11)
                    .task(id: err) {
                        try? await Task.sleep(nanoseconds: 6 * 1_000_000_000)
                        announceError = nil
                    }
            }
        }
    }
    sectionCard(label: "ADMINS ONLY — EDIT GROUP INFO") {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Lock name / description / avatar to admins")
                    .scaledUI(13).foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { (group?.isLocked ?? g.isLocked) },
                    set: { newValue in
                        applyLockedToggle(newValue, chatJID: g.jid)
                    }
                )).labelsHidden()
            }
            if let err = lockedError {
                Text(err).foregroundStyle(.red).scaledUI(11)
                    .task(id: err) {
                        try? await Task.sleep(nanoseconds: 6 * 1_000_000_000)
                        lockedError = nil
                    }
            }
        }
    }
}
```

- [ ] **Step 4:** Add private helpers (mirror v0.7.1 T26 `applyDisappearingTimer`):

```swift
private func applyAnnounceToggle(_ on: Bool, chatJID: String) {
    guard let client = session.client else { return }
    let prior = group?.isAnnounce ?? false
    if var s = group {
        s.isAnnounce = on
        group = s
    }
    Task {
        do {
            try await Task.detached {
                try client.setGroupAnnounce(chatJID: chatJID, on: on)
            }.value
        } catch {
            if var s = group {
                s.isAnnounce = prior
                group = s
            }
            announceError = (error as NSError).localizedDescription
        }
    }
}

private func applyLockedToggle(_ on: Bool, chatJID: String) {
    // identical shape with isLocked / setGroupLocked / lockedError
}
```

- [ ] **Step 5:** `BridgeGroupModel.isAnnounce` and `isLocked` may be `let` per Task 5. To support optimistic flip via the `@State group` shadow, flip them to `var` in `JSONModels.swift` (same surgical pattern as v0.7.1 T25 `joinApprovalMode` flip).

- [ ] **Step 6:** Build → BUILD SUCCEEDED.

- [ ] **Step 7:** Commit:

```bash
git add yawac/Views/ChatInfoView.swift yawac/Bridge/JSONModels.swift
git commit -m "ChatInfoView: Admins-only send + edit-info toggle rows"
```

---

### Task 9: ComposerView announce-mode gate

**File:** `yawac/Views/ComposerView.swift`.

- [ ] **Step 1:** Locate the composer body root:

```bash
grep -nE "var body: some View|attachmentStrip|inputRow|TextField" yawac/Views/ComposerView.swift | head -10
```

- [ ] **Step 2:** At the top of `body` (or wherever the main HStack/VStack starts), gate on announce-mode:

```swift
var body: some View {
    if let chat = currentChat, chat.isAnnounce, !chat.amAdmin {
        announceLockedNotice
    } else {
        // ... existing composer body ...
    }
}

private var announceLockedNotice: some View {
    HStack(spacing: 8) {
        Image(systemName: "megaphone.fill")
            .scaledIcon(14).foregroundStyle(Theme.textMuted)
        Text("Only admins can send messages in this group.")
            .italic().scaledUI(12).foregroundStyle(Theme.textMuted)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12).padding(.horizontal, 16)
    .background(Theme.surface)
}

private var currentChat: Chat? {
    session.chatList?.chats.first(where: { $0.jid == vm.chatJID })
}
```

> **Adapt** existing chat-lookup helper if one already exists; reuse rather than create.

- [ ] **Step 3:** Build → BUILD SUCCEEDED.

- [ ] **Step 4:** Commit:

```bash
git add yawac/Views/ComposerView.swift
git commit -m "ComposerView: hide composer for non-admin in announce-mode groups"
```

---

## Milestone D — Release polish

### Task 10: Bump version + ROADMAP

**Files:** `project.yml`, `yawac/Info.plist`, `docs/ROADMAP.md`.

- [ ] **Step 1:** Bump `project.yml`:

```yaml
CFBundleShortVersionString: "0.8.2"
CFBundleVersion: "11"
```

- [ ] **Step 2:** `xcodegen generate` + verify `yawac/Info.plist`.

- [ ] **Step 3:** ROADMAP strike (under Groups → Group management → Gaps):
- Remove "Admins only message-send toggle" line.
- Remove "Admins only edit-info toggle" line.

Add a "v0.8.2 fix:" note pointing to the new toggles.

- [ ] **Step 4:** Full test pass:

```bash
cd bridge && go test -short ./... 2>&1 | tail -3
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|FAILED" | tail -3
```

Both green.

- [ ] **Step 5:** Commit:

```bash
git add project.yml yawac/Info.plist docs/ROADMAP.md
git commit -m "release: 0.8.2 — group admin polish (announce + locked toggles)"
```

---

## Manual smoke

- [ ] In a group I admin: ChatInfoView → "Admins only — send messages" toggle on. Second account in the group: composer flips to "Only admins can send messages" notice. Toggle off → composer returns.
- [ ] "Admins only — edit group info" → second account's edit affordances stay admin-gated (yawac's strict policy). Phone reflects toggle change.
- [ ] Flip both toggles from phone → yawac rows reflect within ~1s.
