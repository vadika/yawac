# Community Admin (v0.7.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire up community + group creation (sidebar "+" menu and community parent's "Create new sub-group" action), community admin actions (link/unlink sub-groups, approve/reject join requests, toggle membership-approval mode), and a sidebar pending-request chip — shipping as v0.7.0. Spec: `docs/superpowers/specs/2026-06-02-community-admin-design.md`.

**Architecture:** Seven new gomobile bridge funcs in `bridge/groups.go` + one extended event dispatcher in `bridge/events.go`. Swift side gets `WAClient` wrappers, six new SwiftUI views (three Create sheets, LinkSubGroupSheet, PendingRequestsSection, sidebar chip), a `JoinRequestStore` actor for pending counts, and ChatInfoView / ChatListView wire-up.

**Tech Stack:** Go (whatsmeow `go.mau.fi/whatsmeow`), Swift / SwiftUI / `@Observable`, SwiftData (existing), XCTest, `go test`.

**Test commands:**

```bash
# Go side
cd bridge && go test -short ./...

# Swift side
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

When a task changes only Go code, run only the Go test command. When a task touches Swift code, run both (Go to confirm no cross-impact + Swift to validate the change).

---

## Milestone A — Bridge (Go)

### Task 1: `CreateCommunity` bridge func

**Files:**
- Modify: `bridge/groups.go` (append after existing `CreateGroup`)
- Test: `bridge/groups_test.go` (append)

- [ ] **Step 1: Write the failing test**

Append to `bridge/groups_test.go`:

```go
func TestCreateCommunityUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/cc.db")
	defer c.Close()
	_, err := c.CreateCommunity("Outdoor Club")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestCreateCommunityClosed(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/cc2.db")
	c.Close()
	_, err := c.CreateCommunity("Outdoor Club")
	if err == nil {
		t.Fatal("expected error on closed client")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run TestCreateCommunity -short
```

Expected: FAIL with `undefined: Client.CreateCommunity` (or compile error).

- [ ] **Step 3: Implement `CreateCommunity`**

Append to `bridge/groups.go` (place after `CreateGroup`):

```go
// CreateCommunity creates a new community parent group. The server
// auto-creates the default announcements sub-group, whose JID arrives
// via a JoinedGroup event shortly after. Returns the parent's JID.
// Surfaces the 25-char-name 406 from the server verbatim.
func (c *Client) CreateCommunity(name string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	info, err := c.wa.CreateGroup(context.Background(),
		whatsmeow.ReqCreateGroup{
			Name:        name,
			GroupParent: types.GroupParent{IsParent: true},
		})
	if err != nil {
		return "", fmt.Errorf("create community: %w", err)
	}
	return info.JID.String(), nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd bridge && go test -run TestCreateCommunity -short
```

Expected: PASS (both subtests error as expected on closed/unpaired client).

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: CreateCommunity for community-parent creation"
```

---

### Task 2: `CreateSubGroup` bridge func

**Files:**
- Modify: `bridge/groups.go`
- Test: `bridge/groups_test.go`

- [ ] **Step 1: Write the failing test**

Append to `bridge/groups_test.go`:

```go
func TestCreateSubGroupUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/csg.db")
	defer c.Close()
	_, err := c.CreateSubGroup(
		"1234@g.us", "Hiking", `["1111@s.whatsapp.net"]`)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestCreateSubGroupBadParentJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/csg2.db")
	defer c.Close()
	_, err := c.CreateSubGroup("not a jid", "Hiking", `[]`)
	if err == nil {
		t.Fatal("expected parse error on bad parent JID")
	}
}

func TestCreateSubGroupBadParticipantJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/csg3.db")
	defer c.Close()
	_, err := c.CreateSubGroup("1234@g.us", "Hiking", "not json")
	if err == nil {
		t.Fatal("expected parse error on bad participant JSON")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run TestCreateSubGroup -short
```

Expected: FAIL with `undefined: Client.CreateSubGroup`.

- [ ] **Step 3: Implement `CreateSubGroup`**

Append to `bridge/groups.go`:

```go
// CreateSubGroup creates a new group inside the community parent
// identified by parentJIDStr. participantJIDsJSON is a JSON []string
// (may be "[]"). Caller must be admin of the parent (server enforces).
// Returns the new sub-group's JID string.
func (c *Client) CreateSubGroup(
	parentJIDStr, name, participantJIDsJSON string,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	parent, err := types.ParseJID(parentJIDStr)
	if err != nil {
		return "", fmt.Errorf("parse parent: %w", err)
	}
	var jids []string
	if err := json.Unmarshal([]byte(participantJIDsJSON), &jids); err != nil {
		return "", fmt.Errorf("parse participants: %w", err)
	}
	parsed := make([]types.JID, 0, len(jids))
	for _, s := range jids {
		j, err := types.ParseJID(s)
		if err != nil {
			return "", fmt.Errorf("parse %q: %w", s, err)
		}
		parsed = append(parsed, j)
	}
	info, err := c.wa.CreateGroup(context.Background(),
		whatsmeow.ReqCreateGroup{
			Name:              name,
			Participants:      parsed,
			GroupLinkedParent: types.GroupLinkedParent{LinkedParentJID: parent},
		})
	if err != nil {
		return "", fmt.Errorf("create sub-group: %w", err)
	}
	return info.JID.String(), nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd bridge && go test -run TestCreateSubGroup -short
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: CreateSubGroup for community-scoped group creation"
```

---

### Task 3: `LinkSubGroup` bridge func

**Files:**
- Modify: `bridge/groups.go`
- Test: `bridge/groups_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestLinkSubGroupUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ls.db")
	defer c.Close()
	err := c.LinkSubGroup("1111@g.us", "2222@g.us")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestLinkSubGroupBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ls2.db")
	defer c.Close()
	err := c.LinkSubGroup("not a jid", "2222@g.us")
	if err == nil {
		t.Fatal("expected parse error on bad parent JID")
	}
	err = c.LinkSubGroup("1111@g.us", "not a jid")
	if err == nil {
		t.Fatal("expected parse error on bad sub JID")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run TestLinkSubGroup -short
```

Expected: FAIL.

- [ ] **Step 3: Implement `LinkSubGroup`**

```go
// LinkSubGroup attaches a child group to a community parent. Both JIDs
// must be admin-controlled. Surfaces whatsmeow errors verbatim.
func (c *Client) LinkSubGroup(parentJIDStr, subJIDStr string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	parent, err := types.ParseJID(parentJIDStr)
	if err != nil {
		return fmt.Errorf("parse parent: %w", err)
	}
	sub, err := types.ParseJID(subJIDStr)
	if err != nil {
		return fmt.Errorf("parse sub: %w", err)
	}
	if err := c.wa.LinkGroup(context.Background(), parent, sub); err != nil {
		return fmt.Errorf("link group: %w", err)
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd bridge && go test -run TestLinkSubGroup -short
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: LinkSubGroup wrapper for community link admin op"
```

---

### Task 4: `UnlinkSubGroup` bridge func

**Files:**
- Modify: `bridge/groups.go`
- Test: `bridge/groups_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestUnlinkSubGroupUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/us.db")
	defer c.Close()
	err := c.UnlinkSubGroup("1111@g.us", "2222@g.us")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestUnlinkSubGroupBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/us2.db")
	defer c.Close()
	err := c.UnlinkSubGroup("not a jid", "2222@g.us")
	if err == nil {
		t.Fatal("expected parse error on bad parent JID")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run TestUnlinkSubGroup -short
```

Expected: FAIL.

- [ ] **Step 3: Implement `UnlinkSubGroup`**

```go
// UnlinkSubGroup detaches a child from its parent community.
// Swift gates against isDefaultSubGroup; server accepts the IQ
// even on the default sub-group but it breaks the community.
func (c *Client) UnlinkSubGroup(parentJIDStr, subJIDStr string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	parent, err := types.ParseJID(parentJIDStr)
	if err != nil {
		return fmt.Errorf("parse parent: %w", err)
	}
	sub, err := types.ParseJID(subJIDStr)
	if err != nil {
		return fmt.Errorf("parse sub: %w", err)
	}
	if err := c.wa.UnlinkGroup(context.Background(), parent, sub); err != nil {
		return fmt.Errorf("unlink group: %w", err)
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd bridge && go test -run TestUnlinkSubGroup -short
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: UnlinkSubGroup wrapper for community unlink admin op"
```

---

### Task 5: `GetGroupJoinRequests` bridge func

**Files:**
- Modify: `bridge/groups.go`
- Test: `bridge/groups_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestGetGroupJoinRequestsUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gjr.db")
	defer c.Close()
	_, err := c.GetGroupJoinRequests("1234@g.us")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestGetGroupJoinRequestsBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gjr2.db")
	defer c.Close()
	_, err := c.GetGroupJoinRequests("not a jid")
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestJJoinRequestJSONShape(t *testing.T) {
	// Marshal round-trip: ensure the JSON keys match the spec exactly.
	in := JJoinRequest{JID: "1111@s.whatsapp.net", RequestedAt: 1234567890}
	b, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	got := string(b)
	want := `{"jid":"1111@s.whatsapp.net","requested_at":1234567890}`
	if got != want {
		t.Fatalf("JSON mismatch:\ngot:  %s\nwant: %s", got, want)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run "TestGetGroupJoinRequests|TestJJoinRequestJSONShape" -short
```

Expected: FAIL.

- [ ] **Step 3: Implement type + function**

```go
// JJoinRequest is one pending membership-approval request row.
type JJoinRequest struct {
	JID         string `json:"jid"`
	RequestedAt int64  `json:"requested_at"` // unix seconds
}

// GetGroupJoinRequests returns JSON []JJoinRequest for `chatJIDStr`.
// Returns "[]" when the queue is empty or approval-mode is off
// (the two are indistinguishable at this layer; callers consult
// BridgeGroupModel.joinApprovalMode for the mode flag).
func (c *Client) GetGroupJoinRequests(chatJIDStr string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	parts, err := c.wa.GetGroupRequestParticipants(context.Background(), jid)
	if err != nil {
		return "", fmt.Errorf("get join requests: %w", err)
	}
	out := make([]JJoinRequest, 0, len(parts))
	for _, p := range parts {
		out = append(out, JJoinRequest{
			JID:         p.JID.String(),
			RequestedAt: p.RequestedAt.Unix(),
		})
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}
```

> **Note for engineer:** check the actual field name on
> `whatsmeow.types.GroupParticipantRequest` (or whatever
> `GetGroupRequestParticipants` returns) for the timestamp — the
> spec assumed `RequestedAt`. If the upstream field is named
> differently (e.g. `Timestamp`), adjust the assignment to
> `RequestedAt: p.Timestamp.Unix()`. Same for `JID`. Use `grep -n
> "type.*GroupParticipantRequest\|GetGroupRequestParticipants" $(go
> env GOMODCACHE)/github.com/vadika/whatsmeow@*/group.go` to
> confirm.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd bridge && go test -run "TestGetGroupJoinRequests|TestJJoinRequestJSONShape" -short
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: GetGroupJoinRequests for pending-request queue"
```

---

### Task 6: `UpdateGroupJoinRequests` bridge func + action mapping

**Files:**
- Modify: `bridge/groups.go`
- Test: `bridge/groups_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestJoinRequestChangeFromString(t *testing.T) {
	cases := []struct {
		in   string
		want whatsmeow.ParticipantRequestChange
		ok   bool
	}{
		{"approve", whatsmeow.ParticipantChangeApprove, true},
		{"reject", whatsmeow.ParticipantChangeReject, true},
		{"banish", "", false},
		{"", "", false},
	}
	for _, c := range cases {
		got, err := joinRequestChangeFromString(c.in)
		if c.ok && (err != nil || got != c.want) {
			t.Fatalf("%q: got (%q,%v) want (%q,nil)", c.in, got, err, c.want)
		}
		if !c.ok && err == nil {
			t.Fatalf("%q: expected error, got nil", c.in)
		}
	}
}

func TestUpdateGroupJoinRequestsUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ujr.db")
	defer c.Close()
	_, err := c.UpdateGroupJoinRequests(
		"1234@g.us", "approve",
		`["1111@s.whatsapp.net"]`)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestUpdateGroupJoinRequestsInvalidAction(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ujr2.db")
	defer c.Close()
	_, err := c.UpdateGroupJoinRequests(
		"1234@g.us", "banish",
		`["1111@s.whatsapp.net"]`)
	if err == nil {
		t.Fatal("expected error for invalid action")
	}
}

func TestJJoinRequestResultJSONShape(t *testing.T) {
	in := JJoinRequestResult{JID: "1@s.whatsapp.net", ErrorCode: 403}
	b, _ := json.Marshal(in)
	want := `{"jid":"1@s.whatsapp.net","error_code":403}`
	if string(b) != want {
		t.Fatalf("got %s want %s", b, want)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run "TestJoinRequest|TestUpdateGroupJoinRequests" -short
```

Expected: FAIL.

- [ ] **Step 3: Implement helper + function**

```go
// JJoinRequestResult is one row of the UpdateGroupJoinRequests response.
type JJoinRequestResult struct {
	JID       string `json:"jid"`
	ErrorCode int    `json:"error_code,omitempty"`
}

func joinRequestChangeFromString(s string) (whatsmeow.ParticipantRequestChange, error) {
	switch s {
	case "approve":
		return whatsmeow.ParticipantChangeApprove, nil
	case "reject":
		return whatsmeow.ParticipantChangeReject, nil
	}
	return "", fmt.Errorf("invalid action %q (want approve|reject)", s)
}

// UpdateGroupJoinRequests applies "approve" or "reject" to a JSON
// []string batch. Returns JSON []JJoinRequestResult. Per-row failures
// populate ErrorCode; outer error is reserved for fatal cases
// (network / unauthorized / group missing).
func (c *Client) UpdateGroupJoinRequests(
	chatJIDStr, action, participantJIDsJSON string,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	change, err := joinRequestChangeFromString(action)
	if err != nil {
		return "", err
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	var jids []string
	if err := json.Unmarshal([]byte(participantJIDsJSON), &jids); err != nil {
		return "", fmt.Errorf("parse participants: %w", err)
	}
	parsed := make([]types.JID, 0, len(jids))
	for _, s := range jids {
		j, err := types.ParseJID(s)
		if err != nil {
			return "", fmt.Errorf("parse %q: %w", s, err)
		}
		parsed = append(parsed, j)
	}
	results, err := c.wa.UpdateGroupRequestParticipants(
		context.Background(), jid, parsed, change)
	if err != nil {
		return "", fmt.Errorf("update join requests: %w", err)
	}
	out := make([]JJoinRequestResult, 0, len(results))
	for _, r := range results {
		row := JJoinRequestResult{JID: r.JID.String()}
		// whatsmeow surfaces per-row failures via an Error field on the
		// response struct; engineer should confirm exact field name and
		// map to ErrorCode int (use response code if present, else 1).
		row.ErrorCode = participantRequestErrorCode(r)
		out = append(out, row)
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// participantRequestErrorCode extracts a numeric error code from a
// whatsmeow GroupParticipantRequestChangeResult (or whatever the
// upstream type is named). Returns 0 when the row applied cleanly.
//
// Engineer: confirm upstream type name + field shape. If the upstream
// surfaces only a string reason, hash to a stable nonzero int (e.g.
// 1 for any failure) — the Swift layer treats nonzero as "didn't apply".
func participantRequestErrorCode(r whatsmeow.GroupParticipantRequestChangeResult) int {
	if r.Error == "" {
		return 0
	}
	return 1
}
```

> **Note for engineer:** the `GroupParticipantRequestChangeResult`
> type and its `Error` field are spec-assumed. If whatsmeow's actual
> response shape differs, adjust the struct reference + the
> `participantRequestErrorCode` body. Run
> `grep -n "type GroupParticipantRequest\|UpdateGroupRequestParticipants" $(go env GOMODCACHE)/github.com/vadika/whatsmeow@*/group.go`
> to verify, then update both the function body and the test's mapping
> case if needed.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd bridge && go test -run "TestJoinRequest|TestUpdateGroupJoinRequests" -short
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: UpdateGroupJoinRequests with approve/reject action mapping"
```

---

### Task 7: `SetGroupJoinApprovalMode` bridge func

**Files:**
- Modify: `bridge/groups.go`
- Test: `bridge/groups_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestSetGroupJoinApprovalModeUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sm.db")
	defer c.Close()
	err := c.SetGroupJoinApprovalMode("1234@g.us", true)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSetGroupJoinApprovalModeBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sm2.db")
	defer c.Close()
	err := c.SetGroupJoinApprovalMode("not a jid", true)
	if err == nil {
		t.Fatal("expected parse error")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd bridge && go test -run TestSetGroupJoinApprovalMode -short
```

Expected: FAIL.

- [ ] **Step 3: Implement**

```go
// SetGroupJoinApprovalMode flips the require-admin-approval gate
// on a group on or off. Admin only.
func (c *Client) SetGroupJoinApprovalMode(chatJIDStr string, on bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	if err := c.wa.SetGroupJoinApprovalMode(
		context.Background(), jid, on); err != nil {
		return fmt.Errorf("set approval mode: %w", err)
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd bridge && go test -run TestSetGroupJoinApprovalMode -short
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: SetGroupJoinApprovalMode toggle"
```

---

### Task 8: Extend `dispatchGroupInfo` payload + `JoinApprovalModeChanged` event

**Files:**
- Modify: `bridge/events.go` (extend `dispatchGroupInfo` payload struct + add new event dispatcher)
- Test: `bridge/events_dispatch_test.go`

- [ ] **Step 1: Locate the existing dispatcher**

```bash
grep -n "dispatchGroupInfo\|GroupInfoChanged\|MembershipApprovalMode" bridge/events.go
```

Confirm the existing `JGroupInfoChanged` struct and switch arm for `*events.GroupInfo`.

- [ ] **Step 2: Write the failing tests**

Append to `bridge/events_dispatch_test.go`:

```go
func TestDispatchGroupInfoCarriesLinkedParentAndDefaultSub(t *testing.T) {
	c := newTestClient(t)
	got := captureDispatch(c, func() {
		parent, _ := types.ParseJID("1111@g.us")
		c.dispatchGroupInfo(&events.GroupInfo{
			JID:               types.NewJID("2222", "g.us"),
			Name:              &types.GroupName{Name: "Sub"},
			LinkedParentJID:   parent,
			IsDefaultSubGroup: true,
			Timestamp:         time.Unix(1700000000, 0),
		})
	})
	want := findEvent(got, "GroupInfoChanged")
	if want == nil {
		t.Fatal("no GroupInfoChanged event")
	}
	if !strings.Contains(want.payload, `"linked_parent_jid":"1111@g.us"`) {
		t.Errorf("missing linked_parent_jid: %s", want.payload)
	}
	if !strings.Contains(want.payload, `"is_default_subgroup":true`) {
		t.Errorf("missing is_default_subgroup: %s", want.payload)
	}
}

func TestDispatchGroupInfoFiresApprovalModeChanged(t *testing.T) {
	c := newTestClient(t)
	cases := []struct {
		mode    string
		wantOn  bool
	}{
		{"request_required", true},
		{"", false},
	}
	for _, tc := range cases {
		got := captureDispatch(c, func() {
			c.dispatchGroupInfo(&events.GroupInfo{
				JID: types.NewJID("3333", "g.us"),
				MembershipApprovalMode: &types.GroupMembershipApprovalMode{
					DefaultMembershipApprovalMode: tc.mode,
				},
				Timestamp: time.Unix(1700000001, 0),
			})
		})
		ev := findEvent(got, "JoinApprovalModeChanged")
		if ev == nil {
			t.Fatalf("mode=%q: no JoinApprovalModeChanged", tc.mode)
		}
		wantOnJSON := `"on":` + boolJSON(tc.wantOn)
		if !strings.Contains(ev.payload, wantOnJSON) {
			t.Errorf("mode=%q: payload=%s want contains %s",
				tc.mode, ev.payload, wantOnJSON)
		}
	}
}

func TestDispatchGroupInfoFiresBothNameAndApprovalMode(t *testing.T) {
	c := newTestClient(t)
	got := captureDispatch(c, func() {
		c.dispatchGroupInfo(&events.GroupInfo{
			JID:  types.NewJID("4444", "g.us"),
			Name: &types.GroupName{Name: "Renamed"},
			MembershipApprovalMode: &types.GroupMembershipApprovalMode{
				DefaultMembershipApprovalMode: "request_required",
			},
			Timestamp: time.Unix(1700000002, 0),
		})
	})
	if findEvent(got, "GroupInfoChanged") == nil {
		t.Error("missing GroupInfoChanged")
	}
	if findEvent(got, "JoinApprovalModeChanged") == nil {
		t.Error("missing JoinApprovalModeChanged")
	}
}

func boolJSON(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
```

> **Note for engineer:** `newTestClient`, `captureDispatch`,
> `findEvent` are spec-assumed helpers — the existing
> `events_dispatch_test.go` should already have similar harness code
> from prior `GroupParticipantsChanged` tests. Reuse those helpers; if
> the names differ in the existing file, adapt the test code to
> match. Confirm with
> `grep -n "captureDispatch\|findEvent\|newTestClient" bridge/events_dispatch_test.go`.

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd bridge && go test -run "TestDispatchGroupInfoCarriesLinkedParent|TestDispatchGroupInfoFiresApprovalModeChanged|TestDispatchGroupInfoFiresBothNameAndApprovalMode" -short
```

Expected: FAIL (payload missing new keys; `JoinApprovalModeChanged` event not emitted).

- [ ] **Step 4: Extend `JGroupInfoChanged` payload + add `JJoinApprovalModeChanged`**

In `bridge/events.go`, extend the existing payload struct:

```go
type JGroupInfoChanged struct {
	ChatJID           string `json:"chat_jid"`
	Name              string `json:"name,omitempty"`
	Topic             string `json:"topic,omitempty"`
	LinkedParentJID   string `json:"linked_parent_jid,omitempty"`
	IsDefaultSubGroup bool   `json:"is_default_subgroup,omitempty"`
	ActorJID          string `json:"actor_jid,omitempty"`
	Timestamp         int64  `json:"timestamp"`
}

type JJoinApprovalModeChanged struct {
	ChatJID   string `json:"chat_jid"`
	On        bool   `json:"on"`
	ActorJID  string `json:"actor_jid,omitempty"`
	Timestamp int64  `json:"timestamp"`
}
```

> **Note:** keep any existing fields on `JGroupInfoChanged` that are
> not listed above — this struct may already carry additional fields
> from earlier work (e.g. `OwnerJID`, `Created`). Append the new
> fields rather than replacing the struct.

Extend `dispatchGroupInfo` (preserve the existing name + topic
serialization):

```go
func (c *Client) dispatchGroupInfo(evt *events.GroupInfo) {
	// ... existing name/topic serialization preserved ...

	actor := ""
	if evt.Sender != nil {
		actor = evt.Sender.String()
	}

	payload := JGroupInfoChanged{
		ChatJID:           evt.JID.String(),
		LinkedParentJID:   nonEmptyJID(evt.LinkedParentJID),
		IsDefaultSubGroup: evt.IsDefaultSubGroup,
		ActorJID:          actor,
		Timestamp:         evt.Timestamp.Unix(),
	}
	if evt.Name != nil {
		payload.Name = evt.Name.Name
	}
	if evt.Topic != nil {
		payload.Topic = evt.Topic.Topic
	}
	b, _ := json.Marshal(payload)
	c.dispatch("GroupInfoChanged", string(b))

	if evt.MembershipApprovalMode != nil {
		on := evt.MembershipApprovalMode.DefaultMembershipApprovalMode ==
			"request_required"
		mode := JJoinApprovalModeChanged{
			ChatJID:   evt.JID.String(),
			On:        on,
			ActorJID:  actor,
			Timestamp: evt.Timestamp.Unix(),
		}
		mb, _ := json.Marshal(mode)
		c.dispatch("JoinApprovalModeChanged", string(mb))
	}
}

func nonEmptyJID(j types.JID) string {
	if j.IsEmpty() {
		return ""
	}
	return j.String()
}
```

> **Note for engineer:** the existing `dispatchGroupInfo` likely has
> more logic (e.g. `dispatchGroupParticipants` calls). Merge the new
> fields into the existing function without removing prior calls.
> Use `git diff` after editing to verify nothing was deleted by
> accident.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd bridge && go test -run "TestDispatchGroupInfo" -short
```

Expected: PASS.

- [ ] **Step 6: Run the full Go test suite to check no regression**

```bash
cd bridge && go test -short ./...
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add bridge/events.go bridge/events_dispatch_test.go
git commit -m "bridge: GroupInfo carries linked parent + default-sub flag; emit JoinApprovalModeChanged"
```

---

### Task 9: Map `joinApprovalMode` in `GetGroupInfo` + `ListGroups`

**Files:**
- Modify: `bridge/groups.go` (the `JGroup` mapper used by `ListGroups` and `GetGroupInfo`)
- Test: `bridge/groups_test.go`

- [ ] **Step 1: Locate the mapper**

```bash
grep -n "JGroup{" bridge/groups.go
```

Identify every spot that constructs a `JGroup` from a `whatsmeow.types.GroupInfo`.

- [ ] **Step 2: Write the failing test**

```go
func TestJGroupCarriesJoinApprovalMode(t *testing.T) {
	in := &types.GroupInfo{
		JID: types.NewJID("5555", "g.us"),
		GroupName: types.GroupName{Name: "Test"},
		GroupMembershipApprovalMode: types.GroupMembershipApprovalMode{
			DefaultMembershipApprovalMode: "request_required",
		},
	}
	got := mapGroupInfo(in)
	if !got.JoinApprovalMode {
		t.Fatalf("expected JoinApprovalMode true, got %+v", got)
	}
	in.DefaultMembershipApprovalMode = ""
	got = mapGroupInfo(in)
	if got.JoinApprovalMode {
		t.Fatalf("expected JoinApprovalMode false, got %+v", got)
	}
}
```

- [ ] **Step 3: Run to verify failure**

```bash
cd bridge && go test -run TestJGroupCarriesJoinApprovalMode -short
```

Expected: FAIL (either undefined `JoinApprovalMode` field or missing `mapGroupInfo` helper).

- [ ] **Step 4: Add the field + extract a `mapGroupInfo` helper**

Extend `JGroup`:

```go
type JGroup struct {
	JID               string         `json:"jid"`
	Name              string         `json:"name"`
	Topic             string         `json:"topic"`
	OwnerJID          string         `json:"owner_jid"`
	Created           int64          `json:"created"`
	IsParent          bool           `json:"is_parent,omitempty"`
	LinkedParentJID   string         `json:"linked_parent_jid,omitempty"`
	IsDefaultSubGroup bool           `json:"is_default_sub_group,omitempty"`
	JoinApprovalMode  bool           `json:"join_approval_mode,omitempty"`
	Participants      []JParticipant `json:"participants"`
}
```

Refactor existing `ListGroups` + `GetGroupInfo` to use a shared
`mapGroupInfo` helper:

```go
func mapGroupInfo(g *types.GroupInfo) JGroup {
	linked := g.GroupLinkedParent.LinkedParentJID.String()
	if linked != "" && !strings.HasSuffix(linked, "@g.us") {
		linked = ""
	}
	out := JGroup{
		JID:               g.JID.String(),
		Name:              g.GroupName.Name,
		Topic:             g.GroupTopic.Topic,
		OwnerJID:          g.OwnerJID.String(),
		Created:           g.GroupCreated.Unix(),
		IsParent:          g.GroupParent.IsParent,
		LinkedParentJID:   linked,
		IsDefaultSubGroup: g.GroupIsDefaultSub.IsDefaultSubGroup,
		JoinApprovalMode: g.GroupMembershipApprovalMode.
			DefaultMembershipApprovalMode == "request_required",
		Participants: mapParticipants(g.Participants),
	}
	return out
}
```

Then replace the inline `JGroup{...}` literals in `ListGroups` and
`GetGroupInfo` with calls to `mapGroupInfo(&g)`. Preserve
`mapParticipants` (extract if it doesn't already exist; otherwise
reuse).

> **Note for engineer:** the existing `JGroup` construction has more
> nuance around `LinkedParentJID` normalization (anything not ending
> in `@g.us` → empty string) — preserve that exact behavior. The
> helper above carries it forward.

- [ ] **Step 5: Run to verify pass**

```bash
cd bridge && go test -short ./bridge/...
```

Expected: full Go test suite passes; new test included.

- [ ] **Step 6: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: JGroup carries join_approval_mode; extract mapGroupInfo"
```

---

## Milestone B — Swift bridge

### Task 10: Bridge JSON models for join requests + approval mode

**Files:**
- Modify: `yawac/Bridge/JSONModels.swift`

- [ ] **Step 1: Locate `BridgeGroupModel`**

```bash
grep -n "struct BridgeGroupModel\|isCommunityParent\|linkedParentJID" yawac/Bridge/JSONModels.swift
```

- [ ] **Step 2: Add new models + extend `BridgeGroupModel`**

Append to `JSONModels.swift`:

```swift
struct BridgeJoinRequest: Decodable, Hashable {
    let jid: String
    let requestedAt: Int64

    enum CodingKeys: String, CodingKey {
        case jid
        case requestedAt = "requested_at"
    }
}

struct BridgeJoinRequestResult: Decodable, Hashable {
    let jid: String
    let errorCode: Int?

    enum CodingKeys: String, CodingKey {
        case jid
        case errorCode = "error_code"
    }
}
```

Extend the existing `BridgeGroupModel` struct: add
`joinApprovalMode: Bool` field with default `false`, and a matching
`CodingKey` case `case joinApprovalMode = "join_approval_mode"`.

> **Note for engineer:** `BridgeGroupModel` already has CodingKeys
> for `isCommunityParent` / `linkedParentJID` etc. Follow that exact
> pattern — snake-case key on the wire, camelCase on the Swift side.

- [ ] **Step 3: No tests required for pure decode models — covered indirectly by Task 13 + later VM tests.**

- [ ] **Step 4: Commit**

```bash
git add yawac/Bridge/JSONModels.swift
git commit -m "bridge models: BridgeJoinRequest + BridgeJoinRequestResult; joinApprovalMode on BridgeGroupModel"
```

---

### Task 11: WAClient wrappers (all seven)

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`

- [ ] **Step 1: Locate the wrapper section**

```bash
grep -n "createGroup\|updateGroupParticipants\|joinSubGroup" yawac/Bridge/WAClient.swift
```

Find a good insertion point — adjacent to `createGroup` /
`updateGroupParticipants` is ideal.

- [ ] **Step 2: Append the seven new wrappers**

```swift
func createCommunity(name: String) throws -> String {
    var err: NSError?
    let out = go.createCommunity(name, error: &err)
    if let err { throw err }
    return out
}

func createSubGroup(parentJID: String,
                    name: String,
                    participantJIDs: [String]) throws -> String {
    let jids = try JSONEncoder().encode(participantJIDs)
    let jidsString = String(data: jids, encoding: .utf8) ?? "[]"
    var err: NSError?
    let out = go.createSubGroup(parentJID,
                                name: name,
                                participantJIDsJSON: jidsString,
                                error: &err)
    if let err { throw err }
    return out
}

nonisolated func linkSubGroup(parentJID: String, subJID: String) throws {
    try go.linkSubGroup(parentJID, subJIDStr: subJID)
}

nonisolated func unlinkSubGroup(parentJID: String, subJID: String) throws {
    try go.unlinkSubGroup(parentJID, subJIDStr: subJID)
}

func getGroupJoinRequests(chatJID: String) throws -> [BridgeJoinRequest] {
    var err: NSError?
    let json = go.getGroupJoinRequests(chatJID, error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(
        [BridgeJoinRequest].self, from: Data(json.utf8))
}

func updateGroupJoinRequests(chatJID: String,
                             action: String,
                             jids: [String]) throws -> [BridgeJoinRequestResult] {
    let encoded = try JSONEncoder().encode(jids)
    let jidsString = String(data: encoded, encoding: .utf8) ?? "[]"
    var err: NSError?
    let json = go.updateGroupJoinRequests(chatJID,
                                          action: action,
                                          participantJIDsJSON: jidsString,
                                          error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(
        [BridgeJoinRequestResult].self, from: Data(json.utf8))
}

nonisolated func setGroupJoinApprovalMode(chatJID: String, on: Bool) throws {
    try go.setGroupJoinApprovalMode(chatJID, on: on)
}
```

> **Note for engineer:** the exact gomobile-generated Objective-C
> selector names may differ. The pattern: gomobile turns
> `func (c *Client) Foo(a, b string) (string, error)` into
> `go.foo(_:b:error:) -> String`. Confirm by command-clicking through
> on each function or by checking the `Bridge.xcframework` headers.
> Adjust the `go.<name>` calls to match the actual selectors emitted
> by `./scripts/build-xcframework.sh`.

- [ ] **Step 3: Rebuild xcframework so new gomobile symbols are visible**

```bash
./scripts/build-xcframework.sh
```

Expected: completes without error; new methods on `BridgeClient`
visible.

- [ ] **Step 4: Build to verify Swift compiles**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "WAClient: wrappers for community admin + create funcs"
```

---

### Task 12: `WAClient.Event.joinApprovalModeChanged` case + decode

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`

- [ ] **Step 1: Locate the `Event` enum + `decode` switch**

```bash
grep -n "enum Event\|decode(kind:\|case groupInfoChanged" yawac/Bridge/WAClient.swift
```

- [ ] **Step 2: Add the case**

In the `WAClient.Event` enum:

```swift
case joinApprovalModeChanged(chatJID: String,
                             on: Bool,
                             actorJID: String,
                             timestamp: Int64)
```

In the `decode(kind:payload:)` switch:

```swift
case "JoinApprovalModeChanged":
    struct P: Decodable {
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
    guard let p = try? JSONDecoder().decode(P.self, from: Data(payload.utf8))
    else { return .unknown(kind: kind) }
    return .joinApprovalModeChanged(chatJID: p.chatJID,
                                    on: p.on,
                                    actorJID: p.actorJID ?? "",
                                    timestamp: p.timestamp)
```

> **Note:** match the existing decode-arm pattern (the spec assumes
> a `.unknown(kind:)` default — adjust to whatever the file uses,
> e.g. `.unknown(kind, payload)`).

- [ ] **Step 3: Build to verify Swift compiles**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "WAClient.Event: joinApprovalModeChanged + decode arm"
```

---

## Milestone C — JoinRequestStore

### Task 13: `JoinRequestStore` actor

**Files:**
- Create: `yawac/Bridge/JoinRequestStore.swift`
- Create: `yawacTests/JoinRequestStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `yawacTests/JoinRequestStoreTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class JoinRequestStoreTests: XCTestCase {

    func testDecrementClampsAtZero() {
        let store = JoinRequestStore()
        store.set(chatJID: "g1@g.us", count: 2)
        store.decrement(chatJID: "g1@g.us", by: 5)
        XCTAssertEqual(store.counts["g1@g.us"] ?? -1, 0)
    }

    func testClearRemovesEntry() {
        let store = JoinRequestStore()
        store.set(chatJID: "g1@g.us", count: 3)
        store.clear(chatJID: "g1@g.us")
        XCTAssertNil(store.counts["g1@g.us"])
    }

    func testRefreshSetsCountFromClient() async {
        let client = StubJoinRequestClient(responses: [
            "g1@g.us": [.init(jid: "u@s.whatsapp.net", requestedAt: 1)]
        ])
        let store = JoinRequestStore(client: client)
        await store.refresh(chatJID: "g1@g.us")
        XCTAssertEqual(store.counts["g1@g.us"], 1)
    }

    func testRefreshAllAdminBoundedConcurrency() async {
        let probe = ConcurrencyProbe()
        let chats = (0..<10).map { "g\($0)@g.us" }
        let client = StubJoinRequestClient(probe: probe,
                                           responsesFor: chats)
        let store = JoinRequestStore(client: client)
        await store.refreshAllAdmin(chatJIDs: chats)
        XCTAssertLessThanOrEqual(probe.peakConcurrency, 4)
        for chat in chats {
            XCTAssertEqual(store.counts[chat], 1, "missing \(chat)")
        }
    }
}

// Spec-assumed test doubles — engineer creates these in the same file.

final class ConcurrencyProbe: @unchecked Sendable {
    private var inFlight = 0
    private(set) var peakConcurrency = 0
    private let lock = NSLock()
    func enter() {
        lock.lock(); defer { lock.unlock() }
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
    }
    func leave() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
    }
}

final class StubJoinRequestClient: JoinRequestClient, @unchecked Sendable {
    private let responses: [String: [BridgeJoinRequest]]
    private let probe: ConcurrencyProbe?
    init(responses: [String: [BridgeJoinRequest]] = [:],
         probe: ConcurrencyProbe? = nil) {
        self.responses = responses
        self.probe = probe
    }
    convenience init(probe: ConcurrencyProbe, responsesFor chats: [String]) {
        let map = Dictionary(uniqueKeysWithValues: chats.map {
            ($0, [BridgeJoinRequest(jid: "u@s.whatsapp.net", requestedAt: 1)])
        })
        self.init(responses: map, probe: probe)
    }
    func getGroupJoinRequests(chatJID: String) throws -> [BridgeJoinRequest] {
        probe?.enter()
        defer { probe?.leave() }
        Thread.sleep(forTimeInterval: 0.02)
        return responses[chatJID] ?? []
    }
}
```

- [ ] **Step 2: Run test to verify failure**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' test \
  -only-testing:yawacTests/JoinRequestStoreTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL (compile error — `JoinRequestStore` undefined).

- [ ] **Step 3: Implement `JoinRequestStore`**

Create `yawac/Bridge/JoinRequestStore.swift`:

```swift
import Foundation
import Observation

/// Minimal protocol abstracting the WAClient call so tests can stub.
protocol JoinRequestClient {
    func getGroupJoinRequests(chatJID: String) throws -> [BridgeJoinRequest]
}

extension WAClient: JoinRequestClient {}

@MainActor
@Observable
final class JoinRequestStore {

    private(set) var counts: [String: Int] = [:]
    private let client: JoinRequestClient?

    init(client: JoinRequestClient? = nil) {
        self.client = client
    }

    // Test-only direct setter; keep internal.
    func set(chatJID: String, count: Int) {
        counts[chatJID] = max(0, count)
    }

    func decrement(chatJID: String, by n: Int) {
        guard let current = counts[chatJID] else { return }
        counts[chatJID] = max(0, current - n)
    }

    func clear(chatJID: String) {
        counts.removeValue(forKey: chatJID)
    }

    func refresh(chatJID: String) async {
        guard let client else { return }
        let result: [BridgeJoinRequest]
        do {
            result = try await Task.detached {
                try client.getGroupJoinRequests(chatJID: chatJID)
            }.value
        } catch {
            return
        }
        counts[chatJID] = result.count
    }

    func refreshAllAdmin(chatJIDs: [String]) async {
        guard let client, !chatJIDs.isEmpty else { return }
        let maxConcurrent = 4
        await withTaskGroup(of: (String, Int?).self) { group in
            var iterator = chatJIDs.makeIterator()
            var dispatched = 0
            while dispatched < maxConcurrent, let next = iterator.next() {
                dispatched += 1
                group.addTask {
                    await Self.fetchCount(client: client, chatJID: next)
                }
            }
            while let (jid, count) = await group.next() {
                if let count { self.counts[jid] = count }
                if let next = iterator.next() {
                    group.addTask {
                        await Self.fetchCount(client: client, chatJID: next)
                    }
                }
            }
        }
    }

    private static func fetchCount(client: JoinRequestClient,
                                   chatJID: String) async -> (String, Int?) {
        do {
            let rows = try await Task.detached {
                try client.getGroupJoinRequests(chatJID: chatJID)
            }.value
            return (chatJID, rows.count)
        } catch {
            return (chatJID, nil)
        }
    }
}
```

> **Note:** the `Task.detached` wrap is to call the throwing
> synchronous `getGroupJoinRequests` off-main. If WAClient already
> exposes an async version, prefer that. The `JoinRequestClient`
> protocol exists so the store is testable with a stub — keep that.

- [ ] **Step 4: Run tests to verify pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' test \
  -only-testing:yawacTests/JoinRequestStoreTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/JoinRequestStore.swift yawacTests/JoinRequestStoreTests.swift
git commit -m "JoinRequestStore: observable pending-count store with bounded refresh"
```

---

### Task 14: Wire `JoinRequestStore` into `SessionViewModel`

**Files:**
- Modify: `yawac/ViewModels/SessionViewModel.swift`

- [ ] **Step 1: Locate `SessionViewModel` + the bridge event subscription**

```bash
grep -n "class SessionViewModel\|WAClient\|eventStream\|connected" yawac/ViewModels/SessionViewModel.swift
```

- [ ] **Step 2: Add the property + event hook**

Add a stored `joinRequestStore: JoinRequestStore` property (initialized
with `JoinRequestStore(client: client)`).

In the existing event-stream consumption (wherever the
`for await event in client.eventStream()` loop lives), add the
following arms:

```swift
case .connected:
    Task { await self.refreshAllAdminApprovalGroups() }

case .joinApprovalModeChanged(let chatJID, let on, _, _):
    if on {
        Task { await self.joinRequestStore.refresh(chatJID: chatJID) }
    } else {
        self.joinRequestStore.clear(chatJID: chatJID)
    }
```

And add:

```swift
@MainActor
private func refreshAllAdminApprovalGroups() async {
    guard let chats = chatList?.chats else { return }
    let candidates: [String] = chats.compactMap { chat in
        guard chat.isGroup,
              chat.joinApprovalMode,
              chat.amAdmin
        else { return nil }
        return chat.jid
    }
    await joinRequestStore.refreshAllAdmin(chatJIDs: candidates)
}
```

> **Note for engineer:** `Chat.joinApprovalMode` and `Chat.amAdmin` are
> spec-assumed. Confirm the actual fields on `Chat`:
> `grep -n "var amAdmin\|var joinApprovalMode\|isAdmin" yawac/Models/Chat.swift`.
> If they don't exist as named, derive them from the available
> participant array or extend `Chat` to carry the flags (out of scope
> here — preferably done in Task 24 alongside other ChatListViewModel
> mapping).

- [ ] **Step 3: Hook `didBecomeActiveNotification` with 30s throttle**

Add to `SessionViewModel.init` (or wherever app lifecycle hooks are
wired):

```swift
NotificationCenter.default.addObserver(
    forName: NSApplication.didBecomeActiveNotification,
    object: nil, queue: .main
) { [weak self] _ in
    guard let self else { return }
    Task { @MainActor in
        let now = Date()
        if let last = self.lastForegroundRefresh,
           now.timeIntervalSince(last) < 30 { return }
        self.lastForegroundRefresh = now
        await self.refreshAllAdminApprovalGroups()
    }
}
```

Add a `private var lastForegroundRefresh: Date?` field.

- [ ] **Step 4: Build to verify compile**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

> **Build-failure recovery:** if `Chat.joinApprovalMode` /
> `Chat.amAdmin` are not yet defined, defer wiring these references
> until Task 24 lands. Make this task's diff minimal: add the
> property + `didBecomeActiveNotification` hook + a stub
> `refreshAllAdminApprovalGroups()` that just returns. The actual
> refresh population comes online after Task 24.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/SessionViewModel.swift
git commit -m "SessionViewModel: wire JoinRequestStore to .connected + foreground refresh"
```

---

## Milestone D — Creation UI

### Task 15: `NewGroupSheetModel` + tests

**Files:**
- Create: `yawac/ViewModels/NewGroupSheetModel.swift`
- Create: `yawacTests/NewGroupSheetModelTests.swift`

- [ ] **Step 1: Write failing tests**

Create `yawacTests/NewGroupSheetModelTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class NewGroupSheetModelTests: XCTestCase {

    func testCanCreateRequiresName() {
        let m = NewGroupSheetModel(creator: StubGroupCreator())
        XCTAssertFalse(m.canCreate)
        m.name = "  "
        XCTAssertFalse(m.canCreate)
        m.name = "A"
        XCTAssertTrue(m.canCreate)
    }

    func testNameCappedAt25() {
        let m = NewGroupSheetModel(creator: StubGroupCreator())
        m.name = String(repeating: "x", count: 30)
        XCTAssertEqual(m.name.count, 25)
    }

    func testCreateCallsBridgeWithChipJIDs() async {
        let stub = StubGroupCreator()
        let m = NewGroupSheetModel(creator: stub)
        m.name = "Climbers"
        m.chips = [
            BridgeContact(jid: "a@s.whatsapp.net", name: "A"),
            BridgeContact(jid: "b@s.whatsapp.net", name: "B")
        ]
        await m.create()
        XCTAssertEqual(stub.lastName, "Climbers")
        XCTAssertEqual(stub.lastJIDs, ["a@s.whatsapp.net", "b@s.whatsapp.net"])
        XCTAssertNotNil(m.createdJID)
        XCTAssertNil(m.error)
    }

    func testCreateFailureLeavesError() async {
        let stub = StubGroupCreator(throwError: TestError.boom)
        let m = NewGroupSheetModel(creator: stub)
        m.name = "Climbers"
        await m.create()
        XCTAssertNotNil(m.error)
        XCTAssertNil(m.createdJID)
    }
}

enum TestError: Error { case boom }

final class StubGroupCreator: GroupCreator, @unchecked Sendable {
    var lastName: String?
    var lastJIDs: [String]?
    var throwError: Error?
    init(throwError: Error? = nil) { self.throwError = throwError }
    func createGroup(name: String, participantJIDs: [String]) throws -> String {
        if let throwError { throw throwError }
        lastName = name
        lastJIDs = participantJIDs
        return "new@g.us"
    }
}
```

> **Note for engineer:** `BridgeContact` should already exist
> (check `JSONModels.swift`). If its initializer requires more
> fields, supply defaults in the test.

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild ... -only-testing:yawacTests/NewGroupSheetModelTests test
```

Expected: FAIL (undefined `NewGroupSheetModel`).

- [ ] **Step 3: Implement the model**

Create `yawac/ViewModels/NewGroupSheetModel.swift`:

```swift
import Foundation
import Observation

protocol GroupCreator {
    func createGroup(name: String, participantJIDs: [String]) throws -> String
}

extension WAClient: GroupCreator {}

@MainActor
@Observable
final class NewGroupSheetModel {

    var name: String = "" {
        didSet {
            if name.count > 25 { name = String(name.prefix(25)) }
        }
    }
    var chips: [BridgeContact] = []
    var query: String = ""
    var inFlight: Bool = false
    var error: String?
    private(set) var createdJID: String?

    private let creator: GroupCreator

    init(creator: GroupCreator) {
        self.creator = creator
    }

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !inFlight
    }

    func create() async {
        guard canCreate else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let jids = chips.map(\.jid)
        inFlight = true
        defer { inFlight = false }
        do {
            let jid = try await Task.detached { [creator] in
                try creator.createGroup(name: trimmed, participantJIDs: jids)
            }.value
            createdJID = jid
            error = nil
        } catch let err {
            error = (err as NSError).localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild ... -only-testing:yawacTests/NewGroupSheetModelTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/NewGroupSheetModel.swift yawacTests/NewGroupSheetModelTests.swift
git commit -m "NewGroupSheetModel: name/chip state + create() with stubbed creator"
```

---

### Task 16: `NewGroupSheet` view

**Files:**
- Create: `yawac/Views/NewGroupSheet.swift`

- [ ] **Step 1: Implement the view**

```swift
import SwiftUI

struct NewGroupSheet: View {
    @Bindable var model: NewGroupSheetModel
    @Environment(\.dismiss) private var dismiss
    var onCreated: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New group").font(.headline)
                Spacer()
                Text("\(model.name.count) / 25")
                    .foregroundStyle(model.name.count >= 25 ? .red : .secondary)
                    .scaledUI(11)
            }
            TextField("Name", text: $model.name)
                .textFieldStyle(.roundedBorder)

            // Chip + suggestion picker — engineer: lift the implementation
            // from AddParticipantsPanel.swift (chip strip + suggestion list +
            // contact filter). Contacts only (no +phone resolver per spec).
            ParticipantPicker(chips: $model.chips, query: $model.query)
                .frame(minHeight: 200)

            if let err = model.error {
                Text(err).foregroundStyle(.red).scaledUI(11)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    Task {
                        await model.create()
                        if let jid = model.createdJID {
                            onCreated(jid)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
```

> **Note for engineer:** `ParticipantPicker` is a placeholder
> sub-component. Either lift the chip+suggestion view out of
> `AddParticipantsPanel.swift` into a reusable struct (preferred) or
> inline the relevant subset here. If lifted out, ensure
> `AddParticipantsPanel` is updated to consume the new shared
> component — keep the diff bounded to that surface.

- [ ] **Step 2: Build**

```bash
xcodebuild ... build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/NewGroupSheet.swift
git commit -m "NewGroupSheet: sheet view for plain-group creation"
```

---

### Task 17: `NewCommunitySheetModel` + tests

**Files:**
- Create: `yawac/ViewModels/NewCommunitySheetModel.swift`
- Create: `yawacTests/NewCommunitySheetModelTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import yawac

@MainActor
final class NewCommunitySheetModelTests: XCTestCase {

    func testCanCreateRequiresName() {
        let m = NewCommunitySheetModel(creator: StubCommunityCreator())
        XCTAssertFalse(m.canCreate)
        m.name = "Outdoor"
        XCTAssertTrue(m.canCreate)
    }

    func testNameCapped() {
        let m = NewCommunitySheetModel(creator: StubCommunityCreator())
        m.name = String(repeating: "x", count: 40)
        XCTAssertEqual(m.name.count, 25)
    }

    func testCreateCallsBridge() async {
        let stub = StubCommunityCreator()
        let m = NewCommunitySheetModel(creator: stub)
        m.name = "Outdoor"
        await m.create()
        XCTAssertEqual(stub.lastName, "Outdoor")
        XCTAssertEqual(m.createdJID, "comm@g.us")
    }
}

final class StubCommunityCreator: CommunityCreator, @unchecked Sendable {
    var lastName: String?
    var throwError: Error?
    func createCommunity(name: String) throws -> String {
        if let throwError { throw throwError }
        lastName = name
        return "comm@g.us"
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement model**

```swift
import Foundation
import Observation

protocol CommunityCreator {
    func createCommunity(name: String) throws -> String
}

extension WAClient: CommunityCreator {}

@MainActor
@Observable
final class NewCommunitySheetModel {
    var name: String = "" {
        didSet { if name.count > 25 { name = String(name.prefix(25)) } }
    }
    var inFlight: Bool = false
    var error: String?
    private(set) var createdJID: String?

    private let creator: CommunityCreator

    init(creator: CommunityCreator) { self.creator = creator }

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !inFlight
    }

    func create() async {
        guard canCreate else { return }
        inFlight = true
        defer { inFlight = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            createdJID = try await Task.detached { [creator] in
                try creator.createCommunity(name: trimmed)
            }.value
            error = nil
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git commit -m "NewCommunitySheetModel: name + create() with stubbed creator"
```

---

### Task 18: `NewCommunitySheet` view

**Files:**
- Create: `yawac/Views/NewCommunitySheet.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct NewCommunitySheet: View {
    @Bindable var model: NewCommunitySheetModel
    @Environment(\.dismiss) private var dismiss
    var onCreated: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New community").font(.headline)
                Spacer()
                Text("\(model.name.count) / 25")
                    .foregroundStyle(model.name.count >= 25 ? .red : .secondary)
                    .scaledUI(11)
            }
            TextField("Name", text: $model.name)
                .textFieldStyle(.roundedBorder)
            Text("A community holds related groups together. Members are added by linking or creating sub-groups.")
                .scaledUI(11)
                .foregroundStyle(.secondary)
            if let err = model.error {
                Text(err).foregroundStyle(.red).scaledUI(11)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    Task {
                        await model.create()
                        if let jid = model.createdJID {
                            onCreated(jid)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

- [ ] **Step 2: Build**

- [ ] **Step 3: Commit**

```bash
git commit -m "NewCommunitySheet: sheet view for community-parent creation"
```

---

### Task 19: `NewSubGroupSheetModel` + tests

**Files:**
- Create: `yawac/ViewModels/NewSubGroupSheetModel.swift`
- Create: `yawacTests/NewSubGroupSheetModelTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import yawac

@MainActor
final class NewSubGroupSheetModelTests: XCTestCase {

    func testCreatePassesParentAndJIDs() async {
        let stub = StubSubGroupCreator()
        let m = NewSubGroupSheetModel(parentJID: "parent@g.us",
                                      creator: stub)
        m.name = "Hiking"
        m.chips = [BridgeContact(jid: "a@s.whatsapp.net", name: "A")]
        await m.create()
        XCTAssertEqual(stub.lastParent, "parent@g.us")
        XCTAssertEqual(stub.lastName, "Hiking")
        XCTAssertEqual(stub.lastJIDs, ["a@s.whatsapp.net"])
        XCTAssertEqual(m.createdJID, "sub@g.us")
    }

    func testFailureSurfacesError() async {
        let stub = StubSubGroupCreator(throwError: TestError.boom)
        let m = NewSubGroupSheetModel(parentJID: "parent@g.us",
                                      creator: stub)
        m.name = "Hiking"
        await m.create()
        XCTAssertNotNil(m.error)
        XCTAssertNil(m.createdJID)
    }
}

final class StubSubGroupCreator: SubGroupCreator, @unchecked Sendable {
    var lastParent: String?
    var lastName: String?
    var lastJIDs: [String]?
    var throwError: Error?
    init(throwError: Error? = nil) { self.throwError = throwError }
    func createSubGroup(parentJID: String, name: String,
                       participantJIDs: [String]) throws -> String {
        if let throwError { throw throwError }
        lastParent = parentJID
        lastName = name
        lastJIDs = participantJIDs
        return "sub@g.us"
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement model**

```swift
import Foundation
import Observation

protocol SubGroupCreator {
    func createSubGroup(parentJID: String, name: String,
                       participantJIDs: [String]) throws -> String
}

extension WAClient: SubGroupCreator {}

@MainActor
@Observable
final class NewSubGroupSheetModel {
    var name: String = "" {
        didSet { if name.count > 25 { name = String(name.prefix(25)) } }
    }
    var chips: [BridgeContact] = []
    var query: String = ""
    var inFlight: Bool = false
    var error: String?
    private(set) var createdJID: String?

    let parentJID: String
    private let creator: SubGroupCreator

    init(parentJID: String, creator: SubGroupCreator) {
        self.parentJID = parentJID
        self.creator = creator
    }

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !inFlight
    }

    func create() async {
        guard canCreate else { return }
        inFlight = true
        defer { inFlight = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let jids = chips.map(\.jid)
        do {
            createdJID = try await Task.detached {
                [creator, parentJID] in
                try creator.createSubGroup(parentJID: parentJID,
                                          name: trimmed,
                                          participantJIDs: jids)
            }.value
            error = nil
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git commit -m "NewSubGroupSheetModel: parent-scoped sub-group creator"
```

---

### Task 20: `NewSubGroupSheet` view

**Files:**
- Create: `yawac/Views/NewSubGroupSheet.swift`

- [ ] **Step 1: Implement** — mirror `NewGroupSheet` but title shows
  `"New sub-group in \"<parent name>\""`. Use `ParticipantPicker`.

```swift
import SwiftUI

struct NewSubGroupSheet: View {
    @Bindable var model: NewSubGroupSheetModel
    let parentName: String
    @Environment(\.dismiss) private var dismiss
    var onCreated: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New sub-group in “\(parentName)”").font(.headline)
                Spacer()
                Text("\(model.name.count) / 25")
                    .foregroundStyle(model.name.count >= 25 ? .red : .secondary)
                    .scaledUI(11)
            }
            TextField("Name", text: $model.name)
                .textFieldStyle(.roundedBorder)

            ParticipantPicker(chips: $model.chips, query: $model.query)
                .frame(minHeight: 200)

            if let err = model.error {
                Text(err).foregroundStyle(.red).scaledUI(11)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    Task {
                        await model.create()
                        if let jid = model.createdJID {
                            onCreated(jid)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
```

- [ ] **Step 2: Build**

- [ ] **Step 3: Commit**

```bash
git commit -m "NewSubGroupSheet: sheet view for sub-group-of-community creation"
```

---

### Task 21: Sidebar "+" header button + menu

**Files:**
- Modify: `yawac/Views/ChatListView.swift`

- [ ] **Step 1: Locate the search-row block**

```bash
grep -n "magnifyingglass\|TextField(\"Search\"" yawac/Views/ChatListView.swift
```

- [ ] **Step 2: Add a `+` button next to the search field**

Inside the existing search `HStack`, after the search-query trailing
content but before the closing brace, insert:

```swift
Menu {
    Button("New group…") { showingNewGroup = true }
    Button("New community…") { showingNewCommunity = true }
} label: {
    Image(systemName: "plus.circle")
        .scaledIcon(13, weight: .medium)
        .foregroundStyle(Theme.textFaint)
}
.menuStyle(.borderlessButton)
.menuIndicator(.hidden)
.fixedSize()
```

Add the state at the top of the view:

```swift
@State private var showingNewGroup = false
@State private var showingNewCommunity = false
```

Add the sheets at the bottom of the view body (after the existing
`.background(Theme.sidebarBg)`):

```swift
.sheet(isPresented: $showingNewGroup) {
    let model = NewGroupSheetModel(creator: session.client)
    NewGroupSheet(model: model) { newJID in
        session.chatList?.requestSelectChat(newJID)
    }
}
.sheet(isPresented: $showingNewCommunity) {
    let model = NewCommunitySheetModel(creator: session.client)
    NewCommunitySheet(model: model) { newJID in
        session.chatList?.requestSelectChat(newJID)
    }
}
```

> **Note for engineer:** the names `session.client` /
> `session.chatList?.requestSelectChat` are spec-assumed. Grep the
> existing view for how other actions reach `WAClient` and the chat
> selection helper — reuse those exact accessors. If `requestSelectChat`
> doesn't exist, use whatever pattern other "open this chat" callers
> use (e.g. `session.selectChat(jid:)`).

- [ ] **Step 3: Build**

- [ ] **Step 4: Manual check: launch the app, click "+", confirm menu opens, both items present and tap-able.**

- [ ] **Step 5: Commit**

```bash
git add yawac/Views/ChatListView.swift
git commit -m "ChatListView: sidebar + button for New group / New community"
```

---

## Milestone E — Community admin UI

### Task 22: `LinkSubGroupSheetModel` + tests

**Files:**
- Create: `yawac/ViewModels/LinkSubGroupSheetModel.swift`
- Create: `yawacTests/LinkSubGroupSheetModelTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import yawac

@MainActor
final class LinkSubGroupSheetModelTests: XCTestCase {

    private let me = "me@s.whatsapp.net"

    func testCandidatesExcludeParentAndCommunityMembers() {
        let parent = "comm@g.us"
        let all: [BridgeGroupModel] = [
            .stub(jid: "linked-here@g.us", linkedParent: parent, amAdmin: true),
            .stub(jid: "other@g.us", amAdmin: true),
            .stub(jid: "non-admin@g.us", amAdmin: false),
            .stub(jid: "parent@g.us", isCommunityParent: true, amAdmin: true),
            .stub(jid: "linked-other@g.us",
                  linkedParent: "other-comm@g.us", amAdmin: true)
        ]
        let m = LinkSubGroupSheetModel(parentChatJID: parent,
                                       myJID: me,
                                       availableGroups: all,
                                       linker: StubLinker())
        let jids = m.candidates.map(\.jid)
        XCTAssertFalse(jids.contains("linked-here@g.us"))
        XCTAssertFalse(jids.contains("non-admin@g.us"))
        XCTAssertFalse(jids.contains("parent@g.us"))
        XCTAssertTrue(jids.contains("other@g.us"))
        XCTAssertTrue(jids.contains("linked-other@g.us"))
    }

    func testCrossCommunityCandidateRequiresConfirmation() {
        let all: [BridgeGroupModel] = [
            .stub(jid: "x@g.us", linkedParent: "other@g.us", amAdmin: true)
        ]
        let m = LinkSubGroupSheetModel(parentChatJID: "p@g.us",
                                       myJID: me,
                                       availableGroups: all,
                                       linker: StubLinker())
        m.selected = "x@g.us"
        XCTAssertTrue(m.needsCrossCommunityConfirmation)
    }

    func testSuccessfulLink() async {
        let linker = StubLinker()
        let m = LinkSubGroupSheetModel(
            parentChatJID: "p@g.us",
            myJID: me,
            availableGroups: [.stub(jid: "x@g.us", amAdmin: true)],
            linker: linker)
        m.selected = "x@g.us"
        await m.confirmLink()
        XCTAssertEqual(linker.lastParent, "p@g.us")
        XCTAssertEqual(linker.lastSub, "x@g.us")
        XCTAssertTrue(m.didLink)
        XCTAssertNil(m.error)
    }
}

final class StubLinker: SubGroupLinker, @unchecked Sendable {
    var lastParent: String?
    var lastSub: String?
    func linkSubGroup(parentJID: String, subJID: String) throws {
        lastParent = parentJID; lastSub = subJID
    }
}

extension BridgeGroupModel {
    static func stub(jid: String,
                     name: String = "",
                     isCommunityParent: Bool = false,
                     linkedParent: String? = nil,
                     amAdmin: Bool = false) -> BridgeGroupModel {
        // Engineer: substitute the real initializer for BridgeGroupModel.
        // This is a placeholder; mirror existing test fixtures.
        fatalError("implement BridgeGroupModel.stub matching the real init")
    }
}
```

> **Note for engineer:** replace the `fatalError` stub with a real
> initializer call that matches `BridgeGroupModel`'s actual fields.
> Look for similar `.stub` factories in existing `yawacTests/`.

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement the model**

Create `yawac/ViewModels/LinkSubGroupSheetModel.swift`:

```swift
import Foundation
import Observation

protocol SubGroupLinker {
    func linkSubGroup(parentJID: String, subJID: String) throws
}

extension WAClient: SubGroupLinker {}

@MainActor
@Observable
final class LinkSubGroupSheetModel {

    let parentChatJID: String
    private let myJID: String
    private let availableGroups: [BridgeGroupModel]
    private let linker: SubGroupLinker

    var query: String = ""
    var selected: String?
    var inFlight: Bool = false
    var error: String?
    private(set) var didLink: Bool = false

    init(parentChatJID: String,
         myJID: String,
         availableGroups: [BridgeGroupModel],
         linker: SubGroupLinker) {
        self.parentChatJID = parentChatJID
        self.myJID = myJID
        self.availableGroups = availableGroups
        self.linker = linker
    }

    var candidates: [BridgeGroupModel] {
        availableGroups
            .filter { !$0.isCommunityParent }
            .filter { $0.linkedParentJID != parentChatJID }
            .filter { isAdmin(of: $0) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func isAdmin(of group: BridgeGroupModel) -> Bool {
        group.participants.contains {
            $0.jid == myJID && ($0.isAdmin == true || $0.isSuperAdmin == true)
        }
    }

    var selectedGroup: BridgeGroupModel? {
        guard let selected else { return nil }
        return availableGroups.first(where: { $0.jid == selected })
    }

    var needsCrossCommunityConfirmation: Bool {
        guard let g = selectedGroup else { return false }
        let parent = g.linkedParentJID ?? ""
        return !parent.isEmpty
    }

    func confirmLink() async {
        guard let selected else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            try await Task.detached { [linker, parentChatJID, selected] in
                try linker.linkSubGroup(parentJID: parentChatJID, subJID: selected)
            }.value
            didLink = true
            error = nil
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git commit -m "LinkSubGroupSheetModel: candidate filter + cross-community confirm"
```

---

### Task 23: `LinkSubGroupSheet` view

**Files:**
- Create: `yawac/Views/LinkSubGroupSheet.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct LinkSubGroupSheet: View {
    @Bindable var model: LinkSubGroupSheetModel
    let parentName: String
    let resolveCommunityName: (String) -> String
    var onLinked: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCrossCommunityConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link group to “\(parentName)”").font(.headline)
            TextField("Search", text: $model.query)
                .textFieldStyle(.roundedBorder)

            List(model.candidates, id: \.jid, selection: $model.selected) { g in
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.name)
                    if let parent = g.linkedParentJID, !parent.isEmpty {
                        Text("⚠ in “\(resolveCommunityName(parent))”")
                            .foregroundStyle(.orange).scaledUI(11)
                    } else {
                        Text("\(g.participants.count) members")
                            .foregroundStyle(.secondary).scaledUI(11)
                    }
                }
                .tag(g.jid as String?)
            }
            .frame(minHeight: 220)

            if let err = model.error {
                Text(err).foregroundStyle(.red).scaledUI(11)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Link") {
                    if model.needsCrossCommunityConfirmation {
                        showCrossCommunityConfirm = true
                    } else {
                        Task { await performLink() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selected == nil || model.inFlight)
            }
        }
        .padding(20)
        .frame(width: 480)
        .confirmationDialog(
            "Move “\(model.selectedGroup?.name ?? "")” between communities?",
            isPresented: $showCrossCommunityConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to “\(parentName)”", role: .destructive) {
                Task { await performLink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let g = model.selectedGroup, let other = g.linkedParentJID {
                Text("“\(g.name)” is currently linked to “\(resolveCommunityName(other))”. Moving it removes it from there.")
            }
        }
    }

    private func performLink() async {
        await model.confirmLink()
        if model.didLink {
            onLinked()
            dismiss()
        }
    }
}
```

- [ ] **Step 2: Build**

- [ ] **Step 3: Commit**

```bash
git commit -m "LinkSubGroupSheet: picker + cross-community confirmation"
```

---

### Task 24: ChatInfoView — community parent: LINKED GROUPS "+" menu + Unlink ctx + admin gating

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift`

- [ ] **Step 1: Locate the LINKED GROUPS section**

```bash
grep -n "LINKED GROUPS\|COMMUNITY GROUPS\|subGroupRow\|subGroups" yawac/Views/ChatInfoView.swift
```

- [ ] **Step 2: Add header "+" menu**

Replace the existing section header (currently plain `"LINKED GROUPS"`)
with:

```swift
HStack {
    Text("LINKED GROUPS").scaledUI(10, weight: .semibold)
        .foregroundStyle(Theme.textFaint)
    Spacer()
    if isCurrentUserAdmin(g) && g.isCommunityParent {
        Menu {
            Button("Link existing group…") {
                showingLinkSheet = true
            }
            Button("Create new sub-group…") {
                showingNewSubGroupSheet = true
            }
        } label: {
            Image(systemName: "plus.circle")
                .scaledIcon(11, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
```

Add the state:

```swift
@State private var showingLinkSheet = false
@State private var showingNewSubGroupSheet = false
```

Add the sheets near the bottom of `groupBody`:

```swift
.sheet(isPresented: $showingLinkSheet) {
    let allGroups = (try? session.client.listGroups()) ?? []
    let myJID = session.ownJID ?? ""
    let model = LinkSubGroupSheetModel(
        parentChatJID: g.jid,
        myJID: myJID,
        availableGroups: allGroups,
        linker: session.client)
    LinkSubGroupSheet(
        model: model,
        parentName: g.name,
        resolveCommunityName: { jid in
            session.chatList?.chats.first(where: { $0.jid == jid })?.name ?? jid
        },
        onLinked: { Task { await loadGroup() } }
    )
}
.sheet(isPresented: $showingNewSubGroupSheet) {
    let model = NewSubGroupSheetModel(
        parentJID: g.jid, creator: session.client)
    NewSubGroupSheet(
        model: model, parentName: g.name,
        onCreated: { _ in Task { await loadGroup() } }
    )
}
```

- [ ] **Step 3: Add Unlink context menu to existing sub-group row**

In `subGroupRow(_:)` (or wherever sub-group rows are built), append:

```swift
.contextMenu {
    if isCurrentUserAdmin(g),
       !sub.isDefaultSubGroup {
        Button("Unlink from community", role: .destructive) {
            unlinkSubGroupConfirm = sub
        }
    }
    // ... preserve existing ctx-menu items ...
}
```

Add state + dialog at the body level:

```swift
@State private var unlinkSubGroupConfirm: BridgeSubGroup?
```

```swift
.confirmationDialog(
    "Unlink “\(unlinkSubGroupConfirm?.name ?? "")” from community?",
    isPresented: .init(
        get: { unlinkSubGroupConfirm != nil },
        set: { if !$0 { unlinkSubGroupConfirm = nil } }
    ),
    titleVisibility: .visible
) {
    Button("Unlink", role: .destructive) {
        if let sub = unlinkSubGroupConfirm {
            Task {
                do {
                    try await Task.detached {
                        try session.client.unlinkSubGroup(
                            parentJID: g.jid, subJID: sub.jid)
                    }.value
                    await loadGroup()
                } catch {
                    sectionError = (error as NSError).localizedDescription
                }
                unlinkSubGroupConfirm = nil
            }
        }
    }
    Button("Cancel", role: .cancel) { unlinkSubGroupConfirm = nil }
}
```

`sectionError: String?` is a new `@State` rendered as the inline
red text at the LINKED GROUPS section header (6s auto-dismiss
via `.task(id: sectionError)` + `try await Task.sleep`).

- [ ] **Step 4: Build**

- [ ] **Step 5: Manual smoke: open a community parent's info, confirm "+" menu appears (admin only), Link sheet + Create sheet both reachable, default sub-group has no Unlink ctx item.**

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "ChatInfoView: LINKED GROUPS + menu (Link/Create) and Unlink ctx item"
```

---

### Task 25: ChatInfoView — sub-group: approval-mode toggle row

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift`

- [ ] **Step 1: Add the toggle row between description editor and participants**

```swift
if isCurrentUserAdmin(g),
   !g.isCommunityParent,
   let parent = g.linkedParentJID, !parent.isEmpty {
    HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
            Text("Require admin approval to join")
            Text("New members request to join; admins approve.")
                .foregroundStyle(.secondary).scaledUI(11)
        }
        Spacer()
        Toggle("", isOn: Binding(
            get: { g.joinApprovalMode },
            set: { newValue in
                let prior = g.joinApprovalMode
                g.joinApprovalMode = newValue  // optimistic
                Task {
                    do {
                        try await Task.detached {
                            try session.client.setGroupJoinApprovalMode(
                                chatJID: g.jid, on: newValue)
                        }.value
                    } catch {
                        g.joinApprovalMode = prior  // revert
                        toggleError = (error as NSError).localizedDescription
                    }
                }
            }
        ))
        .labelsHidden()
    }
    if let err = toggleError {
        Text(err).foregroundStyle(.red).scaledUI(11)
    }
}
```

Add `@State private var toggleError: String?` with auto-dismiss
after 6s via `.task(id: toggleError) { ... try await Task.sleep ... }`.

> **Note:** if `BridgeGroupModel` is a value type and `g` is a `let`
> binding, the optimistic flip needs to mutate a `@State`
> shadow-copy of `g.joinApprovalMode`. Adapt to the existing
> view's mutation pattern.

- [ ] **Step 2: Build**

- [ ] **Step 3: Commit**

```bash
git commit -m "ChatInfoView: approval-mode toggle row for community sub-groups"
```

---

### Task 26: `PendingRequestsSectionModel` + tests

**Files:**
- Create: `yawac/ViewModels/PendingRequestsSectionModel.swift`
- Create: `yawacTests/PendingRequestsSectionModelTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import yawac

@MainActor
final class PendingRequestsSectionModelTests: XCTestCase {

    func testSingleApproveDropsRowAndDecrements() async {
        let store = JoinRequestStore()
        store.set(chatJID: "g@g.us", count: 2)
        let stub = StubRequestUpdater(responses: [
            "approve+[a@s.whatsapp.net]": [.init(jid: "a@s.whatsapp.net", errorCode: 0)]
        ])
        let m = PendingRequestsSectionModel(
            chatJID: "g@g.us",
            updater: stub, store: store)
        m.requests = [
            .init(jid: "a@s.whatsapp.net", displayName: "Anna", requestedAt: 1),
            .init(jid: "b@s.whatsapp.net", displayName: "B",    requestedAt: 1)
        ]
        await m.approve(jid: "a@s.whatsapp.net")
        XCTAssertEqual(m.requests.map(\.jid), ["b@s.whatsapp.net"])
        XCTAssertEqual(store.counts["g@g.us"], 1)
    }

    func testBulkApproveKeepsFailedRows() async {
        let store = JoinRequestStore()
        store.set(chatJID: "g@g.us", count: 3)
        let stub = StubRequestUpdater(responses: [
            "approve+[a@s.whatsapp.net,b@s.whatsapp.net,c@s.whatsapp.net]": [
                .init(jid: "a@s.whatsapp.net", errorCode: 0),
                .init(jid: "b@s.whatsapp.net", errorCode: 403),
                .init(jid: "c@s.whatsapp.net", errorCode: 0)
            ]
        ])
        let m = PendingRequestsSectionModel(
            chatJID: "g@g.us", updater: stub, store: store)
        m.requests = [
            .init(jid: "a@s.whatsapp.net", displayName: "A", requestedAt: 1),
            .init(jid: "b@s.whatsapp.net", displayName: "B", requestedAt: 1),
            .init(jid: "c@s.whatsapp.net", displayName: "C", requestedAt: 1)
        ]
        await m.approveAll()
        XCTAssertEqual(m.requests.map(\.jid), ["b@s.whatsapp.net"])
        XCTAssertEqual(store.counts["g@g.us"], 1)
        XCTAssertNotNil(m.error)
    }
}

final class StubRequestUpdater: RequestUpdater, @unchecked Sendable {
    var responses: [String: [BridgeJoinRequestResult]] = [:]
    init(responses: [String: [BridgeJoinRequestResult]] = [:]) {
        self.responses = responses
    }
    func updateGroupJoinRequests(chatJID: String,
                                 action: String,
                                 jids: [String]) throws -> [BridgeJoinRequestResult] {
        let key = "\(action)+[\(jids.joined(separator: ","))]"
        return responses[key] ?? []
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement model**

```swift
import Foundation
import Observation

protocol RequestUpdater {
    func updateGroupJoinRequests(chatJID: String, action: String,
                                 jids: [String]) throws -> [BridgeJoinRequestResult]
}

extension WAClient: RequestUpdater {}

struct PendingRequestRow: Identifiable, Hashable {
    let jid: String
    let displayName: String
    let requestedAt: Int64
    var failureCode: Int?
    var id: String { jid }
}

@MainActor
@Observable
final class PendingRequestsSectionModel {
    let chatJID: String
    var requests: [PendingRequestRow] = []
    var inFlightJIDs: Set<String> = []
    var bulkInFlight: Bool = false
    var error: String?

    private let updater: RequestUpdater
    private let store: JoinRequestStore

    init(chatJID: String, updater: RequestUpdater, store: JoinRequestStore) {
        self.chatJID = chatJID
        self.updater = updater
        self.store = store
    }

    func approve(jid: String) async { await apply(action: "approve", jids: [jid]) }
    func reject(jid: String) async  { await apply(action: "reject", jids: [jid]) }
    func approveAll() async {
        let all = requests.map(\.jid)
        await apply(action: "approve", jids: all)
    }

    private func apply(action: String, jids: [String]) async {
        if jids.count == 1, let only = jids.first { inFlightJIDs.insert(only) }
        else { bulkInFlight = true }
        defer {
            for j in jids { inFlightJIDs.remove(j) }
            bulkInFlight = false
        }
        do {
            let results = try await Task.detached { [updater, chatJID] in
                try updater.updateGroupJoinRequests(
                    chatJID: chatJID, action: action, jids: jids)
            }.value
            var failed: [String] = []
            for r in results {
                if r.errorCode == nil || r.errorCode == 0 {
                    requests.removeAll { $0.jid == r.jid }
                } else {
                    failed.append(r.jid)
                    if let idx = requests.firstIndex(where: { $0.jid == r.jid }) {
                        requests[idx].failureCode = r.errorCode
                    }
                }
            }
            let applied = jids.count - failed.count
            if applied > 0 { store.decrement(chatJID: chatJID, by: applied) }
            error = failed.isEmpty
                ? nil
                : "Couldn't apply \(failed.count) of \(jids.count)"
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git commit -m "PendingRequestsSectionModel: approve/reject + bulk approveAll"
```

---

### Task 27: `PendingRequestsSection` view + ChatInfoView host

**Files:**
- Create: `yawac/Views/PendingRequestsSection.swift`
- Modify: `yawac/Views/ChatInfoView.swift`

- [ ] **Step 1: Implement the view**

```swift
import SwiftUI

struct PendingRequestsSection: View {
    @Bindable var model: PendingRequestsSectionModel
    let displayName: (String) -> String
    let formatter: RelativeDateTimeFormatter

    init(model: PendingRequestsSectionModel,
         displayName: @escaping (String) -> String) {
        self.model = model
        self.displayName = displayName
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        self.formatter = f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PENDING REQUESTS (\(model.requests.count))")
                    .scaledUI(10, weight: .semibold)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                if model.requests.count > 1 {
                    Button("Approve all \(model.requests.count)") {
                        Task { await model.approveAll() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.bulkInFlight)
                }
            }
            if let err = model.error {
                Text(err).foregroundStyle(.red).scaledUI(11)
            }
            ForEach(model.requests) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(row.jid))
                        Text("requested \(formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(row.requestedAt)), relativeTo: Date()))")
                            .foregroundStyle(.secondary).scaledUI(11)
                        if let code = row.failureCode {
                            Text("⚠ couldn't apply (code \(code))")
                                .foregroundStyle(.red).scaledUI(11)
                        }
                    }
                    Spacer()
                    Button(action: { Task { await model.approve(jid: row.jid) } }) {
                        Image(systemName: "checkmark")
                    }
                    .disabled(model.inFlightJIDs.contains(row.jid))
                    Button(action: { Task { await model.reject(jid: row.jid) } }) {
                        Image(systemName: "xmark")
                    }
                    .disabled(model.inFlightJIDs.contains(row.jid))
                }
            }
        }
    }
}
```

- [ ] **Step 2: Host in ChatInfoView**

In `groupBody`, between participants section and leave-group footer:

```swift
if isCurrentUserAdmin(g),
   !g.isCommunityParent,
   g.joinApprovalMode,
   pendingRequestsModel.requests.count > 0 {
    PendingRequestsSection(
        model: pendingRequestsModel,
        displayName: { jid in session.contactNames[jid] ?? jid }
    )
}
```

Add `@State private var pendingRequestsModel = PendingRequestsSectionModel(...)`
(or build it lazily in `.task`). On `loadGroup()`, hydrate the
model:

```swift
.task(id: g.jid) {
    if isCurrentUserAdmin(g), g.joinApprovalMode {
        do {
            let rows = try session.client.getGroupJoinRequests(chatJID: g.jid)
            pendingRequestsModel.requests = rows.map { r in
                PendingRequestRow(
                    jid: r.jid,
                    displayName: session.contactNames[r.jid] ?? r.jid,
                    requestedAt: r.requestedAt
                )
            }
            session.joinRequestStore.set(chatJID: g.jid, count: rows.count)
        } catch {
            // silent — keep prior view of requests
        }
    }
}
```

> **Note:** `session.joinRequestStore.set(_:count:)` is an internal
> setter — make sure it stays accessible from this file's module.
> If kept private, expose a `func update(chatJID:count:)` instead.

- [ ] **Step 3: Build**

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/PendingRequestsSection.swift yawac/Views/ChatInfoView.swift
git commit -m "PendingRequestsSection: in-info admin queue with bulk approve"
```

---

### Task 28: Sidebar pending chip

**Files:**
- Modify: `yawac/Views/ChatListView.swift`

- [ ] **Step 1: Locate the chat-row builder + unread chip**

```bash
grep -n "unread\|unreadCount\|UnreadChip\|chatRow" yawac/Views/ChatListView.swift
```

- [ ] **Step 2: Add the pending chip beside unread**

```swift
if let pending = session.joinRequestStore.counts[chat.jid],
   pending > 0,
   chat.amAdmin {
    HStack(spacing: 2) {
        Image(systemName: "checkmark.circle")
            .scaledIcon(9, weight: .medium)
        Text("\(pending)")
            .scaledMono(10, weight: .medium)
    }
    .padding(.horizontal, 5).padding(.vertical, 1)
    .background(Theme.accent.opacity(0.25), in: Capsule())
    .foregroundStyle(Theme.text)
}
```

> **Note for engineer:** `chat.amAdmin` is the same spec-assumed
> flag as in Task 14. Source from the canonical Chat row state.
> `Theme.accent` may not exist — use whatever sidebar-tint constant
> already styles the unread chip.

- [ ] **Step 3: Build + manual visual check**

- [ ] **Step 4: Commit**

```bash
git commit -m "ChatListView: pending-request chip alongside unread chip"
```

---

## Milestone F — ChatListViewModel wire-up

### Task 29: Extend `GroupInfoChanged` mapping + `pendingRequestsChip` helper + tests

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift`
- Modify: `yawacTests/ChatListViewModelTests.swift`

- [ ] **Step 1: Locate event handlers**

```bash
grep -n "case .groupInfoChanged\|case .joinApprovalModeChanged\|applyGroupParticipantsChange" yawac/ViewModels/ChatListViewModel.swift
```

- [ ] **Step 2: Write the failing tests**

Append to `ChatListViewModelTests.swift`:

```swift
func testGroupInfoChangedPopulatesCommunityFields() {
    let vm = ChatListViewModel.testFixture(chats: [
        .stub(jid: "x@g.us")
    ])
    vm.handle(event: .groupInfoChanged(
        chatJID: "x@g.us",
        name: nil, topic: nil,
        linkedParentJID: "parent@g.us",
        isDefaultSubGroup: true,
        actorJID: "", timestamp: 1
    ))
    let updated = vm.chats.first(where: { $0.jid == "x@g.us" })!
    XCTAssertEqual(updated.communityParentJID, "parent@g.us")
    XCTAssertTrue(updated.isDefaultSubGroup)
}

func testJoinApprovalModeChangedOffClearsStoreEntry() async {
    let store = JoinRequestStore()
    store.set(chatJID: "x@g.us", count: 3)
    let vm = ChatListViewModel.testFixture(joinRequestStore: store)
    await vm.handleAsync(event: .joinApprovalModeChanged(
        chatJID: "x@g.us", on: false, actorJID: "", timestamp: 1))
    XCTAssertNil(store.counts["x@g.us"])
}
```

> **Note:** the helpers `.testFixture` / `.stub` / `handle(event:)` /
> `handleAsync(event:)` are spec-assumed and may need to be added in
> a test-helpers file. If existing ChatListViewModelTests pass
> events through a different entry point, route the new tests
> through that same pattern.

- [ ] **Step 3: Run, verify failure**

- [ ] **Step 4: Extend the event handlers + add the helper**

In the event switch where `.groupInfoChanged` is handled:

```swift
case .groupInfoChanged(let chatJID, let name, let topic,
                       let linkedParentJID, let isDefaultSubGroup,
                       _, _):
    updateChat(jid: chatJID) { chat in
        if let name { chat.name = name }
        if let topic { chat.topic = topic }
        chat.communityParentJID = linkedParentJID.isEmpty ? nil : linkedParentJID
        chat.isDefaultSubGroup = isDefaultSubGroup
    }
```

> **Note:** the existing `.groupInfoChanged` arm probably has fewer
> associated values. After Task 12 + Task 8 land, the Event case
> already includes the new payload fields. Extend the destructure
> here to consume them.

For `.joinApprovalModeChanged`:

```swift
case .joinApprovalModeChanged(let chatJID, let on, _, _):
    updateChat(jid: chatJID) { $0.joinApprovalMode = on }
    if !on {
        session.joinRequestStore.clear(chatJID: chatJID)
    } else {
        Task { await session.joinRequestStore.refresh(chatJID: chatJID) }
    }
```

Add the helper:

```swift
func pendingRequestsChip(for chat: Chat) -> Int? {
    guard chat.amAdmin else { return nil }
    let n = session.joinRequestStore.counts[chat.jid] ?? 0
    return n > 0 ? n : nil
}
```

> **Note:** if `Chat` doesn't have `joinApprovalMode` /
> `communityParentJID` / `isDefaultSubGroup` / `amAdmin` fields,
> add them as part of this task. Default `false` / `nil`. Persist
> the same way the existing `isCommunityParent` field is persisted.

- [ ] **Step 5: Run, verify pass**

- [ ] **Step 6: Commit**

```bash
git add yawac/ViewModels/ChatListViewModel.swift yawacTests/ChatListViewModelTests.swift
git commit -m "ChatListVM: route GroupInfo community fields + JoinApprovalMode event"
```

---

## Milestone G — Docs + release polish

### Task 30: Update README + ROADMAP + bump version

**Files:**
- Modify: `README.md`
- Modify: `docs/ROADMAP.md`
- Modify: `yawac/Info.plist`

- [ ] **Step 1: README — add Groups/Communities bullet**

Search for the Groups section. Add:

```markdown
- **Create groups + communities + sub-groups** from the sidebar +
  menu and from a community parent's info pane.
- **Community admin** — link / unlink existing groups, toggle
  "require admin approval to join", review and approve / reject
  pending join requests with a sidebar pending-count chip.
```

- [ ] **Step 2: ROADMAP — flip Communities entry**

In `docs/ROADMAP.md`, change:

```markdown
- ◐ **Communities** — parent / sub-group display done; sub-group
  directory + best-effort join (via invite link, surfaces
  approval-pending state) shipped. Missing: admin actions
  (link/unlink sub-groups, approve member requests).
```

to:

```markdown
- ✅ **Communities** — parent / sub-group display + directory +
  best-effort join shipped earlier; admin actions (link / unlink
  sub-groups, approve / reject join requests with sidebar pending
  chip, approval-mode toggle) and create-new-group / create-new-
  community / create-new-sub-group flows shipped in v0.7.0.
```

- [ ] **Step 3: Bump `CFBundleShortVersionString`**

In `yawac/Info.plist`, change `0.6.0` to `0.7.0`.

- [ ] **Step 4: Final full test pass**

```bash
cd bridge && go test -short ./...
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/ROADMAP.md yawac/Info.plist
git commit -m "release: 0.7.0 — community admin + group/community/sub-group creation"
```

---

## Manual smoke (post-implementation)

Run before tagging the release. Covers the spec's release runbook.

- [ ] Sidebar "+" → New group → name + 2 contacts → Create → new chat appears at top; same group appears on phone within ~3s.
- [ ] "+" → New community → name → Create → community parent appears; open it → LINKED GROUPS shows the auto-created announcements default sub-group within ~3s.
- [ ] In the new community's info → LINKED GROUPS "+" → Create new sub-group → name + 2 contacts → Create → row appears under LINKED GROUPS + own chat in sidebar.
- [ ] Name > 25 chars: Create stays disabled; char counter red.
- [ ] In a community parent (admin): "+" → Link existing group → pick a non-community admin'd group → row appears in LINKED GROUPS + phone reflects.
- [ ] Pick a group already in another community → confirmation dialog quotes both names → confirm → moves.
- [ ] Default sub-group row has no Unlink ctx item. Non-default linked sub-group → Unlink → vanishes; phone reflects.
- [ ] As sub-group admin: toggle "Require admin approval" → on. From a second account: join via invite link → "Request sent — waiting for admin approval". Admin's yawac: sidebar chip "1" appears within 30s of foreground OR on next info open.
- [ ] Open chat info → PENDING REQUESTS shows the request → ✓ → row removed, chip decrements, second account's chat unlocks.
- [ ] ✗ on a second request → row removed; second account sees no group join.
- [ ] Approve all with 3 pending: all dropped at once.
- [ ] Mode off → PENDING section disappears; chip clears.
- [ ] Flip mode on phone → toggle in yawac reflects within ~1s.

---

## Closing notes for the engineer

- Several specs have **"Note for engineer"** callouts where upstream
  whatsmeow field names are inferred from documentation. Verify against
  the actual whatsmeow source in
  `$(go env GOMODCACHE)/github.com/vadika/whatsmeow@*/group.go` before
  committing the Go changes; adapt code + tests if any signature drifts.
- Several Swift tasks reference helpers (`session.client`,
  `session.chatList?.requestSelectChat`, `BridgeGroupModel.stub`, etc.)
  that follow existing patterns. Use `grep` to find the canonical
  accessor before introducing new ones — preserve existing conventions.
- Each task ends with a commit; do not batch. If a task fails to
  build, fix it before moving on.
- If you discover a missing field on `Chat` (`joinApprovalMode`,
  `amAdmin`, `communityParentJID`, `isDefaultSubGroup`) early in
  Milestone E or F, add them as a side-task before continuing; do not
  paper over by hardcoding `false`.
