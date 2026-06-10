# yawac — Yet Another Client for WhatsApp

A native macOS SwiftUI client backed by [tulir/whatsmeow](https://github.com/tulir/whatsmeow).

> **Status:** Pre-alpha. Works end-to-end for text + media + groups + presence + history sync. Not affiliated with WhatsApp / Meta.

## Features

**Messaging**
- Send and receive text, photos, files, and voice notes — in one-on-one chats and groups
- Drag-and-drop or paste attachments, with a preview and caption before sending
- React, reply, edit, delete, forward, and star messages
- Mention people with `@` (and `@everyone` in groups)
- Share your location, or open a live location someone sent you on the map
- Share a contact card; recipients can tap "Message on WhatsApp" to start a chat
- Disappearing messages — pick a timer (off / 24h / 7d / 90d) per chat
- View-once photos and videos — reveal once on receive, send your own with a single toggle
- On-device translation for incoming messages

**Chats**
- Pin chats to the top of the sidebar and pin important messages inside a chat
- Mute a chat for 8 hours, a week, or until you turn it back on (mentions still notify)
- Archive, delete, or block — kept in sync with your phone
- Save names to contacts; changes sync back to the phone address book
- Drafts saved per chat across restarts
- Sidebar shows "Yesterday" and friendly dates in your locale's 12/24-hour format

**Groups & Communities**
- Edit a group's name, description, and photo (admins only)
- Add, remove, promote, and demote members from the group info pane
- Generate, share, and revoke invite links — with a QR code for in-person sharing
- Paste an invite link into `⌘K` to preview the group and join with one click
- Browse and join community sub-groups from the community directory
- Create new groups, communities, and sub-groups from the sidebar `+` menu
- Community admin tools — link/unlink sub-groups, require approval to join, review pending requests

**Search & navigation**
- `⌘F` in a chat to find and jump between matches
- `⌘K` to search every chat and message across the app, with ranked snippets
- Chat inspector — About, starred messages, shared media grid, and file list (tap to jump back)

**Platform**
- QR code to link your account, just like the official mobile + web clients
- Native macOS notifications and dock badge
- Read receipts, typing indicators, and online presence
- Edits, deletes, stars, pins, and mutes stay in sync across your linked devices
- Adjustable interface size (Small → X-Large) for custom fonts
- Keyboard shortcuts cheat sheet — `⌘?` from the Help menu

## Install via Homebrew

```sh
brew tap vadika/yawac https://github.com/vadika/yawac
brew trust vadika/yawac
brew install --cask vadika/yawac/yawac
```

(Homebrew 4 requires the one-time `brew trust` for any third-party tap.)

Requires macOS 14 (Sonoma) or newer.

Install hitting a snag? See [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Developing

Local build, project layout, troubleshooting, and release flow live in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## Caveats

- **Unofficial protocol.** whatsmeow speaks the multi-device companion protocol that WhatsApp doesn't officially support for third-party clients. Use at your own risk; accounts can be banned if usage looks bot-like.
- **Multi-device limit.** WhatsApp allows up to 4 linked devices per account. yawac counts as one.
- **No call support.** Voice/video calls are out of scope for this build.

## Sponsor

yawac is a one-person passion project, and it stays free and open source under
MPL-2.0 — every feature, every release, no exceptions. There's no paid tier, no
license key, nothing behind a paywall.

If it's earned a place in your dock, you can help keep it maintained:

[**❤️ Sponsor yawac on GitHub**](https://github.com/sponsors/vadika)

Sponsorship funds the ongoing work — chasing WhatsApp's protocol changes, cutting
notarized releases, and keeping the lights on. It is **not** a purchase, a support
contract, or a warranty. yawac speaks an unofficial protocol (see
[Caveats](#caveats)); sponsoring doesn't change that risk, and I can't promise
uptime, compatibility, or that your account won't be flagged. You're backing the
work, not buying a product.

Sponsors (thank you 🙏): <!-- names added here -->

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
