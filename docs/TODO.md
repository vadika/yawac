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
- Reactions and poll-vote tallies are in-memory only; lost on restart
  (live re-arrival re-populates).
- Video/audio/document larger than 100 MB skipped with "Too large" badge
  (size cap intentional).
