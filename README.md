# yawac — Yet Another WhatsApp Client

A native macOS SwiftUI client backed by [tulir/whatsmeow](https://github.com/tulir/whatsmeow).

> **Status:** Pre-alpha. Works end-to-end for text + media + groups + presence + history sync. Not affiliated with WhatsApp / Meta.

## Features

**Messaging**
- Text, images, files, and voice notes (Opus/PTT, push-and-hold, slide to cancel) — 1:1 and groups
- Drag-and-drop, multi-select, or `⌘V` to stage attachments with previews + caption before sending
- Reactions, reply, edit, revoke, delete-for-me, forward (single or multi-select), star
- `@`-mention autocomplete (and `@everyone` in groups) — recipients see proper mentions + ping notifications
- Static location via MapKit picker (search + current location + draggable pin); inbound LiveLocation renders with a live badge
- Single-contact share as a WhatsApp-compatible vCard with tappable "Message on WhatsApp" recipient action
- Disappearing messages — chat-level timer (off / 24h / 7d / 90d) set from chat info; outgoing messages wrap in `EphemeralMessage` automatically
- View-once — incoming reveals once then locks + deletes on disk; outbound has a per-attachment toggle on image/video chips
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
- Create groups, communities, and sub-groups from the sidebar `+` menu and from a community parent's info pane
- Community admin — link / unlink existing groups, toggle "require admin approval to join", review and approve / reject pending join requests with a sidebar pending-count chip

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

### Troubleshooting: `brew tap` asks for GitHub credentials

`brew tap` runs `git clone` under the hood. GitHub no longer accepts
password auth on git operations, so a stale credential helper can
turn a public-repo clone into:

```
remote: Invalid username or token. Password authentication is not
supported for Git operations.
```

Fixes (pick one):

```sh
# Suppress the credential prompt for this one tap.
GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
  brew tap vadika/yawac https://github.com/vadika/yawac

# Or skip brew entirely and grab the latest release zip directly.
ver=$(curl -sSL https://api.github.com/repos/vadika/yawac/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
curl -L -o /tmp/yawac.zip \
  "https://github.com/vadika/yawac/releases/download/v${ver}/yawac-${ver}.zip"
unzip -o /tmp/yawac.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/yawac.app
open /Applications/yawac.app
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
