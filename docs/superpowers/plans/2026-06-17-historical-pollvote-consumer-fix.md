# Historical Poll-Vote Consumer Fix (F90) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface own historical poll votes in the bubble after a history sync by fixing the bridge's voter-substitution gate from `r.PollCreationFromMe` to "empty Voter ⇒ own vote".

**Architecture:** Extract the per-record translation `[]events.HistoricalPollVote → []JPollVote` into a pure helper `historicalRecordToVote(r, ownBareJID) JPollVote` in `bridge/history.go` so the substitution rule can be unit-tested without a `*Client`. Drop the wrong `PollCreationFromMe` gate. Add per-sweep counter log line `[yawac/poll-history] sweep records=N self=M peer=K` for empirical verification. Add table-driven Go test covering the five voter-derivation cases plus hash encoding and timestamp preservation. Add Swift tests for `applyPollVote` round-trip (via `StubPollHistoryClient: WAClient` overriding `ownJID`) and `buildHistorySnapshot` poll-vote hydration from an in-memory `ModelContainer`.

**Tech Stack:** Go 1.26 (`bridge/`), Swift 5.10 + SwiftData + XCTest (`yawac/`, `yawacTests/`), XcodeGen, modernc.org/sqlite, whatsmeow fork (PR #1151 helper).

**Spec:** `docs/superpowers/specs/2026-06-17-historical-pollvote-consumer-fix-design.md`.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `bridge/history.go` | Modify (lines 121-156) | Pure helper `historicalRecordToVote` + rewired `emitHistoricalPollUpdatesFromBlob` with counter log |
| `bridge/history_test.go` | Create | Table-driven tests for `historicalRecordToVote`: 5 voter cases + hash encoding + timestamp |
| `yawacTests/ConversationViewModelPollHistoryTests.swift` | Create | `applyPollVote` round-trip + `buildHistorySnapshot` hydration; `StubPollHistoryClient` |
| `build/Bridge.xcframework` | Rebuilt | Output of `scripts/build-xcframework.sh` after Go changes land |
| `project.yml` | Modify (lines 69-70) | Version bump 0.10.17 → 0.10.18, build 100 → 101 |
| `docs/ROADMAP.md` | Modify | Flip the poll cross-device own-vote bullet from ☐ to ✅, add F90 entry to Shipped section |
| `docs/whatsmeow-patches.md` | No change | F88 already documents PR #1151; gate fix is yawac-side |

---

## Task 1: Pure helper `historicalRecordToVote` + Go test

**Files:**
- Create: `/Users/vadikas/Work/yawac/bridge/history_test.go`
- Modify: `/Users/vadikas/Work/yawac/bridge/history.go` (add helper after `emitHistoricalPollUpdatesFromBlob`, around line 157)

- [ ] **Step 1: Write the failing Go test**

Create `/Users/vadikas/Work/yawac/bridge/history_test.go`:

```go
package bridge

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func TestHistoricalRecordToVote(t *testing.T) {
	ownJID := "5550100@s.whatsapp.net"
	peerJID, err := types.ParseJID("5550200@s.whatsapp.net")
	if err != nil {
		t.Fatalf("parse peer: %v", err)
	}
	groupJID, err := types.ParseJID("12345-67890@g.us")
	if err != nil {
		t.Fatalf("parse group: %v", err)
	}
	participantJID, err := types.ParseJID("5550300@s.whatsapp.net")
	if err != nil {
		t.Fatalf("parse participant: %v", err)
	}

	mkHash := func(s string) []byte {
		sum := sha256.Sum256([]byte(s))
		return sum[:]
	}

	cases := []struct {
		name           string
		record         events.HistoricalPollVote
		expectedVoter  string
		expectedChat   string
		expectedHashes []string
	}{
		{
			name: "own vote on own poll",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P1",
				Voter:                types.JID{},
				SelectedOptionHashes: [][]byte{mkHash("A")},
				Timestamp:            time.Unix(1729000000, 0),
				PollCreationFromMe:   true,
			},
			expectedVoter:  ownJID,
			expectedChat:   peerJID.String(),
			expectedHashes: []string{hex.EncodeToString(mkHash("A"))},
		},
		{
			name: "own vote on peer poll (F88 regression guard)",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P2",
				Voter:                types.JID{},
				SelectedOptionHashes: [][]byte{mkHash("B")},
				Timestamp:            time.Unix(1729000001, 0),
				PollCreationFromMe:   false,
			},
			expectedVoter:  ownJID,
			expectedChat:   peerJID.String(),
			expectedHashes: []string{hex.EncodeToString(mkHash("B"))},
		},
		{
			name: "peer vote on peer poll 1:1",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P3",
				Voter:                peerJID,
				SelectedOptionHashes: [][]byte{mkHash("C")},
				Timestamp:            time.Unix(1729000002, 0),
				PollCreationFromMe:   false,
			},
			expectedVoter:  peerJID.String(),
			expectedChat:   peerJID.String(),
			expectedHashes: []string{hex.EncodeToString(mkHash("C"))},
		},
		{
			name: "peer vote on own poll 1:1",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P4",
				Voter:                peerJID,
				SelectedOptionHashes: [][]byte{mkHash("D")},
				Timestamp:            time.Unix(1729000003, 0),
				PollCreationFromMe:   true,
			},
			expectedVoter:  peerJID.String(),
			expectedChat:   peerJID.String(),
			expectedHashes: []string{hex.EncodeToString(mkHash("D"))},
		},
		{
			name: "peer vote in group",
			record: events.HistoricalPollVote{
				Chat:                 groupJID,
				PollCreationID:       "P5",
				Voter:                participantJID,
				SelectedOptionHashes: [][]byte{mkHash("E"), mkHash("F")},
				Timestamp:            time.Unix(1729000004, 0),
				PollCreationFromMe:   false,
			},
			expectedVoter: participantJID.String(),
			expectedChat:  groupJID.String(),
			expectedHashes: []string{
				hex.EncodeToString(mkHash("E")),
				hex.EncodeToString(mkHash("F")),
			},
		},
		{
			name: "empty selection (vote clear)",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P6",
				Voter:                peerJID,
				SelectedOptionHashes: nil,
				Timestamp:            time.Unix(1729000005, 0),
				PollCreationFromMe:   false,
			},
			expectedVoter:  peerJID.String(),
			expectedChat:   peerJID.String(),
			expectedHashes: []string{},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := historicalRecordToVote(tc.record, ownJID)
			if got.VoterJID != tc.expectedVoter {
				t.Errorf("VoterJID = %q, want %q", got.VoterJID, tc.expectedVoter)
			}
			if got.ChatJID != tc.expectedChat {
				t.Errorf("ChatJID = %q, want %q", got.ChatJID, tc.expectedChat)
			}
			if got.PollMessageID != string(tc.record.PollCreationID) {
				t.Errorf("PollMessageID = %q, want %q",
					got.PollMessageID, tc.record.PollCreationID)
			}
			if got.Timestamp != tc.record.Timestamp.Unix() {
				t.Errorf("Timestamp = %d, want %d",
					got.Timestamp, tc.record.Timestamp.Unix())
			}
			if len(got.OptionHashes) != len(tc.expectedHashes) {
				t.Fatalf("OptionHashes len = %d, want %d",
					len(got.OptionHashes), len(tc.expectedHashes))
			}
			for i, h := range got.OptionHashes {
				if h != tc.expectedHashes[i] {
					t.Errorf("OptionHashes[%d] = %q, want %q",
						i, h, tc.expectedHashes[i])
				}
			}
		})
	}
}

func TestHistoricalRecordToVoteUnpaired(t *testing.T) {
	// Empty ownBareJID (client not paired): empty Voter must stay empty,
	// not crash, not pick up a stray string.
	record := events.HistoricalPollVote{
		Chat:                 types.JID{User: "x", Server: types.DefaultUserServer},
		PollCreationID:       "P",
		Voter:                types.JID{},
		SelectedOptionHashes: [][]byte{{0xab}},
		Timestamp:            time.Unix(1, 0),
		PollCreationFromMe:   true,
	}
	got := historicalRecordToVote(record, "")
	if got.VoterJID != "" {
		t.Errorf("unpaired VoterJID = %q, want empty", got.VoterJID)
	}
	if len(got.OptionHashes) != 1 || got.OptionHashes[0] != "ab" {
		t.Errorf("OptionHashes = %v, want [ab]", got.OptionHashes)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vadikas/Work/yawac/bridge && go test -run TestHistoricalRecordToVote -v ./...`
Expected: FAIL with "undefined: historicalRecordToVote".

- [ ] **Step 3: Implement the pure helper**

Edit `/Users/vadikas/Work/yawac/bridge/history.go`. After the closing brace of `emitHistoricalPollUpdatesFromBlob` (currently around line 156), add:

```go
// historicalRecordToVote maps one HistoricalPollVote record into the
// JPollVote payload that mirrors live PollUpdateMessage dispatches.
// Empty r.Voter signals an own-vote: the upstream helper (fork PR
// #1151's HistoricalPollUpdates) sets Voter only when
// PollUpdateMessageKey.Participant is set, OR when the chat is 1:1 and
// the vote is NOT from us; when voteKey.FromMe is true it leaves Voter
// empty. The only consistent interpretation is "vote from us", so
// substitute ownBareJID. Swift's mySelections() keys against
// client.ownJID (= Store.ID.ToNonAD().String()) so the substitution form
// must match.
//
// When the client is unpaired (ownBareJID == ""), the substitution is
// skipped — VoterJID stays empty and SQLite upsert is recoverable on
// the next sweep after pairing.
func historicalRecordToVote(r events.HistoricalPollVote, ownBareJID string) JPollVote {
	voterStr := r.Voter.String()
	if voterStr == "" && ownBareJID != "" {
		voterStr = ownBareJID
	}
	hashes := make([]string, 0, len(r.SelectedOptionHashes))
	for _, h := range r.SelectedOptionHashes {
		hashes = append(hashes, hex.EncodeToString(h))
	}
	return JPollVote{
		ChatJID:       r.Chat.String(),
		PollMessageID: string(r.PollCreationID),
		VoterJID:      voterStr,
		OptionHashes:  hashes,
		Timestamp:     r.Timestamp.Unix(),
	}
}
```

Note: `types.JID{}.String()` returns `"@"` not `""` in some whatsmeow versions, but in the fork tip the zero value formats as the empty string. Verify by reading `~/go/pkg/mod/github.com/vadika/whatsmeow@v0.0.0-20260617085916-69b126129f1b/types/jid.go` `JID.String()` — if zero JID stringifies non-empty, swap the `voterStr == ""` check for `r.Voter.IsEmpty()` (fork exposes `IsEmpty()` on `types.JID`).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/vadikas/Work/yawac/bridge && go test -run TestHistoricalRecordToVote -v ./...`
Expected: PASS with 7 sub-tests (5 voter cases + empty-selection + unpaired).

- [ ] **Step 5: Verify the zero-JID stringification assumption holds**

Run: `cd /Users/vadikas/Work/yawac/bridge && grep -A 8 'func (jid JID) String' $(go env GOMODCACHE)/github.com/vadika/whatsmeow@v0.0.0-20260617085916-69b126129f1b/types/jid.go`
Expected: function returns `""` when `jid.User == "" && jid.Server == ""`. If instead it returns `"@"` or panics on zero-JID, switch the test record construction (zero `types.JID{}` → `types.JID{}`-equivalent) and the helper's check accordingly. If `IsEmpty()` exists on the JID type, prefer it: change the helper line to `if r.Voter.IsEmpty() && ownBareJID != "" { voterStr = ownBareJID }` and the test's record stays unchanged.

- [ ] **Step 6: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add bridge/history.go bridge/history_test.go
git commit -m "F90: pure historicalRecordToVote helper + tests

Extract per-record translation so the substitution rule can be tested
without a *Client. Five voter-derivation cases + empty-selection +
unpaired-client. Caller still untouched in this commit — wired in the
next.
"
```

---

## Task 2: Rewire `emitHistoricalPollUpdatesFromBlob` to use the helper + counter log

**Files:**
- Modify: `/Users/vadikas/Work/yawac/bridge/history.go` (rewrite `emitHistoricalPollUpdatesFromBlob`, currently lines 121-156)

- [ ] **Step 1: Replace the function body**

Read current `emitHistoricalPollUpdatesFromBlob` lines 121-156. Replace the entire function with:

```go
// emitHistoricalPollUpdatesFromBlob dispatches one synthetic "PollVote"
// event per record returned by events.HistorySync.HistoricalPollUpdates().
// The fork's helper already produces SHA-256(optionName) hashes —
// identical to what DecryptPollVote yields for live votes — so the
// Swift tally path is uniform across live and historical sources.
//
// F90: per-sweep counter log so /tmp/yawac.log shows substitution
// activity after a Full sync. self > 0 confirms the empty-voter →
// ownJID substitution fired (fix for the F88 PollCreationFromMe gate
// that missed own-votes on peer-created polls).
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
		if ownBareJID != "" && v.VoterJID == ownBareJID {
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

- [ ] **Step 2: Run all bridge tests**

Run: `cd /Users/vadikas/Work/yawac/bridge && go test ./...`
Expected: PASS (no test regression; helper tests still green; the rewrite calls the same helper).

- [ ] **Step 3: Sanity-check the Go build**

Run: `cd /Users/vadikas/Work/yawac/bridge && go build ./...`
Expected: clean exit code 0; no compile errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add bridge/history.go
git commit -m "F90: rewire emitHistoricalPollUpdatesFromBlob via pure helper

Drops the wrong r.PollCreationFromMe gate (F88 bug) — that field tells
us who created the poll, not who cast the vote. The fork helper leaves
Voter empty whenever the update key has FromMe=true, regardless of
poll authorship, so empty Voter always means own vote.

Adds per-sweep counter log [yawac/poll-history] sweep records=N self=M
peer=K for empirical verification on the existing paired account.
"
```

---

## Task 3: Swift `applyPollVote` round-trip test

**Files:**
- Create: `/Users/vadikas/Work/yawac/yawacTests/ConversationViewModelPollHistoryTests.swift`

- [ ] **Step 1: Write the test file**

Create `/Users/vadikas/Work/yawac/yawacTests/ConversationViewModelPollHistoryTests.swift`:

```swift
import XCTest
import SwiftData
@testable import yawac

/// Covers the historical-poll-vote consumer path (F90):
///   1. `ConversationViewModel.applyPollVote` correctly keys an
///      own-vote against `client.ownJID` so `mySelections(for:)`
///      returns the user's selected option hashes — the in-memory
///      branch fired by `ConversationView.event` when the chat is
///      open during the bridge sweep.
///   2. `ConversationViewModel.buildHistorySnapshot` hydrates
///      `pollVotes` from `PersistedPollVote` rows for visible poll
///      IDs — the cold-open branch fired when the chat was closed
///      during the sweep and the user opens it later.
@MainActor
final class ConversationViewModelPollHistoryTests: XCTestCase {

    private let ownJID = "11234567890@s.whatsapp.net"
    private let chatJID = "5550200@s.whatsapp.net"
    private let pollID = "POLL_MSG_1"

    // MARK: applyPollVote round-trip

    func testApplyPollVoteOwnSelectionSurfaces() async throws {
        let stub = try StubPollHistoryClient.make(ownJID: ownJID)
        let vm = ConversationViewModel(chatJID: chatJID, client: stub)

        vm.applyPollVote(pollMessageID: pollID,
                         voterJID: ownJID,
                         optionHashes: ["h1", "h2"])

        XCTAssertEqual(vm.mySelections(for: pollID), Set(["h1", "h2"]))
    }

    func testApplyPollVotePeerSelectionDoesNotSurfaceAsOwn() async throws {
        let stub = try StubPollHistoryClient.make(ownJID: ownJID)
        let vm = ConversationViewModel(chatJID: chatJID, client: stub)

        vm.applyPollVote(pollMessageID: pollID,
                         voterJID: "5550300@s.whatsapp.net",
                         optionHashes: ["h1"])

        XCTAssertEqual(vm.mySelections(for: pollID), Set())
    }

    func testApplyPollVoteReplacesPriorSelections() async throws {
        let stub = try StubPollHistoryClient.make(ownJID: ownJID)
        let vm = ConversationViewModel(chatJID: chatJID, client: stub)

        vm.applyPollVote(pollMessageID: pollID,
                         voterJID: ownJID,
                         optionHashes: ["h1"])
        vm.applyPollVote(pollMessageID: pollID,
                         voterJID: ownJID,
                         optionHashes: ["h2"])

        XCTAssertEqual(vm.mySelections(for: pollID), Set(["h2"]))
    }
}

/// Minimal WAClient subclass that overrides `ownJID` so the tests can
/// drive `mySelections(for:)` lookups against a stable identity. Same
/// pattern as `StubSelfChatClient` in `SessionViewModelSelfChatTests`.
@MainActor
final class StubPollHistoryClient: WAClient {
    private let stubOwnJID: String

    override var ownJID: String { stubOwnJID }

    init(dbPath: String, ownJID: String) throws {
        self.stubOwnJID = ownJID
        try super.init(dbPath: dbPath)
    }

    static func make(ownJID: String) throws -> StubPollHistoryClient {
        let dir = NSTemporaryDirectory()
            .appending("yawac-pollhistory-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return try StubPollHistoryClient(dbPath: dir + "/state.db",
                                         ownJID: ownJID)
    }
}
```

- [ ] **Step 2: Generate Xcode project + build the test target**

Run: `cd /Users/vadikas/Work/yawac && xcodegen generate`
Expected: clean exit; `yawac.xcodeproj` regenerated.

Run: `cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -only-testing:yawacTests/ConversationViewModelPollHistoryTests -destination 'platform=macOS' test 2>&1 | tail -30`
Expected: 3 test cases pass: `testApplyPollVoteOwnSelectionSurfaces`, `testApplyPollVotePeerSelectionDoesNotSurfaceAsOwn`, `testApplyPollVoteReplacesPriorSelections`.

- [ ] **Step 3: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add yawacTests/ConversationViewModelPollHistoryTests.swift
git commit -m "F90: applyPollVote round-trip tests

Three cases via StubPollHistoryClient overriding ownJID (same shape as
StubSelfChatClient): own-vote surfaces via mySelections; peer-vote does
not; latest vote replaces prior (single- and multi-select semantics).
Snapshot hydration test follows in next commit.
"
```

---

## Task 4: Swift `buildHistorySnapshot` poll-vote hydration test

**Files:**
- Modify: `/Users/vadikas/Work/yawac/yawacTests/ConversationViewModelPollHistoryTests.swift` (append snapshot-hydration tests to the existing test class)

- [ ] **Step 1: Append the hydration test to the existing test file**

In the same `ConversationViewModelPollHistoryTests` class (added in Task 3), add after the `applyPollVote` test methods:

```swift
    // MARK: buildHistorySnapshot hydration

    func testBuildHistorySnapshotHydratesOwnPollVote() async throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        let pollTimestamp = Date(timeIntervalSince1970: 1_729_000_000)
        context.insert(PersistedMessage(
            id: pollID,
            chatJID: chatJID,
            senderJID: chatJID,
            fromMe: false,
            timestamp: pollTimestamp,
            kind: "poll",
            text: "Lunch?"))
        context.insert(PersistedPollVote(
            chatJID: chatJID,
            pollMessageID: pollID,
            voterJID: ownJID,
            optionHashesJSON: "[\"h1\",\"h2\"]",
            timestamp: pollTimestamp.addingTimeInterval(60)))
        try context.save()

        let snap = await Task.detached { [chatJID, container] in
            ConversationViewModel.buildHistorySnapshot(
                chatJID: chatJID,
                container: container,
                canonicalize: { $0 },
                limit: 100)
        }.value

        XCTAssertTrue(
            snap.pollVotes[pollID]?["h1"]?.contains(ownJID) == true,
            "own vote on h1 should hydrate from PersistedPollVote")
        XCTAssertTrue(
            snap.pollVotes[pollID]?["h2"]?.contains(ownJID) == true,
            "own vote on h2 should hydrate from PersistedPollVote")
    }

    func testBuildHistorySnapshotIgnoresVotesForOffWindowPolls() async throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        // No PersistedMessage row for "ORPHAN_POLL" — vote should not
        // be hydrated since the snapshot only seeds for visible polls.
        context.insert(PersistedPollVote(
            chatJID: chatJID,
            pollMessageID: "ORPHAN_POLL",
            voterJID: ownJID,
            optionHashesJSON: "[\"h1\"]",
            timestamp: Date(timeIntervalSince1970: 1_729_000_000)))
        try context.save()

        let snap = await Task.detached { [chatJID, container] in
            ConversationViewModel.buildHistorySnapshot(
                chatJID: chatJID,
                container: container,
                canonicalize: { $0 },
                limit: 100)
        }.value

        XCTAssertNil(snap.pollVotes["ORPHAN_POLL"])
    }

    // MARK: helpers

    private static func makeInMemoryContainer() throws -> ModelContainer {
        // Mirrors the app's ModelContainer construction in yawacApp.swift
        // (the four `@Model` types this app declares). isStoredInMemoryOnly
        // keeps each test hermetic — no on-disk store, no inter-test leak.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: PersistedMessage.self,
            PersistedChat.self,
            PersistedReaction.self,
            PersistedPollVote.self,
            configurations: config)
    }
```

- [ ] **Step 2: Build + run the new tests**

Run: `cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -only-testing:yawacTests/ConversationViewModelPollHistoryTests -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: 5 test cases pass total (3 from Task 3 + 2 new).

If the hydration test fails with `pollVotes[pollID]` nil: the snapshot's poll-vote seeding gate (`displayable.filter { $0.kind == "poll" }`) didn't pick up the row. Verify the inserted `PersistedMessage`'s `kind == "poll"` and that the timestamp puts it inside the snapshot window (limit=100 by recency descending — your one inserted row will always be in window).

- [ ] **Step 3: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add yawacTests/ConversationViewModelPollHistoryTests.swift
git commit -m "F90: buildHistorySnapshot poll-vote hydration tests

In-memory ModelContainer fixture, insert a poll PersistedMessage + an
own-vote PersistedPollVote, run buildHistorySnapshot, assert snap
.pollVotes[pollID][hash] contains ownJID. Second case guards that
orphan votes (no matching poll in window) are silently skipped.
"
```

---

## Task 5: Rebuild XCFramework + manual verification

**Files:**
- Rebuilt: `/Users/vadikas/Work/yawac/build/Bridge.xcframework`
- Read: `/tmp/yawac.log` (verify sweep counter line)
- Visual: open a known peer-created poll the user voted on from phone; bubble should highlight chosen options.

- [ ] **Step 1: Rebuild Bridge.xcframework with the F90 bridge changes**

Run: `cd /Users/vadikas/Work/yawac && ./scripts/build-xcframework.sh 2>&1 | tail -20`
Expected: gomobile builds Bridge.xcframework with the new bridge/history.go. No errors; final line typically `"Built Bridge.xcframework"` or equivalent.

- [ ] **Step 2: Regenerate the Xcode project + build Debug**

Run: `cd /Users/vadikas/Work/yawac && xcodegen generate && xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Launch the Debug binary and tail the log**

In one terminal:
```bash
rm -f /tmp/yawac.log
open /Users/vadikas/Work/yawac/build/Build/Products/Debug/yawac.app
```

In a second terminal:
```bash
tail -F /tmp/yawac.log | grep -E '\[yawac/poll-history\]'
```

- [ ] **Step 4: Trigger a Full sync via the in-app button**

In yawac: open Settings → Sync section → tap **Full sync** (the user-facing button wired in F28 `startFullHistorySync`).

Expected within ~60s: at least one log line of the form:
```
[yawac/poll-history] sweep records=N self=M peer=K
```
with `N > 0` (any non-zero implies the helper found `WebMessageInfo.PollUpdates` records in the sweep). If `self > 0`, the substitution fired — direct evidence the fix is live. If `self == 0` and `peer > 0`, the user has never voted on any historical poll on this account; switch to a fresh-pair test on a known-with-own-votes account, or vote on the phone first and resync.

If NO `[yawac/poll-history]` line appears after ~60s: the bridge sweep helper wasn't called. Check `/tmp/yawac.log` for whatsmeow history-sync errors; check that `bridge/history.go:118 c.emitHistoricalPollUpdatesFromBlob(evt)` is still in place; check that the F84 SQLITE_BUSY fix hasn't regressed.

- [ ] **Step 5: Visual confirmation in the bubble**

Open a chat with a known peer-created poll the user voted on from the phone (before any v0.10.x install). Scroll to the poll bubble.

Expected: the option(s) the user chose render highlighted (filled radio for single-select polls; filled checkbox for multi-select), matching the WhatsApp phone client's rendering of the same poll.

If the highlight doesn't appear: confirm via SQL that the row landed correctly. From a third terminal:
```bash
sqlite3 ~/Library/Application\ Support/default.store \
  "SELECT ZPOLLMESSAGEID, ZVOTERJID, ZOPTIONHASHESJSON FROM ZPERSISTEDPOLLVOTE WHERE ZVOTERJID LIKE '%@s.whatsapp.net' AND ZVOTERJID = (SELECT ZVOTERJID FROM ZPERSISTEDPOLLVOTE LIMIT 1);"
```
If rows exist with `ZVOTERJID == <your bare JID>` for the expected poll: the persistence succeeded; the failure is in the bubble renderer (out of scope for F90 — open as a separate followup). If `ZVOTERJID` is empty or mismatched: the substitution didn't reach this row; re-check the F90 helper code.

- [ ] **Step 6: No commit in this task** — verification only. Snapshot the relevant log lines into the F90 release-notes draft (Task 6) before moving on.

---

## Task 6: Ship — version bump + ROADMAP update + release tag

**Files:**
- Modify: `/Users/vadikas/Work/yawac/project.yml` (lines 69-70)
- Modify: `/Users/vadikas/Work/yawac/docs/ROADMAP.md` (Polls bullet under Communication → Polls; add F90 entry to Shipped section)

- [ ] **Step 1: Bump version**

Edit `/Users/vadikas/Work/yawac/project.yml`:

```yaml
        CFBundleShortVersionString: "0.10.18"
        CFBundleVersion: "101"
```

- [ ] **Step 2: Update ROADMAP**

In `/Users/vadikas/Work/yawac/docs/ROADMAP.md`:

Under **Communication → Polls** (around line 24), change:
```
- ☐ Cross-device own-vote re-render from `HistoricalPollVote`
  event (after history sync the user's own selection may show
  empty until they vote again).
```
to:
```
- ✅ Cross-device own-vote re-render from `HistoricalPollVote`
  event — landed as F90 in v0.10.18.
```

Then prepend to the **Shipped (✅)** section (after the header, before the F89 entry):

```markdown
- ✅ **F90 — Historical poll-vote consumer fix (own-vote substitution
  on peer-created polls)** (v0.10.18) — F88 wired the fork's PR #1151
  helper end-to-end but gated the bridge's empty-Voter substitution on
  `r.PollCreationFromMe` — a field that tells us who created the poll,
  not who cast the vote. The helper at `types/events/historicalpollvotes
  .go` leaves `Voter` empty whenever the update key has `FromMe=true`,
  regardless of poll authorship; the only consistent interpretation is
  "vote from us". Failure case: peer creates poll, user votes from
  phone → bridge persists vote with `voterJID=""` → Swift
  `mySelections(for:)` keyed against `client.ownJID` finds nothing →
  bubble shows the user didn't vote even though they did.
  - **Fix.** Drop the `PollCreationFromMe` gate. Extract the per-record
    translation into a pure helper `historicalRecordToVote(r,
    ownBareJID) JPollVote` so the substitution rule is unit-testable
    without a `*Client`. Substitute `ownBareJID` whenever `r.Voter` is
    the zero JID (and the client is paired). Unpaired client → no
    substitution; SQLite row recoverable on next sweep after pairing.
  - **Tests.** Bridge: table-driven `bridge/history_test.go` covering
    own-vote on own/peer poll, peer-vote on own/peer poll 1:1,
    peer-vote in group with Participant, empty-selection vote-clear,
    unpaired-client guard. Swift: `yawacTests/ConversationView
    ModelPollHistoryTests.swift` covers `applyPollVote` ↔
    `mySelections(for:)` round-trip + `buildHistorySnapshot` hydration
    from `PersistedPollVote` rows. `StubPollHistoryClient: WAClient`
    overrides `ownJID` (same pattern as `StubSelfChatClient`).
  - **Diagnostic.** New per-sweep log line `[yawac/poll-history]
    sweep records=N self=M peer=K` in `/tmp/yawac.log` so substitution
    activity is visible on the existing paired account without
    re-pair. After the user-facing **Full sync** button fires, `self
    > 0` confirms the F90 substitution is live.
```

- [ ] **Step 3: Run the full test suite one more time before tagging**

Run: `cd /Users/vadikas/Work/yawac/bridge && go test ./...`
Expected: PASS.

Run: `cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: all `yawacTests` test cases pass, including the 5 new F90 cases.

- [ ] **Step 4: Commit the bump + roadmap update**

```bash
cd /Users/vadikas/Work/yawac
git add project.yml docs/ROADMAP.md
git commit -m "release: 0.10.18 — F90 historical poll-vote consumer fix

Drops the wrong r.PollCreationFromMe gate in
bridge/history.go's emitHistoricalPollUpdatesFromBlob. Empty Voter
always means own vote per the fork PR #1151 helper's contract;
substitute ownBareJID regardless of poll authorship. Pure helper +
seven Go test cases + five Swift test cases + per-sweep counter log
for empirical verification.
"
```

- [ ] **Step 5: Push to main**

Run: `cd /Users/vadikas/Work/yawac && git pull --rebase origin main && git push origin main`
Expected: push succeeds. Per memory `reference_yawac_release_workflow`: always re-pull main before pushing.

- [ ] **Step 6: Tag the release**

Run:
```bash
cd /Users/vadikas/Work/yawac
git tag v0.10.18 -m "v0.10.18 — F90 historical poll-vote consumer fix"
git push origin v0.10.18
```
Expected: tag pushes; CI picks it up via the existing release workflow.

- [ ] **Step 7: Watch CI**

Run: `gh run watch --exit-status $(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')`
Expected: exit code 0; `gh release view v0.10.18` shows the `yawac-0.10.18.zip` and `appcast.xml` assets uploaded.

If CI fails: read the failing job's log via `gh run view <id> --log-failed | tail -100` and fix forward (do not amend; bump to v0.10.19).

---

## Verification checklist

After Task 6:
- [ ] `go test ./bridge/...` green
- [ ] `xcodebuild test` green (5 new Swift test cases pass)
- [ ] `/tmp/yawac.log` shows `[yawac/poll-history] sweep records=N self=M peer=K` after Full sync, with `self > 0` on an account that voted on peer polls
- [ ] Visual: bubble highlight surfaces on a known peer-created poll the user voted on from the phone
- [ ] `docs/ROADMAP.md` Polls bullet flipped to ✅
- [ ] v0.10.18 tagged + CI green + release assets uploaded
- [ ] Sparkle appcast.xml updated by the release workflow

## Out of scope

- Upstream PR to add `UpdateFromMe bool` on `HistoricalPollVote` struct (would make the inference explicit; fork already carries PR #1151; sending an amendment depends on tulir's appetite).
- Diagnostics-panel surface for poll-history stats (counter is in `/tmp/yawac.log` only; no in-app row).
- Live-vote path changes (already correct; only the historical path was broken).
