# yawac TODO

## Known limitations

### Historical reactions — unrecoverable

**Symptom:** Reactions on messages received before pairing don't show.
Only reactions cast by us after pair appear (via optimistic local
tally + DB hydration on chat re-open).

**Root cause:** WhatsApp's `HistorySync` payload doesn't include
`ReactionMessage` events. Diagnostic confirmation across multiple
conversations:

```
history reactions: 0
live dispatches: 0     (when no live reactions during the window)
```

`bridge/history.go` walks every `Conversation.GetMessages()` and
checks each `WebMessageInfo.GetMessage().GetReactionMessage()` — none
ever match. The phone aggregates reactions internally and replays
neither the individual reaction events nor any aggregate to companion
devices.

**Accepted constraint:** Past reaction state stays phone-only. Live
reactions after pair work, persist via `PersistedReaction`, and
hydrate on chat re-open.

### Historical poll vote tallies — unrecoverable

**Symptom:** Polls created before pairing show 0 votes in yawac even when the
phone shows real tallies. Only votes cast *after* pairing this device populate
the tally.

**Root cause:** WhatsApp's `HistorySync` payload includes
`PollCreationMessage`s but does **not** include the corresponding
`PollUpdateMessage` (vote) events. Diagnostic logging across 9 conversations
and 35 historical polls showed:

```
[yawac/poll-history] conv=…@g.us polls=11 votes=0  with_secret=364 total_msgs=370
[yawac/poll-history] conv=…@g.us polls=14 votes=0  with_secret=430 total_msgs=438
…
poll-history count: 9
poll-vote count: 0
```

`MessageSecret` is present on every poll creation, and the bridge persists it
via `Store.MsgSecrets.PutMessageSecret` so future votes can decrypt — but no
vote messages ever arrive in HistorySync to be decrypted.

The phone-side WhatsApp client maintains an aggregated tally view privately
and apparently doesn't replay individual vote events to companion devices.

**Workarounds considered (not implemented):**

1. **Custom IQ query for poll aggregate** — WhatsApp's web client uses a
   private XMPP-style IQ (`<iq type='get'><query xmlns='w:m:p'>…`) to fetch
   server-side poll aggregates. Undocumented, schema changes silently. High
   maintenance cost.
2. **Request media retry for vote messages** — the retry path only re-sends
   media, not vote history. Doesn't apply.
3. **Scrape from phone via Accessibility / ADB** — out of scope.

**Accepted constraint:** Past poll tallies stay phone-only. Live votes work.

### `@lid` ↔ `@s.whatsapp.net` chat duplication

**Symptom:** The same contact shows up as two chat-list rows. Example:
`Berk Arslan` (`358xxxxx@s.whatsapp.net` from address book) and `Berk`
(`123456789@lid` from a group message).

**Root cause:** WhatsApp's privacy-LID feature gives users an opaque
`@lid` identity. Different message paths surface the same person under
both namespaces:
- Address-book contacts come back as `@s.whatsapp.net`.
- Group participants in lid-protected groups come back as `@lid`.
- Direct DMs may switch over time.

These are different strings to us, so the chat list keeps them as
separate rows.

**What we fixed:** Device-suffixed variants
(`<user>:<device>@<server>`) are now normalized to the bare JID via
`JIDNormalize.bare(_:)` in `yawac/Models/Chat.swift`. Existing
device-suffixed rows in `PersistedChat` are collapsed into canonical
rows on app start (`ChatListViewModel.loadChats`). Unread counts get
summed, the latest timestamp wins.

**What stays broken:** `@lid` ↔ `@s.whatsapp.net` for the *same person*
cannot be linked without a server-side identity lookup. whatsmeow's
`store.Devices` keeps some `lid<->primary` mapping but only for
devices we have a Signal session with; it's incomplete in practice.

**Workaround:** None automatic. Manual: open the `@lid` chat once so
the resolved push-name surfaces; you'll at least see the same display
name on both rows.

### whatsmeow limitations (research pass)

Sourced from `whatsmeow@v0.0.0-20260516102357-8d3700152a69` + upstream
issues. Items below are protocol-level constraints we can't fix
client-side; they shape what yawac can sensibly support.

#### Calls
- Voice/video cannot be initiated or answered from a companion
  (`call.go:106-121`). Only inbound `RejectCall` is exposed.
- yawac action: show incoming-call banner; "open phone to answer".

#### Status / broadcast
- Status post recipient list comes from local contact cache
  (`broadcast.go:77`); may miss recipients before app-state contact sync
  completes.
- No "viewed by X" events surfaced.

#### Newsletter / Channels
- `Platform == MACOS` triggers `argo decoding is currently broken`
  (`newsletter.go:173,208`). Keep a non-MACOS UA.
- `NewsletterMarkViewed` drops the server response (`newsletter.go:78`).

#### Polls
- `BuildPollCreation` silently clamps invalid `selectableOptionCount` to 0
  (`msgsecret.go:328`). Validate client-side.
- No high-level "add option" builder despite `EncSecretPollAddOption`
  (`msgsecret.go:38`).
- LID-migration secret-lookup fallback in `msgsecret.go:115` can fail
  silently. Some PN↔LID vote decrypts will never succeed (upstream #1076).

#### Reactions
- ~~Community-announcement encrypted reactions need explicit
  `DecryptReaction`~~ — handled in `bridge/messages.go` +
  `bridge/history.go` (both live and history-sync paths).
- Same LID-migration silent decrypt failure as polls.

#### Media
- View-once messages return full payload; yawac must enforce "viewed" state.
- Sticker packs need a separate `FetchStickerPack(packID)` call
  (`download.go:209`).
- Mid-quality variants aren't exposed.
- `ReturnDownloadWarnings` is a package global (`download.go:330`), not
  per-client.
- No chunked upload; large files = single POST.
- `media_conn` refresh has no client-side throttle beyond TTL — yawac adds
  its own 30 s cooldown.
- `ErrMediaNotAvailableOnPhone` from MediaRetry = terminal, do not loop.

#### Groups
- Community announcement groups still send PN-addressed despite LID
  context (`send.go:1190` "very hacky hack"). Expect occasional decrypt
  issues at recipient end.
- Cached group addressing mode never re-checked (`group.go:973`);
  invalidate on any `GroupInfo` change.
- Topic-set sender may be missing (`group.go:734`).
- Participant-hash mismatch on send doesn't invalidate device list
  (`send.go:453,458`); some devices may miss messages.

#### Disappearing messages
- Library does NOT auto-wrap outgoing messages in `EphemeralMessage`.
  yawac must track per-chat timer and wrap manually.
- `disappearing_mode` notifications aren't surfaced (`notification.go:496`),
  so changes to default timer on phone go unnoticed.

#### Encryption / retries
- Retry receipts capped at 5 (`retry.go:482`). Past that, message is lost.
- Retry requests drop after 10 internal counts (`retry.go:238`); peer may
  never receive.
- Session re-create throttled to 1/hour/peer (`retry.go:157`).
- ~~Should enable `Client.UseRetryMessageStore = true`~~ — applied in
  `bridge/client.go`.
- ~~Prekey top-up runs only on connect~~ — `bridge/prekeys.go` runs a
  30 min loop calling `DangerousInternals.GetServerPreKeyCount` +
  `UploadPreKeys` while connected.

#### App-state sync
- Cannot create new keys (`appstate.go:526`). Lose them → re-pair
  required. NEVER drop `app_state_sync_keys`.
- `ClearChatAction.DeleteMedia` may parse wrong (`appstate.go:298`).
- Key-request retry interval hard-coded 24 h (`appstate.go:469`); mute
  /archive can lag a day.
- ~~Pin / star / delete-for-me not surfaced~~ — yawac sets
  `EmitAppStateEventsOnFullSync = true` and handles `events.Pin` / `events.Star`
  / `events.DeleteForMe`; cold-start pin state reconciled from
  `Store.ChatSettings` (`ChatListViewModel.reconcilePinsWithStore`).

#### LID / Privacy
- Encryption-time LID lookups are local-cache only (`send.go:1290`).
  Missing entries → send may go to wrong identity.
- `icdc` identity data not fully stored (`user.go:778,780,792`).

#### Login / re-pair
- `device_removed` (401) deletes the store automatically
  (`connectionevents.go:40-47`). yawac should back up the SQLite store
  before letting this run, or rely on user re-pair.
- Fresh-pair first outbound may not deliver (upstream #1095). Add 2-3 s
  delay after pair-success before first send.
- iOS pairing first attempt often fails (upstream #1039).

#### Connectivity / reconnect
- whatsmeow auto-reconnects (`EnableAutoReconnect`, backoff `errors×2s`) +
  keepalive-pings (20–30s, forces reconnect after 3 min of failures). yawac
  adds a `ConnectivityMonitor` that forces an immediate reconnect on
  wake-from-sleep / network-path change / app-active, retrying with backoff
  until connected (`yawac/Services/ConnectivityMonitor.swift`).
- **Slow recovery after a Wi-Fi flap (~40–60s).** Go's pure-Go DNS resolver
  lags reading `resolv.conf` after a network change — `lookup …: no such host`
  persists for tens of seconds even though the system resolver (and other apps)
  resolve instantly. The indefinite retry loop reconnects once the resolver
  catches up; the banner shows Connecting/Offline meanwhile.
  - The `netcgo` build tag (force cgo `getaddrinfo`) makes recovery instant but
    **destabilizes gomobile — beachball/crash on disconnect**. Reverted; not
    usable. Accepted constraint: self-healing but not instant.
- Post-sleep sockets are half-open: `IsConnected()` returns stale `true`, so the
  wake trigger forces a reconnect unconditionally rather than gating on it.

#### Rate limits
- No global IQ throttle in whatsmeow. yawac mitigates via:
  - `AvatarSemaphore(limit: 4)` around `FetchProfilePicture` calls.
  - 30 s cooldown on force `RefreshMediaConn` (`bridge/client.go`).
  - Still vulnerable on `GetUserInfo` bursts — wrap if needed.

#### Protocol / version drift
- `store.SetWAVersion` is NOT auto-updated; outdated builds hit 405
  `ClientOutdated`.
- Known data race in FrameSocket (upstream #1085).
- Unknown server error 463 with no recovery (upstream #1074).

#### Receipts / edits
- `played-self` not distinguished (`receipt.go:212`).
- Edit timestamp precision may be lost (`message.go:258`).

### Other deferred items

- Past media (PDFs/etc) that hash-mismatch on download: `DownloadMediaForce`
  fallback also runs a plaintext-SHA check; when the server returns
  genuinely-different bytes (file deleted, re-uploaded, or never available
  to this companion), the bubble shows
  `plaintext sha mismatch — server returned wrong bytes` instead of saving
  garbage. MediaRetry receipt may recover when the phone has the original
  file; otherwise unrecoverable from a companion device.
- MediaRetry decryption fails with `cipher: message authentication failed`
  for some historical media even though the phone successfully re-uploads
  (we receive valid ciphertext, just 200 bytes of encrypted retry
  notification). Cause: our stored `mediaKey` (from HistorySync's
  DocumentMessage) does not match the key the phone uses for the retry
  receipt. Likely the original message was edited/superseded on phone
  with a new mediaKey, but HistorySync surfaced the old proto.
  **Workaround:** ask the original sender to forward the file again,
  producing a fresh message with mediaKey that we will receive live.
- `@<phone>` mentions for users who never sent a message + aren't in
  contacts: leave as raw digits (no push-name source).
- Multi-select poll UI: tap = replaces current selection; no batch
  "select multiple then submit" flow.
- ~~Reactions and poll-vote tallies are in-memory only; lost on restart~~ —
  both now persist (`PersistedReaction` / `PersistedPollVote`) and hydrate on
  chat load. (Historical pre-pair tallies remain unrecoverable — see above.)
- Video/audio/document larger than 100 MB skipped with "Too large" badge
  (size cap intentional).
