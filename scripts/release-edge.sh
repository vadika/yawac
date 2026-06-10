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

# Developer ID signing path. Falls back to ad-hoc when the secrets
# aren't present (local dev builds + workflow_dispatch from PRs).
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
TEAM_ID="${TEAM_ID:-}"

xcodebuild \
    -project yawac.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    archive \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    ${TEAM_ID:+DEVELOPMENT_TEAM="$TEAM_ID"} \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"

cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>method</key><string>mac-application</string>
  <key>signingStyle</key><string>manual</string>
EOF
if [ "$SIGN_IDENTITY" != "-" ]; then
cat >> build/ExportOptions.plist <<EOF
  <key>signingCertificate</key><string>Developer ID Application</string>
EOF
fi
if [ -n "$TEAM_ID" ]; then
cat >> build/ExportOptions.plist <<EOF
  <key>teamID</key><string>$TEAM_ID</string>
EOF
fi
cat >> build/ExportOptions.plist <<EOF
</dict></plist>
EOF

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist build/ExportOptions.plist \
    -exportPath "$EXPORT"

APP="${EXPORT}/${SCHEME}.app"

# Notarize when credentials are present. Otherwise emit the unsigned
# zip directly (local dev path).
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
