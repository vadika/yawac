# Local whatsmeow patches

We carry three upstream PRs that haven't merged into whatsmeow main.
Pinned via a `replace` directive in `bridge/go.mod` pointing at the
github.com/vadika/whatsmeow fork. The fork mirrors upstream tip with
cherry-picked patches on top.

Current fork tip: `a0d4b7e975f9` (pseudo-version
`v0.0.0-20260704062504-a0d4b7e975f9`), based on upstream
`b572e5bcb92b` (Jun 30 2026).

## Applied patches

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
  upstream profile).

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

## Previously carried, now moved to bridge (no longer in fork)

- **PR #1151** — historical poll-vote tally extractor. Closed
  upstream unmerged. F117 moved the extraction to `bridge/history.go`
  as `historicalPollUpdates()` + `HistoricalPollVote` — the walk only
  touches public whatsmeow API (`HistorySync.Data`, `Conversation`,
  `WebMessageInfo.PollUpdates`), so keeping it in the fork forced a
  never-ending rebase for zero API benefit.

## Bumping the fork

```
cd /Users/vadikas/Work/whatsmeow
git fetch upstream
git checkout -b yawac-YYYY-MM-DD upstream/main
git cherry-pick <PR1160-sha> <PR1168-sha> <PR1171-sha>
git push origin yawac-YYYY-MM-DD
```

Then in yawac:

```
cd bridge
go mod edit -replace=go.mau.fi/whatsmeow=github.com/vadika/whatsmeow@<sha>
go mod tidy
cd ..
./scripts/build-xcframework.sh
```

## Dropping the fork entirely

When tulir merges all three carried PRs upstream, remove the
`replace` block:

1. Remove the `replace` directive from `bridge/go.mod`.
2. `cd bridge && go get go.mau.fi/whatsmeow@<sha-that-includes-the-fixes>`.
3. `go mod tidy`.
4. Rebuild XCFramework.

## Notes

- The fork's go.mod declares `module go.mau.fi/whatsmeow`, so `go get
  github.com/vadika/whatsmeow@...` will fail. Use `go mod edit
  -replace=...@<sha>` and let `go mod tidy` resolve the
  pseudo-version.
- The `go.sum` carries entries for `github.com/vadika/whatsmeow@...`
  instead of `go.mau.fi/whatsmeow@...`. If you remove the `replace`,
  `go mod tidy` will swap them.
