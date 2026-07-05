# Offline-Gap Message Recovery (F118) — Design

Date: 2026-07-05
Status: approved (silent-recovery scope)

## Problem

Messages received and read on the phone while yawac is offline sometimes
never appear in the app. Observed case: image message
`AC495A1FF51C4ED9588FA6F8CD808BA7` from `220405054881957@lid` in
`33612785613-1601323552@g.us` reached the bridge's offline batch but was
never dispatched or persisted.

F92's reconnect catch-up (type-6 `FULL_HISTORY_SYNC_ON_DEMAND`) cannot
recover these: history sync is backward-only and the server picks the
chats. There is no fetch-newer RPC.

## Root cause

Probable loss chain: offline drain → group `skmsg` decrypt failure
(missing sender key) → whatsmeow emits `events.UndecryptableMessage` →
bridge drops it silently (`bridge/events.go:70-73`, no log) → whatsmeow's
only automatic recovery is a retry receipt to the *original sender*,
which often goes unanswered for LID senders in groups → message lost.

whatsmeow has a second recovery path — ask own phone to resend
(`PLACEHOLDER_MESSAGE_RESEND` peer message, what WA Web uses for
"Waiting for this message") — but it is gated on
`Client.AutomaticMessageRerequestFromPhone`, default false, and the
bridge never sets it.

Verified in whatsmeow source (fork tip `a0d4b7e975f9`):

- `retry.go:490-496` — on first decrypt failure (retryCount == 1) with
  the flag set, `delayedRequestMessageFromPhone` fires after
  `RequestFromPhoneDelay` (5 s).
- `retry.go:450-458` — `immediateRequestMessageFromPhone` =
  `SendPeerMessage(BuildUnavailableMessageRequest(chat, sender, id))`.
- `message.go:829-848` — phone's response (`WebMessageInfo` bytes) is
  parsed via `ParseWebMessage` and dispatched as a **normal
  `*events.Message`** with `UnavailableRequestID` set. No new consumer
  plumbing needed; existing `dispatchMessage` → Swift path persists it.
- `message.go:307-315` — fully-unavailable messages (no ciphertext at
  all) already request from phone unconditionally; only the
  ciphertext-present decrypt-fail path needs the flag.

## Changes (bridge only, no Swift)

1. **Enable phone rerequest** — `bridge/client.go`, next to
   `SkipBrokenAppStatePatches`:

   ```go
   wa.AutomaticMessageRerequestFromPhone = true
   ```

2. **Log undecryptable events** — `bridge/events.go`, in the existing
   `case *events.UndecryptableMessage:` (currently a comment-only no-op):

   ```go
   log.Printf("[yawac/undecrypt] id=%s chat=%s sender=%s unavailable=%v mode=%s",
       v.Info.ID, v.Info.Chat, v.Info.Sender, v.IsUnavailable, v.DecryptFailMode)
   ```

   (Match the bridge's actual logging idiom at implementation time.)
   Still no dispatch to Swift.

3. **Manual resend request** — new exported bridge func (~12 LOC, in
   `bridge/messages.go` or a small new file):

   ```go
   // RequestMessageResend asks the primary phone to resend a message
   // this client never received (or failed to decrypt). The resent
   // message arrives as a normal Message event.
   func (c *Client) RequestMessageResend(chatJID, senderJID, msgID string) error
   ```

   Parses both JIDs (`types.ParseJID`, error out on failure), then
   `c.wa.SendPeerMessage(ctx, c.wa.BuildUnavailableMessageRequest(chat, sender, msgID))`.

## Recovery data flow

Future losses: decrypt fail → retry receipt to sender → 5 s → peer
request to own phone → phone resends → whatsmeow dispatches
`events.Message` → `dispatchMessage` → Swift upserts by message ID →
bubble appears. Media downloads normally (the resent `WebMessageInfo`
carries media keys); if the media is expired, the existing
`RequestMediaRetry` path applies.

Known lost image: recovered manually via `RequestMessageResend` with the
coordinates from the log (chat `33612785613-1601323552@g.us`, sender
`220405054881957@lid`, id `AC495A1FF51C4ED9588FA6F8CD808BA7`).

## Caveats (accepted)

- Phone must be online and still hold the message.
- Automatic rerequest fires once per message ID per session
  (whatsmeow-internal bookkeeping).
- Past losses other than the known image stay lost — no IDs to request.
- No placeholder UI. Add only if `[yawac/undecrypt]` logs show frequent
  unrecovered failures (phone offline at rerequest time).

## Testing

- Go unit test: `RequestMessageResend` JID-parse error paths (invalid
  chat, invalid sender). Happy path requires a live socket — not unit
  tested.
- Empirical: rebuild XCFramework, run app, invoke `RequestMessageResend`
  for the known lost image via a temporary one-shot call in
  `SessionViewModel`'s `.connected` handler (removed after
  verification), verify `[yawac/undecrypt]`-adjacent dispatch
  in `/tmp/yawac.log` and the image bubble appearing in the group chat.
  This exercises the same peer-request + response path the automatic
  flag uses.
