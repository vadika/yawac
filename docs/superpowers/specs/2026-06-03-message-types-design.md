# Composer Message Types Design Spec

**Date:** 2026-06-03
**Status:** Approved (design)
**Topic:** Bundle four whatsmeow-supported composer message kinds
missing from yawac — static location share (plus inbound live-location
render), single-contact vCard share, disappearing-messages outbound
(per-chat timer + UI + ephemeral wrap), view-once enforcement
(inbound lock + outbound toggle). Ships as v0.8.0.

## Goal

yawac's composer today sends text, files (image / video / audio /
document), voice notes, and polls. Four whatsmeow-supported message
kinds are missing:

1. **Location share** — `LocationMessage` (static pin). Inbound
   `LiveLocationMessage` is also unrendered.
2. **Contact card (vCard) share** — `ContactMessage` for a single
   contact, with the `waid` parameter so the recipient sees a
   tappable "Message on WhatsApp" button.
3. **Disappearing-messages outbound** — yawac never wraps outgoing
   messages in `EphemeralMessage`, even when the chat has a timer
   set on the phone; messages persist on the recipient after the
   timer elapses.
4. **View-once enforcement** — incoming view-once is rendered as a
   normal image / video (full payload, re-openable); outbound has no
   toggle.

Wire all four into the existing attachment-staging pipeline + bridge
send layer so the composer is feature-complete for v0.8.0.

## Non-goals

- **Live-location send.** Receive-side renders inbound
  `LiveLocationMessage` with the last known coord + "updating" badge;
  send-side stays static. Live-location streaming protocol +
  Core Location continuous updates are a follow-up.
- **macOS Contacts.app integration.** vCard source is
  `session.contactNames` only; system contacts picker
  (`CNContactPickerViewController`) deferred.
- **Multi-contact share.** WhatsApp supports `ContactsArrayMessage`
  for batch contact send; v0.8.0 sends one contact per message.
- **Per-message disappearing override.** Timer is chat-level
  (matches WhatsApp's actual model). No "this message disappears in
  N sec" knob on the composer.
- **View-once for documents or audio.** WhatsApp restricts view-once
  to image / video; we follow.
- **Re-open grace window for view-once.** First reveal locks +
  deletes immediately; no 60s grace.
- **Map polish.** No clustering, no traffic layer, no driving
  directions — pure picker.

## Architecture

Three subsystems share one spine; mirrors the prior community-admin
spec (`docs/superpowers/specs/2026-06-02-community-admin-design.md`).

```
┌─────────────────────────────────────────────────────────────┐
│ Composer (ComposerView)                                      │
│ paperclip menu →                                             │
│   "Attach file…"     (existing)                              │
│   "New poll…"        (existing)                              │
│   "Send location…"   → LocationPickerSheet  (new)            │
│   "Send contact…"    → ContactPickerSheet   (new)            │
│ Staged-attachment chip rendering:                            │
│   .file(url, kind, viewOnce)       (extended)                │
│   .location(coord, name, address)  (new chip)                │
│   .contact(jid, name, phone)       (new chip)                │
│ Per-chip "View once" toggle on .file(image|video) (new)      │
│                                                              │
│ ChatInfoView                                                 │
│   "Disappearing messages" row → 24h/7d/90d/off submenu (new) │
│                                                              │
│ MessageRow (rendering)                                       │
│   .location bubble  — MapKit snapshot + name + Maps link     │
│   .contact bubble   — avatar + name + Message-on-WA button   │
│   .viewOnce         — "Tap to reveal" before tap,            │
│                        "You viewed this once" after          │
└─────────────────────────────────────────────────────────────┘
              │ WAClient wrappers
              ▼
┌─────────────────────────────────────────────────────────────┐
│ bridge/messages.go + bridge/media.go                         │
│   SendLocation(chatJID, lat, lng, name, address, ephS)       │
│   SendContact(chatJID, vcard, displayName, ephS)             │
│ Existing senders gain (ephemeralExpirationSeconds int32):    │
│   SendText / SendImage / SendVideo / SendAudio /             │
│   SendDocument / SendVoiceNote / SendPoll                    │
│ SendImage + SendVideo also gain (viewOnce bool):             │
│   wraps payload in ViewOnceMessageV2 when true               │
│ bridge/groups.go: SetDisappearingTimer(chatJID, seconds)     │
│ bridge/events.go: emit EphemeralTimerChanged for both        │
│   events.GroupInfo.Ephemeral and 1:1 EphemeralSetting paths  │
└─────────────────────────────────────────────────────────────┘
              │ whatsmeow
              ▼
   LocationMessage / ContactMessage / EphemeralMessage /
   ViewOnceMessageV2 / SetDisappearingTimer
```

**Per-chat timer state.** `Chat` gains
`ephemeralExpirationSeconds: Int32` (0 = off, 86_400 = 24h,
604_800 = 7d, 7_776_000 = 90d). Hydrated from
`BridgeGroupModel.ephemeralExpirationSeconds` for groups (whatsmeow
exposes it on `GroupInfo.GroupEphemeral`) and from inbound
`EphemeralSetting` event for 1:1 chats. `ConversationViewModel.
sendDraft` and `sendOneAttachment` read it on every send.

**View-once outbound state** lives on the staged
`PendingAttachment`, not `Chat`. Per-image toggle. Toggle only
shows for `.file(.image, ...)` and `.file(.video, ...)`.

**View-once inbound state** lives on `PersistedMessage`:
`isViewOnce: Bool`, `viewOnceLocked: Bool`, `viewOnceRevealedAt:
Date?`. On reveal: paint media for one cycle, then flip
`viewOnceLocked = true`, delete the on-disk media file, drop
`mediaPath` to `nil`. The row stays for the bubble shell ("You
viewed this once"); the underlying file is gone.

**Composer-stage extension.** `PendingAttachment.kind` enum gains
`.location(LocationPayload)` and `.contact(ContactPayload)`. Both
render as compact chips alongside existing file chips. The send
pipeline (`sendOneAttachment`) gains two switch arms.

**File-size budgeting.** `ComposerView.swift` adds two sheet
presentations and the per-chip view-once toggle; `MessageRow.swift`
gains two body cases (`.location`, `.contact`) and one render-gate
case (`.viewOnce`). New picker views live in their own files
(`LocationPickerSheet.swift`, `ContactPickerSheet.swift`) plus
matching `@Observable` models.

### Bridge (Go)

`bridge/messages.go` gains two exported funcs. All gomobile-friendly
types.

```go
// SendLocation sends a static LocationMessage. When ephemeralSec > 0,
// the LocationMessage is wrapped in EphemeralMessage with the given
// expiration. Returns JSON {"id":"...","timestamp":<unix>}.
// lat/lng in decimal degrees. name + address may be empty strings.
func (c *Client) SendLocation(
    chatJIDStr string,
    lat, lng float64,
    name, address string,
    ephemeralSec int32,
) (string, error)

// SendContact sends a ContactMessage carrying a single vCard. The
// vcard string must be a valid VCARD 3.0 payload (built Swift-side).
// displayName is the human-readable name shown on the message.
// When ephemeralSec > 0, wrapped in EphemeralMessage.
func (c *Client) SendContact(
    chatJIDStr string,
    vcard, displayName string,
    ephemeralSec int32,
) (string, error)
```

**Existing senders gain ephemeral + view-once params.** Backwards-
compatible behavior: callers passing 0 / false get the old code path
verbatim. Seven existing senders updated in parallel:

```go
func (c *Client) SendText(chatJIDStr, body, mentionedJIDsJSON string,
                          ephemeralSec int32) (string, error)
func (c *Client) SendImage(chatJIDStr, filePath, caption string,
                           ephemeralSec int32, viewOnce bool) (string, error)
func (c *Client) SendVideo(chatJIDStr, filePath, caption string,
                           ephemeralSec int32, viewOnce bool) (string, error)
func (c *Client) SendAudio(chatJIDStr, filePath string,
                           ephemeralSec int32) (string, error)
func (c *Client) SendVoiceNote(chatJIDStr, filePath string,
                               durationSec int32, waveform []byte,
                               ephemeralSec int32) (string, error)
func (c *Client) SendDocument(chatJIDStr, filePath, caption string,
                              ephemeralSec int32) (string, error)
func (c *Client) SendPoll(chatJIDStr, question, optionsJSON string,
                          selectableCount int32,
                          ephemeralSec int32) (string, error)
```

**Private wrap helper.**

```go
// wrapForChat optionally wraps in ViewOnceMessageV2 and then
// EphemeralMessage. ViewOnce wrap is only valid for ImageMessage
// and VideoMessage; other kinds with viewOnce=true return the inner
// unchanged and log a Logger.warn (UI gates this, so the path
// should be unreachable in practice).
func wrapForChat(inner *waE2E.Message, ephSec int32, viewOnce bool) *waE2E.Message
```

Stamps `ContextInfo.Expiration = ephSec` on the inner content
per whatsmeow's expectation (server uses it for retention).

**Timer setter.**

```go
// SetDisappearingTimer sets the chat-level disappearing-messages
// timer. seconds ∈ {0, 86_400, 604_800, 7_776_000}. Whatsmeow
// handles 1:1 vs group routing internally (ProtocolMessage vs
// groupIQ). Surfaces ErrNotAuthorized verbatim for groups when
// caller isn't admin.
func (c *Client) SetDisappearingTimer(chatJIDStr string, seconds int32) error
```

**JGroup + dispatchGroupInfo extension.**

```go
type JGroup struct {
    // ... existing fields ...
    EphemeralExpirationSeconds int32 `json:"ephemeral_expiration_seconds,omitempty"`
}

type JEphemeralTimerChanged struct {
    ChatJID   string `json:"chat_jid"`
    Seconds   int32  `json:"seconds"`
    ActorJID  string `json:"actor_jid,omitempty"`
    Timestamp int64  `json:"timestamp"`
}
```

`mapGroupInfo` (from prior community-admin spec) populates
`EphemeralExpirationSeconds` from `g.GroupEphemeral.DisappearingTimer`.

For **1:1 chats**, whatsmeow surfaces timer changes via
`events.Message` whose `ProtocolMessage.EphemeralSetting` is non-nil.
Bridge intercepts in `dispatchMessage`, fans out
`EphemeralTimerChanged` (with `ChatJID` = peer JID), and suppresses
the underlying message from the chat log (it's a control payload,
not a user message).

**Classify extension (inbound).**

- `kind == "location"` — already classified; extend
  `JBridgeMessage` to carry the lat/lng/name/address.
- `kind == "location_live"` for `GetLiveLocationMessage()`. Sequence
  number from inbound `LiveLocationMessage` flows into
  `location_sequence` on the payload.
- `kind == "contact"` for `GetContactMessage()`. vCard +
  display name carried on the payload.
- `is_view_once: true` when inbound carries `ViewOnceMessageV2` or
  `ViewOnceMessageV2Extension`. Bridge unwraps to the inner Image /
  Video message and forwards normally; the flag rides on the
  envelope.

**Bridge payload extensions** (`bridge/jsonmodels.go`):

```json
{
  "kind": "location" | "location_live" | "contact" | "...",
  "location": { "lat": 60.17, "lng": 24.94,
                 "name": "Senate Square", "address": "..." },
  "location_sequence": 42,
  "contact": { "vcard": "BEGIN:VCARD...",
               "display_name": "Anna Berg" },
  "is_view_once": true
}
```

### Swift bridge (WAClient)

```swift
nonisolated func sendLocation(chatJID: String,
                              latitude: Double, longitude: Double,
                              name: String, address: String,
                              ephemeralSeconds: Int32) throws -> SendResult

nonisolated func sendContact(chatJID: String,
                             vcard: String, displayName: String,
                             ephemeralSeconds: Int32) throws -> SendResult

nonisolated func setDisappearingTimer(chatJID: String,
                                      seconds: Int32) throws
```

Existing send wrappers extend with `ephemeralSeconds: Int32 = 0`
default param (keeps existing callers compiling) and image / video
gain `viewOnce: Bool = false`.

`SendResult` already exists. `WAClient.Event` gains:

```swift
case ephemeralTimerChanged(chatJID: String, seconds: Int32,
                           actorJID: String, timestamp: Int64)
```

Decoded via existing `decode(kind:payload:)` arm pattern.

### Bridge JSON models

`yawac/Bridge/JSONModels.swift`:

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

`BridgeMessage` gains:

```swift
let location: BridgeLocationPayload?
let locationSequence: Int64?
let contact: BridgeContactPayload?
let isViewOnce: Bool?
```

`BridgeGroupModel.ephemeralExpirationSeconds: Int32` (default `0`)
added with matching `CodingKey`.

### `PendingAttachment` extension

`yawac/ViewModels/ConversationViewModel.swift`:

```swift
enum PendingAttachment {
    case file(url: URL, kind: FileKind, viewOnce: Bool)
    case location(LocationPayload)
    case contact(ContactPayload)
}

struct LocationPayload: Hashable {
    let lat: Double
    let lng: Double
    let name: String       // e.g. "Senate Square" or ""
    let address: String    // reverse-geocoded; may be ""
}

struct ContactPayload: Hashable {
    let jid: String
    let displayName: String
    let phone: String      // E.164, no leading "+"
    var vcard: String { VCardBuilder.build(jid: jid, name: displayName, phone: phone) }
}
```

`FileKind = .image | .video | .audio | .document | .voiceNote`.
`viewOnce` on the `.file` case is forced to `false` for non-image /
non-video kinds via the UI gate (composer chip toggle hidden).

`sendOneAttachment` switch gains:

```swift
case .location(let loc):
    let result = try await Task.detached { [...] in
        try client.sendLocation(
            chatJID: chatJID,
            latitude: loc.lat, longitude: loc.lng,
            name: loc.name, address: loc.address,
            ephemeralSeconds: chat.ephemeralExpirationSeconds)
    }.value
    optimisticInsertLocationBubble(result, loc)

case .contact(let card):
    let result = try await Task.detached { [...] in
        try client.sendContact(
            chatJID: chatJID,
            vcard: card.vcard, displayName: card.displayName,
            ephemeralSeconds: chat.ephemeralExpirationSeconds)
    }.value
    optimisticInsertContactBubble(result, card)

case .file(let url, let kind, let viewOnce):
    // existing dispatch, threading ephemeralSeconds + viewOnce
```

### `Views/LocationPickerSheet.swift` — new

```
┌── Send location ─────────────────────────────────────────┐
│  ┌────────────────────────────────────────────────────┐  │
│  │ Search: [Helsinki cathed________________]          │  │
│  ├────────────────────────────────────────────────────┤  │
│  │                                                    │  │
│  │            [ MapKit Map view ]                     │  │
│  │              📍 (draggable)                        │  │
│  │                                                    │  │
│  ├────────────────────────────────────────────────────┤  │
│  │ 📍 Senate Square                                   │  │
│  │    Helsinki, Finland                               │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  [ Use current location ]    [ Cancel ] [ Send ]         │
└──────────────────────────────────────────────────────────┘
```

State (`@Observable LocationPickerSheetModel`):

- `region: MKCoordinateRegion`
- `selectedCoord: CLLocationCoordinate2D`
- `query: String` — debounce 250 ms → `MKLocalSearch`
- `searchResults: [MKMapItem]`
- `resolvedName: String` / `resolvedAddress: String` — populated
  by `CLGeocoder.reverseGeocodeLocation` on coord change (debounced)
- `usingCurrentLocation: Bool` — gates
  `CLLocationManager.requestWhenInUseAuthorization`
- `inFlight: Bool`
- `error: String?`

"Send" stages the location as `PendingAttachment.location(...)` and
dismisses; transmit happens on composer Send button (consistent
with file attachments).

### `Views/ContactPickerSheet.swift` — new

Reuses `ParticipantChipPicker` (lifted in v0.7.1) in single-select
mode. On Send: builds the vCard via `VCardBuilder.build(jid:name:
phone:)`:

```
BEGIN:VCARD
VERSION:3.0
FN:Anna Berg
TEL;type=CELL;waid=358405551234:+358405551234
END:VCARD
```

`waid` extension parameter is what makes inbound contacts surface a
tappable "Message on WhatsApp" button on the recipient.

### Composer paperclip menu

```swift
Menu {
    Button("Attach file…")   { showFilePicker = true }
    Button("Send location…") { showLocationPicker = true }
    Button("Send contact…")  { showContactPicker = true }
    Button("New poll…")      { showPollSheet = true }
} label: { Image(systemName: "paperclip") }
```

Two new `.sheet` modifiers wire the picker → `vm.stageAttachment`.

### Per-chip view-once toggle (image / video)

`attachmentChip(_:)` for `.file(_, .image, _)` and
`.file(_, .video, _)` renders a small "view once" toggle (eye icon
with hollow / filled state). Tap flips
`PendingAttachment.viewOnce`. Visual treatment matches existing
chip; tooltip "Send as view once". Toggle hidden for non-image /
non-video kinds.

### `Views/MessageRow.swift` — render

New `UIMessage.Body` cases:

```swift
enum Body: Hashable {
    case text(String)
    case media(...)
    case poll(...)
    case system(String)
    case location(LocationPayload, isLive: Bool, sequence: Int64?)
    case contact(ContactPayload)
}
```

`existingBodyContent` switch arms:

```swift
case .location(let loc, let isLive, _):
    locationBubble(loc, isLive: isLive)
case .contact(let card):
    contactBubble(card)
```

`locationBubble`:

```
┌─────────────────────────────────────┐
│   [ MKMapSnapshot @ 220×120 ]       │
│     📍                              │
├─────────────────────────────────────┤
│ Senate Square          🔴 LIVE      │  ← LIVE only when isLive
│ Helsinki, Finland                   │
└─────────────────────────────────────┘
```

Tap → `NSWorkspace.shared.open(URL("maps://?ll=lat,lng"))`. Snapshots
cached by `MapSnapshotCache` keyed on `(lat, lng, zoom)` PNGs in
`~/Library/Caches/dev.vadikas.yawac.yawac/MapSnapshots/`.

`contactBubble`:

```
┌─────────────────────────────────────┐
│  [avatar]  Anna Berg                │
│            +358 40 555 1234         │
├─────────────────────────────────────┤
│  [ Message on WhatsApp ]            │
└─────────────────────────────────────┘
```

Tap "Message on WhatsApp" → derive JID from `waid` parameter via
`VCardBuilder.parseWAID(_:)`, then `session.requestSelectChat(jid)`.
If `waid` absent, the button is hidden but the bubble still renders
the name + phone.

### View-once render — inbound

`existingBodyContent` checks `message.isViewOnce` first:

```swift
if message.isViewOnce {
    if message.viewOnceLocked {
        Text("You viewed this once")
            .italic()
            .foregroundStyle(Theme.textMuted)
    } else {
        Button {
            revealViewOnce(message)
        } label: {
            HStack {
                Image(systemName: "eye")
                Text("Tap to reveal")
            }
        }
    }
}
```

`revealViewOnce(message)` flow:

1. Render the media inline as a normal image / video bubble.
2. After the first paint cycle (`@State revealedAt: Date`), flip
   `PersistedMessage.viewOnceLocked = true`.
3. Delete the on-disk file via `FileManager.default.removeItem`.
4. Re-save `PersistedMessage` with `mediaPath = nil`,
   `mediaCaption = nil`, `viewOnceLocked = true`.
5. Re-render shows the locked state.

If the bubble is scrolled offscreen during the paint window, the
file is not deleted until the next tap actually reveals (the
`revealedAt` guard requires `onAppear` within 100 ms).

### ChatInfoView: Disappearing-messages row

Between description editor and approval-mode toggle:

```
┌──────────────────────────────────────────────────┐
│ Disappearing messages         24 hours  ▼        │
│                                                  │
│   ◯ Off                                          │
│   ◯ 24 hours                                     │
│   ◯ 7 days                                       │
│   ● 90 days                                      │
└──────────────────────────────────────────────────┘
```

Menu items map to `0 / 86_400 / 604_800 / 7_776_000`. Calls
`WAClient.setDisappearingTimer(chatJID:seconds:)` off-main.
Optimistic; revert + inline red strip on failure (6 s auto-dismiss).

Admin gate: groups → admin-only. 1:1 → both parties can change
(server enforces; both can in real WhatsApp).

## Data flow

### Local actions

| Action | Path | Optimistic UI | Reconcile |
|---|---|---|---|
| Stage location | `LocationPickerSheet` → `vm.stageAttachment(.location(...))` | Chip appears in composer. | None (sheet close). |
| Send composer | `sendPendingAttachments` iterates, dispatches per kind, passes `chat.ephemeralExpirationSeconds` + per-chip `viewOnce` | Bubble inserted with `pending` status, replaced on `SendResult`. | Inbound `events.Message` (own echo) re-merges via existing self-receipt path. |
| Send vCard | `sendContact(vcard:displayName:ephemeralSeconds:)` | Contact bubble with name + phone. | Same. |
| Toggle disappearing timer | `setDisappearingTimer(seconds:)` | `chat.ephemeralExpirationSeconds` flipped optimistically; row text updates. | `EphemeralTimerChanged` event arrives → idempotent re-set. |
| Toggle view-once on chip | Local chip-state flip | Eye icon active state. | No remote effect until send. |
| Reveal inbound view-once | `revealViewOnce(message)` | Media paints once, then bubble flips. | None (local-only). |

### Remote (other-device) actions

| Originating | Effect |
|---|---|
| Phone sets timer on chat | `events.GroupInfo.Ephemeral` (group) or `events.Message{ProtocolMessage.EphemeralSetting}` (1:1) → bridge fans `EphemeralTimerChanged` → Swift updates `chat.ephemeralExpirationSeconds`. UI row flips without round-trip. |
| Inbound location | Classify → `kind == "location"` or `"location_live"` → `BridgeMessage.location` populated → `UIMessage.Body.location(...)`. Live updates re-merge by message ID; the latest `location_sequence` wins. |
| Inbound contact | Classify → `kind == "contact"` → `BridgeMessage.contact` populated. |
| Inbound view-once | Bridge unwraps `ViewOnceMessageV2` → inner Image / Video → `is_view_once: true` on envelope. `PersistedMessage.isViewOnce = true`, `viewOnceLocked = false`. Bubble shows reveal button. |

### Per-chat timer hydration

1. **Group bootstrap**: `ListGroups` / `GetGroupInfo` →
   `mapGroupInfo` → `JGroup.EphemeralExpirationSeconds` →
   `mergeGroups` populates the field.
2. **1:1 bootstrap**: whatsmeow has no
   `GetChatEphemeralSetting(jid)` API. First `EphemeralSetting`
   event after history-sync hydrates the cached value. Until then,
   default `0` (off) — sends go unwrapped. Documented limitation.
3. **Events**: `EphemeralTimerChanged` flows through
   `ChatListViewModel.applyEphemeralTimer(chatJID:seconds:)` to
   update the cached row in place.

### View-once cleanup invariants

- `PersistedMessage.viewOnceLocked = true` is **permanent** — never
  re-revealable.
- After lock: `mediaPath = nil`, `mediaCaption = nil`, on-disk file
  removed. Best-effort: deletion failures logged via `Logger.media`,
  not surfaced.
- On app restart with a locked view-once row: bubble shows "You
  viewed this once". Idempotent — file is already gone.
- Forwarding / quoting a view-once is **blocked**: the row's
  context menu hides Forward / Quote for both locked and unlocked
  view-once inbounds (matches WhatsApp).

### Admin gating

| Surface | Gating |
|---|---|
| LocationPickerSheet open | everyone |
| ContactPickerSheet open | everyone |
| Per-chip view-once toggle | everyone (image / video only) |
| Disappearing timer row (group) | admin of group |
| Disappearing timer row (1:1) | both parties |
| Reveal inbound view-once | recipient only (sender's own outbound view-once shows inline with no lock — matches WhatsApp) |

## Error handling

Inline, no NSAlert outside existing confirmationDialogs.

| Surface | Pattern |
|---|---|
| LocationPickerSheet — search fail | Inline row "Couldn't search nearby" |
| LocationPickerSheet — current-location denied | Inline note "Location access denied — open System Settings" with link |
| LocationPickerSheet — reverse-geocode fail | Send without name / address (just lat / lng) |
| LocationPickerSheet — send fail | Sheet stays; chip not staged; toast on composer "Couldn't send location" |
| ContactPickerSheet — send fail | Same pattern |
| Disappearing timer set fail | Revert optimistic; inline red strip under the row, 6 s auto-dismiss |
| Reveal view-once — file already missing | Bubble immediately flips to "You viewed this once" without paint; logged |
| Bridge `wrapForChat` — view-once on non-image / video | Log warn + return inner unchanged (UI should never hit) |

## Testing

### `bridge/messages_test.go` + `bridge/media_test.go` extensions

- `SendLocation` unpaired → error; bad JID → parse error.
- `SendContact` unpaired → error; empty vCard → still attempts (whatsmeow surfaces).
- `SendText` / `SendImage` / `SendVideo` etc. with `ephemeralSec > 0` — assert wrapped output via `wrapForChat` golden-string fixture.
- `SendImage` / `SendVideo` with `viewOnce = true` — assert outer `ViewOnceMessageV2` wrap.
- `SendImage` with `viewOnce = true` AND `ephemeralSec > 0` — both wraps; assert nesting order (ViewOnce inside Ephemeral).
- `SetDisappearingTimer` unpaired → error.

### `bridge/events_dispatch_test.go`

- `events.GroupInfo{Ephemeral: 86400}` → emits `EphemeralTimerChanged` with `seconds=86400`.
- `events.Message{ProtocolMessage.EphemeralSetting{...}}` (1:1) → emits `EphemeralTimerChanged` with peer JID; underlying message is suppressed (no `MessageReceived`).
- Both `Name` change + `Ephemeral` change in one `GroupInfo` → both `GroupInfoChanged` and `EphemeralTimerChanged` fire.

### Inbound-classify tests

- Inbound `LocationMessage` → `kind = "location"`, payload populated.
- Inbound `LiveLocationMessage` → `kind = "location_live"`, sequence populated.
- Inbound `ContactMessage` → `kind = "contact"`, vcard populated.
- Inbound `ViewOnceMessageV2{ImageMessage}` → unwraps to image kind, `is_view_once = true`.
- Inbound `ViewOnceMessageV2Extension` → handled identically.

### `yawacTests/`

- `LocationPickerSheetModelTests` — query debounce coalesces to one `MKLocalSearch` per quiet burst; reverse-geocode populates name / address; current-location button triggers permission request once.
- `ContactPickerSheetModelTests` — vCard builder produces correct VCARD 3.0 with `waid` parameter; phone extracted from JID.
- `VCardBuilderTests` — build round-trip; `parseWAID` extracts the JID-shaped phone correctly; missing `waid` returns `nil`.
- `ViewOnceRevealTests` — reveal flips `viewOnceLocked`, deletes media path, idempotent on second invocation, no-op when file already missing.
- `ConversationViewModelTests` extended — `sendDraft` threads `chat.ephemeralExpirationSeconds` into bridge call; staged `.location` chip dispatches `sendLocation` not `sendImage`; `.contact` chip dispatches `sendContact`; view-once chip flag flows into bridge call.
- `ChatListViewModelTests` extended — `applyEphemeralTimer` updates the cached chat's `ephemeralExpirationSeconds`; `EphemeralTimerChanged` event routes through it.

### Manual smoke (release runbook)

- Compose → paperclip → "Send location" → search "Senate Square" → result row tapped → pin moves → "Send" → bubble appears with map snapshot. On phone the same bubble renders with the same coords.
- Compose → "Use current location" → Core Location permission prompt → allow → reverse-geocode populates name / address → "Send" → bubble.
- Compose → "Send contact" → pick "Anna" → "Send" → contact bubble appears with name + phone + "Message on WhatsApp" button. Tap → opens chat with Anna.
- ChatInfoView → "Disappearing messages" → "24 hours" → row updates. Send a text → recipient's chat shows the message disappearing after 24 h. Phone shows the timer change.
- ChatInfoView → "Off" → outbound goes back to unwrapped.
- Compose → attach image → toggle view-once → send → recipient sees "Tap to reveal" → tap → image shows → flips to "You viewed this once" → file deleted from disk (verify in `~/Library/Containers/dev.vadikas.yawac.yawac/Data/Library/Caches/...`).
- Inbound view-once from phone → bubble has reveal button → tap → image shows → locks.
- Inbound live-location from phone → bubble renders with "🔴 LIVE" badge; pin moves on each update.

## Open risks

- **Live-location sequence ordering.** `LiveLocationMessage`
  updates arrive with a `SequenceNumber`; out-of-order delivery
  could regress to an older position. Mitigation:
  `PersistedMessage.locationSequence` — only update when
  `incoming.sequence > stored.sequence`. Drop stale updates
  silently.
- **1:1 timer hydration is event-driven, not cold-read.** Whatsmeow
  has no API to query a 1:1's current timer. First-run 1:1s default
  to `0` (off) until a setting message lands. Acceptable — sends
  start unwrapped; once a peer carrying
  `ProtocolMessage.EphemeralSetting` arrives we hydrate.
- **ViewOnce + Ephemeral nesting order.** `wrapForChat` wraps
  view-once first, then ephemeral. Verify on the wire that
  WhatsApp accepts this nesting; if it expects ephemeral inside
  view-once, swap. Bridge golden-string tests pin the chosen order.
- **View-once paint-then-lock race.** Reveal paints media, then
  locks after one paint cycle. If the bubble is scrolled offscreen
  during the window, the file might be deleted before the user
  saw it. Mitigation: `revealedAt` guard — only lock when
  `onAppear` fired within 100 ms.
- **Forwarding lock-out for view-once.** WhatsApp itself strips
  view-once wrap on server-side forward; client-side enforcement
  is impossible (screenshots are uncatchable). Same posture as
  WhatsApp itself; document only.
- **vCard `waid` round-trip.** Outbound vCards carry
  `waid=<phone>` so the recipient sees a tappable "Message on
  WhatsApp" button. Inbound vCards from non-WA clients (Signal
  export, etc.) won't have `waid` — bubble still renders, but the
  button is hidden.
- **MapKit snapshot cache size.** Snapshots are PNG-encoded at
  220×120 @2x ≈ 30 KB each. Cache in
  `~/Library/Caches/dev.vadikas.yawac.yawac/MapSnapshots/`, keyed
  by `<lat>_<lng>_<zoom>.png`. No eviction beyond OS cache
  pressure. Acceptable; add LRU later if it grows.
- **Core Location permission flow.** First "Use current location"
  tap surfaces the system permission prompt; denial flips to the
  inline "Location access denied" affordance. `Info.plist` needs
  `NSLocationWhenInUseUsageDescription` — added via `project.yml`.

## Files touched

**New:**

- `yawac/Views/LocationPickerSheet.swift`
- `yawac/ViewModels/LocationPickerSheetModel.swift`
- `yawac/Views/ContactPickerSheet.swift`
- `yawac/ViewModels/ContactPickerSheetModel.swift`
- `yawac/Utilities/VCardBuilder.swift`
- `yawac/Utilities/MapSnapshotCache.swift`
- `yawacTests/LocationPickerSheetModelTests.swift`
- `yawacTests/ContactPickerSheetModelTests.swift`
- `yawacTests/VCardBuilderTests.swift`
- `yawacTests/ViewOnceRevealTests.swift`

**Modified:**

- `bridge/messages.go` — `SendLocation`, `SendContact`, classify
  extension for `contact` + `location_live` + `is_view_once`;
  `wrapForChat`.
- `bridge/media.go` — ephemeral + view-once params on `SendImage`
  / `SendVideo` / `SendAudio` / `SendVoiceNote` / `SendDocument`.
- `bridge/groups.go` — `SetDisappearingTimer`,
  `JGroup.EphemeralExpirationSeconds`, extend `mapGroupInfo`.
- `bridge/events.go` — `EphemeralTimerChanged` dispatcher for both
  `events.GroupInfo.Ephemeral` and 1:1
  `ProtocolMessage.EphemeralSetting` paths; suppress raw
  EphemeralSetting messages.
- `bridge/jsonmodels.go` — extend `JBridgeMessage` with `Location`,
  `LocationSequence`, `Contact`, `IsViewOnce`.
- `bridge/messages_test.go`, `bridge/media_test.go`,
  `bridge/events_dispatch_test.go` — new cases.
- `yawac/Bridge/WAClient.swift` — `sendLocation`, `sendContact`,
  `setDisappearingTimer`, ephemeral + view-once params on existing
  send wrappers, new `.ephemeralTimerChanged` Event case + decode
  arm.
- `yawac/Bridge/JSONModels.swift` — `BridgeLocationPayload`,
  `BridgeContactPayload`, extend `BridgeMessage`, extend
  `BridgeGroupModel.ephemeralExpirationSeconds`.
- `yawac/Models/Chat.swift` — `ephemeralExpirationSeconds: Int32`.
- `yawac/Models/Message.swift` — `UIMessage.Body.location` /
  `.contact` cases; `isViewOnce` flag.
- `yawac/Models/PersistedMessage.swift` — `isViewOnce: Bool`,
  `viewOnceLocked: Bool`, `viewOnceRevealedAt: Date?`,
  `locationLat: Double?`, `locationLng: Double?`,
  `locationName: String?`, `locationAddress: String?`,
  `locationIsLive: Bool`, `locationSequence: Int64?`,
  `contactVCard: String?`, `contactDisplayName: String?`.
- `yawac/ViewModels/ConversationViewModel.swift` —
  `PendingAttachment` enum cases, `sendOneAttachment` dispatch
  arms, ephemeral threading.
- `yawac/ViewModels/ChatListViewModel.swift` —
  `applyEphemeralTimer`, route `EphemeralTimerChanged` event,
  hydrate `ephemeralExpirationSeconds` in `mergeGroups`.
- `yawac/ViewModels/SessionViewModel.swift` — route
  `EphemeralTimerChanged` event into
  `chatList.applyEphemeralTimer`.
- `yawac/Views/ComposerView.swift` — paperclip menu items, two new
  sheet presentations, per-chip view-once toggle on image / video
  chips.
- `yawac/Views/MessageRow.swift` — `.location` and `.contact` body
  cases, view-once render gate, `revealViewOnce(_:)`.
- `yawac/Views/ChatInfoView.swift` — "Disappearing messages" row
  (groups: admin-gated; 1:1: ungated).
- `project.yml` — `NSLocationWhenInUseUsageDescription` Info.plist
  key; bump version 0.7.1 → 0.8.0.
- `README.md` — feature bullets.
- `docs/ROADMAP.md` — mark four items shipped after merge.
