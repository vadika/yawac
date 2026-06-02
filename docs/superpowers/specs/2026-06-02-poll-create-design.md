# Poll creation — design

Date: 2026-06-02
Status: draft (pending review)

## Goal

Let yawac users create polls in any DM or group chat. The receive,
display, vote-cast, and tally-hydrate paths already exist; this work
adds the missing create path so the feature reaches WhatsApp parity for
the v1 scope below.

## Scope

In:

- "New poll…" entry from the composer's attachment menu.
- Modal sheet with question + 2–12 options + multi-select toggle.
- Bridge → whatsmeow `BuildPollCreation` + `SendMessage`.
- Optimistic local bubble + persistence so the poll survives restart.
- Revoke via the existing context menu (no special-case path).

Deferred:

- Edit poll (`EncSecretPollEdit` — no high-level whatsmeow builder).
- Add option after create (`EncSecretPollAddOption` — same).
- Drag-to-reorder option rows.
- Pre-pair tally recovery (documented unrecoverable in `docs/TODO.md`).
- Multi-select voting UX batch-submit (separate UX bug; tracked in
  `docs/TODO.md`).

Out of scope: changing the receive / vote / display surface. Those are
already shipped and are reused as-is.

## User flow

1. User clicks the paperclip in the composer.
2. The paperclip is now a `Menu` with two items: **Attach file…** and
   **New poll…**.
3. Selecting "New poll…" opens a sheet:
   - **Question** — single TextField, 255-char cap.
   - **Options** — a list of TextFields, 100-char cap each, starting
     with two empty rows. A new empty row appears once the previous
     last row becomes non-empty, capped at 12 rows total. Each row has
     a remove (⊖) affordance, disabled while only two rows exist.
   - **Allow multiple answers** — toggle, default off.
   - **Cancel** / **Create** buttons. `⌘↩` triggers Create; `Esc`
     dismisses.
4. Create disables until: question is non-empty, ≥ 2 non-empty options
   remain after trimming.
5. On Create, the sheet stays open with a disabled button while the
   send is in flight. On success the sheet dismisses and the new poll
   bubble appears at the bottom of the chat. On failure the sheet stays
   open and `transientError` is set (existing banner path).
6. The created poll renders in the existing `MessageRow.pollView`. The
   creator can vote on their own poll via the existing path.

## Architecture

```
ComposerView (paperclip Menu)
       │
       ▼
PollComposerView (sheet)        question, options, allowMultiple
       │ Create
       ▼
ConversationViewModel.sendPoll(question, options, allowMultiple)
       │
       ▼
WAClient.sendPollCreation(chatJID, question, options, selectableCount)
       │   selectableCount = allowMultiple ? 0 : 1
       ▼
bridge.SendPollCreation
       │   BuildPollCreation → SendMessage
       ▼   returns { message_id, timestamp, poll: JPoll }
ConversationViewModel
   appends UIMessage(body: .poll(...))
   persistOutgoingPoll(m, pollJSON)
       │
       ▼
MessageRow.pollView (existing)
PersistedPollVote hydration (existing)
```

The pollJSON returned by the bridge is the authoritative copy: the
bridge runs `extractPoll` on the message it just built so the
SHA256(name) hashes match exactly what peers will compute when they
vote. This avoids any chance of Swift-vs-Go hash drift.

## Bridge surface

### New Go function

`bridge/polls.go`:

```go
// SendPollCreation creates a poll in chatJID. optionsJSON is a JSON
// array of option-name strings. selectableCount = 0 means multi-select
// (WhatsApp convention), 1 means single. Returns JSON of
// JSendPollResult { MessageID, Timestamp, Poll }.
//
// Validation is intentionally strict here even though the UI also
// validates: whatsmeow's BuildPollCreation silently clamps
// selectableOptionCount to 0 on bad input (see msgsecret.go:326), which
// would hide programmer errors. Surface them explicitly.
func (c *Client) SendPollCreation(
    chatJID, question, optionsJSON string,
    selectableCount int,
) (string, error)
```

Steps:

1. Guard `c.wa == nil`.
2. `types.ParseJID` + reject if `User == "" || Server == ""`.
3. Unmarshal `optionsJSON` into `[]string`.
4. Trim each option + question. Reject if `len(question) == 0` after
   trim, or any option is empty after trim, or `len(options) < 2`, or
   `len(options) > 12`.
5. Reject `selectableCount` outside `0..len(options)`. (Tighter than
   whatsmeow's silent clamp.)
6. `msg := c.wa.BuildPollCreation(question, options, selectableCount)`.
7. `resp, err := c.wa.SendMessage(ctx, jid, msg)` — on error,
   `fmt.Fprintf(os.Stderr, "[yawac/poll-create] chat=%s opts=%d err=%v\n", ...)`.
8. Build a `JPoll` via the existing `extractPoll(msg)` so option hashes
   are identical to the wire form.
9. Marshal `JSendPollResult{ MessageID: resp.ID, Timestamp:
   resp.Timestamp.Unix(), Poll: *jp }` and return.

### New JSON type

`bridge/jsonmodels.go`:

```go
type JSendPollResult struct {
    MessageID string `json:"message_id"`
    Timestamp int64  `json:"timestamp"`
    Poll      JPoll  `json:"poll"`
}
```

(`JPoll` and `JPollOption` already exist and are returned for incoming
polls.)

## Swift surface

### Bridge wrapper

`yawac/Bridge/WAClient.swift`:

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

func sendPollCreation(
    _ chatJID: String,
    question: String,
    options: [String],
    selectableCount: Int
) throws -> BridgeSendPollResult {
    let optsData = try JSONEncoder().encode(options)
    guard let optsJSON = String(data: optsData, encoding: .utf8) else {
        throw BridgeError.encode
    }
    let json = go.sendPollCreation(
        chatJID, question, optsJSON, selectableCount)
    return try decodeBridgeResult(json)
}
```

Follow the same JSON-error decoding pattern other bridge calls use
(`decodeBridgeResult` exists in the codebase).

### View-model

`yawac/ViewModels/ConversationViewModel.swift`:

```swift
var showPollComposer: Bool = false

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
            timestamp: Date(timeIntervalSince1970:
                TimeInterval(res.timestamp)),
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
        id: m.id, chatJID: m.chatJID, senderJID: m.senderJID,
        fromMe: m.fromMe, timestamp: m.timestamp,
        kind: "poll", text: nil,
        pollJSON: pollJSON)
    context.insert(row)
    try? context.save()
    MessageIndex.shared.upsert(row.indexFields)
}
```

`persistOutgoingPoll` mirrors `persistOutgoing` but stores `kind:
"poll"` and `pollJSON`. The existing reload path
(`ConversationViewModel.swift:464-473`) already decodes `pollJSON` into
`.poll(...)` so no read-side change is needed.

### Composer menu

`yawac/Views/ComposerView.swift` — replace the paperclip `Button` in
`inputRow` with:

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
        Label("New poll…",
              systemImage: "chart.bar.doc.horizontal")
    }
} label: {
    Image(systemName: "paperclip")
        .scaledIcon(15, weight: .regular)
        .foregroundStyle(Theme.textMuted)
        .padding(4)
}
.menuStyle(.borderlessButton)
.menuIndicator(.hidden)
.help("Attach")
```

`ConversationView` attaches the sheet:

```swift
.sheet(isPresented: $vm.showPollComposer) {
    PollComposerView(vm: vm)
}
```

### Sheet

`yawac/Views/PollComposerView.swift` (new):

```swift
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

    private var trimmedOptions: [String] {
        options.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && trimmedOptions.count >= 2
            && !sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            questionField
            optionList
            Toggle("Allow multiple answers", isOn: $allowMultiple)
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: options) { _, _ in
            autoGrow()
        }
    }

    // header: title "New poll"
    // questionField: TextField + char counter
    // optionList: ForEach with TextField + remove button per row
    // footer: Cancel + Create buttons; Create runs vm.sendPoll
    //
    // autoGrow: if last row is non-empty and options.count < maxOptions,
    //   append "". If user empties a middle row, leave it (manual ⊖).
    //
    // Per-row truncation: .onChange(of: options[i]) clamps to optionCap.
    // Question truncation: same pattern for questionCap.
}
```

Behaviour details kept in the implementation plan; the spec only
fixes the shape.

## Persistence

`PersistedMessage.pollJSON` already exists; no schema change. The
outgoing-poll row is inserted with `kind: "poll"` and the bridge's
`poll_json` blob, so reload (`reloadMessages`) decodes it through the
same path used for incoming polls.

`PersistedPollVote` is keyed on `pollMessageID`; since the outgoing
message ID is the same ID peers vote against, tally hydration for own
polls already works.

## Validation

Three layers because whatsmeow silently clamps `selectableCount`:

| Layer            | Check                                            |
|------------------|--------------------------------------------------|
| Sheet (SwiftUI)  | char caps, row cap 12, Create disabled state    |
| ViewModel        | trim, drop empty options, ≥ 2 / ≤ 12 guard      |
| Bridge (Go)      | trim, empty / size / selectableCount range, JID  |

Tight by design: UI-only validation hides bugs at the bridge boundary.

## Errors

- Closed client / bad JID / validation failure: returned as Go errors,
  surface to Swift as thrown errors, surface to user as
  `transientError` (existing banner).
- Sheet stays open during in-flight send (`sending` flag) so the user
  can correct + retry.
- Successful send: dismiss sheet, clear state.

## Logging

- On send error in `SendPollCreation`:
  ```
  [yawac/poll-create] chat=%s opts=%d multi=%v err=%v
  ```
  Match the existing `[yawac/poll-vote]` log shape.

## Testing

### Go (`bridge/polls_test.go`)

Validation-only — same pattern as `TestSendTextRejectsBadJID`, no live
`SendMessage`:

- bad JID rejected
- closed client rejected
- `options.len < 2` rejected
- `options.len > 12` rejected
- empty / whitespace-only option rejected
- `selectableCount` outside `0..len` rejected (test: -1, len+1)

### Swift (`yawacTests`)

- `sendPoll` trims question + options, drops empty rows
- `sendPoll` with < 2 valid options is a no-op
- `sendPoll(allowMultiple: true)` → `selectableCount = 0`
- `sendPoll(allowMultiple: false)` → `selectableCount = 1`
- `PollComposerView` auto-grow tops out at 12

### Manual

- DM: create single-select; vote from peer; tally renders.
- DM: create multi-select; vote multiple from peer; all show.
- Group: create; vote from multiple devices; tally aggregates.
- Revoke an own poll via context menu — bubble shows revoked state.
- Long-text paste truncates at caps.
- Cancel mid-compose discards.
- Force-disconnect Wi-Fi during Create → `transientError` shows, sheet
  stays open, retry works after reconnect.
- Restart app: own poll persists with question + options.

## Files touched

| Path                                                | Change                              |
|-----------------------------------------------------|-------------------------------------|
| `bridge/polls.go`                                   | + `SendPollCreation`                |
| `bridge/jsonmodels.go`                              | + `JSendPollResult`                 |
| `bridge/polls_test.go`                              | + validation tests                  |
| `yawac/Bridge/WAClient.swift`                       | + `sendPollCreation` + result type  |
| `yawac/ViewModels/ConversationViewModel.swift`      | + `sendPoll`, `persistOutgoingPoll`, `showPollComposer` |
| `yawac/Views/ComposerView.swift`                    | paperclip Button → Menu             |
| `yawac/Views/ConversationView.swift`                | + sheet presentation                |
| `yawac/Views/PollComposerView.swift`                | new file                            |
| `docs/ROADMAP.md`                                   | flip "Polls — create" to ✅         |

## Risks / open issues

- **whatsmeow silent clamp** on `selectableCount` (`msgsecret.go:326`,
  TODO L123-124) — mitigated by bridge-side rejection before the call.
- **LID-migration silent vote-decrypt** (`msgsecret.go:115`, TODO
  L128) — pre-existing; this work does not touch it.
- **No send echo from whatsmeow for own messages.** Same shape as
  `sendDraft` / media send: we insert optimistically + persist. If the
  bridge rewrote the wire-message between `BuildPollCreation` and
  `SendMessage` our local copy would drift. The bridge does not do
  this today; documented as an assumption.
- **Sheet dismissed mid-send**: the in-flight task still finishes and
  persists; the bubble appears later. Acceptable v1 behavior.

## Future work

- Edit / add-option (`EncSecretPollEdit` / `EncSecretPollAddOption`)
  require building wire frames without high-level whatsmeow helpers —
  follow-up.
- Drag-to-reorder options.
- Multi-select voting batch-submit UX (TODO L252-253).
