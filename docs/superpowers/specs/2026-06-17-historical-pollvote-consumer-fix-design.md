# HistoricalPollVote Consumer Fix — Design

**Date:** 2026-06-17
**Status:** Draft → spec
**Roadmap entry:** Communication → Polls → "Cross-device own-vote re-render from `HistoricalPollVote` event (after history sync the user's own selection may show empty until they vote again)."

## Goal

Surface own historical poll votes in the bubble after a history sync. F88 wired the fork's PR #1151 helper (`events.HistorySync.HistoricalPollUpdates()`) end-to-end through bridge → Swift event → SQLite → snapshot hydration → bubble renderer, but the bridge's voter-substitution gate was wrong, so peer-poll own-votes persist with an empty `voterJID` and never match `mySelections()`.

## Background

F88 (v0.10.15) cherry-picked PR #1151. The fork's helper at `types/events/historicalpollvotes.go` exposes a `HistoricalPollVote` struct with fields:

- `Chat types.JID`
- `PollCreationID types.MessageID`
- `Voter types.JID` — set from `PollUpdateMessageKey.Participant` if present, OR from `chatJID` for 1:1 peer votes (`!voteKey.FromMe`), OR **left empty when `voteKey.FromMe` is true**.
- `SelectedOptionHashes [][]byte`
- `Timestamp time.Time`
- `PollCreationFromMe bool` — reflects who **created the poll**, not who cast the vote.

The bridge in `bridge/history.go:138` gates self-vote substitution on `r.PollCreationFromMe`:

```go
if voterStr == "" && r.PollCreationFromMe &&
    c.wa != nil && c.wa.Store != nil && c.wa.Store.ID != nil {
    voterStr = c.wa.Store.ID.ToNonAD().String()
}
```

This only substitutes when **we created the poll AND voter is empty**. But the helper leaves voter empty whenever the vote update has `FromMe=true`, regardless of who created the poll. Failure case: peer creates poll, we vote → `PollCreationFromMe=false`, `Voter=zero` → bridge skips substitution → vote persists with `voterJID=""` → `mySelections()` keyed against `client.ownJID` finds nothing → bubble shows we didn't vote, even though we did.

## Existing wiring (audit summary)

| Layer | File:Line | State |
|---|---|---|
| Bridge sweep helper | `bridge/history.go:118` | ✅ F88 |
| Bridge → Swift event | `bridge/history.go:154` `c.dispatch("PollVote", ...)` | ✅ |
| Swift event parse | `yawac/Bridge/WAClient.swift:1112` | ✅ |
| In-memory `applyPollVote` (chat open) | `yawac/Views/ConversationView.swift:779` | ✅ |
| SQLite persist (always) | `yawac/ViewModels/SessionViewModel.swift:721` → `SQLiteDedupe.upsertPollVote` | ✅ |
| SwiftData model + indices | `PersistedPollVote` + `yawac_idx_poll_msg` | ✅ |
| Snapshot hydration | `buildHistorySnapshot` line 1060 | ✅ |
| Bubble renderer | `mySelections(for:)` line 2867 | ✅ |
| **Bridge tests** | `bridge/history_test.go` | ❌ absent |
| **Swift tests for poll-vote round-trip / snapshot** | `yawacTests/` | ❌ absent |
| **Empirical verification** | — | ❌ |

Self-vote keying form is consistent across bridge and Swift: `c.wa.Store.ID.ToNonAD().String()` (Go) ↔ `client.ownJID` (Swift) both resolve to the bare PN form. No JID-canonicalization gap.

## Decision

Drop the `PollCreationFromMe` gate. Extract the per-record translation into a pure helper so it can be tested without a `*Client`. Substitute `ownBareJID` for any empty `voterStr`. Log per-sweep counts. Add tests on both sides. Empirical verify via existing `/tmp/yawac.log` instrumentation + the user-facing Full sync button.

## Architecture

Single-pass mapping `[]events.HistoricalPollVote → []JPollVote` via a pure helper, dispatched through the existing channel. Caller hands the helper a `(record, ownBareJID)` pair; helper returns a fully-populated `JPollVote` with `VoterJID` substituted to `ownBareJID` whenever `r.Voter` is the zero `types.JID`. No state, no side effects, no `*Client` reference. Bridge counters tracked locally in the sweep and logged once per blob.

## Components

### 1. `bridge/history.go` — pure translator

```go
// historicalRecordToVote maps one HistoricalPollVote record into the
// JPollVote payload that mirrors live PollUpdateMessage dispatches.
// Empty r.Voter signals an own-vote (the upstream helper sets Voter
// only when PollUpdateMessageKey.Participant is set, OR when the chat
// is 1:1 and the vote is NOT from us — see fork PR #1151's
// HistoricalPollUpdates source). When the helper leaves Voter empty,
// the only consistent interpretation is "vote from us"; substitute
// ownBareJID so the Swift mySelections() lookup against client.ownJID
// finds the row.
func historicalRecordToVote(r events.HistoricalPollVote, ownBareJID string) JPollVote {
    voterStr := r.Voter.String()
    if voterStr == "" {
        voterStr = ownBareJID
    }
    hashes := make([]string, 0, len(r.SelectedOptionHashes))
    for _, h := range r.SelectedOptionHashes {
        hashes = append(hashes, hex.EncodeToString(h))
    }
    return JPollVote{
        ChatJID:       r.Chat.String(),
        PollMessageID: r.PollCreationID,
        VoterJID:      voterStr,
        OptionHashes:  hashes,
        Timestamp:     r.Timestamp.Unix(),
    }
}
```

`emitHistoricalPollUpdatesFromBlob` reduces to:

```go
func (c *Client) emitHistoricalPollUpdatesFromBlob(evt *events.HistorySync) {
    records := evt.HistoricalPollUpdates()
    if len(records) == 0 {
        return
    }
    var ownBareJID string
    if c.wa != nil && c.wa.Store != nil && c.wa.Store.ID != nil {
        ownBareJID = c.wa.Store.ID.ToNonAD().String()
    }
    var selfN, peerN int
    for _, r := range records {
        v := historicalRecordToVote(r, ownBareJID)
        if v.VoterJID == ownBareJID && ownBareJID != "" {
            selfN++
        } else {
            peerN++
        }
        b, _ := json.Marshal(v)
        c.dispatch("PollVote", string(b))
    }
    fmt.Fprintf(os.Stderr,
        "[yawac/poll-history] sweep records=%d self=%d peer=%d\n",
        len(records), selfN, peerN)
}
```

Note: `selfN` increments only when the substitution actually happened AND we're paired. When `ownBareJID==""` (unpaired), empty-voter rows count as `peerN` so the log doesn't lie about substitutions.

### 2. `bridge/history_test.go` (new)

Table-driven test of `historicalRecordToVote`. Cases:

| Case | `Voter` | `PollCreationFromMe` | Expected `VoterJID` |
|---|---|---|---|
| Own vote on own poll | zero JID | `true` | `ownBareJID` |
| Own vote on peer poll (regression guard for F88 bug) | zero JID | `false` | `ownBareJID` |
| Peer vote on peer poll (1:1) | `chatJID` (peer) | `false` | peer's JID |
| Peer vote on own poll (1:1) | `chatJID` (peer) | `true` | peer's JID |
| Peer vote in group | `participantJID` | `false` | participant's JID |
| Hash encoding | any | any | `OptionHashes` hex-encodes `SelectedOptionHashes` |
| Timestamp preservation | `t = unix(1729000000)` | any | `Timestamp == 1729000000` |

Test file uses `t.Run(name, ...)` per case. Bridge test scaffolding follows existing `bridge/polls_test.go` style.

### 3. `yawacTests/ConversationViewModelPollHistoryTests.swift` (new)

Two test groups:

**applyPollVote round-trip.**
- Construct a `StubPollHistoryClient: WAClient` that overrides `ownJID` (same pattern as `StubSelfChatClient` in `yawacTests/SessionViewModelSelfChatTests.swift`) returning `"11234567890@s.whatsapp.net"`.
- Build CVM with that stub.
- Call `vm.applyPollVote(pollMessageID: "p", voterJID: "11234567890@s.whatsapp.net", optionHashes: ["h1", "h2"])`.
- Assert `vm.mySelections(for: "p") == Set(["h1", "h2"])`.

**Snapshot hydration.**
- Spin up an in-memory `ModelContainer` for `[PersistedMessage.self, PersistedPollVote.self, ...]` per existing test scaffolding.
- Insert a `PersistedPollVote(chatJID: c, pollMessageID: "p", voterJID: "11234567890@s.whatsapp.net", optionHashesJSON: "[\"h1\"]")`.
- Insert a `PersistedMessage` row for the poll with `id="p", kind="poll"`.
- Drive `buildHistorySnapshot` for that chat.
- Assert `snap.pollVotes["p"]?["h1"]?.contains("11234567890@s.whatsapp.net") == true`.

Stub follows the established subclass-override pattern: `final class StubPollHistoryClient: WAClient { private let stub: String; override var ownJID: String { stub }; init(...) }`.

### 4. Bridge log instrumentation

Existing single log line `[yawac/poll-history] sweep %d records` is extended in-place to `[yawac/poll-history] sweep records=%d self=%d peer=%d`. Same prefix used by F83 OfflineSync instrumentation so `/tmp/yawac.log` greps stay consistent.

## Data flow

```
HistorySync blob
  ↓ events.HistorySync.HistoricalPollUpdates() (fork PR #1151)
[]events.HistoricalPollVote
  ↓ historicalRecordToVote(r, ownBareJID)   ← surgical fix lives here
[]JPollVote
  ↓ c.dispatch("PollVote", json) per record
WAClient.Event.pollVote
  ↓ split into TWO sinks (existing F88 architecture)
SessionViewModel.persistPollVote     ConversationView.event (if chat open)
  ↓                                     ↓
SQLiteDedupe.upsertPollVote          vm.applyPollVote (in-memory dict)
  ↓
PersistedPollVote row
  ↓ (chat opened later)
buildHistorySnapshot — fetch by visible pollIDs
  ↓
snapshot.pollVotes seed → vm.pollVotes
  ↓
PollOptionRow.tally(for:) + mySelections(for:) → bubble renders highlight
```

## Error handling

- **Unpaired client.** `c.wa.Store.ID == nil` → `ownBareJID == ""`. Translator still produces `VoterJID=""`. Swift `applyPollVote` ingests with empty voter; `mySelections()` short-circuits on empty `me`. No crash, no spurious highlight, no data loss — the SQLite row is recoverable on the next sweep when paired.
- **Nil blob.** `events.HistorySync.HistoricalPollUpdates()` returns nil for `h.Data == nil`. Existing `if len(records) == 0` early-return preserved.
- **Hash decode failure on snapshot hydration.** Existing `guard let data = ...; let hashes = try? JSONDecoder().decode(...)` falls through with `continue` (unchanged).
- **Empty `SelectedOptionHashes`.** Represents a vote-clear from the peer (or us). Translator emits the empty array; `applyPollVote` removes the voter from all hash buckets, matching WhatsApp's "latest vote replaces priors" semantics already implemented.

## Testing

**Go:** `go test ./bridge/...` covers the translator. Seven cases (five voter-derivation, one hash encoding, one timestamp).

**Swift:** `yawacTests/ConversationViewModelPollHistoryTests.swift` covers in-memory `applyPollVote` + SwiftData snapshot hydration. In-memory `ModelContainer` per F45 pattern.

**Empirical verification.** Launch yawac on the existing paired account, tap **Full sync** in the settings (drives the deep-history backfill), observe `[yawac/poll-history] sweep records=N self=M peer=K` in `/tmp/yawac.log`. `self > 0` confirms substitutions fired. Re-open a chat with a known poll the user previously voted on from the phone; bubble should highlight chosen options.

## Out of scope

- Cross-device-sync own outbound *live* edits/reactions (separate roadmap entry).
- Anonymous polls (whatsmeow exposes no toggle).
- Upstream PR to add `UpdateFromMe bool` on `HistoricalPollVote` to remove the empty-voter inference (would be nicer but the fork already carries PR #1151; sending an upstream amendment is a separate effort that depends on whether tulir wants the change).
- Diagnostics-panel surface for poll-history stats (counts only logged today; Diagnostics-panel row is a future iteration if needed).

## File summary

| File | Change |
|---|---|
| `bridge/history.go` | Extract `historicalRecordToVote` pure helper; rewrite `emitHistoricalPollUpdatesFromBlob` to call it + count + log. |
| `bridge/history_test.go` | New. Table-driven test of `historicalRecordToVote`. |
| `yawacTests/ConversationViewModelPollHistoryTests.swift` | New. `applyPollVote` round-trip + snapshot hydration. |
| `docs/ROADMAP.md` | Flip the poll cross-device own-vote bullet to ✅ after empirical verification confirms `self > 0` in the log. |
