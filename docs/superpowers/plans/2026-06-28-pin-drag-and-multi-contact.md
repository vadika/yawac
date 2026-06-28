# F103 + F104 — Pin-drag re-geocode + Multi-contact vCard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the location picker re-geocode on a tap-to-move pin (F103), and let users pick multiple contacts and send them as a single WhatsApp `ContactsArrayMessage` bubble (F104).

**Architecture:** F103 is a one-file SwiftUI Map API swap; the underlying model already debounces and reverse-geocodes any coordinate handed to `onPinDrag(to:)`. F104 adds a new Go bridge entry point + classifier arm, a Swift bridge wrapper, a multi-select `ContactPickerSheet`, a new `UIMessage.Body.contacts([ContactPayload])` case, a multi-card render in `MessageRow`, and a `PersistedMessage.contactsJSON` column so the bubble survives a restart. Both ship together as v0.10.35.

**Tech Stack:** SwiftUI (macOS 14, new Map API + MapReader), MapKit, CoreLocation, SwiftData, whatsmeow Go SDK, gomobile-built XCFramework, XCTest, Go `testing`.

## Global Constraints

- Deployment target macOS 14.0; deny anything that bumps it.
- Bridge module path is `bridge/`; the XCFramework is rebuilt via `scripts/build-xcframework.sh` (gomobile bind, target=macos).
- The whatsmeow pin is the fork `github.com/vadika/whatsmeow` per `bridge/go.mod` — do NOT change the `replace` directive.
- TDD per task: write the failing test first, run it red, implement, run it green, commit.
- Frequent commits — one per task; each commit must build green.
- Existing single-contact send path stays untouched as the fallback for 1-staged-contact sends (back-compat).
- App must remain installable from `/Applications/yawac.app` post-release (Sparkle appcast + cask flow per memory `reference_yawac_release_workflow.md`).
- Before launching the Debug build during manual smoke, `pkill -9 -f "yawac.app/Contents/MacOS/yawac"` first (F72 LSMultipleInstancesProhibited gate).
- Logs land in `/tmp/yawac.log`; read with `strings /tmp/yawac.log | grep <tag>` (ANSI escapes).

---

### Task 1: F103 — LocationPickerSheet tap-to-move + new Map API

**Files:**
- Modify: `yawac/Views/LocationPickerSheet.swift` (entire `body`)
- Test: `yawacTests/LocationPickerSheetModelTests.swift` (extend OR create — see step 1)

**Interfaces:**
- Consumes: `LocationPickerSheetModel.onPinDrag(to:)` (already exists), `LocationPickerSheetModel.selectedCoord`, `LocationPickerSheetModel.region` (still used as initial position).
- Produces: nothing new — F103 is contained in the sheet view.

- [ ] **Step 1: Check whether the model tests file exists; create if not**

```bash
ls yawacTests/LocationPickerSheetModelTests.swift 2>&1
```

Expected: either the file path (extend it) or `No such file or directory` (create new in step 2 with the file header below).

- [ ] **Step 2: Write the failing test**

Open `yawacTests/LocationPickerSheetModelTests.swift`. If the file did not exist in step 1, create it with this full content. If it existed, append the new `test_onPinDrag_updates_selectedCoord` function inside the existing `@MainActor final class LocationPickerSheetModelTests: XCTestCase {` body and skip the surrounding boilerplate.

```swift
import XCTest
import CoreLocation
@testable import yawac

@MainActor
final class LocationPickerSheetModelTests: XCTestCase {

    func test_onPinDrag_updates_selectedCoord() {
        let m = LocationPickerSheetModel()
        let target = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        m.onPinDrag(to: target)
        XCTAssertEqual(m.selectedCoord.latitude, target.latitude, accuracy: 0.0001)
        XCTAssertEqual(m.selectedCoord.longitude, target.longitude, accuracy: 0.0001)
    }
}
```

- [ ] **Step 3: Run test to verify it fails (or passes if pre-existing)**

Run:
```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
    -only-testing:yawacTests/LocationPickerSheetModelTests/test_onPinDrag_updates_selectedCoord \
    test 2>&1 | tail -20
```

Expected on a fresh model: `Test Suite 'Selected tests' passed` (the model already updates `selectedCoord` — the test is a pin so future regressions are caught). If it fails, the model regressed and must be fixed before continuing.

- [ ] **Step 4: Replace LocationPickerSheet.body's Map block with the new-API version**

Replace `yawac/Views/LocationPickerSheet.swift` in full with:

```swift
import SwiftUI
import MapKit

struct LocationPickerSheet: View {
    @Bindable var model: LocationPickerSheetModel
    @Environment(\.dismiss) private var dismiss
    var onSend: (LocationPayload) -> Void

    @State private var camera: MapCameraPosition = .automatic

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
                        camera = .region(model.region)
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

            // F103: new Map(position:) API + MapReader. The legacy
            // Map(coordinateRegion:annotationItems:) exposes no per-pin
            // drag; this version uses a DragGesture(minimumDistance: 0)
            // over the whole map to convert any click/release point to
            // a coordinate via the proxy. The pin re-anchors because
            // it reads model.selectedCoord on every body eval.
            MapReader { proxy in
                Map(position: $camera) {
                    Annotation("", coordinate: model.selectedCoord) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.red)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            if let coord = proxy.convert(value.location, from: .local) {
                                model.onPinDrag(to: coord)
                            }
                        }
                )
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
                    Task {
                        await model.useCurrentLocation()
                        camera = .region(model.region)
                    }
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
        .onAppear { camera = .region(model.region) }
    }
}
```

Notes:
- The private `SelectedPin: Identifiable` struct is dropped — `Annotation(_:coordinate:)` takes the `CLLocationCoordinate2D` directly.
- `camera` is local SwiftUI state and is bumped in three places that already mutate `model.region`: `pickResult`, `useCurrentLocation`, initial `onAppear`. Pin drags do NOT bump the camera (the user is pointing at a spot they already see).
- `DragGesture(minimumDistance: 0)` fires on a plain tap as well, giving tap-to-move for free.

- [ ] **Step 5: Run all yawac unit tests to verify nothing else broke**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: `Test Suite 'All tests' passed`.

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/LocationPickerSheet.swift yawacTests/LocationPickerSheetModelTests.swift
git commit -m "F103: LocationPickerSheet tap-to-move pin via new Map API

Swap Map(coordinateRegion:annotationItems:) for MapReader{ Map(position:)
{ Annotation } } and attach DragGesture(minimumDistance: 0) so a click or
drag-release anywhere on the map calls model.onPinDrag(to:). The model's
existing 250ms-debounced reverse-geocode then updates resolvedName /
resolvedAddress. Camera state moves to a local @State driven only by
search-row picks and useCurrentLocation; pin moves do not re-center.

Add a model unit test pinning onPinDrag's coord mutation so the wiring
can't regress silently again."
```

---

### Task 2: F104a — Go bridge: SendContactsArray + ContactsArrayMessage inbound

**Files:**
- Modify: `bridge/jsonmodels.go` (JMessage gains `Contacts`; new `JContactsArrayPayload`)
- Modify: `bridge/messages.go` (`classifyMessage` adds GetContactsArrayMessage arm; `dispatchMessage` sets `jm.Contacts`; new `SendContactsArray`)
- Test: `bridge/messages_test.go` (new `TestSendContactsArrayUnpaired`, `TestSendContactsArrayBadJID`, `TestClassifyInboundContactsArray`)

**Interfaces:**
- Consumes: `waE2E.ContactsArrayMessage`, `waE2E.ContactMessage`, existing `wrapForChat`, `classifyKindUnwrapped` (no change).
- Produces:
  - `(c *Client) SendContactsArray(chatJIDStr string, displayName string, vcards []string, ephemeralSec int32) (string, error)` returning a `JSendResult` JSON string identical to `SendContact`.
  - `JContactsArrayPayload{ DisplayName string, Contacts []JContactPayload }` JSON shape, serialized under `contacts_array` JMessage field. JMessage gets `ContactsArray *JContactsArrayPayload \`json:"contacts_array,omitempty"\``.
  - `classifyMessage` returns kind `"contacts"` when `GetContactsArrayMessage() != nil`, with the parsed payload also wired up — see step 3.

- [ ] **Step 1: Write the failing tests**

Append to `bridge/messages_test.go`:

```go
func TestSendContactsArrayUnpaired(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/sca.db")
    defer c.Close()
    vcards := []string{
        "BEGIN:VCARD\nVERSION:3.0\nFN:Anna\nTEL;type=CELL;waid=11111:+11111\nEND:VCARD",
        "BEGIN:VCARD\nVERSION:3.0\nFN:Bob\nTEL;type=CELL;waid=22222:+22222\nEND:VCARD",
    }
    _, err := c.SendContactsArray("1234@s.whatsapp.net", "Contacts", vcards, 0)
    if err == nil {
        t.Fatal("expected error on unpaired client")
    }
}

func TestSendContactsArrayBadJID(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/sca2.db")
    defer c.Close()
    _, err := c.SendContactsArray("not a jid", "X", []string{"BEGIN:VCARD\nEND:VCARD"}, 0)
    if err == nil {
        t.Fatal("expected parse error")
    }
}

func TestSendContactsArrayEmpty(t *testing.T) {
    c, _ := NewClient(t.TempDir() + "/sca3.db")
    defer c.Close()
    _, err := c.SendContactsArray("1234@s.whatsapp.net", "X", nil, 0)
    if err == nil {
        t.Fatal("expected error on empty vcards")
    }
}

func TestClassifyInboundContactsArray(t *testing.T) {
    m := &waE2E.Message{
        ContactsArrayMessage: &waE2E.ContactsArrayMessage{
            DisplayName: proto.String("Contacts"),
            Contacts: []*waE2E.ContactMessage{
                {DisplayName: proto.String("Anna"), Vcard: proto.String("BEGIN:VCARD\nFN:Anna\nEND:VCARD")},
                {DisplayName: proto.String("Bob"), Vcard: proto.String("BEGIN:VCARD\nFN:Bob\nEND:VCARD")},
            },
        },
    }
    kind, _, _, _, _ := classifyMessage(m)
    if kind != "contacts" {
        t.Fatalf("kind=%s", kind)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd bridge && go test -run 'TestSendContactsArray|TestClassifyInboundContactsArray' -count=1 ./... 2>&1 | tail -10
```

Expected: build errors / undefined `SendContactsArray` / kind != "contacts".

- [ ] **Step 3: Add the bridge JSON shape**

Edit `bridge/jsonmodels.go` — append after `JContactPayload`:

```go
type JContactsArrayPayload struct {
    DisplayName string            `json:"display_name"`
    Contacts    []JContactPayload `json:"contacts"`
}
```

And inside `JMessage`, add the new optional field right after `Contact`:

```go
    Contact          *JContactPayload  `json:"contact,omitempty"`
    ContactsArray    *JContactsArrayPayload `json:"contacts_array,omitempty"`
    IsViewOnce       bool              `json:"is_view_once,omitempty"`
```

- [ ] **Step 4: Wire classifier + dispatcher**

Edit `bridge/messages.go`. First, change `classifyMessage`'s signature is intentionally NOT widened (six callers); instead handle ContactsArrayMessage classification inside the switch by returning `"contacts"` for the kind and leaving the structured payload nil. The dispatcher reads the full payload separately. Insert this arm immediately after the existing `GetContactMessage()` arm (around line 635 in current source) in `classifyMessage`:

```go
        case m.GetContactsArrayMessage() != nil:
            return "contacts", nil, 0, nil, isViewOnce
```

Also extend `classifyKindUnwrapped` so the quoted-snippet path can name it. Insert immediately after the `GetContactMessage()` case (around line 666):

```go
    case m.GetContactsArrayMessage() != nil:
        return "contacts"
```

Then in `dispatchMessage`, populate `jm.ContactsArray` when the inner message carries one. Add this block immediately after the `jm.Contact = contact` line is set via the struct literal — replace the `jm := JMessage{ ... }` block plus the following body to insert population. The cleanest spot is right after the existing `if p := extractPoll(inner); p != nil { jm.Poll = p }` block (around line 567). Append:

```go
    if ca := inner.GetContactsArrayMessage(); ca != nil {
        cards := ca.GetContacts()
        payload := &JContactsArrayPayload{
            DisplayName: ca.GetDisplayName(),
            Contacts:    make([]JContactPayload, 0, len(cards)),
        }
        for _, card := range cards {
            payload.Contacts = append(payload.Contacts, JContactPayload{
                Vcard:       card.GetVcard(),
                DisplayName: card.GetDisplayName(),
            })
        }
        jm.ContactsArray = payload
    }
```

- [ ] **Step 5: Add SendContactsArray**

Append to `bridge/messages.go` immediately after the existing `SendContact` function (right before `stubQuoted`):

```go
// SendContactsArray sends a ContactsArrayMessage (multiple vCards in
// one bubble). displayName labels the array; each vcard is a full
// VCARD 3.0 payload built Swift-side via VCardBuilder. When
// ephemeralSec > 0, wraps in EphemeralMessage. Errors on an empty
// vcards slice — sending zero contacts is never what the caller
// wants and WhatsApp would reject it server-side anyway.
func (c *Client) SendContactsArray(
    chatJIDStr string,
    displayName string,
    vcards []string,
    ephemeralSec int32,
) (string, error) {
    if c.wa == nil {
        return "", errors.New("client closed")
    }
    if len(vcards) == 0 {
        return "", errors.New("no vcards")
    }
    jid, err := types.ParseJID(chatJIDStr)
    if err != nil {
        return "", fmt.Errorf("parse jid: %w", err)
    }
    if jid.User == "" || jid.Server == "" {
        return "", fmt.Errorf("parse jid: empty user or server")
    }
    cards := make([]*waE2E.ContactMessage, 0, len(vcards))
    for _, v := range vcards {
        cards = append(cards, &waE2E.ContactMessage{
            Vcard: proto.String(v),
        })
    }
    inner := &waE2E.Message{
        ContactsArrayMessage: &waE2E.ContactsArrayMessage{
            DisplayName: proto.String(displayName),
            Contacts:    cards,
        },
    }
    msg := wrapForChat(inner, ephemeralSec, false)
    resp, err := c.wa.SendMessage(context.Background(), jid, msg)
    if err != nil {
        return "", fmt.Errorf("send: %w", err)
    }
    out := JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()}
    b, _ := json.Marshal(out)
    return string(b), nil
}
```

- [ ] **Step 6: Run tests, verify green**

```bash
cd bridge && go test -run 'TestSendContactsArray|TestClassifyInboundContactsArray|TestClassifyInboundContact|TestSendContactUnpaired|TestSendContactBadJID' -count=1 ./... 2>&1 | tail -10
```

Expected: all named tests PASS. Run the full suite too:

```bash
cd bridge && go test ./... 2>&1 | tail -5
```

Expected: `ok` for `github.com/vadikas/yawac/bridge`.

- [ ] **Step 7: Commit**

```bash
git add bridge/jsonmodels.go bridge/messages.go bridge/messages_test.go
git commit -m "F104a: bridge SendContactsArray + inbound classify

waE2E.ContactsArrayMessage is now sendable via Client.SendContactsArray
(N vcards, single display name, ephemeral-aware) and surfaces inbound
as kind \"contacts\" with the full JContactsArrayPayload payload on
JMessage.ContactsArray. classifyKindUnwrapped picks it up too so
quoted-snippet paths name the kind correctly. Tests: unpaired,
bad-jid, empty-vcards guards + inbound classifier."
```

---

### Task 3: F104b — Swift bridge surface + UIMessage `.contacts` case

**Files:**
- Modify: `yawac/Bridge/JSONModels.swift` (add `BridgeContactsArrayPayload`; extend `BridgeMessage`)
- Modify: `yawac/Bridge/WAClient.swift` (new `sendContacts` wrapper after `sendContact`)
- Modify: `yawac/Models/Message.swift` (add `.contacts([ContactPayload])` body case; UIMessage init handles `"contacts"` kind)
- Test: `yawacTests/UIMessageContactsArrayTests.swift` (new; one round-trip test)

**Interfaces:**
- Consumes: `bridge.SendContactsArray` (from Task 2; gomobile re-exposes as `go.sendContactsArray` after Task 7 XCFramework rebuild — call site compiles before then by referencing the symbol directly).
- Produces:
  - `WAClient.sendContacts(chatJID:displayName:vcards:ephemeralSeconds:) throws -> BridgeSendResult`.
  - `UIMessage.Body.contacts([ContactPayload])` — used by Task 5 and Task 6.

**Note on build order:** the Swift `sendContacts` wrapper calls `go.sendContactsArray(...)` which only exists after the XCFramework is rebuilt in Task 7. **Therefore the wrapper body in step 3 below is the final form; the build only goes green at Task 7.** All later Swift tasks (4, 5, 6) compile fine because they don't touch `go.sendContactsArray` directly; xcodebuild against the current XCFramework will succeed for everything except this one symbol. Re-run the Task 3 build verification after Task 7 to confirm.

- [ ] **Step 1: Write the failing test**

Create `yawacTests/UIMessageContactsArrayTests.swift`:

```swift
import XCTest
@testable import yawac

final class UIMessageContactsArrayTests: XCTestCase {

    func test_init_parses_contacts_array_kind() throws {
        let json = """
        {
          "id": "wamid.1",
          "chat_jid": "1@s.whatsapp.net",
          "sender_jid": "1@s.whatsapp.net",
          "from_me": false,
          "timestamp": 1700000000,
          "kind": "contacts",
          "contacts_array": {
            "display_name": "Contacts",
            "contacts": [
              { "vcard": "BEGIN:VCARD\\nVERSION:3.0\\nFN:Anna\\nTEL;type=CELL;waid=11:+11\\nEND:VCARD", "display_name": "Anna" },
              { "vcard": "BEGIN:VCARD\\nVERSION:3.0\\nFN:Bob\\nTEL;type=CELL;waid=22:+22\\nEND:VCARD", "display_name": "Bob" }
            ]
          }
        }
        """
        let bm = try JSONDecoder().decode(BridgeMessage.self, from: Data(json.utf8))
        let m = UIMessage(bm)
        guard case .contacts(let cards) = m.body else {
            return XCTFail("expected .contacts body, got \(m.body)")
        }
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].displayName, "Anna")
        XCTAssertEqual(cards[0].phone, "+11")
        XCTAssertEqual(cards[0].jid, "11@s.whatsapp.net")
        XCTAssertEqual(cards[1].displayName, "Bob")
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
    -only-testing:yawacTests/UIMessageContactsArrayTests/test_init_parses_contacts_array_kind \
    test 2>&1 | tail -15
```

Expected: build error — `BridgeMessage` has no `contactsArray` property OR `UIMessage.Body` has no `.contacts` case.

- [ ] **Step 3: Extend BridgeMessage + add BridgeContactsArrayPayload**

In `yawac/Bridge/JSONModels.swift`, immediately after `BridgeContactPayload`:

```swift
struct BridgeContactsArrayPayload: Codable, Hashable {
    let displayName: String
    let contacts: [BridgeContactPayload]

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case contacts
    }
}
```

In the same file, extend `BridgeMessage`:

1. Add the stored property right after the existing `contact: BridgeContactPayload?`:

```swift
    let contact: BridgeContactPayload?
    let contactsArray: BridgeContactsArrayPayload?
    let isViewOnce: Bool?
```

2. Add the coding key in `CodingKeys` right after `case contact`:

```swift
        case contact
        case contactsArray = "contacts_array"
        case isViewOnce = "is_view_once"
```

- [ ] **Step 4: Add the WAClient wrapper**

In `yawac/Bridge/WAClient.swift`, immediately after `sendContact(...)`:

```swift
    nonisolated func sendContacts(chatJID: String,
                                  displayName: String,
                                  vcards: [String],
                                  ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
        bump("sendContacts")
        var err: NSError?
        // gomobile bridges []string as String1; convert via the helper
        // that the rest of WAClient uses for string-array params. The
        // bridge SendContactsArray takes vcards []string.
        let json = go.sendContactsArray(chatJID,
                                        displayName: displayName,
                                        vcards: stringArray(vcards),
                                        ephemeralSec: ephemeralSeconds,
                                        error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }
```

If a `stringArray(_:)` helper does not already exist in `WAClient.swift` for converting `[String]` to whatever gomobile expects (it may be `BridgeStringArray` or similar — check by searching for `[String]` uses in `WAClient.swift` first), use whichever pattern the existing code already uses for the same conversion. If no `[String]`-taking method exists yet on the bridge, the gomobile-generated API may bridge `[]string` as a comma-separated `String` or as a typed object — confirm by inspecting the generated `Bridge.framework/Headers/Bridge.objc.h` for `sendContactsArray:` after Task 7's rebuild, and adjust the call site to whatever the header declares. **If unsure at implementation time, write the call site as `go.sendContactsArray(chatJID, displayName: displayName, vcards: vcards, ephemeralSec: ephemeralSeconds, error: &err)` and let the Task 7 rebuild prove the exact signature; fix locally if the rebuilt header differs.**

- [ ] **Step 5: Add the `.contacts` case + UIMessage init handling**

In `yawac/Models/Message.swift`, inside `UIMessage.Body` enum, add the new case after `.contact`:

```swift
        case contact(ContactPayload)
        case contacts([ContactPayload])
        case system(String)
```

In the `UIMessage.init(_ b: BridgeMessage)` switch (around line 141 in current source), insert a new arm immediately after the existing `case "contact":` block (before `default:`):

```swift
        case "contacts":
            if let arr = b.contactsArray {
                let cards = arr.contacts.map { c -> ContactPayload in
                    let waid = VCardBuilder.parseWAID(c.vcard) ?? ""
                    let jid = waid.isEmpty ? "" : "\(waid)@s.whatsapp.net"
                    let phone = waid.isEmpty ? "" : "+\(waid)"
                    return ContactPayload(
                        jid: jid,
                        displayName: c.displayName,
                        phone: phone,
                        vcard: c.vcard)
                }
                self.body = .contacts(cards)
            } else {
                self.body = .system("(contacts)")
            }
```

- [ ] **Step 6: Run test, verify it passes**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
    -only-testing:yawacTests/UIMessageContactsArrayTests/test_init_parses_contacts_array_kind \
    test 2>&1 | tail -10
```

Expected: PASS. (If the build fails with `sendContactsArray` not found, that is the Task 7 dependency — defer running this verification until Task 7, but the test file alone compiles fine because it never references the WAClient wrapper.)

Then a full test run:

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: `Test Suite 'All tests' passed`. The `.contacts` enum case may produce a warning in other switch-on-body sites that don't yet handle it — Task 6 closes that. If any switch is now non-exhaustive and turns into an error, add a `case .contacts: EmptyView()` placeholder at each site and note them in step 7's commit message; Task 6 replaces them.

- [ ] **Step 7: Commit**

```bash
git add yawac/Bridge/JSONModels.swift yawac/Bridge/WAClient.swift yawac/Models/Message.swift yawacTests/UIMessageContactsArrayTests.swift
git commit -m "F104b: Swift bridge + UIMessage.contacts case

BridgeMessage gains contactsArray (snake_case json contacts_array)
typed via BridgeContactsArrayPayload (display_name + [contacts]).
WAClient.sendContacts wraps go.sendContactsArray symmetrically with
sendContact. UIMessage.Body.contacts([ContactPayload]) decodes from
kind=contacts in BridgeMessage; each vcard's waid is parsed into jid +
phone so the existing single-card renderer fields stay populated.
Round-trip test covers Anna + Bob."
```

---

### Task 4: F104c — ContactPickerSheet multi-select

**Files:**
- Modify: `yawac/ViewModels/ContactPickerSheetModel.swift` (selectedJID → selectedJIDs Set; buildPayloads)
- Modify: `yawac/Views/ContactPickerSheet.swift` (checkbox UI, "Send N contacts" label, onSend callback signature → `[ContactPayload]`)
- Modify: `yawac/Views/ComposerView.swift` (the `ContactPickerSheet` call site — onSend now receives an array; stage each)
- Test: `yawacTests/ContactPickerSheetModelTests.swift` (new — toggle + buildPayloads cover)

**Interfaces:**
- Consumes: nothing new from earlier tasks.
- Produces:
  - `ContactPickerSheetModel.selectedJIDs: Set<String>`
  - `ContactPickerSheetModel.toggle(_ jid: String)`
  - `ContactPickerSheetModel.buildPayloads() -> [ContactPayload]`
  - `ContactPickerSheet.onSend: ([ContactPayload]) -> Void` (signature change — composer call site updates in same task)
  - `ContactPickerSheet` row uses SF Symbol `checkmark.circle.fill` (selected) / `circle` (deselected); send label is `"Send"` for 0–1 selected and `"Send N contacts"` for N ≥ 2.

- [ ] **Step 1: Write the failing test**

Create `yawacTests/ContactPickerSheetModelTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class ContactPickerSheetModelTests: XCTestCase {

    private func make(_ jids: [String]) -> ContactPickerSheetModel {
        let contacts = jids.map {
            BridgeContact(jid: $0, name: $0.prefix(2).uppercased(),
                          pushName: nil, fullName: nil, businessName: nil)
        }
        return ContactPickerSheetModel(contacts: contacts)
    }

    func test_toggle_adds_then_removes() {
        let m = make(["111@s.whatsapp.net", "222@s.whatsapp.net"])
        XCTAssertTrue(m.selectedJIDs.isEmpty)
        XCTAssertFalse(m.canSend)
        m.toggle("111@s.whatsapp.net")
        XCTAssertEqual(m.selectedJIDs, ["111@s.whatsapp.net"])
        XCTAssertTrue(m.canSend)
        m.toggle("111@s.whatsapp.net")
        XCTAssertTrue(m.selectedJIDs.isEmpty)
        XCTAssertFalse(m.canSend)
    }

    func test_buildPayloads_preserves_contacts_order_not_selection_order() {
        let m = make(["111@s.whatsapp.net", "222@s.whatsapp.net", "333@s.whatsapp.net"])
        // Select in reverse order.
        m.toggle("333@s.whatsapp.net")
        m.toggle("111@s.whatsapp.net")
        let payloads = m.buildPayloads()
        XCTAssertEqual(payloads.map { $0.jid },
                       ["111@s.whatsapp.net", "333@s.whatsapp.net"])
    }

    func test_buildPayloads_empty_when_nothing_selected() {
        let m = make(["111@s.whatsapp.net"])
        XCTAssertEqual(m.buildPayloads(), [])
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
    -only-testing:yawacTests/ContactPickerSheetModelTests \
    test 2>&1 | tail -15
```

Expected: build error — `selectedJIDs` / `toggle` / `buildPayloads` undefined.

- [ ] **Step 3: Rewrite the model**

Replace `yawac/ViewModels/ContactPickerSheetModel.swift` in full:

```swift
import Foundation
import Observation

/// Drives the "send a WhatsApp contact" composer sheet.
///
/// Holds the contact list, the search query, and the set of currently
/// selected JIDs. `buildPayloads()` produces a stable-ordered array of
/// `ContactPayload`s (one per selected contact, in original contacts
/// list order). Each vCard is built via `VCardBuilder.build` so the
/// recipient sees a tappable "Message on WhatsApp" button per card.
@MainActor
@Observable
final class ContactPickerSheetModel {
    let contacts: [BridgeContact]
    var query: String = ""
    var selectedJIDs: Set<String> = []

    init(contacts: [BridgeContact]) {
        self.contacts = contacts
    }

    var canSend: Bool { !selectedJIDs.isEmpty }

    var filtered: [BridgeContact] {
        guard !query.isEmpty else { return contacts }
        let q = query.lowercased()
        return contacts.filter { c in
            c.name.lowercased().contains(q)
                || (c.fullName ?? "").lowercased().contains(q)
        }
    }

    func toggle(_ jid: String) {
        if selectedJIDs.contains(jid) {
            selectedJIDs.remove(jid)
        } else {
            selectedJIDs.insert(jid)
        }
    }

    func isSelected(_ jid: String) -> Bool {
        selectedJIDs.contains(jid)
    }

    /// Build payloads in the original contacts list order (NOT
    /// selection order) so the resulting bubble reads predictably and
    /// the composer chip strip stays stable across re-selections.
    func buildPayloads() -> [ContactPayload] {
        contacts.compactMap { c -> ContactPayload? in
            guard selectedJIDs.contains(c.jid) else { return nil }
            let phoneDigits = String(c.jid.split(separator: "@").first ?? "")
            let phone = "+" + phoneDigits
            return ContactPayload(
                jid: c.jid,
                displayName: c.name,
                phone: phone,
                vcard: VCardBuilder.build(
                    jid: c.jid,
                    name: c.name,
                    phone: phone))
        }
    }
}
```

- [ ] **Step 4: Rewrite the sheet**

Replace `yawac/Views/ContactPickerSheet.swift` in full:

```swift
import SwiftUI

struct ContactPickerSheet: View {
    @Bindable var model: ContactPickerSheetModel
    @Environment(\.dismiss) private var dismiss
    var onSend: ([ContactPayload]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send contact").font(.headline)

            TextField("Search", text: $model.query)
                .textFieldStyle(.roundedBorder)

            List(model.filtered, id: \.jid) { contact in
                Button {
                    model.toggle(contact.jid)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.isSelected(contact.jid)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.isSelected(contact.jid)
                                             ? Theme.accent : Theme.textMuted)
                        Text(contact.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(sendButtonLabel) {
                    let payloads = model.buildPayloads()
                    guard !payloads.isEmpty else { return }
                    onSend(payloads)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var sendButtonLabel: String {
        model.selectedJIDs.count >= 2
            ? "Send \(model.selectedJIDs.count) contacts"
            : "Send"
    }
}
```

- [ ] **Step 5: Update the composer call site**

In `yawac/Views/ComposerView.swift`, the `ContactPickerSheet` is mounted around line 128:

```swift
        .sheet(isPresented: $showContactPicker) {
            ContactPickerSheet(
                model: ContactPickerSheetModel(contacts: contactsForPicker),
                onSend: { payload in
                    vm.stageContact(payload)
                }
            )
        }
```

Change `onSend` to take an array and stage each:

```swift
        .sheet(isPresented: $showContactPicker) {
            ContactPickerSheet(
                model: ContactPickerSheetModel(contacts: contactsForPicker),
                onSend: { payloads in
                    for p in payloads { vm.stageContact(p) }
                }
            )
        }
```

- [ ] **Step 6: Run tests, verify they pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
    -only-testing:yawacTests/ContactPickerSheetModelTests \
    test 2>&1 | tail -10
```

Expected: 3 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add yawac/ViewModels/ContactPickerSheetModel.swift yawac/Views/ContactPickerSheet.swift yawac/Views/ComposerView.swift yawacTests/ContactPickerSheetModelTests.swift
git commit -m "F104c: ContactPickerSheet multi-select

selectedJID? → selectedJIDs Set<String>. Sheet rows are toggle buttons
with a checkmark.circle.fill / circle indicator. Send label flips to
\"Send N contacts\" when N ≥ 2. buildPayloads() returns payloads in
the original contacts-list order (not selection order) so the chip
strip stays stable. Composer call site iterates the array."
```

---

### Task 5: F104d — ConversationViewModel batching + persistence

**Files:**
- Modify: `yawac/Models/PersistedMessage.swift` (new `contactsJSON: String?` optional field + init param)
- Modify: `yawac/ViewModels/ConversationViewModel.swift` (`sendPendingAttachments` branches on `cards.count`; new `sendManyContacts`; new `persistOutgoingContacts(_:contacts:)`; load-history path hydrates `.contacts` from `contactsJSON`)
- Test: `yawacTests/ConversationViewModelMultiContactSendTests.swift` (new — exercises the 1-vs-many branch via the existing Stub client pattern)

**Interfaces:**
- Consumes: `WAClient.sendContacts(...)` from Task 3, `UIMessage.Body.contacts(...)` from Task 3, `PersistedMessage` schema.
- Produces:
  - `PersistedMessage.contactsJSON: String?` — JSON-encoded `[BridgeContactPayload]` (same shape as inbound), set on outbound multi-contact and hydrated on cold-start.
  - `ConversationViewModel.sendManyContacts(_:displayName:) async` (private)
  - `ConversationViewModel.persistOutgoingContacts(_:contacts:)` (private)
  - The cold-start history hydration (currently keyed off `kind == "contact"` → `.contact`) gains an arm for `kind == "contacts"` → decode `contactsJSON` → `.contacts(...)`.

- [ ] **Step 1: Locate the history-hydration site for existing single-contact rows**

```bash
grep -n "kind == \"contact\"\|case \"contact\":\|contactVCard" yawac/ViewModels/ConversationViewModel.swift | head
```

Read the surrounding 30 lines. The cold-start loader maps `PersistedMessage` rows back to `UIMessage` values; the new `kind == "contacts"` arm slots in next to that. If it lives in a different file, follow the grep hits.

- [ ] **Step 2: Write the failing test**

Search the test target for an existing Stub client pattern first:

```bash
grep -ln "Stub.*Client\|class Stub" yawacTests/*.swift | head
```

Pick the pattern that's already in use (e.g. `StubSelfChatClient`) and mirror its shape. If no pattern exists for `sendContacts`, the simplest stub is a subclass of `WAClient` that overrides `sendContacts` and `sendContact` to record calls and return a canned `BridgeSendResult`. Create `yawacTests/ConversationViewModelMultiContactSendTests.swift` with:

```swift
import XCTest
@testable import yawac

@MainActor
final class ConversationViewModelMultiContactSendTests: XCTestCase {

    private final class RecordingClient: WAClient {
        var sentSingle: [(jid: String, vcard: String, name: String)] = []
        var sentArray: [(jid: String, name: String, vcards: [String])] = []
        override nonisolated func sendContact(chatJID: String,
                                              vcard: String,
                                              displayName: String,
                                              ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
            // Record via DispatchQueue.main hop so we stay @MainActor-safe.
            DispatchQueue.main.sync {
                self.sentSingle.append((chatJID, vcard, displayName))
            }
            return BridgeSendResult(messageID: "wamid.single.\(self.sentSingle.count)",
                                    timestamp: 1700000000)
        }
        override nonisolated func sendContacts(chatJID: String,
                                               displayName: String,
                                               vcards: [String],
                                               ephemeralSeconds: Int32 = 0) throws -> BridgeSendResult {
            DispatchQueue.main.sync {
                self.sentArray.append((chatJID, displayName, vcards))
            }
            return BridgeSendResult(messageID: "wamid.array.\(self.sentArray.count)",
                                    timestamp: 1700000001)
        }
    }

    func test_single_staged_contact_uses_sendContact() async throws {
        let client = RecordingClient()
        let vm = ConversationViewModel(chatJID: "1@s.whatsapp.net", client: client)
        vm.stageContact(ContactPayload(jid: "11@s.whatsapp.net", displayName: "Anna",
                                       phone: "+11",
                                       vcard: "BEGIN:VCARD\nFN:Anna\nEND:VCARD"))
        await vm.sendPendingAttachments()
        XCTAssertEqual(client.sentSingle.count, 1)
        XCTAssertEqual(client.sentArray.count, 0)
    }

    func test_two_staged_contacts_use_sendContacts() async throws {
        let client = RecordingClient()
        let vm = ConversationViewModel(chatJID: "1@s.whatsapp.net", client: client)
        vm.stageContact(ContactPayload(jid: "11@s.whatsapp.net", displayName: "Anna",
                                       phone: "+11",
                                       vcard: "BEGIN:VCARD\nFN:Anna\nEND:VCARD"))
        vm.stageContact(ContactPayload(jid: "22@s.whatsapp.net", displayName: "Bob",
                                       phone: "+22",
                                       vcard: "BEGIN:VCARD\nFN:Bob\nEND:VCARD"))
        await vm.sendPendingAttachments()
        XCTAssertEqual(client.sentSingle.count, 0)
        XCTAssertEqual(client.sentArray.count, 1)
        XCTAssertEqual(client.sentArray.first?.vcards.count, 2)
    }
}
```

If the existing test files initialize `ConversationViewModel` with extra dependencies (a SessionViewModel, ModelContainer, etc.), copy that initialization verbatim from `SessionViewModelSelfChatTests.swift` rather than guessing the signature.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
    -only-testing:yawacTests/ConversationViewModelMultiContactSendTests \
    test 2>&1 | tail -15
```

Expected: build error (`sendContacts` not overridable yet) OR test failure (`sentArray.count == 0`).

- [ ] **Step 4: Extend PersistedMessage**

In `yawac/Models/PersistedMessage.swift`, immediately after `var contactDisplayName: String? = nil` (around line 54):

```swift
    var contactVCard: String? = nil
    var contactDisplayName: String? = nil
    /// JSON-encoded `[BridgeContactPayload]` for multi-contact
    /// (ContactsArrayMessage) bubbles. nil for single-contact and
    /// non-contact kinds. Stored as a single column so the
    /// SwiftData migration stays lightweight (a new optional field
    /// is back-compatible without a VersionedSchema bump).
    var contactsJSON: String? = nil
```

In the same file, the `init(...)` (around line 117) needs the new param. Add it to the parameter list right after `contactDisplayName: String? = nil`:

```swift
        contactVCard: String? = nil,
        contactDisplayName: String? = nil,
        contactsJSON: String? = nil,
```

And the body assignment right after `self.contactDisplayName = contactDisplayName`:

```swift
        self.contactVCard = contactVCard
        self.contactDisplayName = contactDisplayName
        self.contactsJSON = contactsJSON
```

- [ ] **Step 5: Wire ConversationViewModel send branching + persistence + hydration**

In `yawac/ViewModels/ConversationViewModel.swift`, replace the `for card in cards { await sendOneContact(card) }` line inside `sendPendingAttachments` (around line 2171) with:

```swift
        if cards.count >= 2 {
            await sendManyContacts(cards)
        } else {
            for card in cards {
                await sendOneContact(card)
            }
        }
```

Add the new private method immediately after `sendOneContact` (around line 2295 — just past the existing single-contact persistence call):

```swift
    /// Dispatch ≥2 staged contact cards through the bridge as a single
    /// ContactsArrayMessage and append one bubble carrying all of them.
    /// Display name is the first card's name + " and N other(s)" so
    /// the recipient list-view preview line is human-readable.
    private func sendManyContacts(_ cards: [ContactPayload]) async {
        let displayName: String = {
            guard let first = cards.first else { return "Contacts" }
            let extra = cards.count - 1
            return extra > 0 ? "\(first.displayName) and \(extra) other\(extra == 1 ? "" : "s")"
                              : first.displayName
        }()
        do {
            let res = try client.sendContacts(
                chatJID: chatJID,
                displayName: displayName,
                vcards: cards.map { $0.vcard },
                ephemeralSeconds: ephemeralExpirationSeconds)
            let m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .contacts(cards))
            messages.append(m)
            messageIDs.insert(m.id)
            invalidateTimeline()
            receiptStatus[res.messageID] = .sent
            persistOutgoingContacts(m, contacts: cards)
        } catch {
            let sys = UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID, senderJID: "system",
                fromMe: false, timestamp: Date(),
                body: .system("Failed to send contacts: \(error.localizedDescription)"))
            messages.append(sys)
            messageIDs.insert(sys.id)
            invalidateTimeline()
        }
    }
```

Add the new persistence helper immediately after `persistOutgoingContact` (around line 2511):

```swift
    /// Outbound multi-contact persistence. Stores the array of vCard
    /// payloads as a single JSON column so a cold reopen can re-hydrate
    /// the same UIMessage.Body.contacts(...) bubble.
    private func persistOutgoingContacts(_ m: UIMessage, contacts: [ContactPayload]) {
        guard let context else { return }
        let payloads = contacts.map { c -> BridgeContactPayload in
            BridgeContactPayload(vcard: c.vcard, displayName: c.displayName)
        }
        let data = (try? JSONEncoder().encode(payloads)) ?? Data()
        let row = PersistedMessage(
            id: m.id, chatJID: m.chatJID, senderJID: m.senderJID,
            fromMe: m.fromMe, timestamp: m.timestamp, kind: "contacts",
            text: nil,
            contactsJSON: String(data: data, encoding: .utf8))
        context.insert(row)
        try? context.save()
        MessageIndex.shared.upsert(row.indexFields)
    }
```

For cold-start hydration, find the site that constructs `UIMessage` from a `PersistedMessage` row (grep for `case "contact":` in `ConversationViewModel.swift` first, then check `yawac/Services/HistoryHydrator.swift` and `MessageWriter.swift` if not found there). Wherever the existing `case "contact":` arm hydrates a single-card body, insert immediately after:

```swift
        case "contacts":
            if let json = row.contactsJSON,
               let data = json.data(using: .utf8),
               let arr = try? JSONDecoder().decode([BridgeContactPayload].self, from: data) {
                let cards = arr.map { c -> ContactPayload in
                    let waid = VCardBuilder.parseWAID(c.vcard) ?? ""
                    let jid = waid.isEmpty ? "" : "\(waid)@s.whatsapp.net"
                    let phone = waid.isEmpty ? "" : "+\(waid)"
                    return ContactPayload(
                        jid: jid, displayName: c.displayName,
                        phone: phone, vcard: c.vcard)
                }
                body = .contacts(cards)
            } else {
                body = .system("(contacts)")
            }
```

(Adjust the variable name `body` / `b.body` to match the existing arm's local binding.)

- [ ] **Step 6: Run tests, verify they pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
    -only-testing:yawacTests/ConversationViewModelMultiContactSendTests \
    test 2>&1 | tail -10
```

Expected: 2 tests PASS.

Run the full suite to catch knock-on regressions:

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: `Test Suite 'All tests' passed`.

If SwiftData rejects launch with a schema mismatch (`Duplicate version checksums` or migration error) at test time, the lightweight migration didn't take — confirm `contactsJSON` is declared as `String?` with a default of `nil` so existing rows back-fill, and check there is no `#Index` on the new column. The pattern is documented in memory `project_swiftdata_index_migration.md`.

- [ ] **Step 7: Commit**

```bash
git add yawac/Models/PersistedMessage.swift yawac/ViewModels/ConversationViewModel.swift yawacTests/ConversationViewModelMultiContactSendTests.swift
git commit -m "F104d: ConversationViewModel batching + multi-contact persistence

sendPendingAttachments branches on cards.count: 1 keeps the existing
sendOneContact path (back-compat), ≥2 calls a new sendManyContacts
that fires WAClient.sendContacts once and appends a single .contacts
UIMessage bubble. Display name is \"<first> and N other(s)\" so the
recipient list-view preview line is readable.

Persistence: PersistedMessage gains contactsJSON (lightweight
migration — String? with default nil), persistOutgoingContacts
encodes [BridgeContactPayload] into that column, and cold-start
history hydration decodes it back into UIMessage.Body.contacts(...).

Stub-client test asserts the single-vs-many branch and the array
payload count."
```

---

### Task 6: F104e — MessageRow renders `.contacts`

**Files:**
- Modify: `yawac/Views/MessageRow.swift` (switch in `existingBodyContent` gains `.contacts` arm; new `contactsBubble([ContactPayload])` helper)

**Interfaces:**
- Consumes: `UIMessage.Body.contacts([ContactPayload])` from Task 3, the existing `contactBubble(_:)` helper at line 726 for reuse.
- Produces: nothing — terminal renderer.

- [ ] **Step 1: Add the switch arm + helper**

In `yawac/Views/MessageRow.swift`, the `existingBodyContent` switch (around line 630) currently ends with `case .contact(let c)` and `case .system(let s)`. Insert immediately before `case .system`:

```swift
        case .contacts(let cs):
            contactsBubble(cs)
```

Append the helper immediately after `contactBubble(_:)` (around line 755):

```swift
    @ViewBuilder
    private func contactsBubble(_ cards: [ContactPayload]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .scaledIcon(13)
                    .foregroundStyle(Theme.textMuted)
                Text("\(cards.count) contacts")
                    .scaledUI(11, weight: .semibold)
                    .foregroundStyle(Theme.textMuted)
            }
            Divider()
            // One row per card, reusing the single-contact render so
            // tappable "Message on WhatsApp" stays wired per row.
            ForEach(Array(cards.enumerated()), id: \.offset) { _, c in
                contactBubble(c)
            }
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
    }
```

- [ ] **Step 2: Build to verify the switch is exhaustive again**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED` with no `Switch must be exhaustive` errors. If any other file's switch-on-UIMessage.Body had a placeholder `case .contacts: EmptyView()` from Task 3, leave it — search-result + sidebar previews don't need a full bubble render; only `MessageRow` does. Confirm those placeholders only show in non-bubble contexts:

```bash
grep -rn "case .contacts" yawac --include="*.swift"
```

Each hit outside `MessageRow.swift` should be a one-line summary site (search result row, sidebar preview, etc.) — those can stay as `EmptyView()` or be replaced with a short literal like `Text("📇 \(cs.count) contacts")` if the surrounding switch produces a string snippet. Pick whichever matches the neighbors.

- [ ] **Step 3: Run all tests to verify**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: `Test Suite 'All tests' passed`.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/MessageRow.swift
git commit -m "F104e: MessageRow .contacts bubble

Renders one stacked card row per ContactPayload inside a single
bubble with a \"<N> contacts\" header. Each row reuses the existing
contactBubble(_:) helper so the per-card \"Message on WhatsApp\"
button stays wired unchanged. Closes the switch-exhaustiveness gap
left behind by F104b."
```

---

### Task 7: Rebuild XCFramework + manual smoke

**Files:**
- Modify: `build/Bridge.xcframework/**` (regenerated)

**Interfaces:**
- Consumes: nothing.
- Produces: a fresh `Bridge.xcframework` that exposes `go.sendContactsArray(...)` to `WAClient.sendContacts` (Task 3's wrapper finally compiles green here).

- [ ] **Step 1: Rebuild the XCFramework**

```bash
./scripts/build-xcframework.sh 2>&1 | tail -5
```

Expected: `Built: build/Bridge.xcframework`.

- [ ] **Step 2: Confirm the new exported symbol shape**

```bash
grep -A2 "sendContactsArray" build/Bridge.xcframework/macos-arm64/Bridge.framework/Headers/Bridge.objc.h | head -20
```

Expected: a generated objc selector declaration. The exact Swift signature gomobile produced is what `WAClient.sendContacts` calls; if its parameter labels differ from `displayName:vcards:ephemeralSec:error:` (gomobile sometimes orders strangely), update `WAClient.sendContacts` to match.

- [ ] **Step 3: Rebuild the Debug app + run full test suite**

```bash
pkill -9 -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: `Test Suite 'All tests' passed`. This is where Task 3's `WAClient.sendContacts` finally compiles.

- [ ] **Step 4: Manual smoke — F103 pin-drag**

```bash
: > /tmp/yawac.log
open /Users/vadikas/Library/Developer/Xcode/DerivedData/yawac-bplgxfeuyvjpvlavuewevrxmorvr/Build/Products/Debug/yawac.app
```

Then in the running app:
1. Open any chat → paperclip menu → "Send location…".
2. Type a search query → tap a result; the pin centers on that spot.
3. Click a different spot on the map (no drag). The pin teleports there.
4. Within ~300ms the bottom strip's "name" / "address" updates to the new place.
5. Click and DRAG to a third spot; on mouse-release the pin goes there and the geocoder runs again.
6. Hit "Send"; the chat shows a location bubble matching the last pin coord.

Smoke passes when steps 3–6 all behave as described. If any step fails, capture the symptom and fix before continuing.

- [ ] **Step 5: Manual smoke — F104 multi-contact send + render + restart**

1. In any chat, paperclip menu → "Send contact…".
2. The picker lists contacts; each row has a circle icon on the left. Click 3 rows; each gets a filled checkmark.
3. The Send button label reads "Send 3 contacts".
4. Click Send. The composer chip strip briefly shows 3 contact chips, then they dispatch.
5. A single bubble appears in the conversation captioned "3 contacts" with three stacked rows; each row's "Message on WhatsApp" button works.
6. On the recipient device, the same bubble shows 3 cards (single ContactsArrayMessage).
7. Quit yawac (⌘Q) and relaunch. The 3-card bubble re-renders identically from `PersistedMessage.contactsJSON`.
8. Send a SINGLE contact (1 selection). The bubble is a single-card render — same shape as pre-F104 — confirming back-compat.

Smoke passes when steps 4–8 all behave as described.

- [ ] **Step 6: Commit only if step 2 forced a WAClient signature tweak**

If Task 7 step 2 made you edit `WAClient.sendContacts`, commit that nudge now:

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "F104b: align sendContacts param labels with regenerated gomobile header"
```

Otherwise, skip — there is nothing to commit for the smoke test alone.

---

### Task 8: Ship v0.10.35

**Files:**
- Modify: `project.yml` (version bump)
- Modify: `yawac/Info.plist` (regenerated by xcodegen)
- Modify: `docs/ROADMAP.md` (flip the two pending lines, add Shipped entry)

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: tag `v0.10.35` on a clean main.

- [ ] **Step 1: Bump version in project.yml**

Edit `project.yml` (around line 69):

```yaml
        CFBundleShortVersionString: "0.10.35"
        CFBundleVersion: "118"
```

- [ ] **Step 2: Regen Info.plist**

```bash
xcodegen 2>&1 | tail -3
```

Expected: `Created project at /Users/vadikas/Work/yawac/yawac.xcodeproj`.

Confirm:

```bash
grep -A1 CFBundleShortVersionString yawac/Info.plist
```

Expected: `<string>0.10.35</string>`.

- [ ] **Step 3: Flip pending roadmap bullets**

In `docs/ROADMAP.md`, replace the existing pending pin-drag bullet (around line 34):

```markdown
    - ☐ Pin-drag re-geocode — model has `onPinDrag(to:)` wired but
      the legacy `MapAnnotation` API doesn't expose drag; needs a
      switch to the new `Map { Annotation { ... } }` shape.
```

with:

```markdown
    - ✅ Pin-drag re-geocode — tap-to-move pin via the new
      `MapReader { Map(position:) { Annotation } }` shape landed in
      v0.10.35 as F103.
```

And the existing pending multi-contact bullet (around line 41):

```markdown
    - ☐ Multi-contact share (`ContactsArrayMessage`).
```

with:

```markdown
    - ✅ Multi-contact share (`ContactsArrayMessage`) — picker is
      now a checkbox list; ≥2 selections fire one
      `SendContactsArray` and render as a single multi-card bubble.
      Landed in v0.10.35 as F104.
```

- [ ] **Step 4: Add the Shipped entry**

In `docs/ROADMAP.md`, immediately after the `# Shipped (✅)` heading's intro paragraph and before the existing F101+F102 entry, insert:

```markdown
- ✅ **F103 + F104 — pin-drag re-geocode + multi-contact vCard** (v0.10.35) —
  Two roadmap gaps closed without new protocol surface.
  - **F103.** LocationPickerSheet swaps the legacy
    `Map(coordinateRegion:annotationItems:)` for
    `MapReader { Map(position:) { Annotation } }` and attaches a
    `DragGesture(minimumDistance: 0)` so a click or drag-release
    anywhere on the map calls the already-wired
    `model.onPinDrag(to:)`. The 250ms-debounced reverse-geocode
    updates `resolvedName` / `resolvedAddress` on its own.
  - **F104.** `Client.SendContactsArray` (whatsmeow
    `ContactsArrayMessage` wrap) + inbound classifier arm in the Go
    bridge. New `UIMessage.Body.contacts([ContactPayload])` case
    decodes from the new `contacts_array` JSON field.
    `ContactPickerSheetModel` switches from single-`String?` to
    `Set<String>` selection with `toggle(_:)` + `buildPayloads()`;
    the sheet renders one toggle button per row with a SF Symbol
    checkmark indicator; send label flips to "Send N contacts" at
    N ≥ 2. `ConversationViewModel.sendPendingAttachments` branches
    on `cards.count`: 1 keeps the existing single-contact path
    (back-compat), ≥2 fires `WAClient.sendContacts` once and appends
    one multi-card bubble. `PersistedMessage.contactsJSON` (new
    optional column, lightweight migration) round-trips the array
    across restarts. `MessageRow` renders a "<N> contacts" header
    plus one stacked row per card, each reusing the single-contact
    helper so the per-row "Message on WhatsApp" stays wired.
```

- [ ] **Step 5: Re-pull main, commit, push, tag**

```bash
git pull --rebase origin main 2>&1 | tail -5
```

Expected: `Successfully rebased` or `Current branch main is up to date`.

```bash
git add project.yml yawac/Info.plist docs/ROADMAP.md
git commit -m "release: 0.10.35 — F103 pin-drag re-geocode + F104 multi-contact vCard"
git push origin main 2>&1 | tail -5
```

Expected: `main -> main` push success.

```bash
git tag -a v0.10.35 -m "v0.10.35: F103 pin-drag re-geocode + F104 multi-contact vCard"
git push origin v0.10.35 2>&1 | tail -5
```

Expected: `[new tag] v0.10.35 -> v0.10.35`.

- [ ] **Step 6: Confirm CI release workflow accepted the tag**

```bash
sleep 5
gh run list --workflow=release --limit 3 2>&1 | head -5
```

Expected: a pending or in-progress `release` run referencing `v0.10.35`. The cask bump and Sparkle appcast publish are CI's job.
