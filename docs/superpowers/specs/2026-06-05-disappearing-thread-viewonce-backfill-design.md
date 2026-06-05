# v0.8.1 — Disappearing Thread-Through + View-Once Backfill

**Date:** 2026-06-05
**Status:** Approved (design)
**Topic:** Close two known v0.8.0 gaps — (1) thread chat-level
`ephemeralSec` into the six send paths still hardcoded to `0`
(reply / edit / forward-text / forward-media / reaction /
poll-vote), and (2) auto-replay history on first v0.8.1 boot so
pre-v0.8.0 view-once messages get re-classified and 1:1
disappearing timers hydrate without waiting for the next inbound.
Ships as a v0.8.1 patch; no user-visible feature surface.

## Goal

v0.8.0 shipped composer message types but left six send paths
unwrapped against the chat's disappearing timer. Reply, edit,
forward, reaction, and poll-vote messages sent from yawac in a
disappearing chat arrive on the recipient as **non-ephemeral** —
persisting beyond the timer, contrary to the chat's setting.

Two further v0.8.0 gaps both have the same upstream solution: a
fresh history replay. Whatsmeow's `BuildHistorySyncRequest`
builds an on-demand `*waE2E.Message` that, when sent to ownJID,
prompts the server to stream `events.HistorySync` for messages
older than a known anchor. Whatever those payloads carry flows
through the v0.8.0 classifier and `applyHistorySync` persist path,
which now correctly maps:

- `ViewOnceMessageV2` wrappers → `isViewOnce: true` on the
  re-merged `PersistedMessage`.
- `ContextInfo.Expiration` on any inbound message →
  `EphemeralTimerChanged` → `Chat.ephemeralExpirationSeconds`.

A single on-demand history sync triggered on first v0.8.1 boot
closes both holes.

## Non-goals

- **Per-message `ephemeralSec` override.** Chat-level only, same as
  v0.8.0.
- **New Settings "Rescan" button.** Backfill is automatic and
  one-shot; no UI surface.
- **Time-windowed backfill** (e.g. "last 90 days"). Pass a large
  count and let whatsmeow / server cap it.
- **Backwards-compat for older yawac builds.** v0.8.1 callers update;
  v0.8.0 callers continue compiling because the new `ephemeralSec`
  param defaults to `0` at the Swift wrapper layer.
- **Migrating already-revealed view-once rows back to "Tap to
  reveal" state.** Locked rows stay locked; backfill only touches
  rows where `viewOnceLocked == false`.
- **1:1 cold-read API.** Upstream limitation; backfill is the
  workaround.
- **Anonymous-poll handling, multi-contact share, live-location
  send.** Separate roadmap items.

## Architecture

Two subsystems share one spine.

```
┌─────────────────────────────────────────────────────────────┐
│ Composer + message-action paths (Swift)                      │
│ Each path now threads chat.ephemeralExpirationSeconds:       │
│   sendDraft (reply branch) — sendTextReply                   │
│   saveEdit                 — editText                        │
│   forward loop             — forwardText / forwardMedia      │
│   castVote                 — sendPollVote                    │
│   reactToMessage           — sendReaction                    │
│                                                              │
│ SessionViewModel boot:                                       │
│   if !historyBackfillCompleted → requestHistoryBackfill      │
└─────────────────────────────────────────────────────────────┘
              │ WAClient wrappers
              ▼
┌─────────────────────────────────────────────────────────────┐
│ bridge/messages.go: + ephemeralSec on                        │
│   SendTextReply, SendReaction, ForwardText, ForwardMedia     │
│ bridge/edit_revoke.go: + ephemeralSec on EditText (accepted  │
│   but NOT wrapped — protocol convention)                     │
│ bridge/polls.go: + ephemeralSec on SendPollVote              │
│                                                              │
│ bridge/history_request.go (new):                             │
│   RequestFullHistorySync(beforeChatJID, beforeMsgID,         │
│     beforeFromMe, beforeTSUnix, count)                       │
│ Inbound HistorySync flows through v0.8.0 classifier; existing│
│ applyHistorySync persists with isViewOnce + ContextInfo hints│
└─────────────────────────────────────────────────────────────┘
              │ whatsmeow
              ▼
   wrapForChat wraps inner *waE2E.Message in EphemeralMessage
   when ephemeralSec > 0 (same helper as v0.8.0 T1).
   BuildHistorySyncRequest(*types.MessageInfo, count) builds a
   ProtocolMessage; SendMessage(ownJID, msg) issues it.
```

### Disappearing thread-through

Six bridge funcs get `ephemeralSec int32` as the last positional
arg. Inside each body, build the inner `*waE2E.Message` as before,
then wrap via `wrapForChat(inner, ephemeralSec, false)` before
`SendMessage`. Identical pattern to v0.8.0 T5.

**EditText nuance.** WhatsApp's protocol convention is that edits
inherit the original message's expiration. The bridge accepts
`ephemeralSec` for signature consistency with the other five paths,
but **does not wrap** the resulting `ProtocolMessage`. Documented
inline; the param is reserved for a future protocol change.

Swift `WAClient` wrappers gain `ephemeralSeconds: Int32 = 0`
default param — existing non-CVM callers (if any) compile
unchanged.

### View-once + 1:1-timer backfill

`SessionViewModel.requestHistoryBackfillIfNeeded()` runs once on
the first `.connected` event after a v0.8.1 install:

1. Read `historyBackfillCompleted` `@AppStorage` flag. Return if
   already `true`.
2. Fetch the **globally-oldest** persisted message via a single
   SwiftData `FetchDescriptor` sorted by `timestamp ascending`,
   `fetchLimit = 1`.
3. If nothing is persisted, set the flag `true` and return.
4. Call `client.requestFullHistorySync(beforeChatJID:, beforeMsgID:,
   beforeFromMe:, beforeTSUnix:, count: 100_000)` off the main
   actor. Errors are silent (`Logger.bridge.warn`); flag stays
   `false`; next boot retries.
5. Whatsmeow streams one or more `events.HistorySync`. `ContentView`
   already routes those into `applyHistorySync`, which re-emits the
   raw `*waE2E.Message` payloads through the v0.8.0 classifier and
   into the existing upsert persist path.
6. On the **first** `HistorySync` arrival, `ContentView` sets the
   flag `true` via `UserDefaults.standard`. Subsequent paginated
   batches still flow through the persist path normally; the gate
   just prevents future boot re-requests.

**Anchor strategy.** Globally-oldest persisted message across all
chats. Single anchor → single sync request → server walks back.
This is whatsmeow's intended cursor semantic for
`BuildHistorySyncRequest`.

**Logout reset.** On `client.logout()`, clear
`historyBackfillCompleted` so a fresh re-link triggers a fresh
backfill against the new account's history.

## Bridge (Go)

### Six ephemeral-threaded sends

```go
// bridge/messages.go
func (c *Client) SendReaction(
    chatJID, targetMsgID, targetSenderJID string, targetFromMe bool,
    emoji string,
    ephemeralSec int32,
) (string, error)

func (c *Client) SendTextReply(
    chatJID, body, quotedID, quotedSenderJID string,
    quotedFromMe bool, quotedKind, quotedSnippet string,
    mentionedJIDsJSON string,
    ephemeralSec int32,
) (string, error)

func (c *Client) ForwardText(
    chatJID, text string,
    ephemeralSec int32,
) (string, error)

func (c *Client) ForwardMedia(
    chatJID, refJSON, caption, fileName string,
    ephemeralSec int32,
) (string, error)

// bridge/edit_revoke.go
//
// EditText: ephemeralSec accepted but NOT wrapped. WhatsApp protocol
// convention is that edits inherit the original message's expiration;
// no extra EphemeralMessage wrap is needed. Parameter is reserved for
// future protocol changes.
func (c *Client) EditText(
    chatJID, msgID, newBody, mentionedJIDsJSON string,
    ephemeralSec int32,
) (string, error)

// bridge/polls.go
func (c *Client) SendPollVote(
    chatJID, pollMsgID, pollSenderJID string, pollFromMe bool,
    selectedHashesJSON, pollOptionsJSON string,
    ephemeralSec int32,
) (string, error)
```

Body pattern for each (except `EditText`):

```go
inner := /* existing inner *waE2E.Message build */
msg := wrapForChat(inner, ephemeralSec, false)
resp, err := c.wa.SendMessage(context.Background(), jid, msg)
```

### New `RequestFullHistorySync` wrapper

`bridge/history_request.go` (new):

```go
// RequestFullHistorySync builds an on-demand history-sync request
// anchored on a known (chatJID, msgID, fromMe, ts) tuple and sends
// it to the user's own JID. The server replies with one or more
// events.HistorySync; existing applyHistorySync persists their
// messages through the v0.8.0 classifier (isViewOnce +
// ContextInfo.Expiration hint).
//
// count is the requested message count; whatsmeow and the server
// cap below the requested value in practice.
func (c *Client) RequestFullHistorySync(
    beforeChatJID, beforeMsgID string, beforeFromMe bool,
    beforeTSUnix int64,
    count int32,
) error {
    if c.wa == nil {
        return errors.New("client closed")
    }
    chat, err := types.ParseJID(beforeChatJID)
    if err != nil {
        return fmt.Errorf("parse chat: %w", err)
    }
    info := &types.MessageInfo{
        MessageSource: types.MessageSource{
            Chat:     chat,
            IsFromMe: beforeFromMe,
        },
        ID:        beforeMsgID,
        Timestamp: time.Unix(beforeTSUnix, 0),
    }
    req := c.wa.BuildHistorySyncRequest(info, int(count))
    if req == nil {
        return errors.New("nil history-sync request")
    }
    own := c.wa.Store.ID.ToNonAD()
    if _, err := c.wa.SendMessage(context.Background(), own, req); err != nil {
        return fmt.Errorf("send history-sync request: %w", err)
    }
    return nil
}
```

## Swift bridge (WAClient)

All seven wrappers (six threaded sends + `requestFullHistorySync`)
follow the v0.8.0 nonisolated pattern. Default-zero on the six
existing-signature funcs keeps non-call-site updates compiling.

```swift
nonisolated func sendReaction(chatJID: String,
                              targetMsgID: String,
                              targetSenderJID: String,
                              targetFromMe: Bool,
                              emoji: String,
                              ephemeralSeconds: Int32 = 0) throws -> SendResult

nonisolated func sendTextReply(chatJID: String,
                               body: String,
                               quotedID: String,
                               quotedSenderJID: String,
                               quotedFromMe: Bool,
                               quotedKind: String,
                               quotedSnippet: String,
                               mentionedJIDs: [String] = [],
                               ephemeralSeconds: Int32 = 0) throws -> SendResult

nonisolated func editText(chatJID: String,
                          msgID: String,
                          newBody: String,
                          mentionedJIDs: [String] = [],
                          ephemeralSeconds: Int32 = 0) throws -> SendResult

nonisolated func forwardText(chatJID: String,
                             text: String,
                             ephemeralSeconds: Int32 = 0) throws -> SendResult

nonisolated func forwardMedia(chatJID: String,
                              refJSON: String,
                              caption: String,
                              fileName: String,
                              ephemeralSeconds: Int32 = 0) throws -> SendResult

nonisolated func sendPollVote(chatJID: String,
                              pollMsgID: String,
                              pollSenderJID: String,
                              pollFromMe: Bool,
                              selectedHashesJSON: String,
                              pollOptionsJSON: String,
                              ephemeralSeconds: Int32 = 0) throws -> SendResult

nonisolated func requestFullHistorySync(beforeChatJID: String,
                                        beforeMsgID: String,
                                        beforeFromMe: Bool,
                                        beforeTSUnix: Int64,
                                        count: Int32) throws
```

## CVM call-site updates

Five sites pass `self.ephemeralExpirationSeconds` (existing v0.8.0
property on `ConversationViewModel`):

```swift
// sendDraft reply branch (~line 1159)
try client.sendTextReply(
    chatJID, body: text,
    quotedID: q.id, quotedSenderJID: q.senderJID,
    quotedFromMe: q.fromMe, quotedKind: q.kind,
    quotedSnippet: q.snippet,
    mentionedJIDs: mentioned,
    ephemeralSeconds: ephemeralExpirationSeconds)

// saveEdit (~line 1751)
try client.editText(
    chatJID: chatJID, msgID: target.id, newBody: newBody,
    mentionedJIDs: mentioned,
    ephemeralSeconds: ephemeralExpirationSeconds)

// reactToMessage
try client.sendReaction(
    chatJID: chatJID, targetMsgID: msgID,
    targetSenderJID: senderJID, targetFromMe: fromMe,
    emoji: emoji,
    ephemeralSeconds: ephemeralExpirationSeconds)

// castVote
try client.sendPollVote(
    chatJID: chatJID,
    pollMsgID: pollMsgID, pollSenderJID: pollSenderJID,
    pollFromMe: pollFromMe,
    selectedHashesJSON: selectedHashesJSON,
    pollOptionsJSON: pollOptionsJSON,
    ephemeralSeconds: ephemeralExpirationSeconds)
```

### Forward edge case

Forward sends to a **different chat** than the source. The
ephemeral timer must come from the **destination** chat, not the
source. New private helper:

```swift
private func dstEphemeralSec(_ dstJID: String) -> Int32 {
    session.chatList?.chats.first(where: { $0.jid == dstJID })?
        .ephemeralExpirationSeconds ?? 0
}
```

Forward loop sites:

```swift
// ~line 347
try client.forwardText(
    chatJID: dstJID,
    text: m.text,
    ephemeralSeconds: dstEphemeralSec(dstJID))

// ~line 352
try client.forwardMedia(
    chatJID: dstJID, refJSON: refJSON,
    caption: caption, fileName: fileName,
    ephemeralSeconds: dstEphemeralSec(dstJID))
```

Reaction destination = same chat as the target → uses
`self.ephemeralExpirationSeconds`.

## `SessionViewModel` — backfill gate

```swift
@AppStorage("historyBackfillCompleted") private var historyBackfillCompleted = false

// In the existing .connected event arm (next to refreshAllAdminApprovalGroups):
case .connected:
    Task { await self.refreshAllAdminApprovalGroups() }
    Task { await self.requestHistoryBackfillIfNeeded() }
```

```swift
@MainActor
private func requestHistoryBackfillIfNeeded() async {
    guard !historyBackfillCompleted else { return }
    guard let client else { return }
    guard let context = modelContext else { return }
    var d = FetchDescriptor<PersistedMessage>(
        sortBy: [SortDescriptor(\.timestamp, order: .forward)])
    d.fetchLimit = 1
    guard let oldest = (try? context.fetch(d))?.first else {
        // First-ever launch — nothing to backfill. Mark complete
        // so the next boot doesn't waste an IQ once a message
        // arrives.
        historyBackfillCompleted = true
        return
    }
    do {
        try await Task.detached { [client] in
            try client.requestFullHistorySync(
                beforeChatJID: oldest.chatJID,
                beforeMsgID: oldest.id,
                beforeFromMe: oldest.fromMe,
                beforeTSUnix: Int64(oldest.timestamp.timeIntervalSince1970),
                count: 100_000)
        }.value
    } catch {
        Logger.bridge.warn("history backfill request failed: \(error)")
        return
    }
    // Flag flipped on first HistorySync arrival — see ContentView.
}
```

Logout handler clears the flag:

```swift
// In logout / re-link path
historyBackfillCompleted = false
```

## `ContentView` — flag flip on first HistorySync

Add to the existing event-fanout `task`:

```swift
case .historySync(let conversations):
    if !UserDefaults.standard.bool(forKey: "historyBackfillCompleted") {
        UserDefaults.standard.set(true, forKey: "historyBackfillCompleted")
    }
    // ... existing HistorySync handling (uses conversations) ...
```

Reading via `UserDefaults` avoids passing the `@AppStorage`
binding across actors; SwiftUI re-reads the SessionViewModel
property at next access.

## Data flow

| Step | Trigger | Effect |
|---|---|---|
| 1 | `.connected` event after v0.8.1 upgrade | `requestHistoryBackfillIfNeeded` reads flag |
| 2 | Flag is `false` + persisted store non-empty | Bridge issues `RequestFullHistorySync` against oldest anchor |
| 3 | Server streams `HistorySync` | `applyHistorySync` re-emits per-message payloads |
| 4 | Classifier marks `isViewOnce` + emits `EphemeralTimerChanged` per ContextInfo | Persist upsert flips `isViewOnce`, ChatListVM updates `Chat.ephemeralExpirationSeconds` |
| 5 | First `HistorySync` reaches `ContentView` | Flag flipped to `true` |
| 6 | Subsequent batches | Persist normally; no re-trigger |

Locked view-once rows (`viewOnceLocked == true`) keep their state
— the upsert check that gates "only update isViewOnce when the
existing row's flag is false" prevents stomping. (Per v0.8.0
upsert path at `ChatListViewModel.swift:381`.)

## Admin gating

| Surface | Gating |
|---|---|
| Six threaded sends | None — chat-level ephemeral applies to all senders |
| Backfill request | None — fires once per install, silently |
| HistorySync event arm | None — already processes events client-wide |

## Error handling

| Surface | Pattern |
|---|---|
| Six threaded sends | Existing per-send error surface (toast / system row) |
| `EditText` (param ignored) | Bridge inline comment; no runtime surface |
| `RequestFullHistorySync` IQ failure | Silent; `Logger.bridge.warn`. Flag stays `false` → next boot retries |
| `HistorySync` event never arrives | Flag stays `false`. Endless retry on each boot (cheap; one IQ each) |
| Fetch oldest persisted fails | Flag flipped `true` (empty store → nothing to backfill) |

## Testing

### `bridge/messages_test.go`, `bridge/edit_revoke_test.go`, `bridge/polls_test.go` extensions

- Each of the six funcs: unpaired-client → error.
- `SendTextReply` / `SendReaction` / `SendPollVote` / `ForwardText`
  / `ForwardMedia` with `ephemeralSec > 0` → wrap inspection via
  the v0.8.0 `wrapForChat` golden-string pattern.
- `EditText` with `ephemeralSec > 0` → asserts the dispatched
  `*waE2E.Message` is **NOT** wrapped (documented deferral).

### `bridge/history_request_test.go` (new)

- `RequestFullHistorySync` unpaired-client → error.
- Bad `beforeChatJID` → parse error.
- Path: stub `BuildHistorySyncRequest` returns non-nil
  `*waE2E.Message`; the wrapper sends it. Assert target is
  `Store.ID.ToNonAD()` (own JID).

### `yawacTests/`

- `ConversationViewModelSendDispatchTests` extended:
  - Reply send threads `ephemeralExpirationSeconds` into
    `sendTextReply`.
  - Edit threads via `editText`.
  - Reaction threads via `sendReaction`.
  - PollVote threads via `sendPollVote`.
  - Forward uses **destination** chat's
    `ephemeralExpirationSeconds`, not the source.
- `SessionViewModelBackfillTests` (new):
  - First boot: flag `false` → `requestFullHistorySync` called
    with oldest persisted anchor.
  - Subsequent boot with flag `true` → no call.
  - Empty persisted store → flag flipped `true` without an IQ.
  - `.historySync` event arm flips flag from `false` → `true`.

### Manual smoke

- Boot v0.8.1 on an account with a 24-hour timer on chat X. Send a
  reply → recipient phone shows the reply disappearing at 24h.
- Forward a message into a 7-day chat from a 24h chat → recipient
  phone shows 7-day expiration.
- Reaction in disappearing chat → recipient phone applies
  retention.
- Edit a message in disappearing chat → recipient phone keeps the
  original message's expiration unchanged.
- Send poll vote in disappearing chat → recipient phone applies
  retention.
- Verify in
  `~/Library/Containers/dev.vadikas.yawac.yawac/Data/.../Defaults`
  that `historyBackfillCompleted` flips to `true` after first
  connect post-upgrade.
- Inspect log: `HistorySync` arrives. Verify a previously-stored
  view-once row's `isViewOnce` flips to `true` via SwiftData
  browser.
- A 1:1 chat whose timer was set on phone but never observed in
  yawac → ChatInfoView "Disappearing messages" picker reflects the
  actual timer post-backfill.
- Logout → relink different number → flag reset → fresh backfill
  fires on next `.connected`.

## Open risks

- **Edit wrap deferral.** Bridge accepts `ephemeralSec` but
  doesn't wrap. WhatsApp protocol convention is that edits inherit
  the original's expiration; if upstream behavior changes we have
  a clean place to flip wrapping.
- **Backfill bandwidth.** `count = 100_000` is large. Whatsmeow /
  server caps below the requested value in practice. Worst case
  even if not capped: one boot streams a lot. Persist path is
  upsert-keyed, so CPU + bandwidth only.
- **`@AppStorage` scope.** `historyBackfillCompleted` is
  per-installation, NOT per-account. Logout clears it; re-link
  triggers a fresh backfill.
- **`BuildHistorySyncRequest` nil return.** Bridge surfaces an
  error so the flag stays `false` and the next boot retries.
- **`HistorySync` arrival count.** Whatsmeow may stream multiple
  events per request. The flag is set on the FIRST arrival
  post-request; subsequent paginated batches still flow through
  the persist path normally.
- **CVM call-site coverage.** Six explicit ephemeralSec passes; a
  missed site = regression. Tests pin each one.
- **Locked view-once rows are NOT re-unlocked.** Backfill only
  flips `isViewOnce` on rows where `viewOnceLocked == false`,
  preserving the v0.8.0 semantic that locked rows stay locked.

## Files touched

**New:**

- `bridge/history_request.go` — `RequestFullHistorySync`.
- `bridge/history_request_test.go` — wrapper tests.
- `yawacTests/SessionViewModelBackfillTests.swift`.

**Modified:**

- `bridge/messages.go` — `SendTextReply`, `ForwardText`,
  `ForwardMedia`, `SendReaction` signatures extended.
- `bridge/edit_revoke.go` — `EditText` signature extended (param
  accepted, not wrapped).
- `bridge/polls.go` — `SendPollVote` signature extended.
- `bridge/messages_test.go`, `bridge/edit_revoke_test.go`,
  `bridge/polls_test.go` — call-site updates + new wrap-assertion
  tests.
- `yawac/Bridge/WAClient.swift` — six wrapper signature extensions
  + `requestFullHistorySync` wrapper.
- `yawac/ViewModels/ConversationViewModel.swift` — five call sites
  thread `ephemeralExpirationSeconds`, plus `dstEphemeralSec(_:)`
  helper for forward destination lookup.
- `yawac/ViewModels/SessionViewModel.swift` —
  `historyBackfillCompleted` `@AppStorage` flag,
  `requestHistoryBackfillIfNeeded()` method, `.connected` arm
  extension. Logout handler clears the flag.
- `yawac/ContentView.swift` — `.historySync` event arm flips the
  flag.
- `yawacTests/ConversationViewModelSendDispatchTests.swift` —
  extended with reply / edit / forward / reaction / poll-vote
  dispatch tests.
- `project.yml` — bump `CFBundleShortVersionString` 0.8.0 → 0.8.1,
  `CFBundleVersion` 9 → 10.
- `docs/ROADMAP.md` — strike the threaded-send gaps + the
  pre-v0.8.0 backfill gap on merge.
