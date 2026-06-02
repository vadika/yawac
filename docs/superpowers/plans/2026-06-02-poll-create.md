# Poll Creation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users create polls (single or multi-select) in any DM or group chat from the composer's attachment menu, with the poll bubble appearing optimistically and surviving app restart.

**Architecture:** New Go `bridge.SendPollCreation` wraps whatsmeow's `BuildPollCreation` + `SendMessage` and returns the canonical `JPoll` JSON so option hashes match the wire form exactly. Swift wraps it in `WAClient.sendPollCreation`, the new VM method `sendPoll` performs optimistic append + persistence via the existing `PersistedMessage.pollJSON` schema (no migration), and a new `PollComposerView` sheet drives the input. The receive / vote / tally paths already exist and are reused unchanged.

**Tech Stack:** Go 1.22 + whatsmeow, gomobile xcframework, Swift 5.10, SwiftUI macOS 14+, SwiftData.

**Spec:** `docs/superpowers/specs/2026-06-02-poll-create-design.md`.

---

## File Map

**New files:**
- `yawac/Views/PollComposerView.swift` — modal sheet for question / options / multi-toggle.
- `yawacTests/ConversationViewModelPollCreateTests.swift` — VM unit tests for `sendPoll`.

**Modified files:**
- `bridge/polls.go` — `SendPollCreation`.
- `bridge/jsonmodels.go` — `JSendPollResult`.
- `bridge/polls_test.go` — validation tests for `SendPollCreation`.
- `yawac/Bridge/WAClient.swift` — `sendPollCreation` wrapper.
- `yawac/Bridge/JSONModels.swift` — `BridgeSendPollResult`.
- `yawac/ViewModels/ConversationViewModel.swift` — `showPollComposer`, `sendPoll`, `persistOutgoingPoll`.
- `yawac/Views/ComposerView.swift` — paperclip Button → Menu with "Attach file…" + "New poll…".
- `yawac/Views/ConversationView.swift` — `.sheet(isPresented: $vm.showPollComposer)` presenting `PollComposerView`.
- `docs/ROADMAP.md` — flip "Polls — create" to ✅.

---

## Task 1: Go — `JSendPollResult` JSON type

**Files:**
- Modify: `bridge/jsonmodels.go`

- [ ] **Step 1: Add the struct**

Append to `bridge/jsonmodels.go` (immediately after the existing `JSendResult` definition near line 113):

```go
// JSendPollResult is returned by SendPollCreation. Carries the canonical
// JPoll (built from the wire-form message) so the caller's local copy of
// the option hashes matches what peers will use for vote tallies.
type JSendPollResult struct {
    MessageID string `json:"message_id"`
    Timestamp int64  `json:"timestamp"`
    Poll      JPoll  `json:"poll"`
}
```

- [ ] **Step 2: Confirm it compiles**

Run: `cd bridge && go build ./...`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add bridge/jsonmodels.go
git commit -m "bridge: add JSendPollResult JSON type for SendPollCreation"
```

---

## Task 2: Go — `SendPollCreation` validation (red tests)

**Files:**
- Test: `bridge/polls_test.go`

- [ ] **Step 1: Add failing tests at the bottom of `bridge/polls_test.go`**

Append:

```go
func TestSendPollCreationRejectsBadJID(t *testing.T) {
    c, err := NewClient(t.TempDir() + "/pc1.db")
    if err != nil {
        t.Fatal(err)
    }
    defer c.Close()
    _, err = c.SendPollCreation("not-a-jid", "Q",
        `["A","B"]`, 1)
    if err == nil || !strings.Contains(err.Error(), "jid") {
        t.Fatalf("want jid error, got %v", err)
    }
}

func TestSendPollCreationClosedClient(t *testing.T) {
    c := &Client{} // wa is nil
    _, err := c.SendPollCreation("12345@s.whatsapp.net", "Q",
        `["A","B"]`, 1)
    if err == nil {
        t.Fatal("expected error for closed client")
    }
}

func TestSendPollCreationRejectsTooFewOptions(t *testing.T) {
    c, err := NewClient(t.TempDir() + "/pc2.db")
    if err != nil {
        t.Fatal(err)
    }
    defer c.Close()
    _, err = c.SendPollCreation("12345@s.whatsapp.net", "Q",
        `["only-one"]`, 1)
    if err == nil || !strings.Contains(err.Error(), "options") {
        t.Fatalf("want options error, got %v", err)
    }
}

func TestSendPollCreationRejectsTooManyOptions(t *testing.T) {
    c, err := NewClient(t.TempDir() + "/pc3.db")
    if err != nil {
        t.Fatal(err)
    }
    defer c.Close()
    opts := `["1","2","3","4","5","6","7","8","9","10","11","12","13"]`
    _, err = c.SendPollCreation("12345@s.whatsapp.net", "Q", opts, 1)
    if err == nil || !strings.Contains(err.Error(), "options") {
        t.Fatalf("want options error, got %v", err)
    }
}

func TestSendPollCreationRejectsEmptyOption(t *testing.T) {
    c, err := NewClient(t.TempDir() + "/pc4.db")
    if err != nil {
        t.Fatal(err)
    }
    defer c.Close()
    _, err = c.SendPollCreation("12345@s.whatsapp.net", "Q",
        `["A","   "]`, 1)
    if err == nil || !strings.Contains(err.Error(), "option") {
        t.Fatalf("want option error, got %v", err)
    }
}

func TestSendPollCreationRejectsEmptyQuestion(t *testing.T) {
    c, err := NewClient(t.TempDir() + "/pc5.db")
    if err != nil {
        t.Fatal(err)
    }
    defer c.Close()
    _, err = c.SendPollCreation("12345@s.whatsapp.net", "   ",
        `["A","B"]`, 1)
    if err == nil || !strings.Contains(err.Error(), "question") {
        t.Fatalf("want question error, got %v", err)
    }
}

func TestSendPollCreationRejectsBadSelectableCount(t *testing.T) {
    c, err := NewClient(t.TempDir() + "/pc6.db")
    if err != nil {
        t.Fatal(err)
    }
    defer c.Close()
    _, err = c.SendPollCreation("12345@s.whatsapp.net", "Q",
        `["A","B"]`, -1)
    if err == nil || !strings.Contains(err.Error(), "selectable") {
        t.Fatalf("want selectable error for -1, got %v", err)
    }
    _, err = c.SendPollCreation("12345@s.whatsapp.net", "Q",
        `["A","B"]`, 3)
    if err == nil || !strings.Contains(err.Error(), "selectable") {
        t.Fatalf("want selectable error for >len, got %v", err)
    }
}
```

(The `strings` import already exists in the test file's neighbour `messages_test.go`; add `"strings"` to `bridge/polls_test.go`'s import block if not already present.)

- [ ] **Step 2: Run tests, verify they fail (function does not exist yet)**

Run: `cd bridge && go test ./... -run TestSendPollCreation -v`
Expected: compile error — `c.SendPollCreation undefined`.

- [ ] **Step 3: Commit**

```bash
git add bridge/polls_test.go
git commit -m "bridge: add failing SendPollCreation validation tests"
```

---

## Task 3: Go — `SendPollCreation` implementation

**Files:**
- Modify: `bridge/polls.go`

- [ ] **Step 1: Add the function**

Append to `bridge/polls.go`:

```go
// SendPollCreation builds a poll creation message and sends it. optionsJSON
// is a JSON array of option-name strings. selectableCount must be in
// 0..len(options); 0 means multi-select (WhatsApp convention), 1 means
// single. Returns JSON of JSendPollResult.
//
// Validation is strict because whatsmeow.BuildPollCreation silently clamps
// an out-of-range selectableOptionCount to 0 (msgsecret.go:326), which
// would hide programmer errors.
func (c *Client) SendPollCreation(
    chatJID, question, optionsJSON string,
    selectableCount int32,
) (string, error) {
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

    var rawOpts []string
    if err := json.Unmarshal([]byte(optionsJSON), &rawOpts); err != nil {
        return "", fmt.Errorf("parse options: %w", err)
    }
    q := strings.TrimSpace(question)
    if q == "" {
        return "", errors.New("question is empty")
    }
    opts := make([]string, 0, len(rawOpts))
    for _, o := range rawOpts {
        t := strings.TrimSpace(o)
        if t == "" {
            return "", errors.New("option is empty")
        }
        opts = append(opts, t)
    }
    if len(opts) < 2 {
        return "", fmt.Errorf("options: want 2..12, got %d", len(opts))
    }
    if len(opts) > 12 {
        return "", fmt.Errorf("options: want 2..12, got %d", len(opts))
    }
    if selectableCount < 0 || int(selectableCount) > len(opts) {
        return "", fmt.Errorf("selectable count: want 0..%d, got %d",
            len(opts), selectableCount)
    }

    msg := c.wa.BuildPollCreation(q, opts, int(selectableCount))
    resp, err := c.wa.SendMessage(context.Background(), jid, msg)
    if err != nil {
        fmt.Fprintf(os.Stderr,
            "[yawac/poll-create] chat=%s opts=%d sel=%d err=%v\n",
            chatJID, len(opts), selectableCount, err)
        return "", fmt.Errorf("send: %w", err)
    }

    jp := extractPoll(msg)
    if jp == nil {
        // Should never happen: we just built a PollCreationMessage.
        return "", errors.New("internal: built message is not a poll")
    }
    out, _ := json.Marshal(JSendPollResult{
        MessageID: resp.ID,
        Timestamp: resp.Timestamp.Unix(),
        Poll:      *jp,
    })
    return string(out), nil
}
```

Add to the existing import block in `bridge/polls.go` (the file already imports `context`, `encoding/json`, `errors`, `fmt`, `os`, plus whatsmeow packages — verify and add `"strings"` if missing):

```go
"strings"
```

- [ ] **Step 2: Run the validation tests, verify they pass**

Run: `cd bridge && go test ./... -run TestSendPollCreation -v`
Expected: all seven `TestSendPollCreation*` tests PASS.

- [ ] **Step 3: Run the full bridge package test suite to confirm no regressions**

Run: `cd bridge && go test ./...`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add bridge/polls.go
git commit -m "bridge: SendPollCreation wraps BuildPollCreation + SendMessage

Validates question / options bounds / selectable count tightly to
sidestep whatsmeow's silent clamp. Returns JSendPollResult so the
caller's option hashes match the wire form."
```

---

## Task 4: Rebuild the gomobile xcframework

**Files:** none directly; produces `build/WhatsAppBridge.xcframework`.

- [ ] **Step 1: Rebuild the bridge framework**

Run the project's standard bridge-build command. Check `docs/DEVELOPMENT.md` for the canonical script; the repo convention is usually:

```bash
cd bridge && ./scripts/build-bridge.sh
```

(If `scripts/build-bridge.sh` lives at the repo root, use that path instead — read `docs/DEVELOPMENT.md` for the current command.)

Expected: the script regenerates `build/WhatsAppBridge.xcframework` and exits 0.

- [ ] **Step 2: Confirm the new symbol is exported**

Run:

```bash
nm -gU build/WhatsAppBridge.xcframework/macos-*/WhatsAppBridge.framework/Versions/A/WhatsAppBridge 2>/dev/null | grep -i SendPollCreation || \
strings build/WhatsAppBridge.xcframework/macos-*/WhatsAppBridge.framework/Versions/A/WhatsAppBridge | grep SendPollCreation | head -3
```

Expected: at least one match referencing `SendPollCreation`.

- [ ] **Step 3: Commit the framework if it is tracked**

Check `git status build/`. If `build/WhatsAppBridge.xcframework/` is tracked in git (most yawac releases vendor it), commit it:

```bash
git add build/
git commit -m "bridge: rebuild xcframework with SendPollCreation"
```

If it is git-ignored, skip the commit.

---

## Task 5: Swift — `BridgeSendPollResult` Codable model

**Files:**
- Modify: `yawac/Bridge/JSONModels.swift`

- [ ] **Step 1: Add the model**

Insert directly below the existing `BridgeSendResult` struct (around line 138 of `yawac/Bridge/JSONModels.swift`):

```swift
struct BridgeSendPollResult: Codable {
    let messageID: String
    let timestamp: Int64
    let poll: BridgePoll

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case timestamp, poll
    }
}
```

- [ ] **Step 2: Confirm it builds**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug build -quiet`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add yawac/Bridge/JSONModels.swift
git commit -m "yawac: add BridgeSendPollResult Codable"
```

---

## Task 6: Swift — `WAClient.sendPollCreation` wrapper

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`

- [ ] **Step 1: Add the wrapper**

Insert directly above the existing `sendPollVote(...)` method (around line 345 of `yawac/Bridge/WAClient.swift`):

```swift
func sendPollCreation(_ chatJID: String,
                      question: String,
                      options: [String],
                      selectableCount: Int) throws -> BridgeSendPollResult {
    let optsJSON = (try? JSONEncoder().encode(options))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    var err: NSError?
    let json = go.sendPollCreation(
        chatJID,
        question: question,
        optionsJSON: optsJSON,
        selectableCount: Int32(selectableCount),
        error: &err)
    // Go side declares selectableCount as int32 (gomobile convention in this
    // bridge — see SendVoiceNote.durationSec in bridge/media.go:217).
    if let err { throw err }
    return try JSONDecoder().decode(BridgeSendPollResult.self,
                                    from: Data(json.utf8))
}
```

(Confirm `go.sendPollCreation`'s exact gomobile-generated label order against the autogenerated header inside the xcframework. The exposed Go func is `(c *Client) SendPollCreation(chatJID, question, optionsJSON string, selectableCount int32) (string, error)` — gomobile typically translates the receiver into a single first positional arg, the rest as labelled kwargs in declaration order. If the labels differ, adjust to match the generated header.)

- [ ] **Step 2: Confirm it builds**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug build -quiet`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "yawac: WAClient.sendPollCreation bridge wrapper"
```

---

## Task 7: Swift — VM `showPollComposer` flag

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`

- [ ] **Step 1: Add the flag**

Find the `@Observable @MainActor final class ConversationViewModel` declaration and insert near the other UI-state flags (e.g. next to `forwardSelecting` around line 59):

```swift
/// Drives the PollComposerView modal sheet. Toggled by the composer's
/// "+" menu and by Cancel / on-success inside the sheet.
var showPollComposer: Bool = false
```

- [ ] **Step 2: Confirm it builds**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug build -quiet`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift
git commit -m "yawac: VM showPollComposer flag"
```

---

## Task 8: Swift — VM `sendPoll` + `persistOutgoingPoll` (red tests)

**Files:**
- Test: `yawacTests/ConversationViewModelPollCreateTests.swift` (new)

- [ ] **Step 1: Add the failing test file**

Create `yawacTests/ConversationViewModelPollCreateTests.swift`:

```swift
import Testing
@testable import yawac

/// Behavioural unit tests for ConversationViewModel.sendPoll.
/// These tests use the real bridge stub via a test-only fake of WAClient;
/// if the project doesn't already vend such a fake (check existing
/// yawacTests for the pattern used by sendDraft tests), copy that fake
/// here. The fake must record `sendPollCreation` calls and return a
/// canned BridgeSendPollResult.
@MainActor
struct ConversationViewModelPollCreateTests {

    @Test func sendPollTrimsAndDropsEmpty() async throws {
        let fake = FakeWAClient()
        fake.cannedPollResult = BridgeSendPollResult(
            messageID: "M1",
            timestamp: 100,
            poll: BridgePoll(
                question: "Q",
                options: [
                    BridgePollOption(name: "A", hash: "ha"),
                    BridgePollOption(name: "B", hash: "hb"),
                ],
                selectableCount: 1))
        let vm = ConversationViewModel(chatJID: "12@s.whatsapp.net",
                                       client: fake,
                                       context: nil)

        await vm.sendPoll(question: "  Q  ",
                          options: ["A", "  ", "B", ""],
                          allowMultiple: false)

        #expect(fake.lastPollQuestion == "Q")
        #expect(fake.lastPollOptions == ["A", "B"])
        #expect(fake.lastPollSelectable == 1)
        #expect(vm.messages.count == 1)
        #expect(vm.messages.first?.id == "M1")
    }

    @Test func sendPollMultiSetsZeroSelectable() async throws {
        let fake = FakeWAClient()
        fake.cannedPollResult = BridgeSendPollResult(
            messageID: "M2", timestamp: 100,
            poll: BridgePoll(question: "Q",
                             options: [
                                BridgePollOption(name: "A", hash: "ha"),
                                BridgePollOption(name: "B", hash: "hb"),
                             ],
                             selectableCount: 0))
        let vm = ConversationViewModel(chatJID: "12@s.whatsapp.net",
                                       client: fake, context: nil)
        await vm.sendPoll(question: "Q",
                          options: ["A", "B"],
                          allowMultiple: true)
        #expect(fake.lastPollSelectable == 0)
    }

    @Test func sendPollNoopOnTooFewOptions() async throws {
        let fake = FakeWAClient()
        let vm = ConversationViewModel(chatJID: "12@s.whatsapp.net",
                                       client: fake, context: nil)
        await vm.sendPoll(question: "Q",
                          options: ["A", "   "],
                          allowMultiple: false)
        #expect(fake.lastPollQuestion == nil)
        #expect(vm.messages.isEmpty)
    }

    @Test func sendPollNoopOnEmptyQuestion() async throws {
        let fake = FakeWAClient()
        let vm = ConversationViewModel(chatJID: "12@s.whatsapp.net",
                                       client: fake, context: nil)
        await vm.sendPoll(question: "   ",
                          options: ["A", "B"],
                          allowMultiple: false)
        #expect(fake.lastPollQuestion == nil)
    }

    @Test func sendPollOnErrorSetsTransientErrorAndKeepsSheet() async throws {
        let fake = FakeWAClient()
        fake.pollError = NSError(domain: "x", code: 1)
        let vm = ConversationViewModel(chatJID: "12@s.whatsapp.net",
                                       client: fake, context: nil)
        vm.showPollComposer = true
        await vm.sendPoll(question: "Q",
                          options: ["A", "B"],
                          allowMultiple: false)
        #expect(vm.transientError != nil)
        #expect(vm.messages.isEmpty)
    }
}
```

If `FakeWAClient` doesn't exist in `yawacTests`, copy the pattern used by whichever existing test exercises `sendDraft` / `sendText`. The fake's surface needed here:

```swift
final class FakeWAClient: WAClient {
    var cannedPollResult: BridgeSendPollResult?
    var pollError: Error?
    var lastPollQuestion: String?
    var lastPollOptions: [String]?
    var lastPollSelectable: Int?

    override func sendPollCreation(_ chatJID: String,
                                   question: String,
                                   options: [String],
                                   selectableCount: Int) throws
        -> BridgeSendPollResult
    {
        lastPollQuestion = question
        lastPollOptions = options
        lastPollSelectable = selectableCount
        if let pollError { throw pollError }
        guard let r = cannedPollResult else {
            throw NSError(domain: "fake", code: 0)
        }
        return r
    }
}
```

(If WAClient cannot be subclassed — e.g. it is a `final class` — refactor to a protocol-backed seam first. Check the existing test pattern; if other VM tests already work, that seam exists.)

- [ ] **Step 2: Run the new test file, verify it fails (sendPoll undefined)**

Run: `xcodebuild test -project yawac.xcodeproj -scheme yawac -only-testing:yawacTests/ConversationViewModelPollCreateTests 2>&1 | tail -30`
Expected: compile error — `value of type 'ConversationViewModel' has no member 'sendPoll'`.

- [ ] **Step 3: Commit**

```bash
git add yawacTests/ConversationViewModelPollCreateTests.swift
git commit -m "yawac: add failing sendPoll VM tests"
```

---

## Task 9: Swift — `sendPoll` + `persistOutgoingPoll` (green)

**Files:**
- Modify: `yawac/ViewModels/ConversationViewModel.swift`

- [ ] **Step 1: Add both methods near the existing `sendDraft` / `persistOutgoing`**

Insert immediately after the existing `persistOutgoing` private method (around line 1454):

```swift
func sendPoll(question: String,
              options: [String],
              allowMultiple: Bool) async {
    let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
    let opts = options
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !q.isEmpty, opts.count >= 2, opts.count <= 12 else { return }

    let selectable = allowMultiple ? 0 : 1
    do {
        let res = try client.sendPollCreation(
            chatJID,
            question: q,
            options: opts,
            selectableCount: selectable)

        let m = UIMessage(
            id: res.messageID,
            chatJID: chatJID,
            senderJID: "me",
            fromMe: true,
            timestamp: Date(
                timeIntervalSince1970: TimeInterval(res.timestamp)),
            body: .poll(question: res.poll.question,
                        options: res.poll.options,
                        selectableCount: res.poll.selectableCount))

        messages.append(m)
        receiptStatus[m.id] = .sent
        persistOutgoingPoll(m, pollJSON: res.poll.json ?? "")
    } catch {
        transientError =
            "Couldn't create poll: \(error.localizedDescription)"
    }
}

private func persistOutgoingPoll(_ m: UIMessage, pollJSON: String) {
    guard let context else { return }
    let row = PersistedMessage(
        id: m.id,
        chatJID: m.chatJID,
        senderJID: m.senderJID,
        fromMe: m.fromMe,
        timestamp: m.timestamp,
        kind: "poll",
        text: nil,
        pollJSON: pollJSON)
    context.insert(row)
    try? context.save()
    MessageIndex.shared.upsert(row.indexFields)
}
```

- [ ] **Step 2: Run the new tests, verify they pass**

Run: `xcodebuild test -project yawac.xcodeproj -scheme yawac -only-testing:yawacTests/ConversationViewModelPollCreateTests 2>&1 | tail -30`
Expected: all five tests PASS.

- [ ] **Step 3: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -project yawac.xcodeproj -scheme yawac 2>&1 | tail -10`
Expected: all existing yawac tests still PASS.

- [ ] **Step 4: Commit**

```bash
git add yawac/ViewModels/ConversationViewModel.swift
git commit -m "yawac: VM sendPoll + persistOutgoingPoll

Optimistic append + persist via existing PersistedMessage.pollJSON.
Reload path already decodes pollJSON, so no read-side change."
```

---

## Task 10: Swift — `PollComposerView` modal sheet

**Files:**
- Create: `yawac/Views/PollComposerView.swift`

- [ ] **Step 1: Create the file**

Write `yawac/Views/PollComposerView.swift`:

```swift
import SwiftUI

struct PollComposerView: View {
    @Bindable var vm: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var question: String = ""
    @State private var options: [String] = ["", ""]
    @State private var allowMultiple: Bool = false
    @State private var sending: Bool = false

    private static let questionCap = 255
    private static let optionCap = 100
    private static let maxOptions = 12
    private static let minOptions = 2

    private var trimmedOptions: [String] {
        options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && trimmedOptions.count >= Self.minOptions
            && !sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New poll")
                .font(.title3).bold()
            questionField
            optionsList
            Toggle("Allow multiple answers", isOn: $allowMultiple)
                .toggleStyle(.switch)
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: options) { _, _ in autoGrow() }
        .onChange(of: question) { _, new in
            if new.count > Self.questionCap {
                question = String(new.prefix(Self.questionCap))
            }
        }
    }

    private var questionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Question").font(.caption).foregroundStyle(.secondary)
            TextField("Ask something…", text: $question, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            Text("\(question.count)/\(Self.questionCap)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Options").font(.caption).foregroundStyle(.secondary)
            ForEach(options.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("Option \(i + 1)",
                              text: Binding(
                                get: { options[i] },
                                set: { newVal in
                                    options[i] = String(newVal.prefix(Self.optionCap))
                                }))
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        removeOption(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(options.count <= Self.minOptions)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(sending ? "Sending…" : "Create") {
                send()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
    }

    private func autoGrow() {
        guard options.count < Self.maxOptions else { return }
        let last = options.last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !last.isEmpty {
            options.append("")
        }
    }

    private func removeOption(at index: Int) {
        guard options.count > Self.minOptions,
              options.indices.contains(index) else { return }
        options.remove(at: index)
    }

    private func send() {
        let qSnap = question
        let optsSnap = options
        let multiSnap = allowMultiple
        sending = true
        Task {
            await vm.sendPoll(question: qSnap,
                              options: optsSnap,
                              allowMultiple: multiSnap)
            sending = false
            // Sheet dismisses only on success — VM signals success by
            // appending a message; on failure it sets transientError.
            if vm.transientError == nil {
                dismiss()
            }
        }
    }
}
```

- [ ] **Step 2: Confirm it builds**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug build -quiet`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/PollComposerView.swift
git commit -m "yawac: PollComposerView modal sheet"
```

---

## Task 11: Swift — Composer paperclip → Menu

**Files:**
- Modify: `yawac/Views/ComposerView.swift`

- [ ] **Step 1: Replace the paperclip Button with a Menu**

Locate the existing paperclip Button inside `private var inputRow: some View` (currently at `yawac/Views/ComposerView.swift:155-164`):

```swift
Button {
    attachFile()
} label: {
    Image(systemName: "paperclip")
        .scaledIcon(15, weight: .regular)
        .foregroundStyle(Theme.textMuted)
        .padding(4)
}
.buttonStyle(.plain)
.help("Attach file")
```

Replace with:

```swift
Menu {
    Button {
        attachFile()
    } label: {
        Label("Attach file…", systemImage: "paperclip")
    }
    Button {
        vm.showPollComposer = true
    } label: {
        Label("New poll…", systemImage: "chart.bar.doc.horizontal")
    }
} label: {
    Image(systemName: "paperclip")
        .scaledIcon(15, weight: .regular)
        .foregroundStyle(Theme.textMuted)
        .padding(4)
}
.menuStyle(.borderlessButton)
.menuIndicator(.hidden)
.fixedSize()
.help("Attach")
```

`fixedSize()` keeps the borderless Menu from expanding into a button-shape baseline width; without it the paperclip slides right by ~12 pt.

- [ ] **Step 2: Confirm it builds**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug build -quiet`
Expected: exit 0.

- [ ] **Step 3: Visual sanity check**

Launch the app, open any chat, click the paperclip. Expected: menu shows both "Attach file…" and "New poll…" items, paperclip glyph is unchanged in size/position.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ComposerView.swift
git commit -m "yawac: composer paperclip → Menu (Attach file + New poll)"
```

---

## Task 12: Swift — ConversationView sheet attachment

**Files:**
- Modify: `yawac/Views/ConversationView.swift`

- [ ] **Step 1: Attach the sheet**

Locate the existing `.sheet(isPresented: $showForwardPicker)` modifier in `ConversationView` (around `yawac/Views/ConversationView.swift:539`). Immediately after its closing `}`, add:

```swift
.sheet(isPresented: Binding(
    get: { vm?.showPollComposer ?? false },
    set: { vm?.showPollComposer = $0 })
) {
    if let vm {
        PollComposerView(vm: vm)
    }
}
```

`vm` is optional in this view, so a computed Binding is required (matches the existing optional-vm sheet pattern in the same file).

- [ ] **Step 2: Confirm it builds**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug build -quiet`
Expected: exit 0.

- [ ] **Step 3: End-to-end manual check (single chat)**

Launch the app, open any 1:1 chat:

1. Click paperclip → "New poll…". Expected: sheet appears.
2. Type question "Lunch?", options "Pizza" + "Sushi". Expected: a third empty row appears when "Sushi" is typed.
3. Click Create. Expected: sheet dismisses, a poll bubble appears at the bottom of the chat with the question and two options.
4. Vote on the bubble. Expected: the existing vote UI lights up the picked option (whether the recipient sees a tally update depends on having a peer device handy; check at least that the bubble round-trips through a chat re-open without loss).

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ConversationView.swift
git commit -m "yawac: present PollComposerView sheet from ConversationView"
```

---

## Task 13: End-to-end manual verification

**Files:** none — verification only.

- [ ] **Step 1: DM single-select**

In a 1:1 chat with a phone you can read:
- Create poll with 2 options, multi-select OFF.
- On the phone: confirm the poll arrives, vote one option.
- In yawac: confirm the tally updates within ~1 s.

- [ ] **Step 2: DM multi-select**

Same chat:
- Create poll with 3 options, multi-select ON.
- On the phone: vote two options.
- In yawac: confirm both votes register.

- [ ] **Step 3: Group**

In any group:
- Create poll, 4 options, single-select.
- From two different peer devices: each picks a different option.
- In yawac: confirm tally shows both votes.

- [ ] **Step 4: Revoke own poll**

- Right-click the poll bubble → Revoke for everyone.
- Confirm the bubble enters the revoked state both in yawac and on the phone.

- [ ] **Step 5: Persistence**

- Quit yawac, relaunch.
- Confirm the created polls (and their tallies) still render.

- [ ] **Step 6: Validation failure surfacing**

- Open the sheet, type a question, type only one non-empty option (leave second blank).
- Confirm the "Create" button is disabled.
- Disconnect Wi-Fi, type two options, click Create.
- Confirm the sheet stays open and a banner / `transientError` surfaces an error message. Reconnect and retry; confirm it succeeds.

- [ ] **Step 7: Long input truncation**

- Paste a 600-character string into the question field.
- Confirm it truncates at 255 characters and the counter shows `255/255`.
- Same for an option field at 100.

---

## Task 14: Flip ROADMAP entry to shipped

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Edit the Polls bullet**

Locate the entry in `docs/ROADMAP.md` (currently at line 15):

```markdown
- ☐ **Polls — create** (voting already works); whatsmeow `BuildPollCreation`
  exists with the documented `selectableOptionCount` clamp gotcha.
```

Replace with:

```markdown
- ✅ **Polls — create** — composer "+" menu opens a sheet (question +
  2–12 options + multi-select toggle); bridge wraps
  `BuildPollCreation` + `SendMessage`; optimistic bubble + persistence
  via existing `PersistedMessage.pollJSON`. Shipped 2026-06-02.
```

- [ ] **Step 2: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs: flip Polls — create to shipped"
```

---

## Done

All tasks complete. The feature is shipped behind no flag and the
spec / plan are committed alongside the code for future audits.
