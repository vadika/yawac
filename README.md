# yawac

Yet Another WhatsApp Client — native macOS SwiftUI client backed by [whatsmeow](https://github.com/tulir/whatsmeow).

## Build

    ./scripts/install-tools.sh
    ./scripts/build-xcframework.sh
    open yawac.xcodeproj

Requires macOS 14+, Xcode 15+, Go 1.22+.

## Status

Pre-alpha.

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
