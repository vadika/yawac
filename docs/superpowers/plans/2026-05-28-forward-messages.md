# Forward Messages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward one or several selected messages (text + media-by-reference) to a single chosen chat, with a "Forwarded" tag on sent and received bubbles.

**Architecture:** In-conversation selection mode owned by `ConversationViewModel` + a dedicated single-select destination picker sheet. Forwarding rebuilds the message payload (text → `ExtendedTextMessage`; media → the stored media proto reconstructed from `MediaRef`, no re-upload) with `ContextInfo.IsForwarded=true, ForwardingScore=1`, then `SendMessage`. Inbound forwards are detected via `ContextInfo.IsForwarded` and persisted.

**Tech Stack:** Go (whatsmeow bridge via gomobile), Swift/SwiftUI, SwiftData.

**Spec:** `docs/superpowers/specs/2026-05-28-forward-messages-design.md`

---

## File Structure

- `bridge/messages.go` (modify) — `ForwardText`, `ForwardMedia`; `dispatchMessage` sets `is_forwarded`.
- `bridge/jsonmodels.go` (modify) — `JMessage.IsForwarded`.
- `bridge/forward_test.go` (create) — Go error-path tests.
- `yawac/Bridge/WAClient.swift` (modify) — `forwardText` / `forwardMedia` wrappers.
- `yawac/Bridge/JSONModels.swift` (modify) — `BridgeMessage.isForwarded`.
- `yawac/Models/Message.swift` (modify) — `UIMessage.isForwarded` + hydrate from `BridgeMessage`.
- `yawac/Models/PersistedMessage.swift` (modify) — `PersistedMessage.isForwarded`.
- `yawac/ViewModels/ConversationViewModel.swift` (modify) — selection state, `canForward`, `executeForward`, persist + hydrate `isForwarded`.
- `yawac/Views/MessageContextMenu.swift` (modify) — enable Forward.
- `yawac/Views/MessageRow.swift` (modify) — selection checkbox + "Forwarded" tag.
- `yawac/Views/ConversationView.swift` (modify) — selection wiring + bottom bar + picker sheet.
- `yawac/Views/ForwardPickerView.swift` (create) — destination picker.
- `yawacTests/CVMForwardTests.swift` (create) — selection/canForward tests.

New Swift files require `xcodegen generate` (repo uses XcodeGen; `.pbxproj` and `yawac.xcodeproj` are gitignored — do NOT `git add` them).

---

## Task 1: Bridge — ForwardText, ForwardMedia, inbound is_forwarded

**Files:**
- Modify: `bridge/messages.go`, `bridge/jsonmodels.go`
- Test: `bridge/forward_test.go`

- [ ] **Step 1: Write the failing test**

Create `bridge/forward_test.go`:

```go
package bridge

import (
	"strings"
	"testing"
)

func TestForwardTextBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/fw.db")
	defer c.Close()
	_, err := c.ForwardText("abc:def@x", "hi")
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}

func TestForwardMediaBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/fw.db")
	defer c.Close()
	_, err := c.ForwardMedia("abc:def@x", `{"kind":"image"}`, "", "")
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}

func TestForwardMediaBadRefJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/fw.db")
	defer c.Close()
	_, err := c.ForwardMedia("12345@s.whatsapp.net", "not json", "", "")
	if err == nil || !strings.Contains(err.Error(), "parse ref") {
		t.Fatalf("got %v, want parse ref error", err)
	}
}

func TestForwardMediaUnknownKind(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/fw.db")
	defer c.Close()
	_, err := c.ForwardMedia("12345@s.whatsapp.net", `{"kind":"banana"}`, "", "")
	if err == nil || !strings.Contains(err.Error(), "unsupported kind") {
		t.Fatalf("got %v, want unsupported kind error", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vadikas/Work/yawac/bridge && go test -run TestForward ./...`
Expected: FAIL — `c.ForwardText undefined` / `c.ForwardMedia undefined`.

- [ ] **Step 3: Add the JSON field**

In `bridge/jsonmodels.go`, add `IsForwarded` to `JMessage` (after the `Quoted` field):

```go
type JMessage struct {
	ID             string   `json:"id"`
	ChatJID        string   `json:"chat_jid"`
	SenderJID      string   `json:"sender_jid"`
	SenderPushName string   `json:"sender_push_name,omitempty"`
	FromMe         bool     `json:"from_me"`
	Timestamp      int64    `json:"timestamp"`
	Kind           string   `json:"kind"`
	Text           string   `json:"text,omitempty"`
	Media          *JMedia  `json:"media,omitempty"`
	Poll           *JPoll   `json:"poll,omitempty"`
	Quoted         *JQuoted `json:"quoted,omitempty"`
	IsForwarded    bool     `json:"is_forwarded,omitempty"`
}
```

(Replace the existing `JMessage` struct with this; the only change is the added `IsForwarded` line.)

- [ ] **Step 4: Populate is_forwarded on inbound + add forward senders**

In `bridge/messages.go`, in `dispatchMessage`, find where `jm` is built and the
quoted block sets `jm.Quoted`. Right after that quoted `if` block (before the
media `if` chain), add:

```go
	if ctx := contextInfoFromMessage(evt.Message); ctx != nil && ctx.GetIsForwarded() {
		jm.IsForwarded = true
	}
```

Then add the two forward senders (place them next to `SendText`):

```go
// ForwardText re-sends text to another chat tagged as forwarded. Plain
// Conversation carries no ContextInfo, so forwards use ExtendedTextMessage
// to carry the IsForwarded flag.
func (c *Client) ForwardText(chatJID, text string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
	}
	msg := &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text:        proto.String(text),
		ContextInfo: &waE2E.ContextInfo{IsForwarded: proto.Bool(true), ForwardingScore: proto.Uint32(1)},
	}}
	resp, err := c.wa.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return "", fmt.Errorf("send forward text: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// ForwardMedia re-sends already-uploaded media to another chat by
// reconstructing the media proto from the stored MediaRef — no
// re-download/re-upload. WhatsApp media is content-addressed and
// encrypted by mediaKey, so the same CDN blob is reusable across chats.
// `kind` is taken from the ref. `fileName` applies to documents only.
func (c *Client) ForwardMedia(chatJID, refJSON, caption, fileName string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
	}
	var ref MediaRef
	if err := json.Unmarshal([]byte(refJSON), &ref); err != nil {
		return "", fmt.Errorf("parse ref: %w", err)
	}
	fwd := &waE2E.ContextInfo{IsForwarded: proto.Bool(true), ForwardingScore: proto.Uint32(1)}
	var msg *waE2E.Message
	switch ref.Kind {
	case "image":
		msg = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
			Caption: proto.String(caption), URL: proto.String(ref.URL),
			DirectPath: proto.String(ref.DirectPath), MediaKey: ref.MediaKey,
			Mimetype: proto.String(ref.Mimetype), FileEncSHA256: ref.FileEncSHA256,
			FileSHA256: ref.FileSHA256, FileLength: proto.Uint64(ref.FileLength),
			ContextInfo: fwd,
		}}
	case "video":
		msg = &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
			Caption: proto.String(caption), URL: proto.String(ref.URL),
			DirectPath: proto.String(ref.DirectPath), MediaKey: ref.MediaKey,
			Mimetype: proto.String(ref.Mimetype), FileEncSHA256: ref.FileEncSHA256,
			FileSHA256: ref.FileSHA256, FileLength: proto.Uint64(ref.FileLength),
			ContextInfo: fwd,
		}}
	case "audio":
		msg = &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
			URL: proto.String(ref.URL), DirectPath: proto.String(ref.DirectPath),
			MediaKey: ref.MediaKey, Mimetype: proto.String(ref.Mimetype),
			FileEncSHA256: ref.FileEncSHA256, FileSHA256: ref.FileSHA256,
			FileLength: proto.Uint64(ref.FileLength), ContextInfo: fwd,
		}}
	case "document":
		msg = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
			Caption: proto.String(caption), FileName: proto.String(fileName),
			URL: proto.String(ref.URL), DirectPath: proto.String(ref.DirectPath),
			MediaKey: ref.MediaKey, Mimetype: proto.String(ref.Mimetype),
			FileEncSHA256: ref.FileEncSHA256, FileSHA256: ref.FileSHA256,
			FileLength: proto.Uint64(ref.FileLength), ContextInfo: fwd,
		}}
	case "sticker":
		msg = &waE2E.Message{StickerMessage: &waE2E.StickerMessage{
			URL: proto.String(ref.URL), DirectPath: proto.String(ref.DirectPath),
			MediaKey: ref.MediaKey, Mimetype: proto.String(ref.Mimetype),
			FileEncSHA256: ref.FileEncSHA256, FileSHA256: ref.FileSHA256,
			FileLength: proto.Uint64(ref.FileLength), ContextInfo: fwd,
		}}
	default:
		return "", fmt.Errorf("unsupported kind: %q", ref.Kind)
	}
	resp, err := c.wa.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return "", fmt.Errorf("send forward media: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}
```

`messages.go` already imports `context`, `encoding/json`, `errors`, `fmt`,
`waE2E`, `types`, and `google.golang.org/protobuf/proto`. No new imports.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/vadikas/Work/yawac/bridge && go test -run TestForward ./... && go build ./... && go test -short ./...`
Expected: forward tests PASS; build success; full short suite passes.

- [ ] **Step 6: Commit**

```bash
git add bridge/messages.go bridge/jsonmodels.go bridge/forward_test.go
git commit -m "bridge: ForwardText + ForwardMedia (by reference) + inbound is_forwarded"
```

---

## Task 2: Data model — isForwarded fields

**Files:**
- Modify: `yawac/Models/PersistedMessage.swift`, `yawac/Models/Message.swift`

No unit test (plain stored properties); covered by compile + later tasks.

- [ ] **Step 1: Add the SwiftData field**

In `yawac/Models/PersistedMessage.swift`, in `PersistedMessage`, after the
`var pinnedAt: Date? = nil` line, add:

```swift
    // Set when the message carried ContextInfo.IsForwarded (inbound) or we
    // sent it as a forward (outbound). Drives the "Forwarded" tag.
    var isForwarded: Bool = false
```

In the same file, add an init parameter. Change the init signature line
`         pinnedAt: Date? = nil) {` to:

```swift
         pinnedAt: Date? = nil,
         isForwarded: Bool = false) {
```

And after the `self.pinnedAt = pinnedAt` assignment add:

```swift
        self.isForwarded = isForwarded
```

- [ ] **Step 2: Add the UIMessage field + hydrate from bridge**

In `yawac/Models/Message.swift`, in `struct UIMessage`, after
`var pinnedAt: Date? = nil` add:

```swift
    var isForwarded: Bool = false
```

In the same file, in the `init(_ b: BridgeMessage)` initializer, after the
quoted-fields block (the `if let q = b.quoted { ... }`) add:

```swift
        self.isForwarded = b.isForwarded ?? false
```

- [ ] **Step 3: Verify it compiles after Task 3's bridge field exists**

`BridgeMessage.isForwarded` is added in Task 3 — this file won't compile until
then. That's expected; do not build in isolation. Proceed to Task 3, which
includes the build.

- [ ] **Step 4: Commit**

```bash
git add yawac/Models/PersistedMessage.swift yawac/Models/Message.swift
git commit -m "model: isForwarded on PersistedMessage + UIMessage"
```

---

## Task 3: WAClient wrappers + BridgeMessage decode + framework rebuild

**Files:**
- Modify: `yawac/Bridge/JSONModels.swift`, `yawac/Bridge/WAClient.swift`

- [ ] **Step 1: Rebuild the bridge framework (exposes ForwardText/ForwardMedia)**

Run: `cd /Users/vadikas/Work/yawac && ./scripts/build-xcframework.sh`
Expected: `Built: build/Bridge.xcframework`.

- [ ] **Step 2: Decode is_forwarded in BridgeMessage**

In `yawac/Bridge/JSONModels.swift`, in `struct BridgeMessage`, after
`let quoted: Quoted?` add:

```swift
    let isForwarded: Bool?
```

And in its `CodingKeys`, change the line
`        case timestamp, kind, text, media, poll, quoted` to:

```swift
        case timestamp, kind, text, media, poll, quoted
        case isForwarded = "is_forwarded"
```

- [ ] **Step 3: Add the WAClient forward wrappers**

In `yawac/Bridge/WAClient.swift`, after the `sendTextReply(...)` method, add:

```swift
    func forwardText(_ chatJID: String, text: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.forwardText(chatJID, text: text, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }

    func forwardMedia(_ chatJID: String, refJSON: String,
                      caption: String, fileName: String) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.forwardMedia(chatJID, refJSON: refJSON,
                                   caption: caption, fileName: fileName, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }
```

Note: gomobile maps `ForwardText(chatJID, text string)` → Swift
`forwardText(_:text:error:)` and `ForwardMedia(chatJID, refJSON, caption, fileName string)`
→ `forwardMedia(_:refJSON:caption:fileName:error:)`.

- [ ] **Step 4: Regenerate + build**

Run: `cd /Users/vadikas/Work/yawac && xcodegen generate && xcodebuild -scheme yawac -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD '`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/JSONModels.swift yawac/Bridge/WAClient.swift
git commit -m "WAClient: forwardText/forwardMedia + decode is_forwarded"
```

---

## Task 4: ConversationViewModel — selection + executeForward

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`
- Test: `yawacTests/CVMForwardTests.swift`

- [ ] **Step 1: Write the failing test**

Create `yawacTests/CVMForwardTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class CVMForwardTests: XCTestCase {

    private func makeCVM() throws -> ConversationViewModel {
        let dir = NSTemporaryDirectory().appending("yawac-fwd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let client = try WAClient(dbPath: dir.appending("/state.db"))
        return ConversationViewModel(chatJID: "1@s.whatsapp.net", client: client)
    }

    private func text(_ id: String) -> UIMessage {
        UIMessage(id: id, chatJID: "1@s.whatsapp.net", senderJID: "1@s.whatsapp.net",
                  fromMe: false, timestamp: Date(), body: .text("hi"))
    }

    private func mediaNoRefNoCaption(_ id: String) -> UIMessage {
        UIMessage(id: id, chatJID: "1@s.whatsapp.net", senderJID: "1@s.whatsapp.net",
                  fromMe: false, timestamp: Date(),
                  body: .media(kind: "image", caption: nil, fileName: nil, localPath: nil))
    }

    private func systemMsg(_ id: String) -> UIMessage {
        UIMessage(id: id, chatJID: "1@s.whatsapp.net", senderJID: "system",
                  fromMe: false, timestamp: Date(), body: .system("x"))
    }

    func testCanForwardText() throws {
        let vm = try makeCVM()
        XCTAssertTrue(vm.canForward(text("A")))
    }

    func testCannotForwardSystem() throws {
        let vm = try makeCVM()
        XCTAssertFalse(vm.canForward(systemMsg("A")))
    }

    func testCannotForwardMediaWithoutRefOrCaption() throws {
        let vm = try makeCVM()
        // No PersistedMessage row exists for this id → no ref; no caption.
        XCTAssertFalse(vm.canForward(mediaNoRefNoCaption("A")))
    }

    func testBeginForwardEntersModeAndPreselects() throws {
        let vm = try makeCVM()
        vm.beginForward(text("A"))
        XCTAssertTrue(vm.forwardSelecting)
        XCTAssertEqual(vm.forwardSelection, ["A"])
    }

    func testBeginForwardSkipsPreselectWhenNotForwardable() throws {
        let vm = try makeCVM()
        vm.beginForward(systemMsg("A"))
        XCTAssertTrue(vm.forwardSelecting)
        XCTAssertTrue(vm.forwardSelection.isEmpty)
    }

    func testToggleAddsAndRemoves() throws {
        let vm = try makeCVM()
        vm.beginForward(text("A"))
        vm.messages = [text("A"), text("B")]
        vm.toggleForward("B")
        XCTAssertEqual(vm.forwardSelection, ["A", "B"])
        vm.toggleForward("A")
        XCTAssertEqual(vm.forwardSelection, ["B"])
    }

    func testCancelForwardClears() throws {
        let vm = try makeCVM()
        vm.beginForward(text("A"))
        vm.cancelForward()
        XCTAssertFalse(vm.forwardSelecting)
        XCTAssertTrue(vm.forwardSelection.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' -only-testing:yawacTests/CVMForwardTests 2>&1 | grep -E 'error:|Cannot find|\*\* TEST'`
Expected: FAIL — `value of type 'ConversationViewModel' has no member 'forwardSelecting'`.

- [ ] **Step 3: Add selection state, canForward, begin/toggle/cancel**

In `yawac/ViewModels/ConversationViewModel.swift`, after the
`var highlightedID: String?` property add:

```swift
    /// Forward selection mode. `forwardSelection` holds the chosen message ids.
    var forwardSelecting = false
    var forwardSelection: Set<String> = []
```

Then add these methods (place them near `startReply`/`startEdit`):

```swift
    /// Whether a message can be forwarded: text always; media only if we can
    /// rebuild it (a stored media ref) or it has a caption to forward as text;
    /// poll / system / revoked / locally-deleted never.
    func canForward(_ m: UIMessage) -> Bool {
        if m.revokedAt != nil || m.locallyDeleted { return false }
        switch m.body {
        case .text:
            return true
        case .media(_, let caption, _, _):
            if let c = caption, !c.isEmpty { return true }
            return mediaRefJSON(for: m.id) != nil
        case .poll, .system:
            return false
        }
    }

    func beginForward(_ m: UIMessage) {
        forwardSelecting = true
        if canForward(m) { forwardSelection.insert(m.id) }
    }

    func toggleForward(_ id: String) {
        if forwardSelection.contains(id) {
            forwardSelection.remove(id)
        } else if let m = messages.first(where: { $0.id == id }), canForward(m) {
            forwardSelection.insert(id)
        }
    }

    func cancelForward() {
        forwardSelecting = false
        forwardSelection.removeAll()
    }

    /// Reads the persisted media ref JSON for a message id, if any.
    private func mediaRefJSON(for id: String) -> String? {
        guard let context else { return nil }
        let d = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(d).first)?.mediaRefJSON
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' -only-testing:yawacTests/CVMForwardTests 2>&1 | grep -E 'error:|\*\* TEST'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Add executeForward + hydrate/persist isForwarded**

In `yawac/ViewModels/ConversationViewModel.swift`, add after `cancelForward()`:

```swift
    /// Forward the selected messages to `chatJID` in chronological order.
    func executeForward(to chatJID: String) async {
        let ids = forwardSelection
        let ordered = messages.filter { ids.contains($0.id) }
        for m in ordered {
            do {
                let result: BridgeSendResult
                switch m.body {
                case .text(let t):
                    result = try client.forwardText(chatJID, text: t)
                case .media(let kind, let caption, let fileName, _):
                    if let ref = mediaRefJSON(for: m.id) {
                        result = try client.forwardMedia(chatJID, refJSON: ref,
                                                          caption: caption ?? "",
                                                          fileName: fileName ?? "")
                    } else if let c = caption, !c.isEmpty {
                        result = try client.forwardText(chatJID, text: c)
                    } else {
                        continue
                    }
                    _ = kind
                case .poll, .system:
                    continue
                }
                persistForwarded(messageID: result.messageID, chatJID: chatJID,
                                 timestamp: result.timestamp, source: m)
            } catch {
                messages.append(UIMessage(
                    id: UUID().uuidString, chatJID: self.chatJID, senderJID: "system",
                    fromMe: false, timestamp: .now,
                    body: .system("forward failed: \(error.localizedDescription)")))
            }
        }
        cancelForward()
    }

    /// Persist a forwarded outgoing message under the destination chat so it
    /// shows there (with the Forwarded tag) on switch / restart. Mirrors the
    /// kind/text/media of the source message.
    private func persistForwarded(messageID: String, chatJID: String,
                                  timestamp: Int64, source: UIMessage) {
        guard let context else { return }
        let when = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let row: PersistedMessage
        switch source.body {
        case .text(let t):
            row = PersistedMessage(id: messageID, chatJID: chatJID,
                                   senderJID: client.ownJID, fromMe: true,
                                   timestamp: when, kind: "text", text: t,
                                   isForwarded: true)
        case .media(let kind, let caption, let fileName, _):
            let ref = mediaRefJSON(for: source.id)
            if ref == nil, let c = caption, !c.isEmpty {
                row = PersistedMessage(id: messageID, chatJID: chatJID,
                                       senderJID: client.ownJID, fromMe: true,
                                       timestamp: when, kind: "text", text: c,
                                       isForwarded: true)
            } else {
                row = PersistedMessage(id: messageID, chatJID: chatJID,
                                       senderJID: client.ownJID, fromMe: true,
                                       timestamp: when, kind: kind,
                                       mediaCaption: caption, mediaFileName: fileName,
                                       mediaRefJSON: ref, isForwarded: true)
            }
        case .poll, .system:
            return
        }
        context.insert(row)
        try? context.save()
    }
```

Then hydrate `isForwarded` on history load. In this same file, find the TWO
spots that set `m.pinnedAt = p.pinnedAt` (the in-memory hydration in
`jumpToQuoted`'s injection path and in `loadHistory`'s mapping). After each
`m.pinnedAt = p.pinnedAt` line add:

```swift
        m.isForwarded = p.isForwarded
```

(Match the indentation of the surrounding `m.pinnedAt = p.pinnedAt` line at each site.)

Also set it when persisting inbound messages. In `persist(_ m: BridgeMessage)`,
in the `PersistedMessage(...)` constructor call for the new row, add the
argument `isForwarded: m.isForwarded` (alongside the other fields).

- [ ] **Step 6: Run forward tests + build**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' -only-testing:yawacTests/CVMForwardTests 2>&1 | grep -E 'error:|\*\* TEST'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift yawacTests/CVMForwardTests.swift
git commit -m "CVM: forward selection state + executeForward + isForwarded hydration"
```

---

## Task 5: MessageRow selection UI + Forwarded tag + enable menu

**Files:**
- Modify: `yawac/Views/MessageRow.swift`, `yawac/Views/MessageContextMenu.swift`

Visual/manual verification (SwiftUI views). No unit test.

- [ ] **Step 1: Add selection params to MessageRow**

In `yawac/Views/MessageRow.swift`, add stored properties (after `let onStar` /
`let onPin` group, before `let onJumpToQuoted`):

```swift
    let selecting: Bool
    let selected: Bool
    let selectable: Bool
    let onToggleSelect: (() -> Void)?
```

Add matching init params (after the `onPin:` param, before `onJumpToQuoted:`):

```swift
         selecting: Bool = false,
         selected: Bool = false,
         selectable: Bool = true,
         onToggleSelect: (() -> Void)? = nil,
```

And matching assignments (after `self.onPin = onPin`):

```swift
        self.selecting = selecting
        self.selected = selected
        self.selectable = selectable
        self.onToggleSelect = onToggleSelect
```

- [ ] **Step 2: Render checkbox + dim + intercept taps in selection mode**

In `yawac/Views/MessageRow.swift`, wrap the row body. Find the outermost
`HStack {` of `var body` (the one starting with
`if message.fromMe { Spacer(minLength: 60) }`). Replace the line
`var body: some View {` and its opening `HStack {` with a leading checkbox row:

```swift
    var body: some View {
        HStack(spacing: 8) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Theme.accent : Theme.textFaint)
                    .opacity(selectable ? 1 : 0.3)
            }
            rowContent
        }
        .contentShape(Rectangle())
        .opacity(selecting && !selectable ? 0.4 : 1)
        .onTapGesture {
            if selecting, selectable { onToggleSelect?() }
        }
        .allowsHitTesting(true)
    }

    private var rowContent: some View {
        HStack {
```

The original `var body`'s content (from `if message.fromMe { Spacer... }`
through its closing) now lives under `rowContent`. Keep the original closing
brace of that inner `HStack`/content as the close of `rowContent`. The existing
`.environment(\.openURL, ...)` modifier chain that was attached to the old body
HStack stays attached to the inner content inside `rowContent`.

Note: in `selecting` mode the row-level `.onTapGesture` toggles selection; the
inner bubble's own gestures (double-click, right-click catcher, links) still
exist but are visually superseded — acceptable for v1 since the whole row also
carries the toggle tap. If a gesture conflict surfaces in manual testing, gate
the bubble's `RightClickCatcher`/double-tap with `if !selecting`.

- [ ] **Step 3: Add the Forwarded tag**

In `yawac/Views/MessageRow.swift`, in `bodyView`, in the `else` branch (the
non-revoked, non-deleted branch that renders `quotedStrip` + `existingBodyContent`),
add a forwarded line as the first child of that inner `VStack`:

```swift
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 4) {
                if message.isForwarded {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.system(size: 10))
                        Text("Forwarded")
                            .font(Theme.ui(11))
                            .italic()
                    }
                    .foregroundStyle(Theme.textFaint)
                }
                if message.quotedMessageID != nil {
                    quotedStrip
                }
                existingBodyContent
            }
```

(This replaces the existing inner `VStack { if quoted… ; existingBodyContent }`
— the only additions are the `if message.isForwarded { … }` block.)

- [ ] **Step 4: Enable the Forward menu item**

In `yawac/Views/MessageContextMenu.swift`, change the Forward `MenuRow` (the one
with `disabled: true`) to:

```swift
                MenuRow(icon: "arrowshape.turn.up.right",
                        label: "Forward",
                        action: { dismiss(); onForward() })
```

- [ ] **Step 5: Verify build**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild -scheme yawac -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD '`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/MessageRow.swift yawac/Views/MessageContextMenu.swift
git commit -m "MessageRow: selection checkbox + Forwarded tag; enable Forward menu"
```

---

## Task 6: ConversationView — selection wiring + bottom bar + picker sheet

**Files:**
- Modify: `yawac/Views/ConversationView.swift`

- [ ] **Step 1: Add picker presentation state**

In `yawac/Views/ConversationView.swift`, add near the other `@State`
declarations (e.g. after `@State private var atBottom = true`):

```swift
    @State private var showForwardPicker = false
```

- [ ] **Step 2: Pass selection params into MessageRow**

In `yawac/Views/ConversationView.swift`, in the `MessageRow(...)` call, add these
arguments (right after the `onPin:` argument, before `onJumpToQuoted:`):

```swift
                                            selecting: vm.forwardSelecting,
                                            selected: vm.forwardSelection.contains(msg.id),
                                            selectable: vm.canForward(msg),
                                            onToggleSelect: { vm.toggleForward(msg.id) },
```

- [ ] **Step 3: Swap composer for the forward bar in selection mode**

In `yawac/Views/ConversationView.swift`, find `ComposerView(vm: vm)` (near the
bottom of the main `VStack`). Replace that single line with:

```swift
                    if vm.forwardSelecting {
                        forwardBar
                    } else {
                        ComposerView(vm: vm)
                    }
```

Then add the `forwardBar` view + the sheet. Add this computed property to the
struct (near `headerBar`):

```swift
    @ViewBuilder
    private var forwardBar: some View {
        if let vm {
            HStack(spacing: 14) {
                Button("Cancel") { vm.cancelForward() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text("\(vm.forwardSelection.count) selected")
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Forward") { showForwardPicker = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(vm.forwardSelection.isEmpty ? Theme.textFaint : Theme.accent)
                    .disabled(vm.forwardSelection.isEmpty)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(Theme.bg)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }
```

Attach the sheet to the main content. On the outer `Group { … }` of `body`
(the one that already has `.navigationTitle(...)` etc.), add:

```swift
        .sheet(isPresented: $showForwardPicker) {
            if let vm {
                ForwardPickerView { jid in
                    showForwardPicker = false
                    Task { await vm.executeForward(to: jid) }
                }
                .environment(session)
            }
        }
```

- [ ] **Step 4: Reset selection on chat switch**

In `yawac/Views/ConversationView.swift`, in the `.task(id: chatJID)` block, near
the top where `didInitialScroll = false` etc. reset, add (guard the optional):

```swift
            self.vm?.cancelForward()
```

Place it after the existing `lastSeenCount = 0` reset line. (At that point `vm`
may be the previous chat's VM; cancelling its forward mode is harmless and the
new VM starts clean.)

- [ ] **Step 5: Verify build (will fail until Task 7 creates ForwardPickerView)**

ForwardPickerView is created in Task 7. Skip building in isolation; build at the
end of Task 7.

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/ConversationView.swift
git commit -m "ConversationView: forward selection bar + picker sheet wiring"
```

---

## Task 7: ForwardPickerView

**Files:**
- Create: `yawac/Views/ForwardPickerView.swift`

- [ ] **Step 1: Create the picker**

Create `yawac/Views/ForwardPickerView.swift`:

```swift
import SwiftUI

/// Single-select destination picker for forwarding. A search field over the
/// known chats (filtered locally) + a flat list; tapping a chat calls
/// `onPick(jid)`. Intentionally flat — no scope tabs / community nesting.
struct ForwardPickerView: View {
    let onPick: (String) -> Void
    @Environment(SessionViewModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var chats: [Chat] {
        let all = session.chatList?.chats ?? []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Forward to…")
                    .font(Theme.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textFaint)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(13))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(chats) { chat in
                        Button {
                            onPick(chat.jid)
                        } label: {
                            HStack(spacing: 11) {
                                AvatarView(jid: chat.jid, name: chat.name, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chat.name).font(Theme.ui(14, weight: .medium))
                                        .foregroundStyle(Theme.text).lineLimit(1)
                                    if !chat.lastMessage.isEmpty {
                                        Text(chat.lastMessage).font(Theme.ui(12))
                                            .foregroundStyle(Theme.textMuted).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .frame(width: 360, height: 480)
        .background(Theme.sidebarBg)
    }
}
```

- [ ] **Step 2: Regenerate + build**

Run: `cd /Users/vadikas/Work/yawac && xcodegen generate && xcodebuild -scheme yawac -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD '`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/ForwardPickerView.swift
git commit -m "ForwardPickerView: single-select destination picker"
```

---

## Task 8: Full test + manual verification

**Files:** none (verification).

- [ ] **Step 1: Full build + test suite**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild test -scheme yawac -destination 'platform=macOS' 2>&1 | grep -E 'Failing tests:|\*\* TEST|\*\* BUILD'`
Expected: `** TEST SUCCEEDED **`. (If a timing-sensitive test flakes under full-suite load, re-run that suite in isolation to confirm it's not a logic regression.)

- [ ] **Step 2: Launch**

Run: `pkill -f 'yawac.app/Contents/MacOS/yawac' 2>/dev/null; sleep 1; open /Users/vadikas/Library/Developer/Xcode/DerivedData/yawac-*/Build/Products/Debug/yawac.app`

- [ ] **Step 3: Single text forward**

Right-click a text message → Forward → (selection mode, 1 selected) → Forward →
pick a chat. Expected: message appears in that chat with an italic "Forwarded"
tag; the phone shows it forwarded too.

- [ ] **Step 4: Single image forward (by reference)**

Right-click an image message → Forward → pick a chat. Expected: image appears in
the destination without a re-upload delay (sent near-instantly); renders on the
phone. "Forwarded" tag present.

- [ ] **Step 5: Multi-select forward**

Right-click one message → Forward → tap 2 more rows → "3 selected" → Forward →
pick a chat. Expected: all three appear in destination in chronological order,
each tagged Forwarded.

- [ ] **Step 6: Non-forwardable handling**

Enter selection mode; confirm a system message row is dimmed and won't toggle;
confirm an image with no caption whose media never downloaded is dimmed.

- [ ] **Step 7: Switch-away cancels**

Enter selection mode, switch to another chat, switch back. Expected: selection
mode is cleared (composer shown, no checkboxes).

- [ ] **Step 8: Final commit (only if a fix was needed)**

Otherwise nothing to commit — feature complete.

---

## Self-Review Notes

- **Spec coverage:** single+multi selection (Task 4 begin/toggle + Task 5/6 UI) ✓;
  single destination picker (Task 7) ✓; text + media-by-reference forward
  (Task 1 bridge, Task 4 exec) ✓; media-no-ref→caption-as-text fallback
  (Task 4 `canForward`/`executeForward`) ✓; non-forwardable disable (Task 4
  `canForward`, Task 5 dim) ✓; Forwarded tag persisted + rendered on sent +
  received (Task 1 inbound, Task 2 fields, Task 4 hydrate/persist, Task 5 tag) ✓;
  ForwardingScore=1, no re-upload (Task 1) ✓; reset on chat switch (Task 6) ✓.
- **Type consistency:** `forwardSelecting`/`forwardSelection`/`canForward(_:)`/
  `beginForward(_:)`/`toggleForward(_:)`/`cancelForward()`/`executeForward(to:)`/
  `mediaRefJSON(for:)`/`persistForwarded(...)` in CVM; `forwardText(_:text:)` /
  `forwardMedia(_:refJSON:caption:fileName:)` in WAClient ↔ Go `ForwardText` /
  `ForwardMedia(chatJID, refJSON, caption, fileName)`; `is_forwarded` JSON ↔
  `BridgeMessage.isForwarded` ↔ `UIMessage.isForwarded` ↔
  `PersistedMessage.isForwarded`; MessageRow `selecting/selected/selectable/
  onToggleSelect`. Names consistent across tasks.
- **Placeholders:** none — full code in every code step; commands have expected output.
- **Note:** `.xcodeproj` / `build/` are gitignored — never `git add` them
  (matches the existing repo workflow).
