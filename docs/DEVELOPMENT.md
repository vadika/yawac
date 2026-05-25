# Development

Local build, project layout, troubleshooting, and release flow for `yawac`.

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

## Edge release (automatic, every commit on `main`)

`.github/workflows/release.yml` builds, ad-hoc signs, and uploads a `.zip` to GitHub Releases tagged `0.1.0+<short-sha>` on every push to `main` that isn't ignored by `paths-ignore` (Casks, docs, `*.md`). The workflow then rewrites `Casks/yawac.rb` with the new version + sha256 and commits the bump back with `[skip ci]`. Users on `brew install --cask vadika/yawac/yawac` pull the latest commit's build.

The cask `postflight` strips `com.apple.quarantine` since the build is ad-hoc signed rather than Developer-ID signed.

## Notarized release (manual)

For a Gatekeeper-clean, notarized `.app` outside the brew channel:

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
