# F103 + F104 — Pin-drag re-geocode + Multi-contact vCard

Two roadmap gaps bundled into v0.10.35. Both extend already-shipped
features without new protocol surface.

---

## F103 — Pin-drag re-geocode (LocationPickerSheet)

### Problem

`LocationPickerSheetModel.onPinDrag(to:)` exists (250ms-debounced
reverse-geocode → updates `resolvedName` / `resolvedAddress`), but
`LocationPickerSheet` uses `Map(coordinateRegion:annotationItems:)`
+ `MapAnnotation` — the legacy API exposes no drag callback. Users
can pan/zoom the map but the pin stays anchored to whatever the
search row last set; there is no way to nudge the pin to a precise
spot before sending.

### Approach

Switch the Map to the macOS-14 `Map(initialPosition:) { Annotation }`
shape and wrap it in `MapReader { proxy in … }`. Attach a
`DragGesture(minimumDistance: 0)` to the Map. On gesture end,
`proxy.convert(value.location, from: .local)` returns the
`CLLocationCoordinate2D` under the cursor; pass it to
`model.onPinDrag(to:)`. The model already updates `selectedCoord`
and kicks the debounced geocoder — Annotation re-anchors on its own.

UX is **tap-to-move** rather than literal drag-the-pin: a single
click anywhere on the map moves the pin to that spot. This matches
the new SwiftUI Map API (no per-Annotation drag handler exists) and
is faster to operate than dragging a tiny pin. `minimumDistance: 0`
keeps simple taps responsive; users who drag-and-release also land
the pin at the release point, which feels natural.

Search-row taps continue to work — they call `model.pickResult(_:)`
which sets `selectedCoord` and adjusts `region`; the new annotation
will re-anchor identically.

### Out of scope

- True per-Annotation drag affordance with the pin following the
  cursor frame-by-frame. The new API does not expose this; building
  it on top of `Map` overlays is more code than the value warrants.
- Long-press to drop a pin (would conflict with tap-to-move).

### Files

- Modify: `yawac/Views/LocationPickerSheet.swift` — swap Map API,
  add `MapReader` + DragGesture overlay, remove `SelectedPin`
  Identifiable struct (Annotation takes the coordinate directly).
- No model changes — `onPinDrag(to:)` is already correct.

### Test

`LocationPickerSheetModelTests` already exists; add a test that
asserts `onPinDrag(to:)` updates `selectedCoord` and that a follow-up
geocode runs (mockable via injected geocoder if not already; otherwise
verify the synchronous `selectedCoord` mutation only — the geocoder
side-effect path is covered by manual smoke). One unit test ≥1.

Manual smoke: open Send Location sheet, tap a search result, then
tap a different spot on the map. Pin teleports; bottom strip updates
to the new address within ~300ms.

---

## F104 — Multi-contact vCard (ContactsArrayMessage)

### Problem

`ContactPickerSheet` is single-select today: `selectedJID: String?`,
one bridge `SendContact` call per send. WhatsApp's
`ContactsArrayMessage` carries N contacts in a single bubble; without
support, sending a handful of cards is N separate sheet trips.

### Approach

Three layers change:

1. **Bridge.** New `Client.SendContactsArray(chatJID, displayName,
   vcards []string, ephemeralSec)` in `bridge/messages.go`. Wraps
   `waE2E.ContactsArrayMessage{ DisplayName, Contacts: []*ContactMessage }`
   (one ContactMessage per vcard, no per-card displayName — the
   per-vcard FN field carries it). Mirrors `SendContact`'s JID guard
   + ephemeral wrap + JSendResult return.

2. **Swift WAClient.** `sendContacts(chatJID, displayName, vcards)`
   wrapper next to `sendContact`. Signature parallels the existing
   one.

3. **Sheet + composer plumbing.**
   - `ContactPickerSheetModel.selectedJID: String?` →
     `selectedJIDs: Set<String>`.
   - `buildPayload() -> ContactPayload?` → `buildPayloads() ->
     [ContactPayload]` (returns empty array if nothing selected).
   - `ContactPickerSheet` row tap toggles set membership; checkbox
     visual (SF Symbol `checkmark.circle.fill` / `circle`).
   - Send button label: "Send" when 0–1 selected, "Send N contacts"
     when ≥2.
   - `ConversationViewModel.stageContact(_:)` stays single-payload
     (composer chip is per-card). On send, `sendPendingAttachments`
     batches contacts: 1 staged → existing `sendOneContact` path
     (back-compat); ≥2 → new `sendManyContacts` that calls the bridge
     once with all vcards.

4. **Rendering.** Keep `UIMessage.body = .contact(ContactPayload)`
   for the 1-card case. Add `.contacts([ContactPayload])` body case
   for the N-card bubble. Outbound persistence (`persistOutgoingContact`)
   gets a sibling `persistOutgoingContacts(_:contacts:)` that stores
   the array.

   Inbound parsing (`UIMessage` init from `BridgeMessage`): when the
   bridge surfaces a `ContactsArrayMessage`, route to `.contacts(…)`.
   For this spec the inbound path can stay TODO if the bridge dispatcher
   doesn't already split it — confirm by reading `bridge/messages.go`
   inbound path before implementing.

   `MessageRow` gets a contacts-array case: vertically stacked
   contact rows with a single "Tap to view" header. No new per-row
   tap actions; reuse the single-contact row view by iterating.

### Out of scope

- `CNContactPickerViewController` integration to pick non-WA
  contacts (roadmap entry kept open for later).
- Inbound contacts missing the `waid` param — separate roadmap entry.
- Reordering / removing individual cards before send — chip strip
  already allows individual removal of staged contacts; no new UI.

### Files

- Modify: `bridge/messages.go` — add `SendContactsArray` + inbound
  `ContactsArrayMessage` parse (confirm whether dispatcher already
  handles it).
- Modify: `bridge/messages_test.go` — add `TestSendContactsArrayUnpaired`
  + `TestSendContactsArrayBadJID` mirroring single-contact tests.
- Modify: `yawac/Bridge/WAClient.swift` — `sendContacts` wrapper.
- Modify: `yawac/ViewModels/ContactPickerSheetModel.swift` — set-based
  selection + `buildPayloads()`.
- Modify: `yawac/Views/ContactPickerSheet.swift` — checkbox UI, send
  label.
- Modify: `yawac/Models/Message.swift` — add `.contacts([ContactPayload])`
  body case.
- Modify: `yawac/ViewModels/ConversationViewModel.swift` —
  `sendPendingAttachments` batches contacts, new `sendManyContacts`,
  `persistOutgoingContacts`.
- Modify: `yawac/Views/MessageRow.swift` — render `.contacts` case
  by reusing single-contact row.

### Tests

- `bridge/messages_test.go` — unpaired + bad-JID guard tests.
- `yawacTests/ContactPickerSheetModelTests` (new or extend) —
  multi-select toggle, buildPayloads order, empty case.
- `yawacTests/ConversationViewModelContactSendTests` (new or extend)
  — 1-staged routes to `sendOneContact`, ≥2 routes to
  `sendManyContacts` (use the existing Stub client pattern).

Manual smoke: paperclip → Send contact → select 3 contacts → Send.
One bubble appears containing all three cards; recipient phone shows
the array. Single-contact path unchanged.

---

## Release

v0.10.35: F103 + F104. project.yml version bump, ROADMAP flip the
two `- ☐` lines under Location + Contact sections, tag + push.
