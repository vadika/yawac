# yawac — Yet Another WhatsApp Client

A native macOS SwiftUI client backed by [tulir/whatsmeow](https://github.com/tulir/whatsmeow).

> **Status:** Pre-alpha. Works end-to-end for text + media + groups + presence + history sync. Not affiliated with WhatsApp / Meta.

## Features

- QR-based device pairing (multi-device protocol)
- Send & receive text messages
- Image attachment (file picker + drag-and-drop)
- Inline image rendering (where local file path is known)
- Group conversations
- Read receipts (✓ sent, ✓○ delivered, ✓● read)
- Typing indicators & presence subscription
- History sync banner
- macOS native notifications
- Persistent message + chat store (SwiftData on top of SQLite)
- Log out & re-pair

## Architecture

```
┌──────────────────────────────────────────────┐
│  yawac.app (SwiftUI)                         │
│  ┌────────────────────────────────────────┐  │
│  │  Views (SwiftUI)                       │  │
│  │  Login · ChatList · Conversation       │  │
│  │  ViewModels (@Observable @MainActor)   │  │
│  │  Session · ChatList · Conversation     │  │
│  │  Groups · Notification · MediaCache    │  │
│  └─────────────────┬──────────────────────┘  │
│                    │ AsyncStream<Event>      │
│  ┌─────────────────▼──────────────────────┐  │
│  │  WAClient (@MainActor wrapper)         │  │
│  │  • multicast event fanout              │  │
│  │  • Codable JSON ⇄ BridgeMessage etc.   │  │
│  └─────────────────┬──────────────────────┘  │
└────────────────────┼─────────────────────────┘
                     │ Objective-C bridge
┌────────────────────▼─────────────────────────┐
│  Bridge.xcframework (gomobile-built)         │
│  Go package: bridge/                         │
│  ┌────────────────────────────────────────┐  │
│  │  Client wraps *whatsmeow.Client        │  │
│  │  EventSink interface → Swift callbacks │  │
│  │  JSON payloads for complex types       │  │
│  └─────────────────┬──────────────────────┘  │
│  ┌─────────────────▼──────────────────────┐  │
│  │  whatsmeow + sqlstore + modernc sqlite │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

The Go bridge exposes a flat, gomobile-friendly API: basic types (string, int, []byte) and JSON strings for complex payloads. Swift wraps the generated Objective-C classes in a `@MainActor` `WAClient` actor that publishes a multicast `AsyncStream<Event>`.

## Install via Homebrew

```sh
brew tap vadika/yawac https://github.com/vadika/yawac
brew install --cask vadika/yawac/yawac
```

Builds are ad-hoc signed; the cask strips the macOS quarantine flag
automatically. Each push to `main` produces a new `0.1.0+<sha>` build.

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
