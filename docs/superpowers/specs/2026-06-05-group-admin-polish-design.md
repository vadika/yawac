# v0.8.2 — Group Admin Polish (Announce + Locked)

**Date:** 2026-06-05
**Status:** Approved (design)
**Topic:** Expose two whatsmeow-supported group admin toggles
that aren't surfaced today: "Only admins can send messages"
(`SetGroupAnnounce`) and "Only admins can edit group info"
(`SetGroupLocked`). Mirror v0.7.1 T26 approval-mode pattern.

**Note on super-admin badge.** Recon confirmed
`ChatInfoView:1214` already renders a "SUPER" badge for
`isSuper == true` participants using `Theme.superRole` (purple).
Out of scope for v0.8.2.

## Goal

Two known v0.7.1+ gaps under group management are direct
whatsmeow RPC wrappers + ChatInfoView toggle rows:

- `SetGroupAnnounce(jid, on)` — announcement-group mode; only
  admins can post when on.
- `SetGroupLocked(jid, on)` — only admins can edit name /
  description / avatar when on.

Both ship as v0.8.2 patch, sharing the v0.7.1 approval-mode
infrastructure pattern verbatim.

## Non-goals

- Promote plain group → community parent (upstream RPC absent).
- Group destroy primitive (protocol absent).
- Allow non-admin edits when Locked=OFF (strict policy: yawac
  keeps name/description/avatar edits admin-only regardless of
  Locked state — see Q3).
- Surface state of these flags on sub-group rows in the
  community LINKED GROUPS directory (out of scope; sub-row UI
  stays as-is).

## Architecture

Mirror v0.7.1 T26 (approval-mode) spine.

```
┌─────────────────────────────────────────────────────────────┐
│ ChatInfoView (group + admin gated):                          │
│   "ADMINS ONLY — SEND MESSAGES" toggle row                   │
│   "ADMINS ONLY — EDIT GROUP INFO" toggle row                 │
│                                                              │
│ ComposerView:                                                │
│   if chat.isAnnounce && !chat.amAdmin →                      │
│     replace composer with "Only admins can send" notice      │
└─────────────────────────────────────────────────────────────┘
              │ WAClient wrappers
              ▼
┌─────────────────────────────────────────────────────────────┐
│ bridge/groups.go: SetGroupAnnounce(jid, on),                 │
│   SetGroupLocked(jid, on). JGroup gains is_announce +        │
│   is_locked; mapGroupInfo populates from                     │
│   GroupAnnounce.IsAnnounce + GroupLocked.IsLocked.           │
│ bridge/events.go: dispatchGroupInfo fans                     │
│   GroupAnnounceChanged + GroupLockedChanged when             │
│   evt.Announce / evt.Locked non-nil.                         │
└─────────────────────────────────────────────────────────────┘
              │ whatsmeow
              ▼
   SetGroupAnnounce / SetGroupLocked / events.GroupInfo
   {Announce: *types.GroupAnnounce, Locked: *types.GroupLocked}
```

Per-chat state lives on `Chat.isAnnounce: Bool` +
`Chat.isLocked: Bool` (mirrors `joinApprovalMode` from v0.7.1).
Populated from `BridgeGroupModel.isAnnounce`/`isLocked` via
`mergeGroups`; refreshed via `GroupAnnounceChanged` /
`GroupLockedChanged` events through
`ChatListViewModel.applyGroupAnnounce(_:on:)` /
`applyGroupLocked(_:on:)`.

## Bridge (Go)

`bridge/groups.go`:

```go
type JGroup struct {
    // ... existing fields ...
    IsAnnounce bool `json:"is_announce,omitempty"`
    IsLocked   bool `json:"is_locked,omitempty"`
}

// mapGroupInfo extension (after existing field assignments):
out.IsAnnounce = g.GroupAnnounce.IsAnnounce
out.IsLocked   = g.GroupLocked.IsLocked

// New funcs (mirror SetGroupJoinApprovalMode shape):
func (c *Client) SetGroupAnnounce(chatJIDStr string, on bool) error
func (c *Client) SetGroupLocked(chatJIDStr string, on bool) error
```

Each body: nil-client guard → ParseJID → empty-user/server guard
→ `c.wa.SetGroupAnnounce(ctx, jid, on)` / `SetGroupLocked` →
error wrap.

`bridge/events.go` (`dispatchGroupInfo` extension):

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

// In dispatchGroupInfo, after existing arms:
if evt.Announce != nil {
    payload := JGroupAnnounceChanged{
        ChatJID:   evt.JID.String(),
        On:        evt.Announce.IsAnnounce,
        ActorJID:  actorJID(evt.Sender),
        Timestamp: evt.Timestamp.Unix(),
    }
    b, _ := json.Marshal(payload)
    c.dispatch("GroupAnnounceChanged", string(b))
}
if evt.Locked != nil {
    // same shape with IsLocked, dispatched as "GroupLockedChanged"
}
```

## Swift bridge (WAClient)

```swift
nonisolated func setGroupAnnounce(chatJID: String, on: Bool) throws
nonisolated func setGroupLocked(chatJID: String, on: Bool) throws
```

Two new `WAClient.Event` cases:

```swift
case groupAnnounceChanged(chatJID: String, on: Bool,
                          actorJID: String, timestamp: Int64)
case groupLockedChanged(chatJID: String, on: Bool,
                        actorJID: String, timestamp: Int64)
```

Decoded in the existing `decode(kind:payload:)` switch, mirroring
the `joinApprovalModeChanged` arm.

## Models

`yawac/Bridge/JSONModels.swift` — `BridgeGroupModel` gains:

```swift
var isAnnounce: Bool   // omitempty wire key "is_announce"
var isLocked: Bool     // omitempty wire key "is_locked"
```

`yawac/Models/Chat.swift`:

```swift
var isAnnounce: Bool = false
var isLocked: Bool = false
```

## ChatListViewModel

```swift
func applyGroupAnnounce(chatJID: String, on: Bool) {
    updateChat(jid: chatJID) { $0.isAnnounce = on }
}
func applyGroupLocked(chatJID: String, on: Bool) {
    updateChat(jid: chatJID) { $0.isLocked = on }
}
```

Extend `mergeGroups` to copy `bridgeGroup.isAnnounce` →
`chat.isAnnounce`, same for `isLocked`.

## ContentView

Add event arms next to the existing `joinApprovalModeChanged`:

```swift
case .groupAnnounceChanged(let chatJID, let on, _, _):
    vm.applyGroupAnnounce(chatJID: chatJID, on: on)
case .groupLockedChanged(let chatJID, let on, _, _):
    vm.applyGroupLocked(chatJID: chatJID, on: on)
```

## ChatInfoView — two new sectionCards

Place adjacent to JOIN APPROVAL section (~line 837), admin-gated.

```swift
if isCurrentUserAdmin(g) && g.isParent == false {
    sectionCard(label: "ADMINS ONLY — SEND MESSAGES") {
        Toggle("", isOn: Binding(
            get: { (group?.isAnnounce ?? g.isAnnounce) },
            set: { newValue in
                applyAnnounceToggle(newValue, chatJID: g.jid)
            }
        )).labelsHidden()
    }
    sectionCard(label: "ADMINS ONLY — EDIT GROUP INFO") {
        Toggle("", isOn: Binding(
            get: { (group?.isLocked ?? g.isLocked) },
            set: { newValue in
                applyLockedToggle(newValue, chatJID: g.jid)
            }
        )).labelsHidden()
    }
}
```

Helper methods mirror v0.7.1 T26's `applyDisappearingTimer`:
optimistic local flip → `Task.detached { try client.setGroupAnnounce(...) }`
→ revert + inline error on failure.

## ComposerView gating

At the top of the composer body (before existing send affordances):

```swift
if isAnnounceMode && !amAdmin {
    HStack {
        Image(systemName: "megaphone.fill")
        Text("Only admins can send messages in this group.")
            .italic()
            .foregroundStyle(Theme.textMuted)
    }
    .padding(...)
    .background(Theme.surface)
    return  // suppress composer
}
```

`isAnnounceMode` reads from `chat.isAnnounce` via the existing
chat lookup in ComposerView; `amAdmin` from `chat.amAdmin` (already
populated by v0.7.1 T29).

For groups (`chat.isGroup == true`); 1:1 chats never gate.

## Error handling

| Surface | Pattern |
|---|---|
| Announce toggle fail | Revert optimistic; inline red strip under row, 6s auto-dismiss (mirrors JOIN APPROVAL) |
| Locked toggle fail | Same |
| Announce-gated send (server reject if UI gate misses) | Existing per-send error toast — no new surface |

## Testing

### Bridge

- `SetGroupAnnounce` / `SetGroupLocked` unpaired-client → error.
- `SetGroupAnnounce` bad JID → parse error.
- `mapGroupInfo` carries `is_announce` + `is_locked` from
  `types.GroupInfo`.
- `dispatchGroupInfo` emits `GroupAnnounceChanged` when
  `evt.Announce != nil` (with `On=true` and `On=false` cases).
- Same for `GroupLockedChanged`.

### Swift

- `ChatListViewModel.applyGroupAnnounce` flips `Chat.isAnnounce`.
- `ChatListViewModel.applyGroupLocked` flips `Chat.isLocked`.
- `mergeGroups` populates both fields from `BridgeGroupModel`.

### Manual smoke

- Toggle "Admins only — send messages" in chat info → second
  account in the group sees its composer flip to the read-only
  notice. Toggle off → composer returns.
- Same for "Admins only — edit group info" → second account's
  ChatInfoView name/description/avatar edit affordances stay
  admin-gated by yawac's strict policy (no UI change for that
  account; the toggle is still respected server-side for the
  admin's own actions).
- Flip mode on phone → toggle row in yawac reflects within ~1s.

## Files touched

**New:** none (all extensions to existing files).

**Modified:**

- `bridge/groups.go` — `JGroup` field additions, `mapGroupInfo`
  extension, two new `SetGroupAnnounce` / `SetGroupLocked` funcs.
- `bridge/groups_test.go` — extended.
- `bridge/events.go` — `dispatchGroupInfo` fans
  `GroupAnnounceChanged` + `GroupLockedChanged`.
- `bridge/events_dispatch_test.go` — extended.
- `bridge/jsonmodels.go` — two new payload types
  (`JGroupAnnounceChanged`, `JGroupLockedChanged`).
- `yawac/Bridge/WAClient.swift` — two new wrappers, two new
  Event cases, two new decode arms.
- `yawac/Bridge/JSONModels.swift` — `BridgeGroupModel` two new
  fields + CodingKeys.
- `yawac/Models/Chat.swift` — two new `Bool` fields.
- `yawac/ViewModels/ChatListViewModel.swift` — two new helpers
  + `mergeGroups` extension.
- `yawac/ContentView.swift` — two new event arms.
- `yawac/Views/ChatInfoView.swift` — two new sectionCards +
  optimistic-flip helpers.
- `yawac/Views/ComposerView.swift` — announce-mode gate at top
  of body.
- `yawacTests/ChatListViewModelGroupAnnounceLockedTests.swift`
  (new).
- `project.yml` — bump `CFBundleShortVersionString` 0.8.1 →
  0.8.2, `CFBundleVersion` 10 → 11.
- `docs/ROADMAP.md` — strike Group `Admins only…` rows.
