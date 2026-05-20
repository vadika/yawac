# yawac TODO

## Known limitations

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

### Other deferred items

- Past media (PDFs/etc) that hash-mismatch on download fall back to
  `DownloadMediaForce` (skips SHA + HMAC) — file may differ from original
  upload. No clean fix without server cooperation.
- `@<phone>` mentions for users who never sent a message + aren't in
  contacts: leave as raw digits (no push-name source).
- Multi-select poll UI: tap = replaces current selection; no batch
  "select multiple then submit" flow.
- Reactions and poll-vote tallies are in-memory only; lost on restart
  (live re-arrival re-populates).
- Video/audio/document larger than 100 MB skipped with "Too large" badge
  (size cap intentional).
