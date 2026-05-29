# yawac — Yet Another WhatsApp Client

A native macOS SwiftUI client backed by [tulir/whatsmeow](https://github.com/tulir/whatsmeow).

> **Status:** Pre-alpha. Works end-to-end for text + media + groups + presence + history sync. Not affiliated with WhatsApp / Meta.

## Features

- QR-based device pairing (multi-device protocol)
- Text, image, and file messaging — 1:1 and groups
- Drag-and-drop / multi-select attachments — staged with previews + a caption before sending
- Push-and-hold voice notes (Opus/PTT, slide-up to cancel)
- Reactions, reply / quote, edit, revoke, delete-for-me
- Forward messages (single or multi-select) to another chat
- Star messages (⌘S) — synced via appstate
- Pin chats — pinned section at the top of the sidebar
- Pin messages in chat — banner above the conversation, jump on tap
- Add to contacts / edit name — synced to the phone address book
- Archive chats (collapsible Archived section) and delete chats — synced; deletes stay deleted across restarts
- Block / unblock contacts — blocked banner, sidebar indicator, Settings list
- Leave groups
- Right-click message menu with quick-reaction strip; sidebar + conversation-header action menus
- Shortcuts: double-click to edit/reply, ↑ to recall last own message
- On-device translation (Apple Translation framework)
- Chat inspector: contact About text, starred messages, shared media grid, files list — click any item to jump to its message
- Read receipts, typing indicators, presence
- Peer-device sync (edits / delete-for-me / star / pin) via appstate + SecretEncrypted
- History sync, macOS native notifications

## Install via Homebrew

```sh
brew tap vadika/yawac https://github.com/vadika/yawac
brew install --cask vadika/yawac/yawac
```

Builds are ad-hoc signed; the cask strips the macOS quarantine flag
automatically. Releases are cut from `vX.Y.Z` git tags (e.g. `git tag v0.2.0
&& git push origin v0.2.0`).

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
