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

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15 or newer
- Go 1.22 or newer
- Homebrew (for `xcodegen` and Go if not already installed)

## Install via Homebrew

```sh
brew tap vadika/yawac https://github.com/vadika/yawac
brew install --cask vadika/yawac/yawac
```

Builds are ad-hoc signed; the cask strips the macOS quarantine flag
automatically. Each push to `main` produces a new `0.1.0+<sha>` build.

## Build

    ./scripts/install-tools.sh       # one-time: gomobile + gobind
    ./scripts/build-xcframework.sh   # builds build/Bridge.xcframework (5-15 min first time)
    xcodegen generate                # produces yawac.xcodeproj from project.yml
    open yawac.xcodeproj

To build from CLI:

    xcodebuild -project yawac.xcodeproj -scheme yawac \
        -destination 'platform=macOS' build \
        CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

To run tests:

    cd bridge && go test -short ./...
    xcodebuild -project yawac.xcodeproj -scheme yawac \
        -destination 'platform=macOS' test \
        CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

## Project layout

    bridge/                     — Go module, gomobile-bindable wrapper
    scripts/                    — install-tools, build-xcframework, release
    yawac/                      — SwiftUI app sources
        Bridge/                 — WAClient + JSON mirrors
        Models/                 — Chat, Message, PersistedMessage (SwiftData)
        ViewModels/             — Session, ChatList, Conversation, Groups
        Views/                  — Login (QR), ChatList, Conversation, MessageRow,
                                  ComposerView, GroupInfoView, QRCodeView
        Services/               — AppPaths, NotificationService, MediaCache
    yawacTests/                 — XCTest
    project.yml                 — XcodeGen project descriptor
    docs/superpowers/plans/     — implementation plan
    .github/workflows/ci.yml    — CI pipeline

The `yawac.xcodeproj` directory is generated from `project.yml`; do not commit it.

## Troubleshooting

- **`gomobile: command not found`** — re-run `./scripts/install-tools.sh` and ensure `$(go env GOPATH)/bin` is on `PATH`.
- **`undefined symbol _res_9_nsearch`** at link time — `OTHER_LDFLAGS: -lresolv` is set in `project.yml` for the yawac target. If you split the target structure, copy that setting.
- **`** TEST FAILED **` with code-sign error for `yawacTests`** — `xcodebuild test` requires `CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` flags for ad-hoc dev (no Developer ID).
- **`xcodebuild` cannot find `yawac` scheme** — run `xcodegen generate` to regenerate the project.
- **Build hangs at "Compiling whatsmeow"** — first gomobile bind takes 5–15 minutes (cross-compiles whatsmeow + transitive deps for arm64 + x86_64). Subsequent builds are cached.

## Release

To produce a signed + notarized `.app`:

1. Have an active **Apple Developer ID Application** certificate in your keychain.
2. Create a notarytool keychain profile once:

       xcrun notarytool store-credentials yawac \
           --apple-id you@example.com \
           --team-id ABCDE12345 \
           --password app-specific-pw

3. Run:

       export DEV_ID_APPLICATION="Developer ID Application: Your Name (ABCDE12345)"
       export NOTARY_PROFILE=yawac
       ./scripts/release.sh

The script builds the XCFramework, archives the app, signs it with the Developer ID, submits to Apple's notary service, waits for completion, and staples the resulting ticket. Output: `build/export/yawac.app`.

## Caveats

- **Unofficial protocol.** whatsmeow speaks the multi-device companion protocol that WhatsApp doesn't officially support for third-party clients. Use at your own risk; accounts can be banned if usage looks bot-like.
- **Multi-device limit.** WhatsApp allows up to 4 linked devices per account. yawac counts as one.
- **No call support.** Voice/video calls are out of scope for this build.

## License

(unset — add a LICENSE file if publishing)

## Acknowledgments

- [tulir/whatsmeow](https://github.com/tulir/whatsmeow) — the heavy lifting
- [modernc.org/sqlite](https://gitlab.com/cznic/sqlite) — pure-Go SQLite driver used as the whatsmeow store backend
- [gomobile](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile) — Go-to-Apple framework binding
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — declarative Xcode project generation
