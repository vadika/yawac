# Group Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship live participant add/remove/promote/demote, group avatar edit, and invite-link/QR/paste-to-join from `ChatInfoView` and the ⌘K sidebar search.

**Architecture:** Five new gomobile-bindable Go funcs in `bridge/groups.go`, one new dispatched event (`GroupParticipantsChanged`) split out of `events.GroupInfo`, three new SwiftUI surfaces hung off `ChatInfoView` (inline picker panel, modal avatar crop sheet, modal invite-link sheet), and a ⌘K hook that previews + joins invite links. Local actions update view-model state from the bridge return value; the same event then arrives via `events.GroupInfo` and triggers a no-op reload — phone/peer-companion changes go through the same path.

**Tech Stack:** Go 1.22 + whatsmeow (`tulir/whatsmeow` vadika fork), gomobile-built `Bridge.xcframework`, SwiftUI on macOS 14+, `CIFilter.qrCodeGenerator` for QR rendering, `NSSharingServicePicker` for share, `CoreImage` + `NSBitmapImageRep` for avatar crop.

**Reference spec:** `docs/superpowers/specs/2026-06-02-group-management-design.md`.

---

## Background context for the engineer

- `bridge/` is a Go package compiled via `gomobile bind` into `build/Bridge.xcframework`. Exported methods MUST take only gomobile-friendly types: `string`, `int`, `int32`, `int64`, `bool`, `[]byte`, and pointers to single-value structs. Slices of complex types are NOT bindable — pass them as JSON strings. See `docs/DEVELOPMENT.md` and the existing `bridge/groups.go` for the established pattern.
- Swift bridge wrappers live in `yawac/Bridge/WAClient.swift`. They encode `[String]` args as JSON, throw on `NSError` out-params, and decode results via `JSONDecoder`. `@MainActor` is the default; mark blocking I/O `nonisolated` so it can run off-main.
- Bridge events arrive via `bridge/events.go` `handleWAEvent`, which switches on the whatsmeow `events.*` type and calls a `dispatch<Name>` helper that marshals a `J<Name>` struct and calls `c.dispatch(kind, payload)`. The Swift side decodes in `WAClient.decode(kind:payload:)` and yields the `Event` enum into the main bus consumed by `ContentView`.
- `ChatInfoView` is the entire group inspector — `yawac/Views/GroupInfoView.swift` is a dead stub that we delete in this plan.
- Admin gating lives at `ChatInfoView.isCurrentUserAdmin(_:)` — already handles LID↔PN identity via `JIDNormalize.canonical`. Reuse, do not duplicate.
- The existing `joinSubGroup` flow in `ChatInfoView` is a template for the "joined OR queued-for-approval" dual-return handling we use for `JoinGroupViaLink`.

After every Go bridge change, rebuild the framework before Swift can see the new symbols:

```bash
./scripts/build-xcframework.sh
```

After Swift-only changes use:

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
    -destination 'platform=macOS' build \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Run Go tests with:

```bash
cd bridge && go test -short ./...
```

Run Swift tests with:

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
    -destination 'platform=macOS' test \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

---

## File map

**New:**
- `yawac/Utilities/InviteLink.swift` — pure invite-link URL parser.
- `yawac/Views/AddParticipantsPanel.swift` — inline picker panel (chips + search + suggestions + result strip).
- `yawac/ViewModels/AddParticipantsPanelModel.swift` — `@Observable` model for the panel.
- `yawac/Views/AvatarCropSheet.swift` — modal sheet wrapping `NSViewRepresentable` crop view.
- `yawac/Views/InviteLinkSheet.swift` — modal sheet with QR + link + actions.
- `yawacTests/InviteLinkParserTests.swift`
- `yawacTests/AddParticipantsPanelModelTests.swift`
- `yawacTests/ChatListViewModelGroupParticipantsTests.swift`

**Modified:**
- `bridge/groups.go` — extend `JParticipant`; five new exported methods.
- `bridge/jsonmodels.go` — new `JGroupParticipantsChanged`.
- `bridge/events.go` — new `dispatchGroupParticipants`; `events.GroupInfo` arm calls both dispatchers.
- `bridge/groups_test.go` — add new cases.
- `bridge/events_dispatch_test.go` — add new cases.
- `yawac/Bridge/JSONModels.swift` — three optional fields on `BridgeParticipantModel`.
- `yawac/Bridge/WAClient.swift` — five new wrappers; new `Event.groupParticipantsChanged` case; new decode arm.
- `yawac/ViewModels/ChatListViewModel.swift` — `applyGroupParticipantsChange` (sentinel for observers), `inviteLinkPreview` state + parser hook.
- `yawac/ViewModels/ChatSearchViewModel.swift` — invite-link preview branch on query change.
- `yawac/Views/ChatInfoView.swift` — "+ Add member" section-header button + panel mounting; participant ctx-menu admin items; hero hover overlay + avatar-change/remove actions; action-row Invite icon + sheet; two new `confirmationDialog`s; listener for `groupParticipantsChanged`.
- `yawac/Views/ChatListView.swift` — render `inviteLinkPreview` row at top of search results.
- `yawac/ContentView.swift` — event arm for `.groupParticipantsChanged`.
- `README.md` — feature bullets.
- `docs/ROADMAP.md` — mark shipped after merge.

**Deleted:**
- `yawac/Views/GroupInfoView.swift` (dead stub).

---

## Phase 1 — Bridge Go: data model + participant update

### Task 1: Extend `JParticipant` with optional error fields

**Files:**
- Modify: `bridge/groups.go:28-33` (the `JParticipant` struct).

- [ ] **Step 1: Replace the struct**

Replace the existing `JParticipant` definition:

```go
// JParticipant represents a single member of a group, optionally
// carrying a per-row error code returned by UpdateGroupParticipants.
// When ErrorCode is non-zero and the server queued an invite-via-DM
// as fallback (privacy-block case), InviteCode + InviteExpiry are
// populated so the caller can render "invite sent, pending acceptance".
type JParticipant struct {
    JID          string `json:"jid"`
    IsAdmin      bool   `json:"is_admin"`
    IsSuper      bool   `json:"is_super_admin"`
    ErrorCode    int    `json:"error_code,omitempty"`
    InviteCode   string `json:"invite_code,omitempty"`
    InviteExpiry int64  `json:"invite_expiry,omitempty"`
}
```

- [ ] **Step 2: Build the package**

Run: `cd bridge && go build ./...`
Expected: PASS (no errors). The struct is backwards-compatible — existing code reads `JID`, `IsAdmin`, `IsSuper`; the new fields are optional and serialize away when zero.

- [ ] **Step 3: Run existing group tests**

Run: `cd bridge && go test -short -run TestListGroups ./...`
Expected: PASS or `SKIP` (unpaired client).

- [ ] **Step 4: Commit**

```bash
git add bridge/groups.go
git commit -m "bridge: JParticipant carries per-row error + invite fallback fields"
```

### Task 2: Add `UpdateGroupParticipants`

**Files:**
- Modify: `bridge/groups.go` (append after `LeaveGroup`).
- Test: `bridge/groups_test.go` (extend).

- [ ] **Step 1: Add the failing test**

Append to `bridge/groups_test.go`:

```go
func TestUpdateGroupParticipantsActionMapping(t *testing.T) {
    cases := []struct {
        in   string
        want whatsmeow.ParticipantChange
        ok   bool
    }{
        {"add", whatsmeow.ParticipantChangeAdd, true},
        {"remove", whatsmeow.ParticipantChangeRemove, true},
        {"promote", whatsmeow.ParticipantChangePromote, true},
        {"demote", whatsmeow.ParticipantChangeDemote, true},
        {"banish", "", false},
        {"", "", false},
    }
    for _, c := range cases {
        got, err := participantChangeFromString(c.in)
        if c.ok && (err != nil || got != c.want) {
            t.Fatalf("%q: got (%q,%v) want (%q,nil)", c.in, got, err, c.want)
        }
        if !c.ok && err == nil {
            t.Fatalf("%q: expected error, got nil", c.in)
        }
    }
}
```

Add the import at the top of the test file if missing:

```go
import (
    ...
    "go.mau.fi/whatsmeow"
)
```

- [ ] **Step 2: Run the test, expect FAIL**

Run: `cd bridge && go test -run TestUpdateGroupParticipantsActionMapping ./...`
Expected: FAIL — `undefined: participantChangeFromString`.

- [ ] **Step 3: Implement the helper + the exported method**

Append to `bridge/groups.go`:

```go
func participantChangeFromString(s string) (whatsmeow.ParticipantChange, error) {
    switch s {
    case "add":
        return whatsmeow.ParticipantChangeAdd, nil
    case "remove":
        return whatsmeow.ParticipantChangeRemove, nil
    case "promote":
        return whatsmeow.ParticipantChangePromote, nil
    case "demote":
        return whatsmeow.ParticipantChangeDemote, nil
    default:
        return "", fmt.Errorf("unknown participant action %q", s)
    }
}

// UpdateGroupParticipants applies one of "add" / "remove" / "promote" /
// "demote" to a batch of participant JIDs in `chatJID`. participantJIDsJSON
// is a JSON `[]string`. Returns a JSON `[]JParticipant` of the server's
// response (the changed rows only — caller merges into the local roster).
// Per-row failures (privacy block, invalid JID) surface via JParticipant
// ErrorCode + InviteCode + InviteExpiry rather than a method-level error.
func (c *Client) UpdateGroupParticipants(
    chatJID, action, participantJIDsJSON string,
) (string, error) {
    if c.wa == nil {
        return "", errors.New("client closed")
    }
    chat, err := types.ParseJID(chatJID)
    if err != nil {
        return "", fmt.Errorf("parse chat jid: %w", err)
    }
    act, err := participantChangeFromString(action)
    if err != nil {
        return "", err
    }
    var raw []string
    if err := json.Unmarshal([]byte(participantJIDsJSON), &raw); err != nil {
        return "", fmt.Errorf("parse jids: %w", err)
    }
    parsed := make([]types.JID, 0, len(raw))
    for _, s := range raw {
        j, err := types.ParseJID(s)
        if err != nil {
            return "", fmt.Errorf("parse %q: %w", s, err)
        }
        parsed = append(parsed, j)
    }
    resp, err := c.wa.UpdateGroupParticipants(context.Background(),
        chat, parsed, act)
    if err != nil {
        return "", fmt.Errorf("update participants: %w", err)
    }
    out := make([]JParticipant, 0, len(resp))
    for _, p := range resp {
        jp := JParticipant{
            JID:     p.JID.String(),
            IsAdmin: p.IsAdmin,
            IsSuper: p.IsSuperAdmin,
        }
        if p.Error != 0 {
            jp.ErrorCode = p.Error
            if p.AddRequest != nil {
                jp.InviteCode = p.AddRequest.Code
                jp.InviteExpiry = p.AddRequest.Expiration.Unix()
            }
        }
        out = append(out, jp)
    }
    b, _ := json.Marshal(out)
    return string(b), nil
}
```

- [ ] **Step 4: Run the action-mapping test, expect PASS**

Run: `cd bridge && go test -run TestUpdateGroupParticipantsActionMapping ./...`
Expected: PASS.

- [ ] **Step 5: Add the unpaired-client smoke**

Append:

```go
func TestUpdateGroupParticipantsUnpaired(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/u.db")
    defer c.Close()
    _, err := c.UpdateGroupParticipants(
        "1234@g.us", "add",
        `["1111@s.whatsapp.net"]`)
    if err == nil {
        t.Fatal("expected error on unpaired client")
    }
}
```

- [ ] **Step 6: Run the smoke, expect PASS**

Run: `cd bridge && go test -run TestUpdateGroupParticipantsUnpaired ./...`
Expected: PASS (returns an error from whatsmeow's "not logged in" check).

- [ ] **Step 7: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: UpdateGroupParticipants (add/remove/promote/demote)"
```

---

## Phase 2 — Bridge Go: avatar + invite

### Task 3: Add `SetGroupPhoto` + `RemoveGroupPhoto`

**Files:**
- Modify: `bridge/groups.go` (append).
- Test: `bridge/groups_test.go` (extend).

- [ ] **Step 1: Add the test**

Append:

```go
func TestSetGroupPhotoUnpaired(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/sp.db")
    defer c.Close()
    _, err := c.SetGroupPhoto("1234@g.us", []byte{0xff, 0xd8, 0xff})
    if err == nil {
        t.Fatal("expected error on unpaired client")
    }
}

func TestRemoveGroupPhotoUnpaired(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/rp.db")
    defer c.Close()
    err := c.RemoveGroupPhoto("1234@g.us")
    if err == nil {
        t.Fatal("expected error on unpaired client")
    }
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `cd bridge && go test -run "TestSetGroupPhotoUnpaired|TestRemoveGroupPhotoUnpaired" ./...`
Expected: FAIL — methods not defined.

- [ ] **Step 3: Implement**

Append to `bridge/groups.go`:

```go
// SetGroupPhoto uploads `jpeg` bytes as the group's picture. Returns the
// new picture ID. Surfaces whatsmeow.ErrInvalidImageFormat verbatim when
// the bytes aren't a JPEG the server accepts.
func (c *Client) SetGroupPhoto(chatJID string, jpeg []byte) (string, error) {
    if c.wa == nil {
        return "", errors.New("client closed")
    }
    jid, err := types.ParseJID(chatJID)
    if err != nil {
        return "", fmt.Errorf("parse jid: %w", err)
    }
    pictureID, err := c.wa.SetGroupPhoto(context.Background(), jid, jpeg)
    if err != nil {
        return "", fmt.Errorf("set photo: %w", err)
    }
    return pictureID, nil
}

// RemoveGroupPhoto clears the group's picture. Equivalent to SetGroupPhoto
// with nil bytes per whatsmeow's contract.
func (c *Client) RemoveGroupPhoto(chatJID string) error {
    if c.wa == nil {
        return errors.New("client closed")
    }
    jid, err := types.ParseJID(chatJID)
    if err != nil {
        return fmt.Errorf("parse jid: %w", err)
    }
    _, err = c.wa.SetGroupPhoto(context.Background(), jid, nil)
    if err != nil {
        return fmt.Errorf("remove photo: %w", err)
    }
    return nil
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `cd bridge && go test -run "TestSetGroupPhotoUnpaired|TestRemoveGroupPhotoUnpaired" ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: SetGroupPhoto + RemoveGroupPhoto"
```

### Task 4: Add `GetGroupInviteLink`

**Files:**
- Modify: `bridge/groups.go` (append).
- Test: `bridge/groups_test.go` (extend).

- [ ] **Step 1: Add the test**

Append:

```go
func TestGetGroupInviteLinkUnpaired(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/il.db")
    defer c.Close()
    _, err := c.GetGroupInviteLink("1234@g.us", false)
    if err == nil {
        t.Fatal("expected error on unpaired client")
    }
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `cd bridge && go test -run TestGetGroupInviteLinkUnpaired ./...`
Expected: FAIL — method not defined.

- [ ] **Step 3: Implement**

Append:

```go
// GetGroupInviteLink returns the full `https://chat.whatsapp.com/<code>`.
// reset=true revokes the prior link before issuing the new one. Surfaces
// whatsmeow's ErrGroupInviteLinkUnauthorized / ErrGroupNotFound /
// ErrNotInGroup verbatim — the caller renders the localized message.
func (c *Client) GetGroupInviteLink(chatJID string, reset bool) (string, error) {
    if c.wa == nil {
        return "", errors.New("client closed")
    }
    jid, err := types.ParseJID(chatJID)
    if err != nil {
        return "", fmt.Errorf("parse jid: %w", err)
    }
    link, err := c.wa.GetGroupInviteLink(context.Background(), jid, reset)
    if err != nil {
        return "", fmt.Errorf("get invite link: %w", err)
    }
    return link, nil
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `cd bridge && go test -run TestGetGroupInviteLinkUnpaired ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: GetGroupInviteLink (get + reset)"
```

### Task 5: Add `GroupInfoFromLink` + `JoinGroupViaLink`

**Files:**
- Modify: `bridge/groups.go` (append).
- Test: `bridge/groups_test.go` (extend).

- [ ] **Step 1: Add the helper + tests**

Append to `bridge/groups_test.go`:

```go
func TestStripInviteCodePrefix(t *testing.T) {
    cases := []struct{ in, want string }{
        {"AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
        {"chat.whatsapp.com/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
        {"https://chat.whatsapp.com/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
        {"http://chat.whatsapp.com/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
        {"wa.me/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
        {"https://wa.me/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
    }
    for _, c := range cases {
        if got := stripInviteCodePrefix(c.in); got != c.want {
            t.Errorf("strip(%q)=%q want %q", c.in, got, c.want)
        }
    }
}

func TestGroupInfoFromLinkUnpaired(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/gi.db")
    defer c.Close()
    _, err := c.GroupInfoFromLink("AbCdEfGhIjKlMn")
    if err == nil {
        t.Fatal("expected error on unpaired client")
    }
}

func TestJoinGroupViaLinkUnpaired(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/jl.db")
    defer c.Close()
    _, err := c.JoinGroupViaLink("AbCdEfGhIjKlMn")
    if err == nil {
        t.Fatal("expected error on unpaired client")
    }
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `cd bridge && go test -run "TestStripInviteCodePrefix|TestGroupInfoFromLinkUnpaired|TestJoinGroupViaLinkUnpaired" ./...`
Expected: FAIL — helper + methods not defined.

- [ ] **Step 3: Implement**

Append to `bridge/groups.go`:

```go
// stripInviteCodePrefix accepts any of:
//   https://chat.whatsapp.com/<code>, http://chat.whatsapp.com/<code>,
//   chat.whatsapp.com/<code>, https://wa.me/<code>, wa.me/<code>,
//   bare <code>.
// Returns the bare code. Defence-in-depth — the Swift parser already
// strips the prefix; we strip again here so the bridge can be called
// directly from tests or future surfaces without the cleanup.
func stripInviteCodePrefix(s string) string {
    s = strings.TrimPrefix(s, "https://")
    s = strings.TrimPrefix(s, "http://")
    s = strings.TrimPrefix(s, "chat.whatsapp.com/")
    s = strings.TrimPrefix(s, "wa.me/")
    return s
}

// GroupInfoFromLink resolves an invite link (URL or bare code) into a
// JGroup preview WITHOUT joining the group. Participants list is
// always empty in the response. Surfaces ErrInviteLinkRevoked /
// ErrInviteLinkInvalid verbatim.
func (c *Client) GroupInfoFromLink(code string) (string, error) {
    if c.wa == nil {
        return "", errors.New("client closed")
    }
    info, err := c.wa.GetGroupInfoFromLink(
        context.Background(), stripInviteCodePrefix(code))
    if err != nil {
        return "", fmt.Errorf("group info from link: %w", err)
    }
    jg := JGroup{
        JID:               info.JID.String(),
        Name:              info.Name,
        Topic:             info.Topic,
        OwnerJID:          info.OwnerJID.String(),
        Created:           info.GroupCreated.Unix(),
        IsParent:          info.GroupParent.IsParent,
        LinkedParentJID:   info.GroupLinkedParent.LinkedParentJID.String(),
        IsDefaultSubGroup: info.GroupIsDefaultSub.IsDefaultSubGroup,
        Participants:      []JParticipant{}, // intentionally empty
    }
    if !strings.HasSuffix(jg.LinkedParentJID, "@g.us") {
        jg.LinkedParentJID = ""
    }
    b, _ := json.Marshal(jg)
    return string(b), nil
}

// JoinGroupViaLink joins via an invite link (URL or bare code).
// Returns the joined JID. Dual return semantics: a bare JID alone can
// mean the server queued a membership_approval_request — caller probes
// via GetGroupInfo to distinguish the joined case from "pending".
func (c *Client) JoinGroupViaLink(code string) (string, error) {
    if c.wa == nil {
        return "", errors.New("client closed")
    }
    jid, err := c.wa.JoinGroupWithLink(
        context.Background(), stripInviteCodePrefix(code))
    if err != nil {
        return "", fmt.Errorf("join via link: %w", err)
    }
    return jid.String(), nil
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `cd bridge && go test -run "TestStripInviteCodePrefix|TestGroupInfoFromLinkUnpaired|TestJoinGroupViaLinkUnpaired" ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/groups.go bridge/groups_test.go
git commit -m "bridge: GroupInfoFromLink + JoinGroupViaLink (with prefix stripper)"
```

---

## Phase 3 — Bridge Go: participant-change event

### Task 6: Add `JGroupParticipantsChanged` model

**Files:**
- Modify: `bridge/jsonmodels.go` (append).

- [ ] **Step 1: Append the struct**

Add to `bridge/jsonmodels.go` after `JGroupInfoChanged`:

```go
// JGroupParticipantsChanged carries a single action verb (add / remove /
// promote / demote) and the affected participant JIDs. A single
// whatsmeow events.GroupInfo can carry more than one — the dispatcher
// emits one of these per non-empty slice.
type JGroupParticipantsChanged struct {
    ChatJID   string   `json:"chat_jid"`
    Action    string   `json:"action"`
    ActorJID  string   `json:"actor_jid,omitempty"`
    JIDs      []string `json:"jids"`
    Timestamp int64    `json:"timestamp"`
}
```

- [ ] **Step 2: Build**

Run: `cd bridge && go build ./...`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add bridge/jsonmodels.go
git commit -m "bridge: JGroupParticipantsChanged JSON model"
```

### Task 7: Add `dispatchGroupParticipants` + wire the event arm

**Files:**
- Modify: `bridge/events.go` (extend the `events.GroupInfo` switch arm; add the new dispatcher).
- Test: `bridge/events_dispatch_test.go` (extend).

- [ ] **Step 1: Add the failing tests**

Append to `bridge/events_dispatch_test.go`:

```go
func TestDispatchGroupParticipantsAddOnly(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/gp1.db")
    defer c.Close()
    sink := newRecSink()
    c.SetEventSink(sink)
    chat, _ := types.ParseJID("123@g.us")
    sender, _ := types.ParseJID("999@s.whatsapp.net")
    j1, _ := types.ParseJID("1@s.whatsapp.net")
    j2, _ := types.ParseJID("2@s.whatsapp.net")
    c.dispatchGroupParticipants(&events.GroupInfo{
        JID:       chat,
        Sender:    &sender,
        Join:      []types.JID{j1, j2},
        Timestamp: time.Unix(100, 0),
    })
    e := sink.wait(t, "GroupParticipantsChanged", time.Second)
    var jp JGroupParticipantsChanged
    if err := json.Unmarshal([]byte(e.payload), &jp); err != nil {
        t.Fatal(err)
    }
    if jp.Action != "add" || len(jp.JIDs) != 2 ||
        jp.ChatJID != "123@g.us" || jp.ActorJID != "999@s.whatsapp.net" ||
        jp.Timestamp != 100 {
        t.Fatalf("bad payload: %+v", jp)
    }
}

func TestDispatchGroupParticipantsAllFourActions(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/gp2.db")
    defer c.Close()
    sink := newRecSink()
    c.SetEventSink(sink)
    chat, _ := types.ParseJID("123@g.us")
    j1, _ := types.ParseJID("1@s.whatsapp.net")
    c.dispatchGroupParticipants(&events.GroupInfo{
        JID:       chat,
        Join:      []types.JID{j1},
        Leave:     []types.JID{j1},
        Promote:   []types.JID{j1},
        Demote:    []types.JID{j1},
        Timestamp: time.Unix(7, 0),
    })
    actions := map[string]bool{}
    for i := 0; i < 4; i++ {
        e := sink.wait(t, "GroupParticipantsChanged", time.Second)
        var jp JGroupParticipantsChanged
        if err := json.Unmarshal([]byte(e.payload), &jp); err != nil {
            t.Fatal(err)
        }
        actions[jp.Action] = true
    }
    for _, k := range []string{"add", "remove", "promote", "demote"} {
        if !actions[k] {
            t.Fatalf("missing action %q in %v", k, actions)
        }
    }
}

func TestDispatchGroupParticipantsNoSender(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/gp3.db")
    defer c.Close()
    sink := newRecSink()
    c.SetEventSink(sink)
    chat, _ := types.ParseJID("123@g.us")
    j1, _ := types.ParseJID("1@s.whatsapp.net")
    c.dispatchGroupParticipants(&events.GroupInfo{
        JID:       chat,
        Join:      []types.JID{j1},
        Timestamp: time.Unix(1, 0),
    })
    e := sink.wait(t, "GroupParticipantsChanged", time.Second)
    var jp JGroupParticipantsChanged
    if err := json.Unmarshal([]byte(e.payload), &jp); err != nil {
        t.Fatal(err)
    }
    if jp.ActorJID != "" {
        t.Fatalf("expected empty ActorJID, got %q", jp.ActorJID)
    }
}

func TestDispatchGroupParticipantsEmptyAllNoEvents(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/gp4.db")
    defer c.Close()
    sink := newRecSink()
    c.SetEventSink(sink)
    chat, _ := types.ParseJID("123@g.us")
    c.dispatchGroupParticipants(&events.GroupInfo{
        JID: chat, Timestamp: time.Unix(1, 0),
    })
    select {
    case e := <-sink.ch:
        t.Fatalf("expected no events, got %+v", e)
    case <-time.After(100 * time.Millisecond):
    }
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `cd bridge && go test -run "TestDispatchGroupParticipants" ./...`
Expected: FAIL — `dispatchGroupParticipants` undefined.

- [ ] **Step 3: Implement `dispatchGroupParticipants`**

Append to `bridge/events.go`:

```go
// dispatchGroupParticipants splits a single events.GroupInfo into up to
// four GroupParticipantsChanged events, one per non-empty Join / Leave
// / Promote / Demote slice. Skips emit when every slice is empty. Sender
// JID populates ActorJID; missing sender → "".
func (c *Client) dispatchGroupParticipants(evt *events.GroupInfo) {
    fan := []struct {
        action string
        jids   []types.JID
    }{
        {"add", evt.Join}, {"remove", evt.Leave},
        {"promote", evt.Promote}, {"demote", evt.Demote},
    }
    actor := ""
    if evt.Sender != nil {
        actor = evt.Sender.String()
    }
    for _, f := range fan {
        if len(f.jids) == 0 {
            continue
        }
        out := make([]string, len(f.jids))
        for i, j := range f.jids {
            out[i] = j.String()
        }
        b, _ := json.Marshal(JGroupParticipantsChanged{
            ChatJID:   evt.JID.String(),
            Action:    f.action,
            ActorJID:  actor,
            JIDs:      out,
            Timestamp: evt.Timestamp.Unix(),
        })
        c.dispatch("GroupParticipantsChanged", string(b))
    }
}
```

- [ ] **Step 4: Wire the switch arm**

Locate the existing `case *events.GroupInfo:` in `handleWAEvent` (around `bridge/events.go:73`). Replace the single dispatch with both:

```go
case *events.GroupInfo:
    c.dispatchGroupInfo(v)
    c.dispatchGroupParticipants(v)
```

- [ ] **Step 5: Run, expect PASS**

Run: `cd bridge && go test -run "TestDispatchGroupParticipants" ./...`
Expected: PASS (all four cases).

- [ ] **Step 6: Run the full bridge test suite**

Run: `cd bridge && go test -short ./...`
Expected: PASS (all prior tests still pass).

- [ ] **Step 7: Commit**

```bash
git add bridge/events.go bridge/events_dispatch_test.go
git commit -m "bridge: dispatchGroupParticipants — fan add/remove/promote/demote"
```

---

## Phase 4 — Build xcframework

### Task 8: Rebuild `Bridge.xcframework`

- [ ] **Step 1: Build**

Run: `./scripts/build-xcframework.sh`
Expected: success (5–15 minutes first time, faster after). Output ends with `Bridge.xcframework built`.

- [ ] **Step 2: Verify the new symbols are exported**

Run: `nm build/Bridge.xcframework/macos-arm64/Bridge.framework/Bridge | grep -E "UpdateGroupParticipants|SetGroupPhoto|RemoveGroupPhoto|GetGroupInviteLink|GroupInfoFromLink|JoinGroupViaLink"`
Expected: at least six lines, one per new method.

- [ ] **Step 3: Commit framework if your repo tracks it (check .gitignore first)**

Run: `git status build/`
- If `build/Bridge.xcframework` shows as modified and is **not** ignored → commit it.
- If ignored, skip.

```bash
# Only if tracked:
git add build/Bridge.xcframework
git commit -m "build: rebuild Bridge.xcframework for group-management bridge"
```

---

## Phase 5 — Swift bridge: data model + wrappers

### Task 9: Extend `BridgeParticipantModel`

**Files:**
- Modify: `yawac/Bridge/JSONModels.swift:196-205`.

- [ ] **Step 1: Replace the struct**

```swift
struct BridgeParticipantModel: Codable {
    let jid: String
    let isAdmin: Bool
    let isSuper: Bool
    let errorCode: Int?
    let inviteCode: String?
    let inviteExpiry: Int64?

    enum CodingKeys: String, CodingKey {
        case jid
        case isAdmin = "is_admin"
        case isSuper = "is_super_admin"
        case errorCode = "error_code"
        case inviteCode = "invite_code"
        case inviteExpiry = "invite_expiry"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jid = try c.decode(String.self, forKey: .jid)
        isAdmin = try c.decode(Bool.self, forKey: .isAdmin)
        isSuper = try c.decode(Bool.self, forKey: .isSuper)
        errorCode = try c.decodeIfPresent(Int.self, forKey: .errorCode)
        inviteCode = try c.decodeIfPresent(String.self, forKey: .inviteCode)
        inviteExpiry = try c.decodeIfPresent(Int64.self, forKey: .inviteExpiry)
    }

    init(jid: String, isAdmin: Bool, isSuper: Bool,
         errorCode: Int? = nil, inviteCode: String? = nil,
         inviteExpiry: Int64? = nil) {
        self.jid = jid
        self.isAdmin = isAdmin
        self.isSuper = isSuper
        self.errorCode = errorCode
        self.inviteCode = inviteCode
        self.inviteExpiry = inviteExpiry
    }
}
```

- [ ] **Step 2: Build**

Run the Swift build command from "Background context".
Expected: PASS. (Existing call sites only read `jid`, `isAdmin`, `isSuper`; the new fields are optional.)

- [ ] **Step 3: Commit**

```bash
git add yawac/Bridge/JSONModels.swift
git commit -m "models: BridgeParticipantModel carries error_code + invite fallback"
```

### Task 10: Add `WAClient` wrappers

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`.

- [ ] **Step 1: Add the `Event` case**

In `WAClient.Event` enum (around line 27), add:

```swift
case groupParticipantsChanged(chatJID: String, action: String,
                              actorJID: String, jids: [String],
                              timestamp: Int64)
```

- [ ] **Step 2: Add the decode arm**

In `WAClient.decode(kind:payload:)`, add a new case before `default:`:

```swift
case "GroupParticipantsChanged":
    struct GP: Codable {
        let chatJID: String
        let action: String
        let actorJID: String?
        let jids: [String]
        let timestamp: Int64
        enum CodingKeys: String, CodingKey {
            case chatJID = "chat_jid"
            case action
            case actorJID = "actor_jid"
            case jids, timestamp
        }
    }
    if let g = try? dec.decode(GP.self, from: data) {
        return .groupParticipantsChanged(
            chatJID: g.chatJID, action: g.action,
            actorJID: g.actorJID ?? "",
            jids: g.jids, timestamp: g.timestamp)
    }
```

- [ ] **Step 3: Add the five method wrappers**

Append before the final closing brace of `WAClient`:

```swift
func updateGroupParticipants(chatJID: String,
                             action: String,
                             participantJIDs: [String])
    throws -> [BridgeParticipantModel] {
    let jids = try JSONEncoder().encode(participantJIDs)
    let jidsString = String(data: jids, encoding: .utf8) ?? "[]"
    var err: NSError?
    let json = go.updateGroupParticipants(chatJID,
                                          action: action,
                                          participantJIDsJSON: jidsString,
                                          error: &err)
    if let err { throw err }
    return try JSONDecoder().decode([BridgeParticipantModel].self,
                                    from: Data(json.utf8))
}

func setGroupPhoto(chatJID: String, jpeg: Data) throws -> String {
    var err: NSError?
    let pictureID = go.setGroupPhoto(chatJID, jpeg: jpeg, error: &err)
    if let err { throw err }
    return pictureID
}

nonisolated func removeGroupPhoto(chatJID: String) throws {
    try go.removeGroupPhoto(chatJID)
}

func getGroupInviteLink(chatJID: String, reset: Bool) throws -> String {
    var err: NSError?
    let link = go.getGroupInviteLink(chatJID, reset: reset, error: &err)
    if let err { throw err }
    return link
}

func groupInfoFromLink(code: String) throws -> BridgeGroupModel {
    var err: NSError?
    let json = go.groupInfoFromLink(code, error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(BridgeGroupModel.self,
                                    from: Data(json.utf8))
}

func joinGroupViaLink(code: String) throws -> String {
    var err: NSError?
    let jid = go.joinGroupViaLink(code, error: &err)
    if let err { throw err }
    return jid
}
```

- [ ] **Step 4: Build**

Run the Swift build command.
Expected: PASS. If the `go.<method>` signatures don't match, inspect the generated `Bridge.framework` headers and adjust the labels — gomobile derives Objective-C selectors from Go parameter names.

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "client: wrappers for participants/photo/invite-link + new event case"
```

---

## Phase 6 — Pure helpers (TDD)

### Task 11: Write `InviteLink.parseCode`

**Files:**
- Create: `yawac/Utilities/InviteLink.swift`
- Create: `yawacTests/InviteLinkParserTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `yawacTests/InviteLinkParserTests.swift`:

```swift
import XCTest
@testable import yawac

final class InviteLinkParserTests: XCTestCase {
    func testHttpsChatWhatsapp() {
        XCTAssertEqual(InviteLink.parseCode(
            "https://chat.whatsapp.com/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testHttpChatWhatsapp() {
        XCTAssertEqual(InviteLink.parseCode(
            "http://chat.whatsapp.com/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testBareChatWhatsapp() {
        XCTAssertEqual(InviteLink.parseCode(
            "chat.whatsapp.com/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testHttpsWaMe() {
        XCTAssertEqual(InviteLink.parseCode(
            "https://wa.me/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testBareWaMe() {
        XCTAssertEqual(InviteLink.parseCode(
            "wa.me/AbCdEfGhIjKlMnOpQr"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testBareCodeAccepted() {
        // Real WhatsApp invite codes are 22 chars; 16 is the lower bound.
        XCTAssertEqual(InviteLink.parseCode(
            "AbCdEfGhIjKlMnOpQrSt"), "AbCdEfGhIjKlMnOpQrSt")
    }

    func testShortQueryRejected() {
        XCTAssertNil(InviteLink.parseCode("Anna"))
        XCTAssertNil(InviteLink.parseCode("Anna Berg"))
        XCTAssertNil(InviteLink.parseCode("AbCdEf"))
    }

    func testEmptyRejected() {
        XCTAssertNil(InviteLink.parseCode(""))
        XCTAssertNil(InviteLink.parseCode("   "))
    }

    func testOtherHostRejected() {
        XCTAssertNil(InviteLink.parseCode(
            "https://example.com/AbCdEfGhIjKlMnOpQrSt"))
        XCTAssertNil(InviteLink.parseCode(
            "https://signal.me/AbCdEfGhIjKlMnOpQrSt"))
    }

    func testTrailingPathStripped() {
        XCTAssertEqual(InviteLink.parseCode(
            "https://chat.whatsapp.com/AbCdEfGhIjKlMnOpQr?extra=1"),
            "AbCdEfGhIjKlMnOpQr")
    }

    func testWhitespaceTrimmed() {
        XCTAssertEqual(InviteLink.parseCode(
            "  https://chat.whatsapp.com/AbCdEfGhIjKlMn  "),
            "AbCdEfGhIjKlMn")
    }

    func testNonAlphanumericInBareCodeRejected() {
        XCTAssertNil(InviteLink.parseCode("AbCdEfGh-IjKlMnOpQr"))
        XCTAssertNil(InviteLink.parseCode("AbCdEfGh IjKlMnOpQr"))
    }
}
```

- [ ] **Step 2: Run, expect FAIL**

Run the Swift test command above with `-only-testing:yawacTests/InviteLinkParserTests`.
Expected: FAIL — `InviteLink` not defined.

- [ ] **Step 3: Implement the parser**

Create `yawac/Utilities/InviteLink.swift`:

```swift
import Foundation

/// Extracts a WhatsApp invite-link code from the URL forms the desktop
/// commonly sees on the clipboard. Returns `nil` for anything that isn't
/// either a known invite-URL host or a bare 16+ char alphanumeric token.
/// The host allow-list is hard-coded — only chat.whatsapp.com and wa.me
/// resolve to real invite codes, and matching other hosts would surface
/// preview rows for unrelated URLs the user pastes into search.
enum InviteLink {
    private static let minBareCodeLength = 16

    static func parseCode(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var body = trimmed
        if let r = body.range(of: "://") {
            let scheme = body[..<r.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            body = String(body[r.upperBound...])
        }

        let knownHosts = ["chat.whatsapp.com/", "wa.me/"]
        for host in knownHosts where body.lowercased().hasPrefix(host) {
            let codeStart = body.index(body.startIndex, offsetBy: host.count)
            return extractCode(String(body[codeStart...]))
        }
        if body.contains("/") {
            // Has a path but matches no known host → reject.
            return nil
        }
        return bareCode(body)
    }

    /// Strips trailing query / fragment / extra path segments and validates
    /// the leading run is plain alphanumerics.
    private static func extractCode(_ s: String) -> String? {
        var head = s
        for delimiter in ["?", "#", "/"] {
            if let r = head.range(of: delimiter) {
                head = String(head[..<r.lowerBound])
            }
        }
        guard !head.isEmpty,
              head.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return head
    }

    /// Bare-code path: must be `[A-Za-z0-9]+` and at least `minBareCodeLength`
    /// chars so single-word search queries (names, common words) don't fire
    /// a preview round-trip.
    private static func bareCode(_ s: String) -> String? {
        guard s.count >= minBareCodeLength,
              s.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return s
    }
}
```

- [ ] **Step 4: Run, expect PASS**

Run only the parser tests.
Expected: PASS (all twelve).

- [ ] **Step 5: Commit**

```bash
git add yawac/Utilities/InviteLink.swift yawacTests/InviteLinkParserTests.swift
git commit -m "utility: InviteLink.parseCode — accept chat.whatsapp.com / wa.me / bare code"
```

### Task 12: Add `ChatListViewModel.applyGroupParticipantsChange`

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift` (append to the class).
- Create: `yawacTests/ChatListViewModelGroupParticipantsTests.swift`

The `Chat` model does NOT carry a participant count today, so the method has no roster data to mutate. Its job is to publish a sentinel observers can react to (the open inspector subscribes via `.onChange` and calls `loadGroup()`).

- [ ] **Step 1: Write the failing test**

Create `yawacTests/ChatListViewModelGroupParticipantsTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelGroupParticipantsTests: XCTestCase {
    private func makeVM() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }

    func testApplyAddPublishesTick() {
        let vm = makeVM()
        let before = vm.groupParticipantsTick
        vm.applyGroupParticipantsChange(
            chatJID: "g@g.us", action: "add",
            jids: ["1@s.whatsapp.net"], at: Date())
        XCTAssertNotEqual(vm.groupParticipantsTick, before)
        XCTAssertEqual(vm.lastParticipantsChange?.chatJID, "g@g.us")
        XCTAssertEqual(vm.lastParticipantsChange?.action, "add")
        XCTAssertEqual(vm.lastParticipantsChange?.jids,
                       ["1@s.whatsapp.net"])
    }

    func testApplyPromotePublishesTick() {
        let vm = makeVM()
        let before = vm.groupParticipantsTick
        vm.applyGroupParticipantsChange(
            chatJID: "g@g.us", action: "promote",
            jids: ["1@s.whatsapp.net"], at: Date())
        XCTAssertNotEqual(vm.groupParticipantsTick, before)
        XCTAssertEqual(vm.lastParticipantsChange?.action, "promote")
    }

    func testApplyEmptyJIDsStillTicks() {
        let vm = makeVM()
        let before = vm.groupParticipantsTick
        vm.applyGroupParticipantsChange(
            chatJID: "g@g.us", action: "remove",
            jids: [], at: Date())
        XCTAssertNotEqual(vm.groupParticipantsTick, before)
    }
}
```

- [ ] **Step 2: Run, expect FAIL**

Run only this test class.
Expected: FAIL — `applyGroupParticipantsChange`, `groupParticipantsTick`, `lastParticipantsChange` undefined.

- [ ] **Step 3: Implement**

Append inside the `ChatListViewModel` class (e.g. right after `applyLocalGroupInfo`):

```swift
/// Snapshot of the latest GroupParticipantsChanged event seen, plus a
/// monotonic tick that observers can watch via `.onChange`. The Chat
/// model has no roster cache today — this is purely a notification
/// sentinel so the open inspector reloads from the server.
struct GroupParticipantsChange: Equatable {
    let chatJID: String
    let action: String  // add | remove | promote | demote
    let jids: [String]
    let at: Date
}

var groupParticipantsTick: Int = 0
private(set) var lastParticipantsChange: GroupParticipantsChange? = nil

func applyGroupParticipantsChange(chatJID: String,
                                  action: String,
                                  jids: [String],
                                  at: Date) {
    lastParticipantsChange = GroupParticipantsChange(
        chatJID: chatJID, action: action, jids: jids, at: at)
    groupParticipantsTick &+= 1
}
```

- [ ] **Step 4: Run, expect PASS**

Run only this test class.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ChatListViewModel.swift \
        yawacTests/ChatListViewModelGroupParticipantsTests.swift
git commit -m "clvm: applyGroupParticipantsChange — sentinel tick for inspector reload"
```

### Task 13: Add `ChatListViewModel.inviteLinkPreview` state container

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift`.

- [ ] **Step 1: Add the state**

Add inside the `ChatListViewModel` class, near the top with the other published properties:

```swift
enum InviteLinkPreviewState: Equatable {
    case loading(code: String)
    case ready(BridgeGroupModel, code: String)
    case joining(code: String)
    case pending(code: String, joinedJID: String)
    case error(message: String)

    static func == (lhs: InviteLinkPreviewState,
                    rhs: InviteLinkPreviewState) -> Bool {
        switch (lhs, rhs) {
        case (.loading(let a), .loading(let b)): return a == b
        case (.ready(let a, let b), .ready(let c, let d)):
            return a.jid == c.jid && b == d
        case (.joining(let a), .joining(let b)): return a == b
        case (.pending(let a, let b), .pending(let c, let d)):
            return a == c && b == d
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

var inviteLinkPreview: InviteLinkPreviewState? = nil
```

`BridgeGroupModel` is `Codable` but not `Equatable`; the manual `==` above checks `.jid` only, which is the identity we care about for state-transition comparisons in tests.

- [ ] **Step 2: Build**

Run the Swift build command.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add yawac/ViewModels/ChatListViewModel.swift
git commit -m "clvm: InviteLinkPreviewState slot for ⌘K paste-to-join"
```

### Task 14: Wire the invite-link branch into `ChatSearchViewModel`

**Files:**
- Modify: `yawac/ViewModels/ChatSearchViewModel.swift`.

- [ ] **Step 1: Add the preview-resolution branch**

Inside `ChatSearchViewModel`, add a new private helper and call it from `onQueryChanged`. The check runs in parallel with the existing filter / validate / message-refresh paths.

Add inside the class:

```swift
private var inviteLinkTask: Task<Void, Never>? = nil

private func maybeResolveInviteLink(_ q: String) async {
    inviteLinkTask?.cancel()
    let code = InviteLink.parseCode(q)
    guard let code else {
        listVM?.inviteLinkPreview = nil
        return
    }
    // Skip resolution if we're not connected — the bridge call would just
    // throw. Preview clears so the user isn't staring at a stale spinner.
    let listVM = self.listVM
    guard let client = listVM?.client, !client.ownJID.isEmpty else {
        listVM?.inviteLinkPreview = .error(
            message: "Sign in to preview invite links.")
        return
    }
    listVM?.inviteLinkPreview = .loading(code: code)
    inviteLinkTask = Task { @MainActor [weak self] in
        do {
            let info = try await Task.detached(priority: .userInitiated) {
                try client.groupInfoFromLink(code: code)
            }.value
            guard let _ = self, !Task.isCancelled else { return }
            listVM?.inviteLinkPreview = .ready(info, code: code)
        } catch {
            listVM?.inviteLinkPreview = .error(
                message: error.localizedDescription)
        }
    }
}
```

`ChatListViewModel.client` is private — expose it (or a passthrough). Add to `ChatListViewModel`:

```swift
/// Read-only accessor for collaborators that need to call bridge methods
/// directly (e.g. ChatSearchViewModel for invite-link preview).
var clientRef: WAClient? { client }
```

…and in `ChatSearchViewModel` change `let client = listVM?.client` → `let client = listVM?.clientRef`.

In `onQueryChanged`, inside the debounced `Task`, add the call alongside the other awaits:

```swift
await self.runFilter(q)
await self.maybeValidate(q)
await self.refreshMessages(q)
await self.maybeResolveInviteLink(q)
```

In `clear()`, add cleanup:

```swift
inviteLinkTask?.cancel()
listVM?.inviteLinkPreview = nil
```

- [ ] **Step 2: Build**

Run Swift build.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add yawac/ViewModels/ChatSearchViewModel.swift \
        yawac/ViewModels/ChatListViewModel.swift
git commit -m "search: ⌘K previews invite links via groupInfoFromLink"
```

### Task 15: Write `AddParticipantsPanelModel` + tests

**Files:**
- Create: `yawac/ViewModels/AddParticipantsPanelModel.swift`
- Create: `yawacTests/AddParticipantsPanelModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `yawacTests/AddParticipantsPanelModelTests.swift`:

```swift
import XCTest
@testable import yawac

/// Fake validator captures calls so we can assert debouncing.
final class CountingValidator: PhoneValidating {
    var ownJID: String = "me@s.whatsapp.net"
    var calls: [String] = []
    var result: PhoneCheckResult = .init(
        jid: "1234@s.whatsapp.net", registered: true,
        businessName: nil, pushName: nil, fullName: nil)

    func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult {
        calls.append(phone)
        return result
    }
}

@MainActor
final class AddParticipantsPanelModelTests: XCTestCase {
    private func makeModel(existing: [String] = [],
                           validator: PhoneValidating = CountingValidator())
        -> AddParticipantsPanelModel {
        let m = AddParticipantsPanelModel(
            existingParticipantJIDs: Set(existing),
            allContacts: [
                BridgeContact(jid: "1@s.whatsapp.net", name: "Anna",
                              pushName: nil, fullName: "Anna Berg",
                              businessName: nil),
                BridgeContact(jid: "2@s.whatsapp.net", name: "Carlos",
                              pushName: nil, fullName: "Carlos Romero",
                              businessName: nil),
                BridgeContact(jid: "3@s.whatsapp.net", name: "Dana",
                              pushName: nil, fullName: "Dana Park",
                              businessName: nil),
            ],
            validator: validator)
        m.debounceMs = 10  // keep tests fast
        return m
    }

    func testSuggestionsFilterByQuery() {
        let m = makeModel()
        m.query = "an"
        XCTAssertTrue(m.suggestions.contains(where: { $0.name == "Anna" }))
        XCTAssertTrue(m.suggestions.contains(where: { $0.name == "Dana" }))
        XCTAssertFalse(m.suggestions.contains(where: { $0.name == "Carlos" }))
    }

    func testExistingParticipantsExcluded() {
        let m = makeModel(existing: ["1@s.whatsapp.net"])
        m.query = ""
        XCTAssertFalse(m.suggestions.contains(where: { $0.jid == "1@s.whatsapp.net" }))
    }

    func testChipsExcludedFromSuggestions() {
        let m = makeModel()
        m.addChip(BridgeContact(jid: "1@s.whatsapp.net", name: "Anna",
                                pushName: nil, fullName: nil,
                                businessName: nil))
        m.query = ""
        XCTAssertFalse(m.suggestions.contains(where: { $0.jid == "1@s.whatsapp.net" }))
    }

    func testPhoneQueryDebouncesValidator() async {
        let v = CountingValidator()
        let m = makeModel(validator: v)
        m.query = "+1"
        m.query = "+14"
        m.query = "+1415"
        m.query = "+14155551234"
        // give the debounce window a moment to settle
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertLessThanOrEqual(v.calls.count, 1,
            "validator should fire at most once per quiet burst, got \(v.calls)")
    }

    func testPhoneResolvedAddsCandidate() async {
        let v = CountingValidator()
        let m = makeModel(validator: v)
        m.query = "+14155551234"
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(m.phoneCandidate?.jid, "1234@s.whatsapp.net")
    }

    func testNonPhoneClearsCandidate() async {
        let v = CountingValidator()
        let m = makeModel(validator: v)
        m.query = "+14155551234"
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertNotNil(m.phoneCandidate)
        m.query = "Anna"
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(m.phoneCandidate)
    }

    func testApplyResultDropsSuccessChipsKeepsFailures() {
        let m = makeModel()
        let anna = BridgeContact(jid: "1@s.whatsapp.net", name: "Anna",
                                 pushName: nil, fullName: nil, businessName: nil)
        let carlos = BridgeContact(jid: "2@s.whatsapp.net", name: "Carlos",
                                   pushName: nil, fullName: nil, businessName: nil)
        m.addChip(anna)
        m.addChip(carlos)
        m.applyResult([
            BridgeParticipantModel(jid: "1@s.whatsapp.net",
                                   isAdmin: false, isSuper: false),
            BridgeParticipantModel(jid: "2@s.whatsapp.net",
                                   isAdmin: false, isSuper: false,
                                   errorCode: 403,
                                   inviteCode: "ABC", inviteExpiry: 0),
        ])
        XCTAssertEqual(m.chips.count, 1)
        XCTAssertEqual(m.chips.first?.jid, "2@s.whatsapp.net")
        XCTAssertEqual(m.result?.rows.count, 2)
    }
}
```

- [ ] **Step 2: Run, expect FAIL**

Run only this test class.
Expected: FAIL — `AddParticipantsPanelModel` undefined.

- [ ] **Step 3: Implement the model**

Create `yawac/ViewModels/AddParticipantsPanelModel.swift`:

```swift
import Foundation
import Observation

@Observable @MainActor
final class AddParticipantsPanelModel {
    private(set) var chips: [BridgeContact] = []
    var query: String = "" {
        didSet { onQueryChanged() }
    }
    private(set) var suggestions: [BridgeContact] = []
    private(set) var phoneCandidate: PhoneCheckResult? = nil
    private(set) var validating: Bool = false
    var inFlight: Bool = false
    private(set) var result: AddResult? = nil

    /// Exposed for tests so they don't have to sleep the production
    /// debounce window.
    var debounceMs: Int = 250

    struct AddResult: Equatable {
        struct Row: Equatable {
            enum Kind: Equatable { case ok, pending(inviteCode: String), failed(code: Int) }
            let jid: String
            let displayName: String
            let kind: Kind
        }
        let rows: [Row]
    }

    private let existingParticipantJIDs: Set<String>
    private let allContacts: [BridgeContact]
    private let validator: PhoneValidating
    private var debounceTask: Task<Void, Never>? = nil

    init(existingParticipantJIDs: Set<String>,
         allContacts: [BridgeContact],
         validator: PhoneValidating) {
        self.existingParticipantJIDs = existingParticipantJIDs
        self.allContacts = allContacts
        self.validator = validator
        refreshSuggestions()
    }

    func addChip(_ c: BridgeContact) {
        guard !chips.contains(where: { $0.jid == c.jid }) else { return }
        chips.append(c)
        refreshSuggestions()
    }

    func removeChip(_ jid: String) {
        chips.removeAll { $0.jid == jid }
        refreshSuggestions()
    }

    func addPhoneCandidate() {
        guard let r = phoneCandidate else { return }
        let displayName: String = {
            if let n = r.businessName, !n.isEmpty { return n }
            if let n = r.fullName, !n.isEmpty { return n }
            if let n = r.pushName, !n.isEmpty { return n }
            return r.jid
        }()
        addChip(BridgeContact(jid: r.jid, name: displayName,
                              pushName: r.pushName, fullName: r.fullName,
                              businessName: r.businessName))
        query = ""
        phoneCandidate = nil
    }

    /// Apply the bridge response: drop chips for successful rows, keep
    /// the originally-attempted ones for failures, and surface a result
    /// strip with one row per attempt.
    func applyResult(_ response: [BridgeParticipantModel]) {
        var rows: [AddResult.Row] = []
        var successJIDs = Set<String>()
        for r in response {
            let name = chips.first(where: { $0.jid == r.jid })?.name ?? r.jid
            if let code = r.errorCode, code != 0 {
                if let invite = r.inviteCode, !invite.isEmpty {
                    rows.append(.init(jid: r.jid, displayName: name,
                                      kind: .pending(inviteCode: invite)))
                } else {
                    rows.append(.init(jid: r.jid, displayName: name,
                                      kind: .failed(code: code)))
                }
            } else {
                rows.append(.init(jid: r.jid, displayName: name, kind: .ok))
                successJIDs.insert(r.jid)
            }
        }
        chips.removeAll { successJIDs.contains($0.jid) }
        result = AddResult(rows: rows)
    }

    func dismissResult() { result = nil }

    private func onQueryChanged() {
        debounceTask?.cancel()
        refreshSuggestions()
        let q = query
        let looksLikePhone = Self.looksLikePhone(q)
        if !looksLikePhone {
            phoneCandidate = nil
            validating = false
            return
        }
        debounceTask = Task { @MainActor [weak self, debounceMs] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self, !Task.isCancelled else { return }
            await self.runValidation(q)
        }
    }

    private func runValidation(_ q: String) async {
        guard !validator.ownJID.isEmpty else {
            phoneCandidate = nil
            return
        }
        let digits = Self.digitsOnly(q)
        guard !digits.isEmpty else { phoneCandidate = nil; return }
        validating = true
        let v = self.validator
        defer { validating = false }
        do {
            let r = try await Task.detached(priority: .userInitiated) {
                try v.checkOnWhatsApp(digits)
            }.value
            guard !Task.isCancelled, r.registered else {
                phoneCandidate = nil
                return
            }
            phoneCandidate = r
        } catch {
            phoneCandidate = nil
        }
    }

    private func refreshSuggestions() {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
                              .lowercased()
        let chipJIDs = Set(chips.map(\.jid))
        suggestions = allContacts.filter { c in
            if existingParticipantJIDs.contains(c.jid) { return false }
            if chipJIDs.contains(c.jid) { return false }
            if normalized.isEmpty { return true }
            return c.name.localizedCaseInsensitiveContains(normalized)
                || c.fullName?.localizedCaseInsensitiveContains(normalized) == true
        }
    }

    static func looksLikePhone(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let digits = digitsOnly(trimmed)
        let allowed = CharacterSet(charactersIn: "+-() ")
                       .union(.decimalDigits).union(.whitespaces)
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return false
        }
        return trimmed.hasPrefix("+") ? digits.count >= 6 : digits.count >= 7
    }

    static func digitsOnly(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }
}
```

- [ ] **Step 4: Run, expect PASS**

Run only this test class.
Expected: PASS (all seven cases).

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/AddParticipantsPanelModel.swift \
        yawacTests/AddParticipantsPanelModelTests.swift
git commit -m "vm: AddParticipantsPanelModel — chips, debounced phone lookup, result strip"
```

---

## Phase 7 — UI views

### Task 16: Build `AddParticipantsPanel` view

**Files:**
- Create: `yawac/Views/AddParticipantsPanel.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI

struct AddParticipantsPanel: View {
    @Bindable var model: AddParticipantsPanelModel
    var onCommit: ([String]) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chipRow
            divider
            suggestionsRow
            divider
            footer
            if let res = model.result {
                resultStrip(res)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    @ViewBuilder
    private var chipRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(model.chips, id: \.jid) { c in
                HStack(spacing: 4) {
                    Text(c.name).scaledUI(11, weight: .medium)
                        .foregroundStyle(Color.white)
                    Button {
                        model.removeChip(c.jid)
                    } label: {
                        Image(systemName: "xmark")
                            .scaledIcon(8, weight: .semibold)
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.accent, in: Capsule())
            }
            TextField("Search contacts or +phone…",
                      text: Bindable(model).query)
                .textFieldStyle(.plain)
                .scaledUI(12)
                .foregroundStyle(Theme.text)
                .frame(minWidth: 100)
        }
        .padding(8)
    }

    @ViewBuilder
    private var suggestionsRow: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let candidate = model.phoneCandidate {
                    Button {
                        model.addPhoneCandidate()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .scaledIcon(11)
                                .foregroundStyle(Theme.accent)
                            Text("Add \(candidate.fullName ?? candidate.pushName ?? candidate.jid) (on WhatsApp)")
                                .scaledUI(12)
                                .foregroundStyle(Theme.text)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(model.suggestions, id: \.jid) { c in
                    Button {
                        model.addChip(c)
                    } label: {
                        HStack(spacing: 8) {
                            Text(c.name)
                                .scaledUI(12)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(c.jid)
                                .scaledMono(10)
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if model.suggestions.isEmpty && model.phoneCandidate == nil {
                    Text(model.validating ? "Checking…" : "No matches")
                        .scaledUI(11)
                        .foregroundStyle(Theme.textFaint)
                        .padding(10)
                }
            }
        }
        .frame(maxHeight: 200)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if model.inFlight {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
            Button(model.chips.isEmpty ? "Add" : "Add \(model.chips.count)") {
                onCommit(model.chips.map(\.jid))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.chips.isEmpty || model.inFlight)
        }
        .padding(8)
    }

    @ViewBuilder
    private func resultStrip(_ res: AddParticipantsPanelModel.AddResult)
        -> some View {
        HStack(spacing: 8) {
            ForEach(Array(res.rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 3) {
                    Image(systemName: icon(for: r.kind))
                        .scaledIcon(10, weight: .semibold)
                        .foregroundStyle(color(for: r.kind))
                    Text(label(for: r))
                        .scaledUI(11)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                model.dismissResult()
            } label: {
                Image(systemName: "xmark")
                    .scaledIcon(9, weight: .semibold)
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Theme.surface.opacity(0.6))
    }

    private func icon(for kind: AddParticipantsPanelModel.AddResult.Row.Kind) -> String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .pending: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for kind: AddParticipantsPanelModel.AddResult.Row.Kind) -> Color {
        switch kind {
        case .ok: return .green
        case .pending: return .orange
        case .failed: return .red
        }
    }

    private func label(for row: AddParticipantsPanelModel.AddResult.Row) -> String {
        switch row.kind {
        case .ok: return row.displayName
        case .pending: return "\(row.displayName) — invite sent"
        case .failed: return "\(row.displayName) — not added"
        }
    }
}

/// Minimal flow layout for chip + textfield wrapping. Native
/// SwiftUI HStack doesn't wrap; this is a single-file Layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxW: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x)
        }
        return CGSize(width: min(width, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y),
                      proposal: ProposedViewSize(width: s.width, height: s.height))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
```

- [ ] **Step 2: Build**

Run Swift build.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/AddParticipantsPanel.swift
git commit -m "view: AddParticipantsPanel — chip picker w/ phone fallback + result strip"
```

### Task 17: Build `AvatarCropSheet` view

**Files:**
- Create: `yawac/Views/AvatarCropSheet.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI
import AppKit

/// Modal sheet that lets the user pan + zoom an image inside a circular
/// mask, then exports the masked rectangle as a 640×640 JPEG.
struct AvatarCropSheet: View {
    let original: NSImage
    var onApply: (Data) -> Void
    var onCancel: () -> Void

    @State private var zoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    private let cropSize: CGFloat = 240

    var body: some View {
        VStack(spacing: 14) {
            Text("Crop photo")
                .scaledUI(13, weight: .semibold)
                .foregroundStyle(Theme.text)
            cropArea
            Slider(value: $zoom, in: 1.0...3.0)
                .frame(width: cropSize)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                Button("Apply") {
                    if let data = render() { onApply(data) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    @ViewBuilder
    private var cropArea: some View {
        ZStack {
            Image(nsImage: original)
                .resizable()
                .scaledToFill()
                .scaleEffect(zoom)
                .offset(pan)
                .frame(width: cropSize, height: cropSize)
                .clipped()
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            pan = CGSize(
                                width: dragStart.width + v.translation.width,
                                height: dragStart.height + v.translation.height)
                        }
                        .onEnded { _ in dragStart = pan }
                )
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
                .frame(width: cropSize, height: cropSize)
                .allowsHitTesting(false)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Renders the on-screen cropped area into a 640×640 JPEG.
    private func render() -> Data? {
        let outSize: CGFloat = 640
        let scale = outSize / cropSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(outSize), pixelsHigh: Int(outSize),
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: outSize, height: outSize).fill()
        let imgSize = original.size
        let drawW = imgSize.width * scale * zoom
        let drawH = imgSize.height * scale * zoom
        let originX = (outSize - drawW) / 2 + pan.width * scale
        // NSImage origin is bottom-left; SwiftUI top-left. Invert the Y pan.
        let originY = (outSize - drawH) / 2 - pan.height * scale
        original.draw(
            in: NSRect(x: originX, y: originY, width: drawW, height: drawH),
            from: .zero, operation: .copy, fraction: 1.0)
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: 0.85])
    }
}
```

- [ ] **Step 2: Build**

Run Swift build.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/AvatarCropSheet.swift
git commit -m "view: AvatarCropSheet — pan + zoom + 640x640 JPEG export"
```

### Task 18: Build `InviteLinkSheet` view

**Files:**
- Create: `yawac/Views/InviteLinkSheet.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct InviteLinkSheet: View {
    let chatJID: String
    let chatName: String
    let isAdmin: Bool
    let client: WAClient
    var onClose: () -> Void

    @State private var link: String? = nil
    @State private var loadError: String? = nil
    @State private var loading: Bool = true
    @State private var confirmRevoke: Bool = false
    @State private var revokeCooldownUntil: Date? = nil

    var body: some View {
        VStack(spacing: 14) {
            Text("Invite to \"\(chatName)\"")
                .scaledUI(13, weight: .semibold)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 18) {
                qrSquare
                rightColumn
            }
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task { await refresh(reset: false) }
        .confirmationDialog("Revoke link?",
                            isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) {
                Task { await refresh(reset: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone holding the current link won't be able to join with it.")
        }
    }

    @ViewBuilder
    private var qrSquare: some View {
        Group {
            if let link, let img = makeQR(link) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(width: 140, height: 140)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anyone with this link can join.")
                .scaledUI(11)
                .foregroundStyle(Theme.textMuted)
            if loading {
                ProgressView().controlSize(.small)
            } else if let err = loadError {
                Text(err)
                    .scaledUI(12)
                    .foregroundStyle(Color.red.opacity(0.9))
            } else if let link {
                Text(link)
                    .scaledMono(11)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.surface,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .textSelection(.enabled)
            }
            Button("Copy link") { copy() }
                .buttonStyle(.bordered)
                .disabled(link == nil)
            ShareButton(link: link)
            if isAdmin {
                Button("Revoke link") { confirmRevoke = true }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(link == nil || revokeOnCooldown())
            }
        }
    }

    private func revokeOnCooldown() -> Bool {
        guard let until = revokeCooldownUntil else { return false }
        return Date() < until
    }

    private func copy() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func refresh(reset: Bool) async {
        loading = true
        loadError = nil
        let chatJID = self.chatJID
        let client = self.client
        do {
            let l = try await Task.detached(priority: .userInitiated) {
                try client.getGroupInviteLink(chatJID: chatJID, reset: reset)
            }.value
            link = l
            if reset {
                revokeCooldownUntil = Date().addingTimeInterval(3)
            }
        } catch {
            loadError = error.localizedDescription
            link = nil
        }
        loading = false
    }

    private func makeQR(_ s: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(s.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: .init(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// Bridges `NSSharingServicePicker` so the SwiftUI button anchors the
/// macOS share sheet correctly.
private struct ShareButton: NSViewRepresentable {
    let link: String?

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(title: "Share…", target: context.coordinator,
                           action: #selector(Coordinator.share(_:)))
        btn.bezelStyle = .rounded
        return btn
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.isEnabled = link != nil
        context.coordinator.link = link
    }

    func makeCoordinator() -> Coordinator { Coordinator(link: link) }

    final class Coordinator: NSObject {
        var link: String?
        init(link: String?) { self.link = link }
        @objc func share(_ sender: NSButton) {
            guard let link else { return }
            let picker = NSSharingServicePicker(items: [link])
            picker.show(relativeTo: sender.bounds,
                        of: sender, preferredEdge: .minY)
        }
    }
}
```

- [ ] **Step 2: Build**

Run Swift build.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/InviteLinkSheet.swift
git commit -m "view: InviteLinkSheet — QR + link + share + admin revoke w/ cooldown"
```

---

## Phase 8 — `ChatInfoView` integration

### Task 19: Mount the Add-Participants panel

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift`.

- [ ] **Step 1: Add new state at the top of the view**

In the `ChatInfoView` struct, alongside the existing `@State` declarations (around line 27-55), add:

```swift
@State private var addPanelOpen: Bool = false
@State private var addPanelModel: AddParticipantsPanelModel? = nil
@State private var addPanelError: String? = nil
@State private var participantOpError: String? = nil
@State private var confirmRemoveJID: String? = nil
@State private var confirmDemoteJID: String? = nil
@State private var avatarMenuOpen: Bool = false
@State private var avatarError: String? = nil
@State private var pickedImage: NSImage? = nil
@State private var confirmRemovePhoto: Bool = false
@State private var inviteSheetOpen: Bool = false
```

- [ ] **Step 2: Replace the participants `sectionLabel` line**

Find this line in `groupBody(_:)` (around `ChatInfoView.swift:436`):

```swift
sectionLabel("PARTICIPANTS", trailing: "\(g.participants.count)")
```

Replace with:

```swift
HStack {
    sectionLabel("PARTICIPANTS", trailing: "\(g.participants.count)")
    if admin {
        Button {
            openAddPanel(group: g)
        } label: {
            Label("Add member", systemImage: "plus")
                .scaledUI(11, weight: .medium)
                .foregroundStyle(Theme.accentText)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}
if addPanelOpen, let model = addPanelModel {
    AddParticipantsPanel(
        model: model,
        onCommit: { jids in commitAdd(group: g, jids: jids) },
        onCancel: { closeAddPanel() }
    )
    .padding(.bottom, 6)
}
if let err = participantOpError {
    Text(err)
        .scaledUI(11)
        .foregroundStyle(Color.red.opacity(0.9))
        .padding(.bottom, 4)
}
```

- [ ] **Step 3: Add the helper methods**

Inside `ChatInfoView`, add:

```swift
private func openAddPanel(group: BridgeGroupModel) {
    guard let client = session.client else { return }
    let existing = Set(group.participants.map(\.jid))
    let contacts = session.contactNames.map { (jid, name) in
        BridgeContact(jid: jid, name: name,
                      pushName: nil, fullName: nil, businessName: nil)
    }
    addPanelModel = AddParticipantsPanelModel(
        existingParticipantJIDs: existing,
        allContacts: contacts,
        validator: client)
    addPanelOpen = true
}

private func closeAddPanel() {
    addPanelOpen = false
    addPanelModel = nil
}

private func commitAdd(group: BridgeGroupModel, jids: [String]) {
    guard let client = session.client, let model = addPanelModel else { return }
    model.inFlight = true
    let chatJID = group.jid
    Task { @MainActor in
        defer { model.inFlight = false }
        do {
            let resp = try await Task.detached {
                try client.updateGroupParticipants(
                    chatJID: chatJID, action: "add",
                    participantJIDs: jids)
            }.value
            model.applyResult(resp)
            await loadGroup()
        } catch {
            participantOpError = error.localizedDescription
            scheduleParticipantErrorAutodismiss()
        }
    }
}

private func scheduleParticipantErrorAutodismiss() {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(6))
        participantOpError = nil
    }
}
```

- [ ] **Step 4: Build**

Run Swift build.
Expected: PASS.

- [ ] **Step 5: Manually verify (run app, sign in to a paired account)**

Open a group inspector as admin. The "+ Add member" pill appears in the section header. Click it — the panel mounts. Cancel closes it.

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "info: mount AddParticipantsPanel under participants section"
```

### Task 20: Add participant context-menu admin items

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift` (the `participantRow(_:)` function).

- [ ] **Step 1: Locate `participantRow(_:)`**

Around `ChatInfoView.swift:630-675`. The `.contextMenu { … }` block currently has only Copy JID + Copy name.

- [ ] **Step 2: Wrap participantRow with admin context**

Change the signature of `participantRow(_:)` so it accepts the current group + admin flag:

Find:
```swift
@ViewBuilder
private func participantRow(_ p: BridgeParticipantModel) -> some View {
```

Replace with:
```swift
@ViewBuilder
private func participantRow(_ p: BridgeParticipantModel,
                            in group: BridgeGroupModel,
                            currentUserIsAdmin: Bool) -> some View {
```

- [ ] **Step 3: Extend the `.contextMenu`**

Replace the existing context menu in `participantRow`:

```swift
.contextMenu {
    Button("Copy JID") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p.jid, forType: .string)
    }
    Button("Copy name") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.displayName(for: p.jid),
                                       forType: .string)
    }
    if currentUserIsAdmin && !isCurrentUser(p.jid) {
        Divider()
        if p.isAdmin || p.isSuper {
            Button("Demote") { confirmDemoteJID = p.jid }
        } else {
            Button("Promote to admin") {
                applyParticipantOp(group: group, action: "promote",
                                   jid: p.jid)
            }
        }
        Button("Remove from group", role: .destructive) {
            confirmRemoveJID = p.jid
        }
    }
}
```

Add the helper:

```swift
private func isCurrentUser(_ jid: String) -> Bool {
    let own = session.client?.ownJID ?? ""
    guard !own.isEmpty else { return false }
    return JIDNormalize.bare(jid) == JIDNormalize.bare(own)
        || JIDNormalize.canonical(jid, client: session.client) ==
           JIDNormalize.canonical(own, client: session.client)
}

private func applyParticipantOp(group: BridgeGroupModel,
                                action: String,
                                jid: String) {
    guard let client = session.client else { return }
    let chatJID = group.jid
    Task { @MainActor in
        do {
            _ = try await Task.detached {
                try client.updateGroupParticipants(
                    chatJID: chatJID, action: action,
                    participantJIDs: [jid])
            }.value
            await loadGroup()
        } catch {
            participantOpError = error.localizedDescription
            scheduleParticipantErrorAutodismiss()
        }
    }
}
```

- [ ] **Step 4: Update the call site**

In `groupBody(_:)`, the `ForEach` that builds participant rows currently calls `participantRow(p)`. Update the call to pass the group + admin flag:

```swift
ForEach(sortedParticipants(g.participants), id: \.jid) { p in
    participantRow(p, in: g, currentUserIsAdmin: admin)
    Rectangle().fill(Theme.hairline).frame(height: 1)
}
```

- [ ] **Step 5: Add the two confirmation dialogs**

Append at the bottom of `body`, alongside the existing `.confirmationDialog` modifiers:

```swift
.confirmationDialog(
    "Remove \(confirmRemoveJID.map { session.displayName(for: $0) } ?? "member")?",
    isPresented: Binding(
        get: { confirmRemoveJID != nil },
        set: { if !$0 { confirmRemoveJID = nil } })
) {
    Button("Remove", role: .destructive) {
        if let jid = confirmRemoveJID, let g = group {
            applyParticipantOp(group: g, action: "remove", jid: jid)
        }
        confirmRemoveJID = nil
    }
    Button("Cancel", role: .cancel) { confirmRemoveJID = nil }
} message: {
    Text("They'll stop receiving messages from this group.")
}
.confirmationDialog(
    "Demote \(confirmDemoteJID.map { session.displayName(for: $0) } ?? "admin")?",
    isPresented: Binding(
        get: { confirmDemoteJID != nil },
        set: { if !$0 { confirmDemoteJID = nil } })
) {
    Button("Demote", role: .destructive) {
        if let jid = confirmDemoteJID, let g = group {
            applyParticipantOp(group: g, action: "demote", jid: jid)
        }
        confirmDemoteJID = nil
    }
    Button("Cancel", role: .cancel) { confirmDemoteJID = nil }
} message: {
    Text("They'll lose admin privileges in this group.")
}
```

- [ ] **Step 6: Build**

Run Swift build.
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "info: participant ctx menu — admin promote/demote/remove with confirms"
```

### Task 21: Hover overlay on hero avatar + avatar actions

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift` (the `hero` builder + add the sheet binding).

- [ ] **Step 1: Replace the `hero` view body's `AvatarView` for admins**

Find this in `hero`:
```swift
AvatarView(jid: chatJID, name: name, size: 92)
```

Replace with:
```swift
ZStack {
    AvatarView(jid: chatJID, name: name, size: 92)
    if isGroup, isAdminForCurrentGroup {
        avatarHoverOverlay
    }
}
```

Add a derived helper inside `ChatInfoView`:
```swift
private var isAdminForCurrentGroup: Bool {
    guard let g = group else { return false }
    return isCurrentUserAdmin(g)
}

@State private var avatarHovered: Bool = false

@ViewBuilder
private var avatarHoverOverlay: some View {
    Group {
        if avatarHovered {
            Circle()
                .fill(Color.black.opacity(0.5))
                .frame(width: 92, height: 92)
                .overlay {
                    Text("EDIT\nPHOTO")
                        .scaledUI(10, weight: .semibold)
                        .tracking(0.6)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.white)
                }
        }
    }
    .frame(width: 92, height: 92)
    .contentShape(Circle())
    .onHover { avatarHovered = $0 }
    .onTapGesture { avatarMenuOpen = true }
    .confirmationDialog("Group photo",
                        isPresented: $avatarMenuOpen,
                        titleVisibility: .visible) {
        Button("Change photo…") { pickPhoto() }
        if !avatarIsPlaceholder {
            Button("Remove photo", role: .destructive) {
                confirmRemovePhoto = true
            }
        }
        Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog("Remove group photo?",
                        isPresented: $confirmRemovePhoto) {
        Button("Remove", role: .destructive) { removePhoto() }
        Button("Cancel", role: .cancel) {}
    }
    .sheet(item: Binding(
        get: { pickedImage.map { ImageBox(image: $0) } },
        set: { pickedImage = $0?.image })
    ) { box in
        AvatarCropSheet(original: box.image,
                        onApply: { data in
                            pickedImage = nil
                            uploadAvatar(data)
                        },
                        onCancel: { pickedImage = nil })
    }
}

private struct ImageBox: Identifiable {
    let id = UUID()
    let image: NSImage
}

private var avatarIsPlaceholder: Bool {
    AvatarCache.shared.has(jid: chatJID) == false
}
```

If `AvatarCache.shared.has(jid:)` doesn't exist, treat `avatarIsPlaceholder` as `false` (the "Remove" item still shows up; the server returns the appropriate error if there's nothing to remove, and the inline error surfaces it).

- [ ] **Step 2: Add the action methods**

```swift
private func pickPhoto() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.jpeg, .png, .heic]
    panel.begin { resp in
        guard resp == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        DispatchQueue.main.async {
            pickedImage = img
        }
    }
}

private func uploadAvatar(_ data: Data) {
    guard let client = session.client else { return }
    let chatJID = self.chatJID
    Task { @MainActor in
        do {
            _ = try await Task.detached {
                try client.setGroupPhoto(chatJID: chatJID, jpeg: data)
            }.value
            AvatarCache.shared.invalidate(jid: chatJID)
        } catch {
            avatarError = error.localizedDescription
            scheduleAvatarErrorAutodismiss()
        }
    }
}

private func removePhoto() {
    guard let client = session.client else { return }
    let chatJID = self.chatJID
    Task { @MainActor in
        do {
            try await Task.detached {
                try client.removeGroupPhoto(chatJID: chatJID)
            }.value
            AvatarCache.shared.invalidate(jid: chatJID)
        } catch {
            avatarError = error.localizedDescription
            scheduleAvatarErrorAutodismiss()
        }
    }
}

private func scheduleAvatarErrorAutodismiss() {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(6))
        avatarError = nil
    }
}
```

- [ ] **Step 3: Render the inline avatar error under the hero**

In `hero`, append (after the inner `VStack`):

```swift
if let err = avatarError {
    Text(err)
        .scaledUI(11)
        .foregroundStyle(Color.red.opacity(0.9))
        .multilineTextAlignment(.center)
}
```

- [ ] **Step 4: Confirm `AvatarCache.shared.invalidate(jid:)` exists**

Run: `grep -n "func invalidate" /Users/vadikas/Work/yawac/yawac/Services/AvatarCache.swift`
- If found: nothing to do.
- If not found: add the helper:

```swift
// Append inside the AvatarCache class:
@MainActor
func invalidate(jid: String) {
    cache.removeValue(forKey: jid)
    // Force the AvatarView reload by bumping the per-jid revision.
    revision[jid, default: 0] &+= 1
}
```

If the cache's internal storage shape differs, mirror the existing `clear()` or `purge` semantics — the goal is to force the next read to re-fetch from the bridge.

- [ ] **Step 5: Build + run**

Run Swift build. PASS expected.

Run the app, open a group as admin, hover the avatar — overlay appears. Click → action menu. Pick → crop sheet opens. Apply → upload triggers.

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/ChatInfoView.swift yawac/Services/AvatarCache.swift
git commit -m "info: hero hover overlay → change/remove group photo via crop sheet"
```

### Task 22: Add the Invite-link action-row icon + sheet

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift` (the `actionRow` call in `groupBody`).

- [ ] **Step 1: Add a 4th action**

Find the existing `actionRow(actions: [ … ])` in `groupBody(_:)`:

```swift
actionRow(actions: [
    .init(label: "Mute", icon: "speaker.slash"),
    .init(label: "Search", icon: "magnifyingglass"),
    .init(label: "Leave", icon: "rectangle.portrait.and.arrow.right",
          destructive: true, action: { confirmLeave = true }),
])
```

Replace with:

```swift
actionRow(actions: [
    .init(label: "Mute", icon: "speaker.slash"),
    .init(label: "Search", icon: "magnifyingglass"),
    .init(label: "Invite", icon: "link",
          action: { inviteSheetOpen = true }),
    .init(label: "Leave", icon: "rectangle.portrait.and.arrow.right",
          destructive: true, action: { confirmLeave = true }),
])
```

- [ ] **Step 2: Mount the sheet**

Append to the `body` modifiers chain (next to existing `.sheet` / `.confirmationDialog` calls):

```swift
.sheet(isPresented: $inviteSheetOpen) {
    if let client = session.client {
        InviteLinkSheet(chatJID: chatJID,
                        chatName: name,
                        isAdmin: isAdminForCurrentGroup,
                        client: client,
                        onClose: { inviteSheetOpen = false })
    }
}
```

- [ ] **Step 3: Build + run**

Run Swift build. PASS.

In-app: open a group inspector. Tap Invite. Sheet opens. Link loads, QR renders. Copy works (paste into Notes confirms). Share opens the macOS share sheet. As admin: Revoke shows; non-admin: hidden.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "info: action-row Invite icon → InviteLinkSheet"
```

### Task 23: Listen for `groupParticipantsChanged`

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift`.

- [ ] **Step 1: Add the onChange hook**

Append to the `body` modifier chain:

```swift
.onChange(of: session.chatList?.groupParticipantsTick ?? 0) { _, _ in
    guard let change = session.chatList?.lastParticipantsChange,
          change.chatJID == chatJID || change.chatJID == JIDNormalize.canonical(chatJID, client: session.client)
    else { return }
    Task { @MainActor in await loadGroup() }
}
```

- [ ] **Step 2: Build**

Run Swift build. PASS.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "info: reload group on incoming participants-changed event"
```

---

## Phase 9 — Event routing in ContentView

### Task 24: Route `.groupParticipantsChanged` events

**Files:**
- Modify: `yawac/ContentView.swift` (event-stream switch around line 189).

- [ ] **Step 1: Add the case**

In the event-stream `switch event {` block, add a new arm before `default:`:

```swift
case .groupParticipantsChanged(let chatJID, let action, _, let jids, let ts):
    let when = Date(timeIntervalSince1970: TimeInterval(ts))
    let canonical = JIDNormalize.canonical(chatJID, client: client)
    vm.applyGroupParticipantsChange(
        chatJID: canonical, action: action, jids: jids, at: when)
```

- [ ] **Step 2: Build**

Run Swift build. PASS.

- [ ] **Step 3: Commit**

```bash
git add yawac/ContentView.swift
git commit -m "content: route groupParticipantsChanged to chatList VM"
```

---

## Phase 10 — Sidebar invite-link preview

### Task 25: Render the preview row in sidebar search

**Files:**
- Modify: `yawac/Views/ChatListView.swift`.

- [ ] **Step 1: Append a preview row to the search-results section list**

Locate the `buildSections` (or equivalent) that builds the rows list (in `ChatListView.swift`, the function around line 168 that returns `out`).

Add at the very top of `out` when an invite link preview is active:

```swift
if let preview = vm.inviteLinkPreview {
    out.insert(.invitePreview(state: preview), at: 0)
}
```

Define the new case on the section/row enum the function uses. Search the file for the enum (likely `Row` or `SidebarItem`) and add:

```swift
case invitePreview(state: ChatListViewModel.InviteLinkPreviewState)
```

- [ ] **Step 2: Render the row**

In the body's `ForEach` over the rows, add a new branch that switches on `case .invitePreview(let state):` and renders:

```swift
case .invitePreview(let state):
    InvitePreviewRow(state: state) { code in
        Task { @MainActor in await joinPreview(code: code) }
    }
```

Add the helper view at the bottom of the file (still in the same file is OK):

```swift
private struct InvitePreviewRow: View {
    let state: ChatListViewModel.InviteLinkPreviewState
    var onJoin: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .scaledIcon(13)
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledUI(12.5, weight: .medium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .scaledUI(11)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
            }
            Spacer()
            if case .loading = state { ProgressView().controlSize(.small) }
            if case .joining = state { ProgressView().controlSize(.small) }
            if case .ready(_, let code) = state {
                Button("Join") { onJoin(code) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.surface)
    }

    private var title: String {
        switch state {
        case .loading: return "Resolving invite link…"
        case .ready(let g, _): return "Join group: \(g.name)"
        case .joining: return "Joining…"
        case .pending: return "Request sent"
        case .error: return "Couldn't resolve link"
        }
    }
    private var subtitle: String {
        switch state {
        case .ready(let g, _):
            return g.topic.isEmpty ? g.jid : g.topic
        case .pending: return "Waiting for admin approval"
        case .error(let m): return m
        default: return ""
        }
    }
    private var detailColor: Color {
        if case .error = state { return Color.red.opacity(0.9) }
        return Theme.textMuted
    }
}
```

- [ ] **Step 2.5: Add `joinPreview(code:)` to the view**

Inside `ChatListView`, add:

```swift
@MainActor
private func joinPreview(code: String) async {
    guard let client = vm.clientRef else { return }
    vm.inviteLinkPreview = .joining(code: code)
    do {
        let joinedJID = try await Task.detached(priority: .userInitiated) {
            try client.joinGroupViaLink(code: code)
        }.value
        // Probe to distinguish "joined" from "pending approval".
        if let info = try? await Task.detached(priority: .userInitiated, operation: {
            try client.getGroupInfo(jid: joinedJID)
        }).value {
            vm.mergeGroups([info])
            vm.inviteLinkPreview = nil
            search.clear()
            session.requestSelectChat(joinedJID)
        } else {
            vm.inviteLinkPreview = .pending(code: code, joinedJID: joinedJID)
        }
    } catch {
        vm.inviteLinkPreview = .error(message: error.localizedDescription)
    }
}
```

The view already injects `vm`, `search`, `session` via `@Environment` (confirm at the top of the file; if `session` isn't injected, add `@Environment(SessionViewModel.self) private var session`).

- [ ] **Step 3: Build**

Run Swift build. PASS.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ChatListView.swift
git commit -m "sidebar: invite-link preview row at top of search results"
```

---

## Phase 11 — Cleanup + docs

### Task 26: Delete the dead `GroupInfoView` stub

**Files:**
- Delete: `yawac/Views/GroupInfoView.swift`.

- [ ] **Step 1: Verify no remaining references**

Run: `grep -rn "GroupInfoView" /Users/vadikas/Work/yawac/yawac --include="*.swift"`
Expected: only the file itself listed (or empty if XcodeGen will rebuild without it).

- [ ] **Step 2: Delete**

Run: `git rm yawac/Views/GroupInfoView.swift`

- [ ] **Step 3: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: PASS.

- [ ] **Step 4: Build**

Run Swift build. PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac.xcodeproj
git commit -m "views: drop dead GroupInfoView stub"
```

### Task 27: Update README + ROADMAP

**Files:**
- Modify: `README.md`.
- Modify: `docs/ROADMAP.md`.

- [ ] **Step 1: Add a README bullet**

Edit `README.md` — append under the existing features list (before "**Edit group name + description**"):

```markdown
- **Group management** — admins can add (from contacts or by phone), remove, promote, and demote members from the chat inspector; edit the group photo with a crop sheet; share or revoke the public invite link with QR code. ⌘K also recognises pasted `chat.whatsapp.com` / `wa.me` links and offers a one-tap join.
```

- [ ] **Step 2: Mark items shipped in ROADMAP**

Edit `docs/ROADMAP.md`. Move the "Group management" / "Group avatar" / "Invite link" entries (if present) into the **shipped** section with the today's-date heading.

If those items don't appear in the file, add a "Shipped 2026-06-02" line summarizing this work at the top of the shipped list.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/ROADMAP.md
git commit -m "docs: README + ROADMAP — group management, avatar, invite link"
```

---

## Phase 12 — Full test pass + manual smoke

### Task 28: Run the full suite

- [ ] **Step 1: Go tests**

Run: `cd bridge && go test -short ./...`
Expected: PASS. All new + pre-existing tests green.

- [ ] **Step 2: Swift tests**

Run the Swift test command from "Background context".
Expected: PASS. New test classes — `InviteLinkParserTests`, `ChatListViewModelGroupParticipantsTests`, `AddParticipantsPanelModelTests` — green.

- [ ] **Step 3: If anything fails**

Re-run only the failing test with verbose output, fix, re-run. Do NOT skip with `-skip` or comment out. Commit fixes as `test: …` follow-ups.

### Task 29: Manual smoke checklist

Open the app, signed into a paired account. Pick a group of ≥3 where you're admin.

- [ ] Add 2 contacts in one batch — strip shows two green ✓ rows; both appear in PARTICIPANTS; phone-side roster matches.
- [ ] Add a +phone non-contact with locked-down privacy — strip shows an orange ⚠ "invite sent" row; recipient gets the invite DM; group does not gain that row until they accept.
- [ ] Right-click an existing non-admin member → Promote — ADMIN badge appears in ~1s.
- [ ] Right-click an admin → Demote → confirm — badge disappears.
- [ ] Right-click a member → Remove → confirm — row vanishes; recipient's chat shows "removed".
- [ ] As a non-admin in a different group: ctx menu shows only Copy JID / Copy name. Invite icon present; Revoke button hidden inside the sheet.
- [ ] Hover the hero avatar — overlay appears. Change → pick image → crop → Apply. New photo lands within ~3s on the phone.
- [ ] Hover avatar → Remove photo → confirm — falls back to initials placeholder.
- [ ] Invite icon → sheet opens. Copy → paste into Notes works. Share → macOS share sheet opens. Revoke → URL changes; Revoke button disables for 3s.
- [ ] Paste `https://chat.whatsapp.com/<live-code>` into ⌘K — preview row appears with name + count. Click Join → chat opens.
- [ ] Paste a revoked code — preview row shows the error in red.
- [ ] Paste a `wa.me/<code>` variant — preview renders identically.

If any item fails, file a follow-up task and commit a fix.

### Task 30: Final commit + branch wrap-up

- [ ] **Step 1: Confirm clean state**

Run: `git status`
Expected: clean.

- [ ] **Step 2: Optional release tag bump**

Match the existing release cadence — bump `release: 0.6.0 — group management` if all features land in one go (mirrors `release: 0.5.0 — community directory…` style). Confer with the user before tagging.

---

## Spec self-review (already applied)

- [x] Spec coverage — bridge funcs (T2–T5), event (T6–T7), models (T9), wrappers (T10), helpers (T11–T15), views (T16–T18), inspector wiring (T19–T23), event routing (T24), sidebar (T25), cleanup (T26–T27), tests + smoke (T28–T29).
- [x] Placeholder scan — every code step shows the actual code; no TBDs or "similar to" references.
- [x] Type consistency — `BridgeParticipantModel` adds three optionals, used identically in `AddParticipantsPanelModel.applyResult` (T15), wrappers (T10), bridge struct (T1). `InviteLinkPreviewState` defined in T13, consumed in T14 + T25. `applyGroupParticipantsChange` signature `(chatJID, action, jids, at:)` consistent across T12 (test), T12 (impl), T24 (caller).

Two minor risks the engineer should be aware of:

1. **gomobile method-name shape.** When you call `go.updateGroupParticipants(...)` from Swift in T10, the generated selector labels are derived from the Go parameter names (`participantJIDsJSON:`). If the Swift code doesn't compile because the selector differs, open the generated Objective-C header (Xcode → jump to `BridgeClient` definition) and use the actual selector verbatim.

2. **AvatarCache invalidation.** If `AvatarCache` doesn't expose `invalidate(jid:)` or a `revision`-style cache buster, the simplest fallback is to call `AvatarCache.shared.clear()` (whole-cache purge) after a SetGroupPhoto — slightly heavier, but always works. Replace `invalidate(jid:)` with `clear()` if the surgical helper isn't trivial to add.

---

Plan complete and saved to `docs/superpowers/plans/2026-06-02-group-management.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
