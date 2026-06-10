#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?VERSION env var required}"

SCHEME="yawac"
ARCHIVE="build/yawac.xcarchive"
EXPORT="build/export"
DIST="build/dist"
mkdir -p "$DIST"

./scripts/build-xcframework.sh
xcodegen generate

# Build ad-hoc. SPM packages auto-sign for development and refuse
# to inherit a workspace-level `CODE_SIGN_IDENTITY=Developer ID
# Application`. Build everything ad-hoc; re-sign the final .app
# below with the Developer ID cert when the env is present.
xcodebuild \
    -project yawac.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES

cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>method</key><string>mac-application</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
EOF

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist build/ExportOptions.plist \
    -exportPath "$EXPORT"

APP="${EXPORT}/${SCHEME}.app"

# Optional: re-sign with Developer ID + notarize when CI passes the
# secrets. Local dev runs skip this and keep ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -n "$SIGN_IDENTITY" ]; then
    ENTITLEMENTS="yawac/yawac.entitlements"
    # Sign every nested framework + dylib + helper binary first, then
    # the outer app. codesign refuses to sign an app whose contents
    # are unsigned, but is happy when contents are signed by the
    # same identity. Order: deepest first.
    find "$APP" \
        \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" \
           -o -name "*.app" -o -name "*.bundle" \) \
        -print0 |
    while IFS= read -r -d '' path; do
        # Skip the outer .app itself; signed last.
        if [ "$path" = "$APP" ]; then continue; fi
        echo "[sign] $path"
        codesign --force --options=runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$path"
    done
    echo "[sign] $APP (outer)"
    codesign --force --options=runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

# Notarize when credentials are present.
if [ -n "${NOTARY_APPLE_ID:-}" ] \
   && [ -n "${NOTARY_APP_PASSWORD:-}" ] \
   && [ -n "${NOTARY_TEAM_ID:-}" ]; then
    NOTARY_ZIP="${DIST}/yawac-${VERSION}-notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --apple-id "$NOTARY_APPLE_ID" \
        --password "$NOTARY_APP_PASSWORD" \
        --team-id "$NOTARY_TEAM_ID" \
        --wait
    xcrun stapler staple "$APP"
    rm -f "$NOTARY_ZIP"
fi

# Final distribution zip. ditto preserves framework symlinks + xattrs;
# plain `zip` corrupts them.
ZIP="${DIST}/yawac-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "built: $ZIP"
