# Development

Local build, project layout, troubleshooting, and release flow for `yawac`.

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
│  │  • one session event consumer              │  │
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

The Go bridge exposes a flat, gomobile-friendly API: basic types (string, int, []byte) and JSON strings for complex payloads. Swift wraps the generated Objective-C classes in a `@MainActor` `WAClient` actor whose `AsyncStream<Event>` is consumed by the session. See [ARCHITECTURE.md](ARCHITECTURE.md) for state and persistence ownership.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15 or newer
- Go 1.22 or newer
- Homebrew (for `xcodegen` and Go if not already installed)

## Build

    ./scripts/install-tools.sh       # one-time: gomobile + gobind
    ./scripts/build-xcframework.sh   # builds build/Bridge.xcframework (5–15 min first time)
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
    scripts/                    — install-tools, build-xcframework, release-edge,
                                  release, bump-cask
    yawac/                      — SwiftUI app sources
        Bridge/                 — WAClient + JSON mirrors
        Models/                 — Chat, Message, PersistedMessage (SwiftData)
        ViewModels/             — Session, ChatList, Conversation, Groups,
                                  ChatSearch, Translation
        Views/                  — Login (QR), ChatList, Conversation, MessageRow,
                                  ComposerView, GroupInfoView, QRCodeView,
                                  SettingsView
        Services/               — AppPaths, NotificationService, MediaCache,
                                  LanguageDetector, TranslationStore,
                                  TranslationEngine, TranslationModelManager,
                                  MentionResolver
    Casks/                      — Homebrew Cask (auto-bumped by release workflow)
    yawacTests/                 — XCTest
    project.yml                 — XcodeGen project descriptor
    docs/superpowers/specs/     — design specs
    docs/superpowers/plans/     — implementation plans
    .github/workflows/ci.yml    — CI pipeline
    .github/workflows/release.yml — per-commit edge release + cask bump

The `yawac.xcodeproj` directory is generated from `project.yml`; do not commit it.

## Troubleshooting

- **`gomobile: command not found`** — re-run `./scripts/install-tools.sh` and ensure `$(go env GOPATH)/bin` is on `PATH`.
- **`undefined symbol _res_9_nsearch`** at link time — `OTHER_LDFLAGS: -lresolv` is set in `project.yml` for the yawac target. If you split the target structure, copy that setting.
- **`** TEST FAILED **` with code-sign error for `yawacTests`** — `xcodebuild test` requires `CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` flags for ad-hoc dev (no Developer ID).
- **`xcodebuild` cannot find `yawac` scheme** — run `xcodegen generate` to regenerate the project.
- **Build hangs at "Compiling whatsmeow"** — first gomobile bind takes 5–15 minutes (cross-compiles whatsmeow + transitive deps for arm64 + x86_64). Subsequent builds are cached.
- **Metal toolchain missing** during MLX compile — run `xcodebuild -downloadComponent MetalToolchain` once, then retry.

## Release

Releases are triggered by pushing a `v*` tag. Bump `CFBundleShortVersionString`
and `CFBundleVersion` in `project.yml`, regenerate the project (which also
updates `yawac/Info.plist`), run validation, and commit. Push `main` and the
matching version tag.

`.github/workflows/release.yml` builds a universal app on macOS 26, signs it
with Developer ID, submits it for notarization, verifies the packaged app,
and publishes the zip and signed Sparkle appcast. The workflow then updates
`Casks/yawac.rb` and pushes the cask commit to `main`. Fast-forward the local
branch after the workflow completes.

Manual workflow dispatch builds and validates a development artifact without
creating a public release. `scripts/release-edge.sh` is the shared build and
packaging entry point; signing and notarization credentials are supplied by
CI secrets.
