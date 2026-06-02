# yawac — Yet Another WhatsApp Client

A native macOS SwiftUI client backed by [tulir/whatsmeow](https://github.com/tulir/whatsmeow).

> **Status:** Pre-alpha. Works end-to-end for text + media + groups + presence + history sync. Not affiliated with WhatsApp / Meta.

## Features

**Messaging**
- Text, images, files, and voice notes (Opus/PTT, push-and-hold, slide to cancel) — 1:1 and groups
- Drag-and-drop, multi-select, or `⌘V` to stage attachments with previews + caption before sending
- Reactions, reply, edit, revoke, delete-for-me, forward (single or multi-select), star
- `@`-mention autocomplete (and `@everyone` in groups) — recipients see proper mentions + ping notifications
- On-device translation (Apple Translation framework)

**Chats**
- Pin chats (sidebar section) and pin messages in chat (jump-on-tap banner)
- Mute (8h / 1 week / Always; bell-slash badge; suppresses banner + dock badge + reactions; `@`-mentions pierce mute)
- Archive, delete, block / unblock — synced via appstate; deletes survive restarts
- Add to contacts and edit names — synced to the phone address book
- Per-chat drafts persist across restarts
- Locale-aware sidebar dates ("Yesterday", year on old dates, 12/24h per system)

**Groups & Communities**
- Edit group name, description, and photo (with pan/zoom crop sheet) — admin-gated, cross-device sync
- Live participant management — add (from contacts or by `+phone`), remove, promote, demote
- Public invite link with QR — copy, share, admin-only revoke with cooldown
- `⌘K` recognises pasted `chat.whatsapp.com` / `wa.me` links and offers one-tap join (with pending-approval state)
- Community sub-groups directory — browse every group linked under a community; best-effort Join

**Search & navigation**
- In-chat `⌘F` find bar with highlight + ↑/↓ navigation
- Sidebar `⌘K` — chats, messages (FTS5 ranked snippets, tap to jump), and invite-link previews
- Chat inspector — About text, starred messages, shared media grid, files list (tap any to jump)

**Platform**
- QR-based pairing (multi-device protocol); history sync; macOS native notifications + dock badge
- Read receipts, typing indicators, presence
- Peer-device sync (edits, delete-for-me, star, pin, mute) via appstate
- Interface size scaling (Small → X-Large) for custom fonts
- Keyboard shortcuts sheet (`⌘?` from the Help menu)

## Install via Homebrew

```sh
brew tap vadika/yawac https://github.com/vadika/yawac
brew install --cask vadika/yawac/yawac
```

Builds are ad-hoc signed; the cask strips the macOS quarantine flag
automatically. Releases are cut from `vX.Y.Z` git tags (e.g. `git tag v0.6.0
&& git push origin v0.6.0`).

Requires macOS 14 (Sonoma) or newer.

## Developing

Local build, project layout, troubleshooting, and release flow live in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## Caveats

- **Unofficial protocol.** whatsmeow speaks the multi-device companion protocol that WhatsApp doesn't officially support for third-party clients. Use at your own risk; accounts can be banned if usage looks bot-like.
- **Multi-device limit.** WhatsApp allows up to 4 linked devices per account. yawac counts as one.
- **No call support.** Voice/video calls are out of scope for this build.

## License

[Mozilla Public License 2.0](LICENSE). File-level copyleft: modifications to
MPL-covered files must be published under the MPL, but you can combine the
work with code under other licenses (including proprietary) without
relicensing the rest. Matches the license of the upstream
[whatsmeow](https://github.com/tulir/whatsmeow) library.

## Acknowledgments

- [tulir/whatsmeow](https://github.com/tulir/whatsmeow) — the heavy lifting
- [modernc.org/sqlite](https://gitlab.com/cznic/sqlite) — pure-Go SQLite driver used as the whatsmeow store backend
- [gomobile](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile) — Go-to-Apple framework binding
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — declarative Xcode project generation
