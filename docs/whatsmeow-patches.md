# Local whatsmeow patches

We carry four upstream PRs that haven't merged into whatsmeow main.
Pinned via a `replace` directive in `bridge/go.mod` pointing at the
github.com/vadika/whatsmeow fork. The fork mirrors upstream tip with
cherry-picked patches on top.

Current fork tip: `e4ae908359c8` (pseudo-version
`v0.0.0-20260704061232-e4ae908359c8`), based on upstream
`b572e5bcb92b` (Jun 30 2026).

## Applied patches

- **PR #1151** — historical poll-vote tally extractor.
  Upstream: https://github.com/tulir/whatsmeow/pull/1151

  Adds `events.HistorySync.HistoricalPollUpdates()` which flattens
  `WebMessageInfo.PollUpdates` records across all conversations in a
  HistorySync blob into `[]events.HistoricalPollVote`. Used by
  `bridge/history.go` so newly-paired companions can render existing
  poll tallies they never received as live `PollUpdateMessage` events.

- **PR #1160** — binary decoder doesn't panic on malformed nodes.
  Upstream: https://github.com/tulir/whatsmeow/pull/1160

  `consumeFrames` has no recover, so a single malformed frame
  panicked the whole goroutine and took down the process. Returns an
  error instead. Carries a fuzz target + table tests + a
  marshal/unmarshal round trip.

- **PR #1168** — per-address signal session lock around encrypt
  and decrypt.
  Upstream: https://github.com/tulir/whatsmeow/pull/1168

  Prevents the send-while-receive ratchet race where one side
  overwrites the other's session advance, causing either silent
  "old counter" drops at the recipient or a permanent record bloat
  from spurious skipped-message keys (22.5 MB observed on the
  upstream profile). Likely closes our issue #6.

- **PR #1171** — `Client.SkipBrokenAppStatePatches` opt-in.
  Upstream: https://github.com/tulir/whatsmeow/pull/1171

  Default off; yawac sets it `true` in `bridge/client.go`. Advances
  the appstate version cursor past patches that fail LTHash
  verification or reference missing sync keys, instead of aborting
  the entire collection. Bounded skip-loop (300ms throttle × 200
  cap). Fixes upstream issues #382, #518, #651, #858 where a
  server-side bad patch wedges archive/mute/pin sync forever.

## Previously applied, now upstreamed (no longer carried)

- **PR #1120** — appstate auto-recovery snapshot trigger. Merged
  upstream as `b6f3348` + `1ba7eba`.
- **PR #1148** — LID-addressed conversation privacy-token extraction.
  Merged upstream as `595ceb0` (which also adds the missing
  PhoneNumber→LID mapping store call alongside the privacy-token fix).

## Bumping the fork

```
cd /tmp && git clone git@github.com:vadika/whatsmeow.git
cd whatsmeow
git remote add upstream https://github.com/tulir/whatsmeow.git
git fetch upstream
git rebase upstream/main          # re-applies the PR #1151 patch on top
git push --force-with-lease origin main
```

Then in yawac:

```
cd bridge
# Edit replace directive in go.mod with new pseudo-version.
go mod tidy
cd ..
./scripts/build-xcframework.sh
```

## Dropping the fork entirely

When tulir merges PR #1151 upstream, remove the `replace` block:

1. Remove the `replace` directive from `bridge/go.mod`.
2. `cd bridge && go get go.mau.fi/whatsmeow@<sha-that-includes-the-fix>`.
3. `go mod tidy`.
4. Rebuild XCFramework.

## Notes

- The fork's go.mod declares `module go.mau.fi/whatsmeow`, so `go get
  github.com/vadika/whatsmeow@...` will fail. Edit the `replace`
  directive's pseudo-version by hand and let `go mod tidy` resolve.
- The `go.sum` carries entries for `github.com/vadika/whatsmeow@...`
  instead of `go.mau.fi/whatsmeow@...`. If you remove the `replace`,
  `go mod tidy` will swap them.
