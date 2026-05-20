# Local whatsmeow patches

We carry two upstream PRs that haven't merged into whatsmeow main.
Applied as a local clone at `/Users/vadikas/Work/vendor/whatsmeow-fork`,
referenced via a `replace` directive in `bridge/go.mod`.

Base commit: `8d3700152a6930c5a7fdae84a47b49a34d3d9cb0` (matches the
pseudo-version `v0.0.0-20260516102357-8d3700152a69` we were pinned to).

## Applied patches

- **PR #1120** — appstate auto-recovery snapshot trigger.
  Branch: `yawac-patches`, commit `dc1589a` (on top of `8d37001`).
  Upstream: https://github.com/tulir/whatsmeow/pull/1120

  When `applyAppStatePatches` sees `ErrMismatchingLTHash` or
  `ErrMismatchingPatchMAC`, fires off `BuildAppStateRecoveryRequest(name)`
  via `SendPeerMessage` so the primary device sends a fresh snapshot.
  `handleAppStateRecovery` (already present in our base) consumes it and
  resets the local collection — unsticks accounts whose app state diverged
  from the server after offline mutations or upstream proto bumps.

- **PR #1148** — LID-addressed conversation privacy-token extraction.
  Branch: `yawac-patches`, commit `235f2f1` (on top of `dc1589a`).
  Upstream: https://github.com/tulir/whatsmeow/pull/1148

  `storeHistoricalMessageSecrets` now also extracts `tcToken` for chats
  whose `chatJID.Server == types.HiddenUserServer` (LID), not just
  `DefaultUserServer`. Without this, accounts migrated to LID get zero
  privacy tokens from history sync and 1:1 sends fail with WA error 463.

## Updating

When tulir merges either PR upstream, drop the local clone:

1. Remove the `replace` directive from `bridge/go.mod`.
2. `cd bridge && go get go.mau.fi/whatsmeow@<sha-that-includes-the-fix>`.
3. `go mod tidy`.
4. Rebuild XCFramework.
5. Delete `/Users/vadikas/Work/vendor/whatsmeow-fork`.

## Rebuilding after pulling new whatsmeow main

To stay current while keeping our patches:

```
cd /Users/vadikas/Work/vendor/whatsmeow-fork
git fetch origin main
git rebase origin/main
cd /Users/vadikas/Work/yawac
./scripts/build-xcframework.sh
```

## Concerns

- The fork repo lives outside the yawac git tree at an absolute path. If
  the project (or the vendor dir) is ever moved, update the `replace`
  target in `bridge/go.mod`. Anyone cloning yawac fresh must reproduce
  the `/Users/vadikas/Work/vendor/whatsmeow-fork` checkout, or rebuild
  the patchset under their own path and adjust the `replace`.
- The `go.sum` no longer carries entries for `go.mau.fi/whatsmeow`
  itself (local replace path → no checksum). Indirect dependencies
  inherited from whatsmeow are still pinned via go.sum. If you remove
  the `replace`, `go mod tidy` will re-fetch and re-checksum.
- `go mod download` run before the replace lands will pull upstream;
  always commit `bridge/go.mod` with the `replace` block intact.
