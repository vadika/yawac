# @-Mention Autocomplete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Typing `@` in the composer opens a strip of group participants (or single recipient in 1:1) with ↑/↓/Tab/Enter/Esc keys; picking inserts `@DisplayName` plain-text and tracks the JID so the outbound message ships with proper `ContextInfo.MentionedJID` encoding. A synthetic `@everyone` row pings every group participant.

**Architecture:** New `MentionPickerViewModel` owns the picker state; new `MentionStrip` view renders inline above the composer; `ConversationViewModel` holds an `activeMentions: [ActiveMention]` list and runs the substitution loop in `sendDraft()` / `saveEdit()`. The Go bridge `SendText` / `SendTextReply` / `EditText` extend to accept `mentionedJIDs []string` and build an `ExtendedTextMessage{ContextInfo}` instead of plain `Conversation` when non-empty. Swift wrappers default the new parameter so non-mention callers stay source-compatible.

**Tech Stack:** Swift 5.10, SwiftUI on macOS 14+, AppKit `@FocusState` + `.onKeyPress`, Go 1.22 with whatsmeow, gomobile-generated `Bridge.xcframework`.

---

## File Map

**New files:**
- `yawac/ViewModels/MentionPickerViewModel.swift` — picker state + filtering + commit/cancel.
- `yawac/Views/MentionStrip.swift` — slim inline list.
- `yawacTests/MentionPickerViewModelTests.swift`
- `yawacTests/MentionEncodingTests.swift`

**Modified files:**
- `bridge/messages.go` — `SendText`, `SendTextReply` accept `mentionedJIDs []string`; build `ExtendedTextMessage` when non-empty.
- `bridge/edit_revoke.go` — `EditText` same treatment.
- `yawac/Bridge/WAClient.swift` — `sendText`, `sendTextReply`, `editText` Swift wrappers gain defaulted `mentionedJIDs: [String] = []`.
- `yawac/ViewModels/ConversationViewModel.swift`:
  - `struct ActiveMention { let displayName: String; let jid: String }` (sentinel jid `"*all*"` = everyone).
  - `var activeMentions: [ActiveMention] = []`.
  - `var groupParticipants: [BridgeParticipantModel]? = nil` + lazy fetcher `loadGroupParticipantsIfNeeded()`.
  - `sendDraft()`: substitute `@<displayName>` → `@<phone>`, collect `mentionedJIDs`, pass through `client.sendText` / `client.sendTextReply`.
  - `saveEdit(_:)`: same substitution; pass through `client.editText`.
- `yawac/Views/ComposerView.swift`:
  - Construct `MentionPickerViewModel` once (`@State`) wired to `vm`.
  - Slot `MentionStrip(picker:)` above `inputRow` in the existing composer `VStack`.
  - On TextField `onChange(of: vm.draft)`: `picker.update(text: vm.draft, vm: vm, isGroup: …)`.
  - Extend `.onKeyPress(.tab / .return / .upArrow / .downArrow / .escape)` to route to picker when `picker.isActive`.
- `yawac/Bridge/JSONModels.swift` — already exposes `BridgeParticipantModel`, no change.

Order chosen: bridge first (everything else assumes the extended wire). Then VM state + tests. Then UI. Then encoding tests + full gates.

---

## Task 1: Bridge — extend `SendText` / `SendTextReply` / `EditText` with `mentionedJIDs`

**Files:**
- Modify: `bridge/messages.go` (`SendText` ~line 153, `SendTextReply` ~line 710).
- Modify: `bridge/edit_revoke.go` (`EditText` line 19).
- Test: `bridge/messages_test.go` (append two table-driven cases verifying the new signature compiles + the empty-slice path stays plain `Conversation`).

The new parameter is a JSON-encoded string array (gomobile doesn't expose `[]string` cleanly across the Swift boundary; the pattern in this project is to pass JSON when arrays are needed — see existing `MarkRead` for the pattern).

Actually, looking at gomobile bindings: gomobile **does** support `[]string` via reflection from Go method signatures. The existing `MarkRead(idStrings []string, ...)` signature confirms it. Use `[]string` directly.

- [ ] **Step 1: Extend `SendText` signature**

Replace `bridge/messages.go` `SendText` (lines 152–174) with:

```go
// SendText sends a plain-text message. When mentionedJIDs is non-empty,
// the message is sent as an ExtendedTextMessage with a ContextInfo whose
// MentionedJID array carries the pinged JIDs (matches WhatsApp's wire
// format for @mentions). Returns JSON of JSendResult.
func (c *Client) SendText(chatJID, body string, mentionedJIDs []string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	if jid.User == "" || jid.Server == "" {
		return "", fmt.Errorf("parse jid: %q is not a valid jid", chatJID)
	}
	var msg *waE2E.Message
	if len(mentionedJIDs) == 0 {
		msg = &waE2E.Message{Conversation: proto.String(body)}
	} else {
		msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text:        proto.String(body),
			ContextInfo: &waE2E.ContextInfo{MentionedJID: mentionedJIDs},
		}}
	}
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out, _ := json.Marshal(JSendResult{
		MessageID: resp.ID,
		Timestamp: resp.Timestamp.Unix(),
	})
	return string(out), nil
}
```

- [ ] **Step 2: Extend `SendTextReply` signature**

In `bridge/messages.go` `SendTextReply` (the function starting around line 710), add `mentionedJIDs []string` as the final parameter and set it on the existing `ContextInfo`:

```go
func (c *Client) SendTextReply(
	chatJID, body, quotedID, quotedSenderJID string,
	quotedFromMe bool, quotedKind, quotedSnippet string,
	mentionedJIDs []string,
) (string, error) {
```

Then in the existing `ctx := &waE2E.ContextInfo{...}` block (lines 736–740), add `MentionedJID: mentionedJIDs` (gomobile-safe — `nil` and empty slice are equivalent on the wire):

```go
	ctx := &waE2E.ContextInfo{
		StanzaID:      proto.String(quotedID),
		Participant:   proto.String(senderForCtx),
		QuotedMessage: stubQuoted(quotedKind, quotedSnippet),
		MentionedJID:  mentionedJIDs,
	}
```

- [ ] **Step 3: Extend `EditText` signature**

In `bridge/edit_revoke.go` `EditText` (lines 19–41), replace with:

```go
func (c *Client) EditText(chatJID, msgID, newBody string, mentionedJIDs []string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	if newBody == "" {
		return "", errors.New("empty body")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
	}
	var newMsg *waE2E.Message
	if len(mentionedJIDs) == 0 {
		newMsg = &waE2E.Message{Conversation: proto.String(newBody)}
	} else {
		newMsg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text:        proto.String(newBody),
			ContextInfo: &waE2E.ContextInfo{MentionedJID: mentionedJIDs},
		}}
	}
	edit := c.wa.BuildEdit(chat, types.MessageID(msgID), newMsg)
	resp, err := c.wa.SendMessage(context.Background(), chat, edit)
	if err != nil {
		return "", fmt.Errorf("send edit: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}
```

- [ ] **Step 4: Update `bridge/messages_test.go`**

The existing tests pass to `SendText(jid, body)`. Update every call site to `SendText(jid, body, nil)`. Same for `SendTextReply` (add a trailing `nil`).

Use grep:

```bash
grep -n 'SendText\|SendTextReply\|EditText' bridge/*_test.go
```

For each match in test code that calls one of these, add a trailing `nil` argument. Show the diff so the reviewer can spot any missed sites.

- [ ] **Step 5: Build the Go bridge**

```bash
cd bridge && go build ./... && cd ..
```

Expected: clean compile.

- [ ] **Step 6: Run Go tests**

```bash
cd bridge && go test ./... 2>&1 | tail -10
```

Expected: PASS (call-site updates from Step 4 keep the test suite compiling and green).

- [ ] **Step 7: Rebuild `Bridge.xcframework`**

```bash
./scripts/build-xcframework.sh
```

Expected: `Built: build/Bridge.xcframework`. This regenerates the gomobile-bound Objective-C wrappers; the Swift side now sees `SendText(chatJID, body, mentionedJIDs)` etc.

- [ ] **Step 8: Commit**

```bash
git add bridge/messages.go bridge/edit_revoke.go bridge/messages_test.go build/Bridge.xcframework
git commit -m "bridge: SendText/SendTextReply/EditText accept mentionedJIDs"
```

(If `build/Bridge.xcframework` is gitignored — check with `git check-ignore build/Bridge.xcframework` — drop it from the add list. The release pipeline rebuilds it.)

---

## Task 2: Swift wrappers — defaulted `mentionedJIDs:` param

**Files:**
- Modify: `yawac/Bridge/WAClient.swift` (`sendText` line 103, `sendTextReply` line 169, `editText` line 199).

This task is source-compatible only when the gomobile-bound `Sendtext` / `Sendtextreply` / `Edittext` Objective-C signatures now require the extra `mentionedJIDs` argument. The Swift wrappers must pass it through.

- [ ] **Step 1: Extend `sendText` wrapper**

In `yawac/Bridge/WAClient.swift`, replace `sendText` (lines 103–108) with:

```swift
    func sendText(_ chatJID: String, _ body: String,
                  mentionedJIDs: [String] = []) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendText(chatJID, body: body,
                               mentionedJIDs: mentionedJIDs, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }
```

(If gomobile names the new arg differently — e.g. `mentionedJIDs:` vs `mentionedJID:` — check by inspecting the gomobile-generated `Bridge` interface header after Step 7 of Task 1. Adapt accordingly.)

- [ ] **Step 2: Extend `sendTextReply` wrapper**

Replace `sendTextReply` (lines 169–181) with:

```swift
    func sendTextReply(_ chatJID: String, _ body: String,
                       quotedID: String, quotedSenderJID: String,
                       quotedFromMe: Bool, quotedKind: String,
                       quotedSnippet: String,
                       mentionedJIDs: [String] = []) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.sendTextReply(
            chatJID, body: body,
            quotedID: quotedID, quotedSenderJID: quotedSenderJID,
            quotedFromMe: quotedFromMe, quotedKind: quotedKind,
            quotedSnippet: quotedSnippet,
            mentionedJIDs: mentionedJIDs, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }
```

- [ ] **Step 3: Extend `editText` wrapper**

Replace `editText` (lines 199–204) with:

```swift
    func editText(_ chatJID: String, _ msgID: String, _ newBody: String,
                  mentionedJIDs: [String] = []) throws -> BridgeSendResult {
        var err: NSError?
        let json = go.editText(chatJID, msgID: msgID, newBody: newBody,
                               mentionedJIDs: mentionedJIDs, error: &err)
        if let err { throw err }
        return try JSONDecoder().decode(BridgeSendResult.self, from: Data(json.utf8))
    }
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. All existing callers continue to compile because the new parameter is defaulted.

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "bridge: Swift wrappers route optional mentionedJIDs through to Go"
```

---

## Task 3: `MentionPickerViewModel`

**Files:**
- Create: `yawac/ViewModels/MentionPickerViewModel.swift`
- Test: `yawacTests/MentionPickerViewModelTests.swift`

TDD: failing tests → implementation → green → commit.

- [ ] **Step 1: Write the failing test file**

Create `yawacTests/MentionPickerViewModelTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class MentionPickerViewModelTests: XCTestCase {

    private func makePicker() -> MentionPickerViewModel { MentionPickerViewModel() }

    private func participant(_ jid: String, _ name: String) -> MentionPickerViewModel.Candidate {
        .participant(jid: jid, displayName: name)
    }

    private func loadGroup(_ p: MentionPickerViewModel,
                           _ items: [MentionPickerViewModel.Candidate]) {
        p.setCandidates(items, includeEveryone: true)
    }

    private func loadDM(_ p: MentionPickerViewModel,
                        _ items: [MentionPickerViewModel.Candidate]) {
        p.setCandidates(items, includeEveryone: false)
    }

    func testAtOpensWithFullList() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice"),
                      participant("b@s.whatsapp.net", "Bob")])
        p.update(text: "@")
        XCTAssertTrue(p.isActive)
        // @everyone first, then alphabetical
        XCTAssertEqual(p.filtered.map(\.label), ["everyone", "Alice", "Bob"])
        XCTAssertEqual(p.selectedIdx, 0)
    }

    func testFilterByPrefix() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice"),
                      participant("b@s.whatsapp.net", "Bob")])
        p.update(text: "@bo")
        XCTAssertEqual(p.filtered.map(\.label), ["Bob"])
    }

    func testWhitespaceAfterAtClosesPicker() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "@ ")
        XCTAssertFalse(p.isActive)
    }

    func testAtMustFollowWhitespace() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "email@example")   // '@' after a non-space char
        XCTAssertFalse(p.isActive)
    }

    func testAtAfterSpaceOpens() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "hello @a")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.filtered.map(\.label), ["Alice"])
    }

    func testEveryoneHiddenInDM() {
        let p = makePicker()
        loadDM(p, [participant("u@s.whatsapp.net", "User")])
        p.update(text: "@")
        XCTAssertEqual(p.filtered.map(\.label), ["User"])
    }

    func testMoveWraps() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice"),
                      participant("b@s.whatsapp.net", "Bob")])
        p.update(text: "@")
        // 3 rows: everyone, Alice, Bob
        XCTAssertEqual(p.selectedIdx, 0)
        p.move(by: 1); XCTAssertEqual(p.selectedIdx, 1)
        p.move(by: 1); XCTAssertEqual(p.selectedIdx, 2)
        p.move(by: 1); XCTAssertEqual(p.selectedIdx, 0)   // wrap
        p.move(by: -1); XCTAssertEqual(p.selectedIdx, 2)  // wrap back
    }

    func testCommitSelectedReturnsCandidate() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "@al")
        let picked = p.commitSelected()
        XCTAssertEqual(picked?.label, "Alice")
        XCTAssertFalse(p.isActive)
    }

    func testTriggerRangeCoversAtThroughEnd() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        let text = "hello @al"
        p.update(text: text)
        let r = p.triggerRange!
        XCTAssertEqual(String(text[r]), "@al")
    }

    func testEveryoneMatchesAllPrefix() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "@all")
        XCTAssertEqual(p.filtered.first?.label, "everyone")
    }

    func testCancelClears() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "@a")
        p.cancel()
        XCTAssertFalse(p.isActive)
        XCTAssertNil(p.triggerRange)
    }
}
```

- [ ] **Step 2: Run, confirm build failure**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MentionPickerViewModelTests 2>&1 | tail -10
```

Expected: `Cannot find 'MentionPickerViewModel' in scope`.

- [ ] **Step 3: Create `yawac/ViewModels/MentionPickerViewModel.swift`**

```swift
import Foundation
import Observation

/// Composer-side picker state for @-mention autocomplete. Owns the
/// candidate list, the substring being typed after `@`, and the keyboard
/// selection cursor. Composer reacts by reading `isActive` / `filtered`
/// and calling `commitSelected()` / `cancel()` from keypress handlers.
@Observable @MainActor
final class MentionPickerViewModel {

    /// Sentinel JID for the synthetic `@everyone` row — `*` makes it
    /// impossible to confuse with a real WhatsApp JID. Consumers use
    /// this to detect "expand to all participants" at send time.
    static let everyoneSentinelJID = "*all*"

    enum Candidate: Equatable {
        case everyone
        case participant(jid: String, displayName: String)

        var jid: String {
            switch self {
            case .everyone: return MentionPickerViewModel.everyoneSentinelJID
            case .participant(let jid, _): return jid
            }
        }

        /// User-facing label inserted into the composer body (without
        /// the leading `@`). For `everyone` this is literally "everyone".
        var label: String {
            switch self {
            case .everyone: return "everyone"
            case .participant(_, let n): return n
            }
        }
    }

    private(set) var candidates: [Candidate] = []
    private(set) var filtered: [Candidate] = []
    private(set) var selectedIdx: Int = 0
    private(set) var triggerRange: Range<String.Index>?
    private(set) var isActive: Bool = false
    private var includeEveryone: Bool = false

    func setCandidates(_ items: [Candidate], includeEveryone: Bool) {
        self.includeEveryone = includeEveryone
        // Sort real participants alphabetically by label.
        let sorted = items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        self.candidates = (includeEveryone ? [.everyone] : []) + sorted
    }

    /// Update picker state from the composer's current text. Cursor is
    /// assumed at `text.endIndex` (TextField doesn't expose live cursor
    /// position on macOS without subclassing NSTextView).
    func update(text: String) {
        // Find the last '@' that is at start of string or preceded by whitespace.
        var atIdx: String.Index? = nil
        var i = text.endIndex
        while i > text.startIndex {
            let prev = text.index(before: i)
            let c = text[prev]
            if c == "@" {
                // Validate left boundary: start-of-string or whitespace.
                let okLeft = (prev == text.startIndex)
                    || text[text.index(before: prev)].isWhitespace
                if okLeft { atIdx = prev }
                break
            }
            if c.isWhitespace {
                break
            }
            i = prev
        }
        guard let at = atIdx else {
            cancel()
            return
        }
        let afterAt = text.index(after: at)
        // Whitespace between @ and end → closed.
        if let _ = text[afterAt..<text.endIndex].firstIndex(where: { $0.isWhitespace }) {
            cancel()
            return
        }
        let query = String(text[afterAt..<text.endIndex])
        triggerRange = at..<text.endIndex
        isActive = true
        applyFilter(query: query)
    }

    private func applyFilter(query: String) {
        let q = query.lowercased()
        let digits = q.filter(\.isNumber)
        filtered = candidates.filter { c in
            switch c {
            case .everyone:
                // Only include in groups; setCandidates already pre-filters
                // by `includeEveryone`, so c==.everyone here implies group.
                if q.isEmpty { return true }
                return "everyone".hasPrefix(q) || "all".hasPrefix(q) || "every".hasPrefix(q)
            case .participant(let jid, let name):
                if q.isEmpty { return true }
                if name.localizedCaseInsensitiveContains(query) { return true }
                if !digits.isEmpty, jid.filter(\.isNumber).contains(digits) { return true }
                return false
            }
        }
        // Reset selection — first row.
        selectedIdx = 0
    }

    func move(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let n = filtered.count
        // ((sel + delta) % n + n) % n keeps wrap correct for negative deltas.
        selectedIdx = ((selectedIdx + delta) % n + n) % n
    }

    /// Returns the candidate at `selectedIdx` and closes the picker.
    /// `nil` when filtered is empty.
    func commitSelected() -> Candidate? {
        guard !filtered.isEmpty,
              filtered.indices.contains(selectedIdx) else {
            cancel()
            return nil
        }
        let pick = filtered[selectedIdx]
        cancel()
        return pick
    }

    func cancel() {
        isActive = false
        triggerRange = nil
        filtered = []
        selectedIdx = 0
    }
}
```

- [ ] **Step 4: Run tests, confirm green**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MentionPickerViewModelTests 2>&1 | tail -20
```

Expected: 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/MentionPickerViewModel.swift \
        yawacTests/MentionPickerViewModelTests.swift
git commit -m "compose: MentionPickerViewModel — trigger detection + filter + selection"
```

---

## Task 4: `ConversationViewModel` — `ActiveMention`, participants cache, encoding

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`.
- Test: `yawacTests/MentionEncodingTests.swift`

- [ ] **Step 1: Write failing encoding tests**

Create `yawacTests/MentionEncodingTests.swift`:

```swift
import XCTest
@testable import yawac

final class MentionEncodingTests: XCTestCase {

    private func encode(body: String,
                        mentions: [ConversationViewModel.ActiveMention],
                        allParticipants: [String] = []) -> (String, [String]) {
        ConversationViewModel.encodeMentions(
            body: body, mentions: mentions, allParticipants: allParticipants)
    }

    func testNoMentionsPassThrough() {
        let (out, jids) = encode(body: "hello", mentions: [])
        XCTAssertEqual(out, "hello")
        XCTAssertTrue(jids.isEmpty)
    }

    func testSingleMentionReplacedAndJIDCaptured() {
        let m = ConversationViewModel.ActiveMention(
            displayName: "Natali", jid: "200347423354946@s.whatsapp.net")
        let (out, jids) = encode(body: "hi @Natali bye", mentions: [m])
        XCTAssertEqual(out, "hi @200347423354946 bye")
        XCTAssertEqual(jids, ["200347423354946@s.whatsapp.net"])
    }

    func testMissingNeedleDropsMention() {
        // User mangled the inserted display name.
        let m = ConversationViewModel.ActiveMention(
            displayName: "Natali", jid: "200347423354946@s.whatsapp.net")
        let (out, jids) = encode(body: "hi @Natli bye", mentions: [m])
        XCTAssertEqual(out, "hi @Natli bye")
        XCTAssertTrue(jids.isEmpty)
    }

    func testMultipleMentionsBothReplaced() {
        let m1 = ConversationViewModel.ActiveMention(
            displayName: "Natali", jid: "1@s.whatsapp.net")
        let m2 = ConversationViewModel.ActiveMention(
            displayName: "Bob", jid: "2@s.whatsapp.net")
        let (out, jids) = encode(body: "hi @Natali and @Bob", mentions: [m1, m2])
        XCTAssertEqual(out, "hi @1 and @2")
        XCTAssertEqual(Set(jids), Set(["1@s.whatsapp.net", "2@s.whatsapp.net"]))
    }

    func testEveryoneSentinelExpandsToAllAndKeepsLiteral() {
        let m = ConversationViewModel.ActiveMention(
            displayName: "everyone", jid: MentionPickerViewModel.everyoneSentinelJID)
        let (out, jids) = encode(
            body: "hello @everyone",
            mentions: [m],
            allParticipants: ["a@s.whatsapp.net", "b@s.whatsapp.net", "c@s.whatsapp.net"])
        XCTAssertEqual(out, "hello @everyone", "@everyone stays literal on the wire")
        XCTAssertEqual(Set(jids),
                       Set(["a@s.whatsapp.net", "b@s.whatsapp.net", "c@s.whatsapp.net"]))
    }

    func testEveryoneAndDirectMentionDedupe() {
        let everyone = ConversationViewModel.ActiveMention(
            displayName: "everyone", jid: MentionPickerViewModel.everyoneSentinelJID)
        let direct = ConversationViewModel.ActiveMention(
            displayName: "Bob", jid: "b@s.whatsapp.net")
        let (out, jids) = encode(
            body: "hi @Bob and @everyone",
            mentions: [direct, everyone],
            allParticipants: ["a@s.whatsapp.net", "b@s.whatsapp.net"])
        XCTAssertEqual(out, "hi @b and @everyone")
        XCTAssertEqual(Set(jids), Set(["a@s.whatsapp.net", "b@s.whatsapp.net"]),
                       "duplicate Bob (via @everyone + direct) appears once")
    }

    func testLIDJIDStripsToLIDNumber() {
        let m = ConversationViewModel.ActiveMention(
            displayName: "Carol", jid: "987654@lid")
        let (out, jids) = encode(body: "hi @Carol", mentions: [m])
        XCTAssertEqual(out, "hi @987654")
        XCTAssertEqual(jids, ["987654@lid"])
    }
}
```

- [ ] **Step 2: Run, confirm build failure**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MentionEncodingTests 2>&1 | tail -10
```

Expected: `Cannot find type 'ConversationViewModel.ActiveMention' in scope` (and missing `encodeMentions`).

- [ ] **Step 3: Add `ActiveMention` + `encodeMentions` to `ConversationViewModel.swift`**

Append inside `ConversationViewModel` class — near the other small value types if any, otherwise at the bottom before the closing brace:

```swift
    // MARK: - Mentions

    struct ActiveMention: Equatable {
        let displayName: String
        let jid: String   // MentionPickerViewModel.everyoneSentinelJID for @everyone
    }

    /// Live picker state shared with ComposerView. Lazily configured per
    /// chat the first time the composer requests it (see ComposerView).
    var picker = MentionPickerViewModel()

    /// Captures every successful pick during the current draft session;
    /// cleared whenever `draft` is reset.
    var activeMentions: [ActiveMention] = []

    /// Cached participants for this chat (groups only). Lazily fetched.
    var groupParticipants: [BridgeParticipantModel]?

    /// Pure helper — testable without spinning up a CVM. Walks `mentions`
    /// in order, swapping each `@<displayName>` in `body` for `@<phone>`
    /// (or expanding `@everyone` to every participant) and returning a
    /// de-duplicated `mentionedJIDs` list.
    static func encodeMentions(
        body: String,
        mentions: [ActiveMention],
        allParticipants: [String]
    ) -> (String, [String]) {
        var out = body
        var jids: [String] = []
        for m in mentions {
            let needle = "@\(m.displayName)"
            if m.jid == MentionPickerViewModel.everyoneSentinelJID {
                if out.contains(needle) {
                    jids.append(contentsOf: allParticipants)
                }
                // Body keeps literal "@everyone".
            } else {
                let replacement = "@" + Self.phoneDigits(jid: m.jid)
                if let r = out.range(of: needle) {
                    out.replaceSubrange(r, with: replacement)
                    jids.append(m.jid)
                }
            }
        }
        // Stable dedupe (keep first-occurrence order).
        var seen = Set<String>()
        let deduped = jids.filter { seen.insert($0).inserted }
        return (out, deduped)
    }

    /// Substring before the first `@` of a JID — the WhatsApp-side phone
    /// or LID number. Returns the full string if `@` not present (defensive).
    private static func phoneDigits(jid: String) -> String {
        guard let at = jid.firstIndex(of: "@") else { return jid }
        return String(jid[..<at])
    }
```

- [ ] **Step 4: Wire encoding into `sendDraft()` + `saveEdit(_:)`**

In `ConversationViewModel.swift`, locate `sendDraft()` (line 1109). Replace the existing implementation body with the mention-aware version:

```swift
    func sendDraft() async {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        draft = ""

        let mentionsSnapshot = activeMentions
        activeMentions = []

        let allP = (groupParticipants ?? []).map(\.jid)
        let (body, mentionedJIDs) = Self.encodeMentions(
            body: raw, mentions: mentionsSnapshot, allParticipants: allP)

        let replyTo = replyTarget
        replyTarget = nil

        do {
            let res: BridgeSendResult
            if let q = replyTo {
                res = try client.sendTextReply(
                    chatJID, body,
                    quotedID: q.id,
                    quotedSenderJID: q.senderJID,
                    quotedFromMe: q.fromMe,
                    quotedKind: Self.quotedKind(of: q),
                    quotedSnippet: Self.quotedSnippet(of: q),
                    mentionedJIDs: mentionedJIDs)
            } else {
                res = try client.sendText(chatJID, body,
                                          mentionedJIDs: mentionedJIDs)
            }
            var m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .text(body))
            if let q = replyTo {
                m.quotedMessageID = q.id
                m.quotedSenderJID = q.senderJID
                m.quotedFromMe = q.fromMe
                m.quotedKind = Self.quotedKind(of: q)
                m.quotedTextSnippet = Self.quotedSnippet(of: q)
            }
            messages.append(m)
            receiptStatus[m.id] = .sent
            persistOutgoing(m, kind: "text", text: body)
        } catch {
            replyTarget = replyTo
            draft = raw
            activeMentions = mentionsSnapshot
            transientError = "Couldn't send: \(error.localizedDescription)"
        }
    }
```

Then locate `saveEdit(_ newBody: String)` (use grep: `grep -n 'saveEdit' yawac/ViewModels/ConversationViewModel.swift`). Apply the same encoding pattern there: snapshot `activeMentions`, compute `(body, jids)`, pass `mentionedJIDs:` to `client.editText`. Restore the snapshot on error.

A representative shape:

```swift
    func saveEdit(_ newBody: String) async {
        guard let target = editTarget else { return }
        let raw = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let mentionsSnapshot = activeMentions
        activeMentions = []

        let allP = (groupParticipants ?? []).map(\.jid)
        let (body, mentionedJIDs) = Self.encodeMentions(
            body: raw, mentions: mentionsSnapshot, allParticipants: allP)

        editTarget = nil
        do {
            _ = try client.editText(chatJID, target.id, body,
                                    mentionedJIDs: mentionedJIDs)
            // (existing post-edit UI update logic stays — leave it intact.)
        } catch {
            editTarget = target
            activeMentions = mentionsSnapshot
            transientError = "Couldn't edit: \(error.localizedDescription)"
        }
    }
```

Read the existing `saveEdit` body before applying — preserve any persistence / UI-update calls. The change is only: pull `mentionsSnapshot`, call `encodeMentions`, pass `mentionedJIDs:`.

- [ ] **Step 5: Add `loadGroupParticipantsIfNeeded()` helper**

Append in `ConversationViewModel`:

```swift
    /// Lazily fetches group participants for this chat. No-op for 1:1
    /// chats. Caller awaits before opening the mention picker; UI shows
    /// a "Loading…" row in the strip while in-flight.
    func loadGroupParticipantsIfNeeded() async {
        if groupParticipants != nil { return }
        guard chatJID.hasSuffix("@g.us") else { return }
        do {
            let info = try await Task.detached(priority: .userInitiated) { [chatJID, client] in
                try client.getGroupInfo(jid: chatJID)
            }.value
            self.groupParticipants = info.participants
        } catch {
            self.groupParticipants = []
        }
    }
```

- [ ] **Step 6: Run encoding tests, confirm green**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/MentionEncodingTests 2>&1 | tail -15
```

Expected: 7 tests pass.

- [ ] **Step 7: Run full suite to confirm no regression**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. The known-flaky `ChatSearchViewModelTests` debounce tests may need a retry — that's pre-existing.

- [ ] **Step 8: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift \
        yawacTests/MentionEncodingTests.swift
git commit -m "convo: ActiveMention + encodeMentions + lazy participants cache"
```

---

## Task 5: `MentionStrip` view + ComposerView integration

**Files:**
- Create: `yawac/Views/MentionStrip.swift`
- Modify: `yawac/Views/ComposerView.swift`

View-layer only; no unit tests — verification = build + manual.

- [ ] **Step 1: Create `yawac/Views/MentionStrip.swift`**

```swift
import SwiftUI

/// Slim inline list anchored above the composer, gated on
/// `picker.isActive`. Renders one row per filtered candidate plus a
/// loading state. ↑/↓/Tab/Enter/Esc are handled by ComposerView's
/// `.onKeyPress` chain — this view is render-only.
struct MentionStrip: View {

    @Bindable var picker: MentionPickerViewModel
    let onCommit: (MentionPickerViewModel.Candidate) -> Void

    var body: some View {
        if picker.isActive {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(picker.filtered.prefix(5).enumerated()),
                        id: \.offset) { idx, cand in
                    row(cand: cand, isSelected: idx == picker.selectedIdx)
                        .contentShape(Rectangle())
                        .onTapGesture { onCommit(cand) }
                }
                if picker.filtered.count > 5 {
                    ScrollView { /* extras for completeness */
                        ForEach(Array(picker.filtered.dropFirst(5).enumerated()),
                                id: \.offset) { idx2, cand in
                            row(cand: cand, isSelected: false)
                                .contentShape(Rectangle())
                                .onTapGesture { onCommit(cand) }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
            .padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func row(cand: MentionPickerViewModel.Candidate,
                     isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            switch cand {
            case .everyone:
                Image(systemName: "megaphone.fill")
                    .scaledIcon(14, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20)
                Text("@everyone")
                    .scaledUI(13, weight: .semibold)
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.text)
                Spacer()
            case .participant(let jid, let name):
                Image(systemName: "person.circle.fill")
                    .scaledIcon(18)
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 20, height: 20)
                Text("@\(name)")
                    .scaledUI(13)
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.text)
                Spacer()
                Text(phoneOnly(jid))
                    .scaledMono(10)
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Theme.accentSoft : Color.clear)
    }

    private func phoneOnly(_ jid: String) -> String {
        guard let at = jid.firstIndex(of: "@") else { return jid }
        return String(jid[..<at])
    }
}
```

- [ ] **Step 2: Integrate into `ComposerView.swift`**

In `yawac/Views/ComposerView.swift`:

**2a.** In the `VStack(spacing: 8)` body (lines 14–22), insert `MentionStrip` between `attachmentStrip` and the `if recorder.state == .recording` block:

```swift
    var body: some View {
        VStack(spacing: 8) {
            replyChip
            editChip
            attachmentStrip
            MentionStrip(picker: vm.picker, onCommit: commitMention)
            if recorder.state == .recording {
                RecordingBar(recorder: recorder, cancelHint: wantsCancel)
            }
            inputRow
        }
        .animation(.easeOut(duration: 0.15), value: vm.pendingAttachments)
        .animation(.easeOut(duration: 0.12), value: vm.picker.isActive)
        // … existing onChange modifiers stay …
    }
```

**2b.** Extend the existing `.onChange(of: vm.draft)` on the TextField (line 78) to also drive the picker:

```swift
                .onChange(of: vm.draft) { _, new in
                    vm.setTyping(!new.isEmpty)
                    Task { await vm.loadGroupParticipantsIfNeeded() }
                    let candidates: [MentionPickerViewModel.Candidate] = {
                        if let parts = vm.groupParticipants, !parts.isEmpty {
                            return parts.map { .participant(
                                jid: $0.jid,
                                displayName: session.displayName(for: $0.jid)) }
                        }
                        // 1:1 fallback — the other party only.
                        if !vm.chatJID.hasSuffix("@g.us") {
                            return [.participant(jid: vm.chatJID,
                                                 displayName: session.displayName(for: vm.chatJID))]
                        }
                        return []
                    }()
                    vm.picker.setCandidates(candidates,
                                            includeEveryone: vm.chatJID.hasSuffix("@g.us"))
                    vm.picker.update(text: new)
                }
```

**2c.** Extend the `.onKeyPress` chain (around lines 82–99) — add four new handlers BEFORE the existing `.onKeyPress(.escape)` and `.onKeyPress(.upArrow)`:

```swift
                .onKeyPress(.tab) {
                    guard vm.picker.isActive else { return .ignored }
                    if let pick = vm.picker.commitSelected() {
                        commitMention(pick)
                    }
                    return .handled
                }
                .onKeyPress(.return) {
                    guard vm.picker.isActive else { return .ignored }
                    if let pick = vm.picker.commitSelected() {
                        commitMention(pick)
                    }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard vm.picker.isActive else { return .ignored }
                    vm.picker.move(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    if vm.picker.isActive {
                        vm.picker.move(by: -1)
                        return .handled
                    }
                    // existing recall-last-own-message behavior
                    guard vm.editTarget == nil, vm.replyTarget == nil,
                          vm.draft.isEmpty
                    else { return .ignored }
                    vm.editLastOwnMessage()
                    return vm.editTarget == nil ? .ignored : .handled
                }
                .onKeyPress(.escape) {
                    if vm.picker.isActive {
                        vm.picker.cancel()
                        return .handled
                    }
                    let wasEditing = (vm.editTarget != nil)
                    if vm.replyTarget != nil || vm.editTarget != nil {
                        vm.cancelCompose()
                        if wasEditing { vm.draft = "" }
                        return .handled
                    }
                    return .ignored
                }
```

DELETE the original `.onKeyPress(.escape)` and `.onKeyPress(.upArrow)` you just replaced.

**2d.** Add the `commitMention` helper to `ComposerView` (sibling of `send()`):

```swift
    private func commitMention(_ cand: MentionPickerViewModel.Candidate) {
        guard let r = vm.picker.triggerRange ?? findCurrentTriggerRange() else { return }
        let insertion = "@\(cand.label) "
        vm.draft.replaceSubrange(r, with: insertion)
        vm.activeMentions.append(.init(displayName: cand.label, jid: cand.jid))
        vm.picker.cancel()
    }

    /// `picker.cancel()` clears triggerRange before this closure may run
    /// if the picker auto-closed (e.g. tab while only one candidate);
    /// recompute by finding the last '@' in the current draft.
    private func findCurrentTriggerRange() -> Range<String.Index>? {
        guard let at = vm.draft.lastIndex(of: "@") else { return nil }
        return at..<vm.draft.endIndex
    }
```

- [ ] **Step 3: Build verify**

```bash
xcodegen generate
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/MentionStrip.swift yawac/Views/ComposerView.swift
git commit -m "compose: MentionStrip + @ trigger / keyboard handlers / commit"
```

---

## Task 6: Full test suite gate

- [ ] **Step 1: Run full suite**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `** TEST SUCCEEDED **`. If a pre-existing flake (`ChatSearchViewModelTests.testRateLimitedPreservesPriorSuggestion` or similar debounce-timing tests) fails, retry once.

- [ ] **Step 2: If green, no commit. If red on unrelated tests, retry per known-flake list.**

---

## Task 7: Manual visual gate

No commit — interactive check.

- [ ] Launch the app. Open a group chat.
- [ ] Type `@`. Strip appears with `@everyone` first + alphabetical participants. First row selected.
- [ ] Type a partial name (e.g. `@al`). List filters live.
- [ ] Press ↓ then ↑ — selection cycles. Press Tab — picker commits and `@<Name> ` is inserted.
- [ ] Press Enter (on a fresh `@al` selection) — picker commits.
- [ ] Press Esc on `@a` — picker closes, the `@a` substring stays as typed.
- [ ] Pick `@everyone`. Type rest of message. Send. Verify recipient on a phone sees `@everyone` highlighted.
- [ ] Open a DM. Type `@`. Strip shows only the other party. No `@everyone` row.
- [ ] In a group, mention someone, then edit the inserted `@Name` to `@Nam`. Send. Recipient sees plain text `@Nam` (no ping, no highlight).
- [ ] Edit a previously-sent message: replace its body with `hi @everyone`. Send the edit. Recipient sees the edit highlighted.

---

## Done When

- All `xcodebuild` commands succeed.
- All eight manual checks pass.
- Commits land on `main`: Task 1 (bridge), Task 2 (Swift wrappers), Task 3 (picker VM), Task 4 (CVM + encoding), Task 5 (UI). Tasks 6 / 7 are gates.
