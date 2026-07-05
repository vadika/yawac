# F118 Offline-Gap Message Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover messages read on the phone while yawac was offline by enabling whatsmeow's phone-rerequest fallback, logging undecryptable events, and adding a manual resend-request entry point.

**Architecture:** Three bridge-side (Go) changes, no permanent Swift changes. whatsmeow already parses the phone's resend response and dispatches it as a normal `events.Message`, so the existing `dispatchMessage` → Swift persistence path consumes recovered messages with zero new plumbing. A temporary Swift call recovers one known-lost message and empirically verifies the path, then is removed.

**Tech Stack:** Go (bridge, gomobile), whatsmeow fork `a0d4b7e975f9`, Swift (temporary verify hook only).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-05-offline-gap-message-recovery-design.md`.
- **F117 v0.10.45 work is already staged/uncommitted in this tree** (bridge/go.mod, bridge/go.sum, bridge/history.go, bridge/history_test.go, docs/ROADMAP.md, docs/whatsmeow-patches.md, project.yml, yawac/Info.plist). Every `git add`/`git commit` in this plan MUST name exact paths — never `git add -A`, `git add .`, or bare `git commit -a`. Do not commit, unstage, or otherwise touch the F117 files.
- Task 4 (release) assumes F117 has shipped as v0.10.45 before F118 releases; if it has not, STOP and ask the user for ordering.
- Bridge logging idiom: `fmt.Fprintf(os.Stderr, "[yawac/...] ...\n", ...)`.
- Run bridge tests from `/Users/vadikas/Work/yawac/bridge` with `go test ./...`.

---

### Task 1: Enable phone rerequest + log undecryptable events

**Files:**
- Modify: `bridge/client.go` (~line 177, after `wa.SkipBrokenAppStatePatches = true`)
- Modify: `bridge/events.go:70-73` (the `case *events.UndecryptableMessage:` no-op)

**Interfaces:**
- Consumes: `whatsmeow.Client.AutomaticMessageRerequestFromPhone` (bool field), `events.UndecryptableMessage{Info types.MessageInfo; IsUnavailable bool; DecryptFailMode DecryptFailMode}`.
- Produces: nothing consumed by later tasks; behavior change only.

No unit test possible for either change (flag needs a live socket; log line is a side effect). One-line flag + one log call — trivial per ponytail test policy. Compile check + full existing suite instead.

- [ ] **Step 1: Add the flag in `bridge/client.go`**

Directly after the `wa.SkipBrokenAppStatePatches = true` line (~177), add:

```go
	// F118: when a message fails to decrypt (e.g. group skmsg with a
	// missing sender key during offline drain), ask the primary phone
	// to resend it — the same PLACEHOLDER_MESSAGE_RESEND peer request
	// WhatsApp Web uses for "Waiting for this message". Without this,
	// the only recovery is a retry receipt to the original sender,
	// which often goes unanswered for LID senders in groups, and the
	// message is silently lost. The phone's response is dispatched by
	// whatsmeow as a normal events.Message, so the existing pipeline
	// persists it. Fires 5s after the first decrypt failure per
	// message ID (whatsmeow retry.go).
	wa.AutomaticMessageRerequestFromPhone = true
```

- [ ] **Step 2: Replace the no-op `UndecryptableMessage` case body in `bridge/events.go`**

Replace:

```go
	case *events.UndecryptableMessage:
		// Do NOT dispatch to Swift — the Swift side has no UI for
		// undecryptable messages; whatsmeow's own retry mechanism
		// handles the recovery path.
```

with:

```go
	case *events.UndecryptableMessage:
		// Do NOT dispatch to Swift — no UI for undecryptable
		// messages. whatsmeow sends a retry receipt to the sender
		// and (F118) requests a resend from the primary phone; the
		// recovered copy arrives as a normal Message event. Log so
		// losses are greppable instead of invisible.
		fmt.Fprintf(os.Stderr,
			"[yawac/undecrypt] id=%s chat=%s sender=%s unavailable=%v mode=%s\n",
			v.Info.ID, v.Info.Chat, v.Info.Sender, v.IsUnavailable, v.DecryptFailMode)
```

Check `bridge/events.go` imports already include `fmt` and `os` (they do — used at line 145); add if missing.

- [ ] **Step 3: Compile + run full bridge suite**

Run: `cd /Users/vadikas/Work/yawac/bridge && go build ./... && go test ./...`
Expected: build OK, all tests PASS (186+).

- [ ] **Step 4: Commit (exact paths only)**

```bash
cd /Users/vadikas/Work/yawac
git add bridge/client.go bridge/events.go
git commit -m "feat(bridge): F118 enable phone rerequest for undecryptable messages + log them" -- bridge/client.go bridge/events.go
```

---

### Task 2: `RequestMessageResend` bridge func + test

**Files:**
- Create: `bridge/resend.go`
- Test: `bridge/resend_test.go`

**Interfaces:**
- Consumes: `c.wa` (`*whatsmeow.Client`), `types.ParseJID`, `c.wa.BuildUnavailableMessageRequest(chat, sender types.JID, id string) *waE2E.Message`, `c.wa.SendPeerMessage(ctx, msg)`.
- Produces: `func (c *Client) RequestMessageResend(chatJID, senderJID, msgID string) error` — gomobile exposes it to Swift as `go.requestMessageResend(chatJID, senderJID, msgID)` (throws). Task 3 calls it.

- [ ] **Step 1: Write the failing test `bridge/resend_test.go`**

```go
package bridge

import (
	"strings"
	"testing"
)

// Guard + parse error paths only; the happy path needs a live socket
// and is covered by the manual empirical verify (see plan Task 3).
// All cases use a bare &Client{} — the implementation parses JIDs
// BEFORE the nil-client guard precisely so these tests need no store.
func TestRequestMessageResendErrors(t *testing.T) {
	cases := []struct {
		name         string
		chat, sender string
		wantSubstr   string
	}{
		{"bad chat jid", "a@b@c", "456@lid", "chat jid"},
		{"bad sender jid", "123@g.us", "a@b@c", "sender jid"},
		{"closed client", "123@g.us", "456@lid", "client closed"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &Client{} // c.wa == nil
			err := c.RequestMessageResend(tc.chat, tc.sender, "ABC123")
			if err == nil {
				t.Fatalf("want error containing %q, got nil", tc.wantSubstr)
			}
			if !strings.Contains(err.Error(), tc.wantSubstr) {
				t.Fatalf("want error containing %q, got %q", tc.wantSubstr, err.Error())
			}
		})
	}
}
```

If `types.ParseJID("a@b@c")` turns out not to error, substitute any input that does (check `types/jid.go` in the whatsmeow fork for what ParseJID rejects) — adjust the test input, not the implementation.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vadikas/Work/yawac/bridge && go test -run TestRequestMessageResendErrors ./...`
Expected: FAIL — `c.RequestMessageResend undefined`.

- [ ] **Step 3: Implement `bridge/resend.go`**

```go
package bridge

import (
	"context"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow/types"
)

// RequestMessageResend asks the primary phone to resend a message this
// client never received or failed to decrypt (PLACEHOLDER_MESSAGE_RESEND
// peer request — what WhatsApp Web uses for "Waiting for this message").
// The resent copy arrives as a normal Message event through the usual
// pipeline. The phone must be online and still hold the message. F118.
func (c *Client) RequestMessageResend(chatJID, senderJID, msgID string) error {
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("chat jid: %w", err)
	}
	sender, err := types.ParseJID(senderJID)
	if err != nil {
		return fmt.Errorf("sender jid: %w", err)
	}
	if c.wa == nil {
		return errors.New("client closed")
	}
	req := c.wa.BuildUnavailableMessageRequest(chat, sender, msgID)
	if _, err := c.wa.SendPeerMessage(context.Background(), req); err != nil {
		return fmt.Errorf("send placeholder-resend request: %w", err)
	}
	return nil
}
```

Note: JID parsing intentionally precedes the nil guard so the parse-error
tests in Step 1 run against a bare `&Client{}` with no store.

- [ ] **Step 4: Run test to verify it passes, then full suite**

Run: `cd /Users/vadikas/Work/yawac/bridge && go test -run TestRequestMessageResendErrors ./... && go test ./...`
Expected: PASS, full suite PASS.

- [ ] **Step 5: Commit (exact paths only)**

```bash
cd /Users/vadikas/Work/yawac
git add bridge/resend.go bridge/resend_test.go
git commit -m "feat(bridge): F118 RequestMessageResend manual placeholder-resend request" -- bridge/resend.go bridge/resend_test.go
```

---

### Task 3: Rebuild XCFramework + empirical verify (recover the known lost image)

**Files:**
- Modify (temporary, reverted in this task): `yawac/ViewModels/SessionViewModel.swift` (`.connected` handler, ~line 700-713)
- Regenerated: `build/Bridge.xcframework` (not committed; check `.gitignore` — build/ is ignored)

**Interfaces:**
- Consumes: `go.requestMessageResend(_:_:_:)` from Task 2 (gomobile-generated, throwing). Exact Swift spelling: match how `go.requestFullHistorySync` is called in `yawac/Bridge/WAClient.swift:745`.

- [ ] **Step 1: Rebuild the XCFramework**

Run: `cd /Users/vadikas/Work/yawac && ./scripts/build-xcframework.sh`
Expected: exits 0, `build/Bridge.xcframework` regenerated.

- [ ] **Step 2: Add temporary one-shot recovery call**

In `yawac/ViewModels/SessionViewModel.swift`, inside the `case .connected:` handler (next to the existing `Task { await self.requestReconnectCatchupSyncIfNeeded() }` at ~line 712), add:

```swift
            // F118 TEMP: one-shot recovery of known lost image; remove
            // after empirical verify.
            Task {
                try? await Task.sleep(for: .seconds(10))
                do {
                    try self.client.requestMessageResend(
                        chatJID: "33612785613-1601323552@g.us",
                        senderJID: "220405054881957@lid",
                        msgID: "AC495A1FF51C4ED9588FA6F8CD808BA7")
                    NSLog("[yawac/f118-temp] resend request sent")
                } catch {
                    NSLog("[yawac/f118-temp] resend request failed: \(error)")
                }
            }
```

If `WAClient` wraps bridge calls (it does — see `requestFullHistorySync` wrapper at `WAClient.swift:739-745`), add a matching thin wrapper `requestMessageResend(chatJID:senderJID:msgID:)` there and call through it; copy the existing wrapper's `bump(...)`/`nonisolated` style exactly.

- [ ] **Step 3: Build + run the app**

Run: `cd /Users/vadikas/Work/yawac && xcodegen generate && xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug build`
Expected: BUILD SUCCEEDED. Launch the built app.

- [ ] **Step 4: Verify empirically**

Wait ~30 s after connect, then:

Run: `strings /tmp/yawac.log | grep -E "f118-temp|undecrypt|AC495A1F" | tail -20`
Expected: `[yawac/f118-temp] resend request sent`, followed by message-dispatch evidence for `AC495A1FF51C4ED9588FA6F8CD808BA7`.

Then check the group `33612785613-1601323552@g.us` in the app: the missing picture message should now render. ALSO ask the user to confirm visually — do not self-certify the bubble.

If the phone doesn't respond within ~2 min: confirm phone online, retry once (relaunch app). If still nothing, STOP and report — the message may have aged out on the phone; the code path is still validated if the peer message sent without error, but say so honestly rather than claiming full verification.

- [ ] **Step 5: Remove the temporary Swift call (keep the WAClient wrapper)**

Delete the `// F118 TEMP` block from `SessionViewModel.swift`. Keep the `requestMessageResend` wrapper in `WAClient.swift` — it is the permanent manual entry point.

Run: `cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit (exact paths only)**

```bash
cd /Users/vadikas/Work/yawac
git add yawac/Bridge/WAClient.swift
git commit -m "feat: F118 requestMessageResend Swift wrapper" -- yawac/Bridge/WAClient.swift
```

(`SessionViewModel.swift` ends this task unchanged — verify with `git status` that it is not listed; if it is, the temp block wasn't fully removed.)

---

### Task 4: Ship — ROADMAP + version bump + tag

**Precondition:** F117 v0.10.45 has been committed, tagged, and pushed. If `git tag -l v0.10.45` is empty or F117 files are still uncommitted, STOP and ask the user.

**Files:**
- Modify: `docs/ROADMAP.md` (add F118 entry after F117's)
- Modify: `project.yml` (CFBundleShortVersionString `0.10.45` → `0.10.46`, CFBundleVersion `128` → `129`)
- Regenerated: `yawac.xcodeproj`, `yawac/Info.plist` (via xcodegen)

- [ ] **Step 1: Add ROADMAP entry**

In `docs/ROADMAP.md`, after the F117 entry, add:

```markdown
- ✅ **F118 — offline-gap message recovery** (v0.10.46) — Messages read
  on the phone while yawac was offline could be silently lost: group
  skmsg decrypt failures during offline drain emitted
  `UndecryptableMessage`, which the bridge dropped with no log, and the
  only automatic recovery was a retry receipt to the original sender
  (often unanswered for LID senders). Enabled
  `AutomaticMessageRerequestFromPhone` so whatsmeow asks the primary
  phone to resend after the first decrypt failure (same
  PLACEHOLDER_MESSAGE_RESEND peer request WhatsApp Web uses); the
  phone's copy arrives as a normal Message event through the existing
  pipeline. Added `[yawac/undecrypt]` logging and a manual
  `RequestMessageResend(chat, sender, id)` bridge entry point, used to
  recover the known-lost image in 33612785613-1601323552@g.us.
  Empirically verified end-to-end. Bridge tests green.
```

Adjust the "Empirically verified" sentence to match the actual Task 3 outcome (fully verified vs request-sent-but-phone-aged-out).

- [ ] **Step 2: Bump version in `project.yml`**

Change `CFBundleShortVersionString: "0.10.45"` → `"0.10.46"` and `CFBundleVersion: "128"` → `"129"`.

- [ ] **Step 3: Regenerate + build**

Run: `cd /Users/vadikas/Work/yawac && xcodegen generate && xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit + tag + push (exact paths; re-pull main first per release workflow)**

```bash
cd /Users/vadikas/Work/yawac
git pull --rebase origin main
git add docs/ROADMAP.md project.yml yawac/Info.plist yawac.xcodeproj
git commit -m "release: 0.10.46 — F118 offline-gap message recovery" -- docs/ROADMAP.md project.yml yawac/Info.plist yawac.xcodeproj
git tag v0.10.46
git push origin main v0.10.46
```

Expected: CI release run triggered by the tag.
