# Community Admin Design Spec

**Date:** 2026-06-02
**Status:** Approved (design)
**Topic:** Community admin actions — create new group, create new
community, create new sub-group inside a community, link/unlink
existing sub-groups, toggle membership-approval mode, review pending
join requests. Creation surfaces from a sidebar "+" menu (plain
group + community) and from the community parent's `ChatInfoView`
LINKED GROUPS section (new sub-group). Admin actions surface from
`ChatInfoView` for community parents (link/unlink) and sub-groups
(approval-mode toggle + request queue), with a sidebar chip on chat
rows that have pending requests. Builds on the group management
plumbing landed 2026-06-02 (live participant management, invite
links, paste-to-join).

## Goal

The group / community surface in yawac today is read-only-plus-edit.
Users can browse the linked sub-group directory of a community
parent and join sub-groups via invite link, and admins can edit
existing groups (name, description, avatar, participants, invite
link). What is missing on every level:

- **Creation.** `bridge.CreateGroup(name, participantJIDs)` exists
  but has no UI caller, and only handles plain groups — community
  parents (`IsParent=true`) and sub-groups of a community
  (`LinkedParentJID=<jid>`) are not exposed at all.
- Attach existing groups to a community parent (`LinkGroup`).
- Detach a sub-group from its parent (`UnlinkGroup`).
- Toggle a sub-group's "require admin approval to join"
  (`SetGroupJoinApprovalMode`).
- See or act on pending join requests
  (`GetGroupRequestParticipants` / `UpdateGroupRequestParticipants`).

Wire the whatsmeow primitives behind those operations so a user
can stand up a new group / community / sub-group from the desktop
and an admin can drive structure + moderation without falling back
to the phone. Surface the pending-request count in the sidebar so
admins notice without opening the chat.

## Non-goals

- Setting group avatar / description / approval-mode / disappearing
  default at creation time. All of those are post-creation edits
  using already-shipped flows.
- Inviting non-contact `+phone` numbers during creation. The
  AddParticipantsPanel pattern (phone resolver + `AddRequest`
  privacy fallback) already exists; for v0.7.0 the create sheets
  pick from contacts only and use the existing
  participant-management UI for any post-creation phone adds.
- Editing a community description distinct from the parent group's
  description (single field today).
- Per-request justification text from the joining user — rendered as
  plain row with no rich preview.
- Inbound `JoinRequest` push event — whatsmeow does not emit one. We
  poll (see Architecture). Stale-window documented.
- LID ↔ PN identity reconciliation beyond what
  `JIDNormalize.canonical` already does.
- Approval-mode UI for plain non-community groups. The toggle works
  there too; we expose it only inside community sub-groups for
  v0.7.0 scope clarity. Revisit in a follow-up if asked.

## Architecture

Three subsystems share one spine; mirrors the prior group-management
spec (`docs/superpowers/specs/2026-06-02-group-management-design.md`).

1. **Bridge writes** — seven new gomobile-bindable Go functions in
   `bridge/groups.go`: create community, create sub-group, link
   sub-group, unlink sub-group, get join requests, update join
   requests, set approval mode. (Existing `CreateGroup` for plain
   groups is reused — has a Swift wrapper, just needs UI.)
2. **Bridge events** — extend `dispatchGroupInfo` to fan out a new
   `JoinApprovalModeChanged` event when
   `events.GroupInfo.MembershipApprovalMode` is non-nil, and to
   carry `linked_parent_jid` / `is_default_subgroup` in the
   `GroupInfoChanged` payload (today only name + description).
   Creation paths surface in the sidebar via the existing
   `JoinedGroup` event (already wired) — no new event needed.
3. **Swift UI** — six new views (`NewGroupSheet`,
   `NewCommunitySheet`, `NewSubGroupSheet`, `LinkSubGroupSheet`,
   `PendingRequestsSection`, sidebar pending chip), one sidebar
   "+" header button + menu, and one new state object
   (`JoinRequestStore`) inside `ChatInfoView` and `ChatListView`.

```
┌──────────────────────────────────────────────────────────────┐
│ Sidebar header ("+" button → menu)                           │
│ ├─ New group…       → NewGroupSheet                          │
│ └─ New community…   → NewCommunitySheet                      │
│                                                               │
│ ChatInfoView (community parent OR sub-group, admin gating)   │
│                                                               │
│ Parent view:                                                  │
│ ├─ LINKED GROUPS section header "+" menu (admin only):        │
│ │    "Link existing group…"  → LinkSubGroupSheet              │
│ │    "Create new sub-group…" → NewSubGroupSheet               │
│ │   → existing subgroup rows: ctx menu "Unlink"               │
│ │     (hidden when isDefaultSubGroup)                         │
│                                                               │
│ Sub-group view:                                               │
│ ├─ "Require admin approval to join" toggle row (admin only)   │
│ ├─ PENDING REQUESTS section (admin + mode=on + count>0)       │
│ │   → per-row ✓/✗ buttons + "Approve all N" header button     │
│                                                               │
│ Sidebar (ChatListView):                                       │
│ └─ Group row: pending-count chip next to unread chip          │
└──────────────────────────────────────────────────────────────┘
              │ WAClient wrappers
              ▼
┌──────────────────────────────────────────────────────────────┐
│ bridge/groups.go — 7 new + 1 reused gomobile funcs            │
│   CreateGroup (reused) · CreateCommunity · CreateSubGroup     │
│   LinkSubGroup · UnlinkSubGroup                               │
│   GetGroupJoinRequests · UpdateGroupJoinRequests              │
│   SetGroupJoinApprovalMode                                    │
│ bridge/events.go — extend dispatchGroupInfo for               │
│   MembershipApprovalMode → JoinApprovalModeChanged            │
│   linked_parent_jid + is_default_subgroup in GroupInfoChanged │
└──────────────────────────────────────────────────────────────┘
              │ whatsmeow
              ▼
   CreateGroup (with IsParent / LinkedParentJID flags) /
   LinkGroup / UnlinkGroup / GetGroupRequestParticipants /
   UpdateGroupRequestParticipants / SetGroupJoinApprovalMode
```

**Pending-count source of truth.** A new `JoinRequestStore` actor
(Swift, `@MainActor @Observable`) keyed by group JID exposes
`[chatJID: Int]`. Sidebar rows and the in-chat PENDING REQUESTS
section both observe one state. Whatsmeow has no inbound
`JoinRequest` event, so the store refreshes on:

- `WAClient` `.connected` event (cold-start reconcile).
- `NSApplication.didBecomeActiveNotification` (with a 30s
  in-foreground throttle to avoid bouncing on Cmd-Tab).
- `ChatInfoView.loadGroup()` for the open group, when admin and
  approval-mode on.
- Local `approve` / `reject` success (decrement, no extra IQ).
- `JoinApprovalModeChanged` event: `on=false` clears the entry,
  `on=true` triggers a refresh.

Refresh enumerates the admin'd approval-mode groups derived from the
current chat list. Concurrency bounded to 4 parallel IQs.

**File-size budgeting.** `ChatInfoView` already exceeds ~1.2k lines.
Sub-views live in separate files (`LinkSubGroupSheet.swift`,
`PendingRequestsSection.swift`). Sidebar chip render is one helper
on `ChatListView`'s row builder, no extra file. `bridge/groups.go`
stays under ~700 lines after additions; no split.

### Bridge (Go)

`bridge/groups.go` gains seven exported methods (two creation, two
linking, three approval). All gomobile-friendly types: `string`,
`int64`, `bool`, JSON strings for arrays. Existing
`CreateGroup(name, participantJIDsJSON)` is reused for plain-group
creation — wrapper exists in Swift already; only UI to add.

```go
// CreateCommunity creates a new community parent group with the
// given display name. Whatsmeow server auto-creates the default
// announcements sub-group; its JID arrives via a JoinedGroup event
// shortly after. Returns the parent's JID string. Server enforces
// the 25-char Name limit (406 not_acceptable on overflow).
func (c *Client) CreateCommunity(name string) (string, error)

// CreateSubGroup creates a new group inside the community parent
// identified by parentJIDStr, optionally pre-populating participants.
// participantJIDsJSON is a JSON []string (may be "[]"). Returns the
// new sub-group's JID. Caller must be admin of the parent (server
// enforces; surfaces ErrNotAuthorized verbatim).
func (c *Client) CreateSubGroup(
    parentJIDStr, name, participantJIDsJSON string,
) (string, error)

// LinkSubGroup attaches a child group to a community parent. Both
// JIDs must be admin-controlled (server enforces). Surfaces
// ErrGroupNotFound / ErrNotAuthorized / ErrGroupParent verbatim.
func (c *Client) LinkSubGroup(parentJIDStr, subJIDStr string) error

// UnlinkSubGroup detaches a child from its parent community. Same
// auth model. Caller is expected to gate against isDefaultSubGroup
// (server accepts the IQ but it breaks the community's announcements
// channel; Swift hides the action).
func (c *Client) UnlinkSubGroup(parentJIDStr, subJIDStr string) error

// JJoinRequest is one pending request row.
type JJoinRequest struct {
    JID         string `json:"jid"`
    RequestedAt int64  `json:"requested_at"` // unix seconds
}

// GetGroupJoinRequests returns JSON []JJoinRequest. Empty array when
// approval-mode off OR queue empty (the two are indistinguishable at
// this layer — caller relies on BridgeGroupModel.joinApprovalMode for
// the mode). Surfaces ErrNotInGroup / ErrNotAuthorized verbatim.
func (c *Client) GetGroupJoinRequests(chatJIDStr string) (string, error)

// JJoinRequestResult is one row of the response.
type JJoinRequestResult struct {
    JID       string `json:"jid"`
    ErrorCode int    `json:"error_code,omitempty"` // 0 = applied
}

// UpdateGroupJoinRequests applies "approve" or "reject" to a JSON
// []string batch. Returns JSON []JJoinRequestResult — per-row
// failures populate ErrorCode; the outer error is reserved for fatal
// cases (network / unauthorized / group missing). Invalid action
// string → ("", error) with a descriptive message.
func (c *Client) UpdateGroupJoinRequests(
    chatJIDStr, action, participantJIDsJSON string,
) (string, error)

// SetGroupJoinApprovalMode flips the gate on/off. Admin only.
// Surfaces ErrNotAuthorized verbatim.
func (c *Client) SetGroupJoinApprovalMode(chatJIDStr string, on bool) error
```

`UpdateGroupJoinRequests` accepts the action as a string and maps
to the `whatsmeow.ParticipantRequestChange` constants Go-side
(`ParticipantChangeApprove` / `ParticipantChangeReject`). Same
shape as `UpdateGroupParticipants` from the prior spec.

### Bridge events (Go)

Two payload changes to `bridge/events.go`:

1. `dispatchGroupInfo` widens its existing `GroupInfoChanged`
   payload with two fields (no new event kind):

   ```go
   type JGroupInfoChanged struct {
       ChatJID            string `json:"chat_jid"`
       Name               string `json:"name,omitempty"`
       Topic              string `json:"topic,omitempty"`
       // NEW:
       LinkedParentJID    string `json:"linked_parent_jid,omitempty"`
       IsDefaultSubGroup  bool   `json:"is_default_subgroup,omitempty"`
       Timestamp          int64  `json:"timestamp"`
       // existing fields ...
   }
   ```

   Backwards-compatible: existing Swift `Decodable` ignores unknown
   payload fields, so older builds that never read the new keys are
   unaffected.

2. New event kind `JoinApprovalModeChanged`, fanned from
   `dispatchGroupInfo` when `evt.MembershipApprovalMode != nil`:

   ```go
   type JJoinApprovalModeChanged struct {
       ChatJID   string `json:"chat_jid"`
       On        bool   `json:"on"`
       ActorJID  string `json:"actor_jid"` // may be empty
       Timestamp int64  `json:"timestamp"`
   }

   // mode == "request_required" → on=true
   // mode == "" or "open"        → on=false
   ```

   Fired in addition to the existing `GroupInfoChanged` from the same
   `events.GroupInfo` payload, so one whatsmeow event can produce two
   bridge events (matches the prior spec's
   `GroupParticipantsChanged` + `GroupInfoChanged` split).

No bridge event for link / unlink. Whatsmeow emits a `GroupInfo`
for the affected groups with updated `LinkedParentJID`, which the
extended `GroupInfoChanged` already carries.

### Swift bridge (WAClient)

Seven new wrappers in `yawac/Bridge/WAClient.swift` (the existing
`createGroup(name:participantJIDs:)` wrapper is kept and gets its
first UI caller):

```swift
func createCommunity(name: String) throws -> String
func createSubGroup(parentJID: String, name: String,
                    participantJIDs: [String]) throws -> String

nonisolated func linkSubGroup(parentJID: String, subJID: String) throws
nonisolated func unlinkSubGroup(parentJID: String, subJID: String) throws

func getGroupJoinRequests(chatJID: String) throws -> [BridgeJoinRequest]
func updateGroupJoinRequests(chatJID: String, action: String,
                             jids: [String]) throws -> [BridgeJoinRequestResult]
nonisolated func setGroupJoinApprovalMode(chatJID: String, on: Bool) throws
```

`WAClient.Event` gains one case:

```swift
case joinApprovalModeChanged(chatJID: String, on: Bool,
                             actorJID: String, timestamp: Int64)
```

Decoded in the existing `decode(kind:payload:)` switch with the
snake-case → camelCase `CodingKeys` pattern already used.

`yawac/Bridge/JSONModels.swift`:

```swift
struct BridgeJoinRequest: Decodable {
    let jid: String
    let requestedAt: Int64
}
struct BridgeJoinRequestResult: Decodable {
    let jid: String
    let errorCode: Int?
}
```

`BridgeGroupModel` gains `joinApprovalMode: Bool` (default false).
Populated from `GetGroupInfo` mapper (where `LinkedParentJID` is
already populated) and from the extended `GroupInfoChanged` payload.

### Swift views

#### Sidebar "+" header button

`ChatListView` already renders a 64pt `WindowDragHandle` gutter
above the search row. The "+" button slots into the existing
search-row trailing edge (replaces nothing; just an additional
button before the `⌘K` hint or aligned right of the field).
Glyph: `plus.circle`. Tap opens an `NSMenu`-style menu:

```
┌─────────────────────────┐
│  New group…             │
│  New community…         │
└─────────────────────────┘
```

Both rows present their respective sheet on tap. No "New chat" row
in this menu — chat creation is the implicit default of typing a
contact name into the existing search field, no change there.

#### `Views/NewGroupSheet.swift` — new

Modal sheet for creating a plain (non-community) group.

```
┌── New group ──────────────────────────────────────────┐
│  Name: [Climbing Crew___________________]   23 / 25   │
│                                                       │
│  ┌─────────────────────────────────────────────────┐  │
│  │ [Anna Berg ×] [Dana Park ×] | …                 │  │  ← chip row + search
│  ├─────────────────────────────────────────────────┤  │
│  │ SUGGESTIONS                                      │  │
│  │ Carlos Romero                                    │  │
│  │ — scroll for more —                              │  │
│  └─────────────────────────────────────────────────┘  │
│                                                       │
│                       [ Cancel ]   [ Create ]         │
└───────────────────────────────────────────────────────┘
```

State (`@Observable NewGroupSheetModel`):

- `name: String` — trimmed at send. Empty disables Create. Length
  capped client-side at 25 (matches whatsmeow server limit).
- `chips: [BridgeContact]` — chosen participants. Empty allowed
  (WhatsApp accepts solo group; rare flow but legal).
- `query: String` + `suggestions: [BridgeContact]` — same filter
  pattern as the existing `AddParticipantsPanel` (contacts only;
  `+phone` resolution deferred per non-goals).
- `inFlight: Bool` / `error: String?`.

`Create` calls `WAClient.createGroup(name:, participantJIDs:)`
off-main. Success → sheet closes → `JoinedGroup` event arrives →
`ChatListViewModel` merges the new chat → caller does
`requestSelectChat(newJID)` to focus it.

#### `Views/NewCommunitySheet.swift` — new

Modal sheet for creating a community parent. No participants
field — the community parent is a shell; members join sub-groups,
not the parent directly. Server auto-creates the default
announcements sub-group.

```
┌── New community ──────────────────────────────────────┐
│  Name: [Outdoor Club______________________]  11 / 25  │
│                                                       │
│  A community holds related groups together.           │
│  Members are added by linking or creating sub-groups. │
│                                                       │
│                       [ Cancel ]   [ Create ]         │
└───────────────────────────────────────────────────────┘
```

State:

- `name: String` — same trim + 25-cap.
- `inFlight: Bool` / `error: String?`.

`Create` calls `WAClient.createCommunity(name:)`. Success → sheet
closes → two `JoinedGroup` events typically arrive (parent + auto
announcements sub) → `ChatListViewModel` merges both. Caller
focuses the parent JID. The default sub-group surfaces under
LINKED GROUPS automatically on next `loadGroup()`.

#### `Views/NewSubGroupSheet.swift` — new

Modal sheet presented from the LINKED GROUPS section header's
"Create new sub-group…" menu item, when the chat is a community
parent and the user is admin.

Identical layout to `NewGroupSheet` but with the parent context
displayed in the sheet title and the bridge call routed to
`createSubGroup(parentJID:, name:, participantJIDs:)`.

```
┌── New sub-group in "Outdoor Club" ────────────────────┐
│  Name: [Hiking & Wild Cycling_____________]  21 / 25  │
│                                                       │
│  ┌─────────────────────────────────────────────────┐  │
│  │ [Anna Berg ×] | …                                │  │
│  └─────────────────────────────────────────────────┘  │
│                                                       │
│                       [ Cancel ]   [ Create ]         │
└───────────────────────────────────────────────────────┘
```

State + flow same as `NewGroupSheet`; on success the parent's
`ChatInfoView.subGroups` is reloaded so the new row appears.

#### `Views/LinkSubGroupSheet.swift` — new

Modal sheet presented from the LINKED GROUPS section header's
"Link existing group…" menu item (see Sidebar / sub-group section
above for the menu shape) when the chat is a community parent and
the current user is admin.

```
┌── Link group to "Climbing Crew" ─────────────────────┐
│  Search: [climb_____________________]                │
│  ──────────────────────────────────────────────────  │
│  ✓ Boulder Squad — 12 members                        │
│    Hiking & Wild Cycling Society — 41 members        │
│    Trad Sundays — 8 members · ⚠ in "Outdoor Club"    │
│    — scroll for more —                               │
│  ──────────────────────────────────────────────────  │
│                              [ Cancel ]  [ Link ]    │
└──────────────────────────────────────────────────────┘
```

State (`@Observable LinkSubGroupSheetModel`):

- `candidates: [BridgeGroupModel]` — from `WAClient.listGroups()`
  (already present), filtered to:
  - `isCommunityParent == false`
  - current user is admin (per `participants` admin flag)
  - `linkedParentJID != parentChatJID` (skip already-in-this-community)
- `query: String` — substring filter, case-insensitive.
- `selected: String?` — JID of the chosen candidate (single-select).
- `inFlight: Bool`.
- `error: String?` — inline red row below the picker on failure.

Per-row subtitle:

- Plain participant count when `linkedParentJID == nil`.
- `"⚠ in \"<other-community-name>\""` when the picked group is
  already linked to a community. Parent display name resolved via
  `session.chatList?.chats.first(where:)`; falls back to the JID's
  short form.

`Link` button flow:

1. If `selected.linkedParentJID != nil`: present
   `confirmationDialog`:
   - Title: `Move "<sub-name>" between communities?`
   - Message: `"<sub-name>" is currently linked to "<other-community>".
     Moving it removes it from there.`
   - Destructive button: `Move to "<this-community>"`.
   - Cancel.
2. Off-main: `WAClient.linkSubGroup(parentJID:, subJID:)`.
3. Success → close sheet; trigger `loadGroup()` in the parent's
   `ChatInfoView` (re-fetches sub-group directory).
4. Failure → error row stays; sheet open.

#### `Views/PendingRequestsSection.swift` — new

Inline section inside `ChatInfoView.groupBody`, rendered between the
participants section and the leave-group footer when:

- `group.joinApprovalMode == true`
- `isCurrentUserAdmin(group) == true`
- `pendingCount > 0`

```
┌── PENDING REQUESTS (3) ─────── [ Approve all ] ──┐
│ ┌──────────────────────────────────────────────┐ │
│ │ Anna Berg            requested 2h ago        │ │
│ │                              [ ✓ ]  [ ✗ ]    │ │
│ ├──────────────────────────────────────────────┤ │
│ │ Carlos Romero        requested 5h ago        │ │
│ │                              [ ✓ ]  [ ✗ ]    │ │
│ ├──────────────────────────────────────────────┤ │
│ │ +358 40 555 1234     requested yesterday     │ │
│ │                              [ ✓ ]  [ ✗ ]    │ │
│ └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

State (`@Observable PendingRequestsSectionModel`):

- `requests: [PendingRequestRow]` — `(jid, displayName, requestedAt)`.
- `inFlightJIDs: Set<String>` — per-row spinner gating.
- `bulkInFlight: Bool` — disables Approve all.
- `error: String?` — 6s auto-dismiss inline strip at section header.

`.task` calls `WAClient.getGroupJoinRequests(chatJID:)` on appear.

Per-row actions:

- `✓` → `updateGroupJoinRequests(action:"approve", jids:[row.jid])`.
  On success: drop row, `JoinRequestStore.decrement(by: 1)`.
- `✗` → same with `"reject"`.

`Approve all` → single bridge call with all current JIDs. Success
rows dropped; failure rows stay with `"⚠ couldn't apply"` suffix
rendered from `errorCode`. Section header strip carries the aggregate
"Couldn't apply M of N".

Display name resolution: `session.contactNames[jid]` first, then
`+phoneFromJID` fallback. `requestedAt` rendered via
`RelativeDateTimeFormatter`.

#### Approval-mode toggle row

In `ChatInfoView.groupBody`, between the existing description editor
and the participants section, when user is admin AND chat is a
sub-group of a community (`group.linkedParentJID != nil` AND
`group.isCommunityParent == false` — toggle is meaningful only on
the actual chat sub-groups, not the parent shell):

```
┌──────────────────────────────────────────────────┐
│ Require admin approval to join         [   ●  ]  │
│ New members request to join; admins approve.     │
└──────────────────────────────────────────────────┘
```

`Toggle` binding writes to
`WAClient.setGroupJoinApprovalMode(chatJID:on:)` off-main with
optimistic flip. On error: revert flip + 6s inline red strip.

#### Sidebar pending chip

`ChatListView.swift` chat-row layout gains a chip rendered alongside
the unread chip when:

- `session.joinRequestStore.counts[chat.jid] > 0`, and
- the current user is admin of that chat (gated client-side; the
  store's count is authoritative, but render is admin-only as a
  belt-and-braces check against role flips).

Style: small pill, secondary-tint background, "N" inside, "✓" SF
symbol leading. Suppressed for muted chats? **No** — moderation
duty trumps mute (mute silences notifications, not roster). Tap on
the chat row opens the chat normally; the chip is a read-only signal.

#### `Bridge/JoinRequestStore.swift` — new

```swift
@MainActor @Observable final class JoinRequestStore {
    private(set) var counts: [String: Int] = [:]   // chatJID → count

    func refresh(chatJID: String) async
    func refreshAllAdmin(chatJIDs: [String]) async  // bounded conc = 4
    func decrement(chatJID: String, by n: Int)      // clamped at 0
    func clear(chatJID: String)
}
```

Wired into `SessionViewModel` alongside `chatList`. Refresh triggers listed in the Architecture spine.

### Cache + reconciliation

`ChatListViewModel` already merges `BridgeGroupModel` into `chats`
via `mergeGroups`. Two small additions:

1. The extended `dispatchGroupInfo` payload's `linkedParentJID` and
   `isDefaultSubGroup` are mapped into `Chat.communityParentJID` and
   `Chat.isDefaultSubGroup` on every `GroupInfoChanged`. (Today these
   come only from `ListGroups` / `GetGroupInfo` — the event path
   is silent on community membership.)
2. New helper `pendingRequestsChip(for: Chat) -> Int?` reads from
   `session.joinRequestStore.counts[chat.jid]` for the sidebar
   render. `nil` when zero or not admin.

No new fields on `Chat`. `JoinRequestStore` is the source of truth
for pending counts. `Chat` keeps the cheap `isCommunityParent` /
`communityParentJID` / `isDefaultSubGroup` already present.

**Local vs server-driven updates.** Local actions (link / unlink /
approve / reject / mode toggle) update view-model state immediately
from the bridge call's return value — no wait for the server-fanned
event. The same event then arrives via `GroupInfoChanged` /
`JoinApprovalModeChanged` and re-runs `loadGroup()` as a no-op
reconciliation. Updates originating on the phone or another
companion device take the same event path; in that case the reload
is the only source of truth.

### Admin gating

| Surface | Gating |
|---|---|
| Sidebar "+" menu (NewGroup / NewCommunity) | everyone (creation creates admin role) |
| LINKED GROUPS section header "+" menu | admin of parent (both items inside) |
| LinkSubGroupSheet open | admin of parent |
| NewSubGroupSheet open | admin of parent |
| Per-subgroup Unlink ctx item | admin of parent + admin of sub + `!isDefaultSubGroup` |
| Approval-mode toggle row | admin of sub-group |
| PendingRequestsSection visible | admin + `joinApprovalMode == true` + `count > 0` |
| Sidebar pending chip | admin + count > 0 |
| Per-row ✓ / ✗ buttons | admin (re-checked at click time) |

## Error handling

Inline only, no NSAlert outside the existing destructive
`confirmationDialog`s (cross-community-move confirm is one of those).

| Surface | Pattern |
|---|---|
| NewGroup / NewCommunity / NewSubGroup sheets | inline red row under fields; sheet stays open; Create re-enabled |
| Name overflow (>25 chars) | client-side block (`Create` disabled, char counter turns red); the 406 path is a defence-in-depth fallback rendered as inline error |
| LinkSubGroupSheet | inline red row below picker; sheet stays open |
| Unlink ctx-menu op | inline red text at LINKED GROUPS section header, 6s auto-dismiss |
| Approval-mode toggle | revert optimistic flip; inline red strip under toggle |
| Per-row approve/reject | row stays; `errorCode` rendered as `"⚠ couldn't apply"` suffix |
| Approve all | per-row error inline; section header strip "Couldn't apply M of N" |
| `JoinRequestStore.refresh` | silent; `Logger.bridge` only. Stale chip preferable to noisy banner; next refresh tick recovers |

## Testing

### `bridge/groups_test.go` — extended

- `CreateCommunity` → success returns parent JID; 406 name-too-long
  surfaces verbatim; ErrNotConnected when client closed.
- `CreateSubGroup` → success returns sub JID with `LinkedParentJID`
  set on response; empty participant list permitted; bad parent
  JID → parse error.
- `CreateGroup` (existing) — keep current passing cases.
- `LinkSubGroup` → success / `ErrNotAuthorized` / `ErrGroupNotFound`.
- `UnlinkSubGroup` → success / `ErrNotAuthorized`.
- `GetGroupJoinRequests` empty queue → empty JSON array.
- `GetGroupJoinRequests` populated queue → rows parsed with
  `requested_at` unix seconds.
- `GetGroupJoinRequests` approval-mode-off group → empty array; no
  spurious error.
- `UpdateGroupJoinRequests` "approve" all-success → all
  `error_code == 0`.
- `UpdateGroupJoinRequests` mixed → some rows with non-zero
  `error_code` populated.
- `UpdateGroupJoinRequests` invalid action string → `("", error)`.
- `SetGroupJoinApprovalMode` true/false → iqSet routing + auth error
  mapping.

### `bridge/events_dispatch_test.go` — extended

- `events.GroupInfo{MembershipApprovalMode: &{Mode:"request_required"}}`
  → one `JoinApprovalModeChanged` with `on=true`.
- `events.GroupInfo{MembershipApprovalMode: &{Mode:""}}` → one event
  with `on=false`.
- `events.GroupInfo` carrying both `Name` change AND
  `MembershipApprovalMode` → both `GroupInfoChanged` and
  `JoinApprovalModeChanged` fire.
- Extended `dispatchGroupInfo` payload assertion: `linked_parent_jid`
  + `is_default_subgroup` appear in the `GroupInfoChanged` JSON.

### `yawacTests/` — new files

- `NewGroupSheetModelTests` — name trim + 25-char block; empty
  name disables Create; bridge call dispatched with chip JIDs;
  failure leaves sheet open with inline error.
- `NewCommunitySheetModelTests` — same name-validation shape,
  no participants field.
- `NewSubGroupSheetModelTests` — parent JID propagated to bridge
  call; success triggers parent `loadGroup()` reload.
- `LinkSubGroupSheetModelTests` — candidate filter (admin gate,
  parent exclusion, current-community exclusion); cross-community
  move requires confirmation; success reload path.
- `PendingRequestsSectionModelTests` — single approve drops row +
  decrements store; reject drops row; bulk approve with mixed
  results keeps failed rows with `errorCode`; error stays inline (no
  NSAlert).
- `JoinRequestStoreTests` — `refresh` populates counts; bounded
  concurrency (max 4 in flight, asserted via a stub bridge);
  `decrement` clamps at zero; `clear(jid:)` removes entry.
- Extended `ChatListViewModelTests`:
  - `joinApprovalModeChanged` with `on=false` clears store entry.
  - `joinApprovalModeChanged` with `on=true` triggers refresh.
  - Sidebar chip helper returns `nil` when count == 0.
  - Extended `GroupInfoChanged` payload populates
    `Chat.communityParentJID` / `Chat.isDefaultSubGroup`.

### Manual smoke (release runbook)

- From sidebar "+" menu → "New group" → enter name + add 2
  contacts → Create → new chat appears at the top of the sidebar,
  same group appears on phone within ~3s.
- "+" menu → "New community" → enter name → Create → community
  parent appears in sidebar with the community-parent badge; open
  it → LINKED GROUPS shows one row (the auto-created announcements
  default sub-group) within ~3s.
- Inside the new community's info → LINKED GROUPS header "+" menu
  → "Create new sub-group" → enter name + 2 contacts → Create →
  new sub-group row appears under LINKED GROUPS, also visible as
  its own chat in sidebar.
- Name > 25 chars: Create stays disabled, char counter red. Server
  never sees the request.
- As community-parent admin: open info → LINKED GROUPS header "+"
  menu → "Link existing group" → pick
  a non-community group I admin → row appears in LINKED GROUPS.
  Verify same row appears on phone within ~3s.
- As community-parent admin: pick a group already in another
  community → confirmation dialog quotes both community names →
  confirm → row appears here, vanishes from other community on phone.
- As community-parent admin: ctx menu on the default sub-group row
  shows no Unlink entry. On a non-default linked sub-group: Unlink
  → row vanishes; phone reflects.
- As sub-group admin: toggle "Require admin approval" → on. From a
  second account: join via invite link → invite shows "Request sent
  — waiting for admin approval". Admin's yawac: sidebar chip "1"
  appears within 30s of foreground OR on next info open.
- Open the chat info → PENDING REQUESTS shows the request → ✓ →
  row removed, chip decrements, second account's chat unlocks.
  Try ✗ on a second request → row removed, second account sees no
  group join.
- Approve all with 3 pending: all dropped at once.
- Mode off → PENDING section disappears, chip clears.
- Cross-device sync: flip mode on phone → toggle in yawac reflects
  within ~1s via event.

## Open risks

- **No `JoinRequest` event from whatsmeow.** Pending chip is
  stale-by-up-to-foreground-poll. Acceptable for moderator workflow
  but documented. Mitigation later: parse system messages of type
  `membership_approval_request` if WhatsApp posts them to the
  admin's chat stream (needs investigation; out of scope for v0.7.0).
- **`events.GroupInfo.Sender` may be nil** (same caveat as the prior
  spec). `ActorJID` on `JoinApprovalModeChanged` falls back to
  empty; no UI consequence today.
- **Cross-community move atomicity.** `LinkGroup` does not return
  whether it replaced a prior parent; the prior parent's `GroupInfo`
  arrival is the only confirmation. If that event is dropped, the
  prior community's directory shows the sub for a refresh cycle.
  Self-corrects on next `loadGroup()`.
- **`isDefaultSubGroup` flag freshness.** Comes only from
  `ListSubGroups` and the extended `dispatchGroupInfo`. A freshly
  linked sub-group's flag is `false` until the next directory
  fetch — acceptable, since the Unlink action is hidden only on
  default sub-groups, and freshly linked groups are not default.
- **`JoinRequestStore.refreshAllAdmin` concurrency.** Bounded to 4
  parallel IQs. Larger admin sets serialize. Acceptable; typical
  user has <10 admin'd approval-mode groups.
- **Bridge dispatch payload widening for `dispatchGroupInfo`.**
  Adding `linked_parent_jid` / `is_default_subgroup` to the event
  payload is backwards-compatible (existing consumers ignore unknown
  fields per Swift `Decodable` setup). Confirm by grep on the
  `GroupInfoChanged` decode path at build time.
- **Mute does not suppress the pending chip.** Intentional — admin
  moderation duty trumps mute. Document in release notes.

## Files touched

**New:**

- `yawac/Views/NewGroupSheet.swift`
- `yawac/Views/NewCommunitySheet.swift`
- `yawac/Views/NewSubGroupSheet.swift`
- `yawac/Views/LinkSubGroupSheet.swift`
- `yawac/Views/PendingRequestsSection.swift`
- `yawac/Bridge/JoinRequestStore.swift`
- `yawacTests/NewGroupSheetModelTests.swift`
- `yawacTests/NewCommunitySheetModelTests.swift`
- `yawacTests/NewSubGroupSheetModelTests.swift`
- `yawacTests/LinkSubGroupSheetModelTests.swift`
- `yawacTests/PendingRequestsSectionModelTests.swift`
- `yawacTests/JoinRequestStoreTests.swift`

**Modified:**

- `bridge/groups.go` — seven new exported methods
  (`CreateCommunity`, `CreateSubGroup`, `LinkSubGroup`,
  `UnlinkSubGroup`, `GetGroupJoinRequests`,
  `UpdateGroupJoinRequests`, `SetGroupJoinApprovalMode`).
- `bridge/groups_test.go` — extended.
- `bridge/events.go` — `JoinApprovalModeChanged` dispatcher; extend
  `dispatchGroupInfo` payload with `linked_parent_jid` +
  `is_default_subgroup`.
- `bridge/events_dispatch_test.go` — extended.
- `yawac/Bridge/WAClient.swift` — seven new wrappers
  (`createCommunity`, `createSubGroup`, `linkSubGroup`,
  `unlinkSubGroup`, `getGroupJoinRequests`,
  `updateGroupJoinRequests`, `setGroupJoinApprovalMode`); new Event
  case `joinApprovalModeChanged`; new decode arm.
- `yawac/Bridge/JSONModels.swift` — `BridgeJoinRequest`,
  `BridgeJoinRequestResult`; `BridgeGroupModel.joinApprovalMode`.
- `yawac/Views/ChatInfoView.swift` — LINK GROUPS section header
  "+" menu ("Link existing group" + "Create new sub-group") +
  per-row Unlink ctx item; approval-mode toggle row;
  `PendingRequestsSection` host; event subscription extension for
  `joinApprovalModeChanged`.
- `yawac/Views/ChatListView.swift` — sidebar header "+" button +
  menu (NewGroup / NewCommunity); sidebar pending chip render.
- `yawac/ViewModels/ChatListViewModel.swift` — extended
  `dispatchGroupInfo` mapping (`communityParentJID` /
  `isDefaultSubGroup` from events); `pendingRequestsChip(for:)`
  helper.
- `yawac/ViewModels/SessionViewModel.swift` —
  `joinRequestStore: JoinRequestStore` property + wire to bridge
  `.connected` and `didBecomeActiveNotification`.
- `yawacTests/ChatListViewModelTests.swift` — extended.

**Updated docs:**

- `README.md` — community admin bullet under Groups / Communities.
- `docs/ROADMAP.md` — mark community admin actions shipped after merge.
