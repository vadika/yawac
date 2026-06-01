# Group Management Design Spec

**Date:** 2026-06-02
**Status:** Approved (design)
**Topic:** Live participant management (add / remove / promote /
demote), group avatar edit, and invite link with QR + paste-to-join,
surfaced from `ChatInfoView` and the ⌘K sidebar search. Admin-gated
where the server requires it. Cross-device sync via whatsmeow's
`events.GroupInfo`. Builds on the existing name + description edit
plumbing landed 2026-06-01.

## Goal

`ChatInfoView` today renders a group's participant list read-only,
the hero avatar from `AvatarCache` with no setter, and offers no
invite-link surface. Admins have to fall back to the phone for every
roster change, avatar swap, or invite-link share. Wire up the
whatsmeow primitives (`UpdateGroupParticipants`, `SetGroupPhoto`,
`GetGroupInviteLink`, `GetGroupInfoFromLink`, `JoinGroupWithLink`) so
admins can drive all three from the desktop, route inbound roster
changes from `events.GroupInfo` into the local participants cache,
and let any user paste an invite link into ⌘K search to preview +
join.

## Non-goals

- Membership-approval-request management (admin approving / rejecting
  incoming join requests via `UpdateGroupRequestParticipants`).
  Deferred — separate UI surface.
- Group settings — announce-only / edit-by-admin / disappearing-default
  toggles. Same `events.GroupInfo` carries these but out of scope.
- Drag-to-add from sidebar contact rows. Picker is the only entry path.
- Avatar input formats beyond JPEG / PNG / HEIC. SVG / GIF / WebP rejected
  at the `NSOpenPanel` filter.
- Editing the photo crop after upload — re-upload is the only edit.
- Audit log / "added by" footers under participant rows. The actor JID
  is captured in the event payload but not rendered yet.
- LID ↔ PN identity reconciliation beyond what `JIDNormalize.canonical`
  already does.

## Architecture

Three subsystems share one spine:

1. **Bridge writes** — five new gomobile-bindable Go functions in
   `bridge/groups.go` (participants update, set / remove photo, get
   invite link, group info from link, join via link).
2. **Bridge events** — a new `GroupParticipantsChanged` event
   dispatched from `events.GroupInfo` whenever its `Join` / `Leave`
   / `Promote` / `Demote` slices are non-empty. Existing
   `GroupInfoChanged` (name + description) keeps its current shape.
3. **Swift UI** — three new views inside `ChatInfoView`:
   `AddParticipantsPanel` (inline expansion), `AvatarCropSheet`
   (modal), `InviteLinkSheet` (modal). Plus a ⌘K hook for
   paste-to-join.

```
┌─────────────────────────────────────────────────────────────┐
│ ChatInfoView (admin gating via isCurrentUserAdmin)          │
│ ├─ Hero avatar      → hover overlay → action menu           │
│ │                     → NSOpenPanel → CropSheet → upload    │
│ ├─ Action row       → "Invite" icon → InviteLinkSheet       │
│ ├─ Participants     → ctx menu (Promote/Demote/Remove)      │
│ │                   → "+ Add member" → AddParticipantsPanel │
│ │                     (inline chip picker + phone fallback) │
│ └─ confirmationDialog for 4 destructive ops                 │
└─────────────────────────────────────────────────────────────┘
              │ WAClient wrappers
              ▼
┌─────────────────────────────────────────────────────────────┐
│ bridge/groups.go — 5 new gomobile funcs                     │
│   UpdateGroupParticipants · SetGroupPhoto · RemoveGroupPhoto│
│   GetGroupInviteLink · JoinGroupViaLink · GroupInfoFromLink │
│ bridge/events.go — new dispatchGroupParticipants for        │
│   events.GroupInfo.{Join,Leave,Promote,Demote}              │
└─────────────────────────────────────────────────────────────┘
              │ whatsmeow
              ▼
   UpdateGroupParticipants / SetGroupPhoto / GetGroupInviteLink
   GetGroupInfoFromLink / JoinGroupWithLink
```

The dead stub at `yawac/Views/GroupInfoView.swift` is deleted (real
group UI lives in `ChatInfoView`).

### Bridge (Go)

`bridge/groups.go` gains five exported methods. All accept and
return only gomobile-friendly types (`string`, `int64`, `bool`,
`[]byte`, JSON strings for arrays).

```go
// JParticipant gains optional fields. The server returns a slice of
// participants on UpdateGroupParticipants; rows with a non-zero
// error code carry an inline failure cause (e.g. 403 privacy, in
// which case AddRequest carries an invite code the user can share
// via DM as a fallback).
type JParticipant struct {
    JID         string `json:"jid"`
    IsAdmin     bool   `json:"is_admin"`
    IsSuper     bool   `json:"is_super_admin"`
    ErrorCode   int    `json:"error_code,omitempty"`
    InviteCode  string `json:"invite_code,omitempty"`
    InviteExpiry int64 `json:"invite_expiry,omitempty"`
}

// UpdateGroupParticipants applies one of "add", "remove", "promote",
// "demote" to a comma-separated batch. participantJIDs is JSON
// `[]string`. Returns JSON `[]JParticipant` of the server response
// (the changed rows, NOT the full roster) — caller merges into the
// local cache.
func (c *Client) UpdateGroupParticipants(
    chatJID, action, participantJIDsJSON string,
) (string, error)

// SetGroupPhoto uploads JPEG bytes. Returns the new picture ID.
// Surfaces ErrInvalidImageFormat verbatim so the caller can show
// "Image format not accepted by WhatsApp".
func (c *Client) SetGroupPhoto(chatJID string, jpeg []byte) (string, error)

// RemoveGroupPhoto wraps SetGroupPhoto with nil bytes.
func (c *Client) RemoveGroupPhoto(chatJID string) error

// GetGroupInviteLink returns the full `https://chat.whatsapp.com/CODE`.
// reset=true revokes the prior link before issuing a new one.
// Surfaces ErrGroupInviteLinkUnauthorized / ErrGroupNotFound /
// ErrNotInGroup verbatim.
func (c *Client) GetGroupInviteLink(chatJID string, reset bool) (string, error)

// GroupInfoFromLink resolves a chat.whatsapp.com URL or bare code into
// a JGroup preview (no participants — light-weight). Strips the URL
// prefix Go-side as a defence in depth; Swift already does it too.
func (c *Client) GroupInfoFromLink(code string) (string, error)

// JoinGroupViaLink joins via invite link. Returns the joined JID.
// Same dual-return semantics as JoinSubGroup: a bare JID alone may
// mean the server queued a membership_approval_request — caller probes
// via GetGroupInfo to distinguish the joined case from pending.
func (c *Client) JoinGroupViaLink(code string) (string, error)
```

`UpdateGroupParticipants` accepts the action as a string ("add" /
"remove" / "promote" / "demote") to keep gomobile signatures simple,
maps to the `whatsmeow.ParticipantChange` constants Go-side, and
returns `("", error)` on any non-element-level error. Element-level
per-row errors are surfaced via `JParticipant.ErrorCode` instead.

### Bridge events (Go)

New dispatcher in `bridge/events.go`:

```go
type JGroupParticipantsChanged struct {
    ChatJID   string   `json:"chat_jid"`
    Action    string   `json:"action"`     // add | remove | promote | demote
    ActorJID  string   `json:"actor_jid"`  // who did the change; may be empty
    JIDs      []string `json:"jids"`
    Timestamp int64    `json:"timestamp"`
}

// dispatchGroupParticipants is called from the existing GroupInfo
// switch arm. It fans out up to four events when Join / Leave /
// Promote / Demote arrays are non-empty in the same payload. Sender
// JID populates ActorJID; missing sender → empty string. The
// existing dispatchGroupInfo (name + description) keeps its current
// gating logic unchanged.
func (c *Client) dispatchGroupParticipants(evt *events.GroupInfo) {
    fan := []struct {
        action string
        jids   []types.JID
    }{
        {"add", evt.Join}, {"remove", evt.Leave},
        {"promote", evt.Promote}, {"demote", evt.Demote},
    }
    actor := ""
    if evt.Sender != nil { actor = evt.Sender.String() }
    for _, f := range fan {
        if len(f.jids) == 0 { continue }
        out := make([]string, len(f.jids))
        for i, j := range f.jids { out[i] = j.String() }
        b, _ := json.Marshal(JGroupParticipantsChanged{
            ChatJID: evt.JID.String(), Action: f.action,
            ActorJID: actor, JIDs: out,
            Timestamp: evt.Timestamp.Unix(),
        })
        c.dispatch("GroupParticipantsChanged", string(b))
    }
}
```

`bridge/events.go`'s existing `case *events.GroupInfo:` block calls
both `dispatchGroupInfo(v)` and `dispatchGroupParticipants(v)` — one
event from whatsmeow can carry both kinds of change.

### Swift bridge (WAClient)

Five new wrappers in `yawac/Bridge/WAClient.swift`, all mirroring
existing patterns (JSON decode for arrays, `nonisolated` where the
call should not pin MainActor):

```swift
func updateGroupParticipants(chatJID: String, action: String,
                             participantJIDs: [String])
    throws -> [BridgeParticipantModel]
func setGroupPhoto(chatJID: String, jpeg: Data) throws -> String
nonisolated func removeGroupPhoto(chatJID: String) throws
func getGroupInviteLink(chatJID: String, reset: Bool) throws -> String
func groupInfoFromLink(code: String) throws -> BridgeGroupModel
func joinGroupViaLink(code: String) throws -> String
```

`WAClient.Event` gains:

```swift
case groupParticipantsChanged(chatJID: String, action: String,
                              actorJID: String, jids: [String],
                              timestamp: Int64)
```

Decoded in the same `decode(kind:payload:)` switch using the existing
camelCase-with-snake-case-CodingKeys pattern.

`BridgeParticipantModel` (Swift mirror of `JParticipant`) gains
optional `errorCode: Int?`, `inviteCode: String?`, `inviteExpiry: Int64?`.

### Swift views

**`Views/AddParticipantsPanel.swift`** — new file. Inline expansion
inside `ChatInfoView` when the section-header "+ Add member" button
is tapped. Layout:

```
┌── PARTICIPANTS ─────────── + Add member ──┐
│ ┌─────────────────────────────────────┐  │
│ │ [Anna Berg ×] [Dana Park ×] | …     │  │  ← chip row + search field
│ ├─────────────────────────────────────┤  │
│ │ SUGGESTIONS                          │  │
│ │ Carlos Romero                         │  │
│ │ + Add +358 40 555 1234 (on WhatsApp)  │  │  ← appears when query
│ │ — scroll for more —                   │  │    is a +phone
│ ├─────────────────────────────────────┤  │
│ │  Cancel              Add 2          │  │
│ └─────────────────────────────────────┘  │
│                                          │
│ — existing participant rows below —      │
└──────────────────────────────────────────┘
```

State (`@Observable` view-model `AddParticipantsPanelModel`):

- `chips: [BridgeContact]` — chosen rows.
- `query: String` — search text.
- `suggestions: [BridgeContact]` — `session.contactNames` filtered
  by `query`, minus chips already added and minus existing group
  members.
- `phoneCandidate: PhoneCheckResult?` — populated when `query`
  matches `^\+?[0-9 ]{7,}$` after a 250ms debounce; cleared on
  query change.
- `inFlight: Bool` — disables the panel while the bridge call runs.
- `result: AddResult?` — populated by the bridge response. Renders an
  inline strip below the panel:
  - `✓ Anna · ⚠ Carlos (sent invite — pending) · ✗ Dana (not added)`
  - Dismiss button on the right of the strip.

`Add N` calls `WAClient.updateGroupParticipants(action: "add", …)` once
for the full chip set, then merges the response into
`group.participants`. Failed rows (`errorCode != 0`) drop their chips
from the panel but remain visible in the result strip until dismissed.
`session.chatList?.applyGroupParticipantsChange(...)` is the cache-
update hook (see below).

**`Views/AvatarCropSheet.swift`** — new file. Modal sheet (`.sheet`
from the hero avatar's hover overlay action menu). `NSViewRepresentable`
wraps a custom `NSView` with:

- background `NSImageView` displaying the picked image.
- circular `CAShapeLayer` mask centered.
- pan via `NSPanGestureRecognizer`.
- zoom via an `NSSlider` (1×–3×).

`Apply` renders the masked rect to a 640×640 `NSBitmapImageRep`
(`NSImage.drawRepresentation` into off-screen context), exports JPEG
at quality 0.85. Resulting `Data` is fed to
`WAClient.setGroupPhoto(jpeg:)` off-main via `Task.detached`. Success →
`AvatarCache.invalidate(jid:)` + a manual `FetchProfilePicture` retry
~500ms later to repopulate. Failure → inline red text under the hero
("Couldn't update photo — <localizedDescription>"), sheet stays open.

Hover overlay is detected with `.onHover`; admin-only via the same
`isCurrentUserAdmin` gate as the name / description editors. The
overlay is a 50% black circle with "EDIT PHOTO" text in 11pt over
the avatar; only renders for admins. Tap presents an action menu:

- "Change photo…" → `NSOpenPanel` (filters: jpg, jpeg, png, heic).
- "Remove photo" → `confirmationDialog` → `removeGroupPhoto`.

**`Views/InviteLinkSheet.swift`** — new file. Modal sheet from a 4th
action-row icon (`link` SF symbol) added to the existing
Mute / Search / Leave row in `ChatInfoView` for groups. Layout
(side-by-side):

```
┌── Invite to "Climbing Crew" ─────────────────────────┐
│  ┌──────────┐  Anyone with this link can join.       │
│  │   QR     │  ┌────────────────────────────────┐    │
│  │  square  │  │ chat.whatsapp.com/AbCdEfGhIjKl │    │
│  │ 140×140  │  └────────────────────────────────┘    │
│  └──────────┘  [ Copy link ]                          │
│                [ Share…    ]                          │
│                [ Revoke link ]   ← admin-only         │
│                                                       │
│                                            [ Done ]   │
└──────────────────────────────────────────────────────┘
```

State:

- `.task` runs `getGroupInviteLink(chatJID:, reset:false)`. Spinner
  while pending. Error replaces the QR + link area with an inline
  red row carrying the localized error.
- Copy → `NSPasteboard.general.clearContents()` +
  `setString(link, forType:.string)`.
- Share → `NSSharingServicePicker(items:[link])` anchored on the
  Share button.
- Revoke (admin only) → `confirmationDialog` → calls
  `getGroupInviteLink(reset:true)` → updates state with the new URL.
  A 3s cooldown disables the Revoke button after a successful call
  to defend against accidental double-click.

QR is rendered with `CIFilter.qrCodeGenerator` (no third-party
dependency), scaled with `CIFilter.lanczosScaleTransform` to 140pt.
Error correction = M.

**⌘K paste-to-join** — `ChatListViewModel` (where global search
lives) gains:

```swift
var inviteLinkPreview: InviteLinkPreviewState? = nil

enum InviteLinkPreviewState {
    case loading(code: String)
    case ready(BridgeGroupModel, code: String)
    case error(String)
}
```

On every query change, run `InviteLink.parseCode(query)`. If the
result is non-nil:

1. Set `.loading(code:)`.
2. Debounce 300ms.
3. Off-main: `groupInfoFromLink(code)`.
4. On success → `.ready(info, code)`. On failure → `.error(msg)`.

The sidebar search-results view renders this state as a single
top-row card above all other sections: `🔗 Join group: <name> ·
<member count> members`. Tap on `.ready` → off-main
`joinGroupViaLink(code)` → on returned JID, probe `getGroupInfo` →
on success `mergeGroups([info])` + `requestSelectChat(joinedJID)`.
Pending-approval (probe fails) flips the row text to "Request sent
— waiting for admin approval" (mirrors `ChatInfoView`'s
`joinStatusByJID` pattern).

**`InviteLink.parseCode(_:)`** — pure helper in `yawac/Utilities/`.
Accepts:

- `https://chat.whatsapp.com/<code>`
- `http://chat.whatsapp.com/<code>`
- `chat.whatsapp.com/<code>`
- `https://wa.me/<code>` and bare `wa.me/<code>`
- bare `<code>` only when length ≥ 16 and matches `[A-Za-z0-9]+`
  (so casual single-word search queries don't trigger preview).

### Cache + reconciliation

`ChatListViewModel` gains:

```swift
func applyGroupParticipantsChange(chatJID: String,
                                  action: String,
                                  jids: [String])
```

Sidebar-row cache is shallow — `Chat` carries a participant count, not
the roster. So `applyGroupParticipantsChange` only updates the count
on `add` / `remove`, and is a no-op for `promote` / `demote`. The full
roster (with admin flags) lives in `ChatInfoView`'s
`@State group: BridgeGroupModel`, refreshed via `loadGroup()` whenever
a relevant event arrives. The view model also subscribes to the
event-bus `groupParticipantsChanged` case from `WAClient.eventStream()`.

`ChatInfoView` listens for `groupParticipantsChanged` events whose
`chatJID == self.chatJID` and re-runs `loadGroup()` to refresh the
participants list from the server (cheaper than diffing, and matches
the existing `GroupInfoChanged` reload pattern).

**Local vs server-driven updates.** Local actions (add via picker,
remove / promote / demote via ctx menu, both avatar paths, all invite-
link ops) update view-model state immediately from the bridge call's
return value — there is no wait for the server-fanned event. The same
event then arrives via `groupParticipantsChanged` / `GroupInfoChanged`
and re-runs `loadGroup()` as a no-op reconciliation (the server-side
view is now what's already on screen). Updates originating on the
phone or another companion device take the same event path; in that
case the reload is the only source of truth.

### Admin gating

`isCurrentUserAdmin` already lives in `ChatInfoView`. The new
surfaces gate as follows:

| Surface | Gating |
|---|---|
| Participant ctx-menu Promote / Demote / Remove | admin |
| "+ Add member" section-header button | admin |
| Hero hover-overlay edit affordance | admin |
| Action-row Invite icon | everyone (read + share) |
| Revoke button in InviteLinkSheet | admin |
| ⌘K paste-to-join | everyone |

Non-admins clicking the invite icon still get a working link
(server enforces "members can share invite link" by default; if the
group's setting blocks non-admins, `GetGroupInviteLink` returns
`ErrGroupInviteLinkUnauthorized`, which the sheet renders as the
inline error row).

## Error handling

All non-fatal errors surface inline, no NSAlert outside the four
destructive `confirmationDialog`s already covered (Remove member,
Demote admin, Revoke invite, Remove group photo).

| Surface | Pattern |
|---|---|
| Picker per-participant on add | inline strip with ✓ / ⚠ / ✗ rows |
| Avatar set / remove | inline red text below hero, sheet stays open |
| Invite-link fetch / revoke | inline red row replacing QR + link area |
| Participant ctx-menu op | inline red text in PARTICIPANTS section header, 6s auto-dismiss |
| ⌘K paste-to-join preview | row text flips to error state |

The picker's "⚠ pending" row is specifically for the
`AddRequest` privacy-fallback case: when adding a participant whose
privacy settings block direct add, whatsmeow returns
`Error: <code>` + an `AddRequest{Code, Expiration}` payload — the
server has already queued an invite-via-message on our behalf. We
surface "Couldn't add — invite sent, pending acceptance" rather
than treating it as a failure.

## Testing

**`bridge/groups_test.go`** extended with table-driven cases:

- `UpdateGroupParticipants` add → response with two success rows.
- `UpdateGroupParticipants` add → mixed success + 403-with-AddRequest
  (asserts `InviteCode` + `InviteExpiry` populated).
- `UpdateGroupParticipants` add → mixed success + plain error
  (asserts `ErrorCode` populated, no AddRequest).
- `UpdateGroupParticipants` remove / promote / demote → action verb
  routed to correct `ParticipantChange` constant.
- `SetGroupPhoto` success → returns picture ID from response.
- `SetGroupPhoto` invalid format → maps to `ErrInvalidImageFormat`.
- `RemoveGroupPhoto` → calls SetGroupPhoto with nil bytes.
- `GetGroupInviteLink` get vs reset → iqGet vs iqSet routing.
- `GetGroupInviteLink` unauthorized / not-in-group → error mapping.
- `GroupInfoFromLink` accepts `chat.whatsapp.com/<code>`, `<code>`,
  and rejects garbage.
- `JoinGroupViaLink` `membership_approval_request` branch → returns
  JID, no group node, caller can probe.

**`bridge/events_dispatch_test.go`** extended:

- `events.GroupInfo{Join: […]}` → one `GroupParticipantsChanged`
  with action="add", correct jid list.
- `events.GroupInfo{Join: […], Promote: […]}` → two events, one per
  action.
- `events.GroupInfo` with all four slices populated → four events.
- `events.GroupInfo` with name + Join populated → both
  `GroupInfoChanged` and `GroupParticipantsChanged` fire.
- `events.GroupInfo` with empty Sender → ActorJID is "".

**`yawacTests/`**:

- `InviteLinkParserTests` — every accepted URL shape returns the
  bare code; rejects single-word queries < 16 chars; rejects URLs
  pointing at other hosts.
- `ChatListViewModelTests` —
  `applyGroupParticipantsChange(.add, jids)` increments
  `Chat.participants` count; `.remove` decrements; `.promote` flips
  the cached participant's isAdmin.
- `AddParticipantsPanelModelTests` — chip add/remove, debounce
  coalescing of phone resolution (one `CheckOnWhatsApp` per quiet
  burst, not per keystroke), failed phone resolution leaves chip
  set untouched.

**Manual smoke (release runbook)**:

- As admin in a group of ≥3: add 2 contacts at once → roster grows
  on yawac and on phone. Add 1 +phone non-contact with locked-down
  privacy → "Couldn't add — invite sent" strip on yawac (the
  `AddRequest` privacy-fallback branch); recipient receives an invite
  DM with the link, group does NOT gain the row until they accept.
- As admin: promote → ADMIN badge appears within ~1s. Demote → badge
  disappears. Remove → row vanishes; recipient's chat shows
  "<you> removed <them>".
- As non-admin in a group: ctx menu shows only Copy JID / Copy name.
  Invite icon shows; tapping opens sheet with link but no Revoke
  button.
- Avatar: change → crop → apply. Verify the new picture renders in
  the inspector hero, the sidebar row, and on the phone within ~3s.
  Remove → falls back to initials placeholder.
- Invite link: copy to clipboard, paste into Mail / Slack — link
  opens chat.whatsapp.com in browser correctly. Revoke → URL
  changes. Verify the cooldown disables Revoke for 3s.
- ⌘K paste of: live link (preview renders, Join works) · revoked
  link (`ErrInviteLinkRevoked` → error row) · `wa.me` variant
  (preview renders).

## Open risks

- `events.GroupInfo.Sender` is sometimes nil per whatsmeow research
  notes (`docs/TODO.md` § Groups). `ActorJID` may be empty in
  `GroupParticipantsChanged` for some flows — Swift treats as
  "unknown editor" with no UI consequence today.
- LID ↔ PN duality on participant add: a contact picked by
  `@s.whatsapp.net` may come back in the server response as `@lid`
  for announcement-group contexts. Reconciliation already handled by
  `JIDNormalize.canonical`; new rows go through the same path on
  merge.
- `SetGroupPhoto` returns a picture ID that is **not** the URL we'd
  fetch via `FetchProfilePicture`. We use it only to gate the cache
  invalidate (forces refresh on next access), not as a content key.
- No client-side rate limit on `GetGroupInviteLink`. Spam-clicking
  Revoke could 429 the IQ; the 3s cooldown is the only defence.
  Future hardening can add a shared throttle if needed.
- `JoinGroupViaLink` dual return (joined vs queued) is opaque per
  the bridge layer. The probe-`GetGroupInfo` round trip is the only
  way to distinguish — same trade-off as the existing community
  `JoinSubGroup` path. Acceptable.
- HEIC decode requires macOS 14+ (already our minimum). PNG / JPEG
  fall back to standard decode paths.

## Files touched

New:
- `bridge/groups_test.go` (extended)
- `yawac/Views/AddParticipantsPanel.swift`
- `yawac/Views/AvatarCropSheet.swift`
- `yawac/Views/InviteLinkSheet.swift`
- `yawac/Utilities/InviteLink.swift`
- `yawacTests/InviteLinkParserTests.swift`
- `yawacTests/AddParticipantsPanelModelTests.swift`

Modified:
- `bridge/groups.go` — five new exported methods, extended
  `JParticipant`.
- `bridge/events.go` — new dispatcher, switch arm calls both
  dispatchers from one `events.GroupInfo`.
- `bridge/events_dispatch_test.go` — new cases.
- `yawac/Bridge/WAClient.swift` — five new wrappers, new Event case,
  new decode arm.
- `yawac/Bridge/JSONModels.swift` — three optional fields on
  `BridgeParticipantModel`.
- `yawac/Views/ChatInfoView.swift` — section-header "+ Add member"
  button, participant ctx-menu admin items, hero hover overlay,
  action-row Invite icon, two new `confirmationDialog`s, listener
  for `groupParticipantsChanged`.
- `yawac/ViewModels/ChatListViewModel.swift` —
  `applyGroupParticipantsChange`, `inviteLinkPreview` state and
  parser hook, event-stream subscription extension.

Deleted:
- `yawac/Views/GroupInfoView.swift` (dead stub).

Updated docs:
- `README.md` — features bullet for participant management, avatar
  edit, invite link / QR / paste-to-join.
- `docs/ROADMAP.md` — mark these items shipped after merge.
