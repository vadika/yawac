#!/usr/bin/env bash
set -euo pipefail

# Requires env:
#   DEV_ID_APPLICATION   — code-signing identity (e.g. "Developer ID Application: NAME (TEAMID)")
#   NOTARY_PROFILE       — keychain profile created via `xcrun notarytool store-credentials`

cd "$(dirname "$0")/.."

SCHEME="yawac"
ARCHIVE="build/yawac.xcarchive"
EXPORT="build/export"

: "${DEV_ID_APPLICATION:?DEV_ID_APPLICATION env var required}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE env var required}"

./scripts/build-xcframework.sh

xcodegen generate

xcodebuild \
    -project yawac.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    archive \
    CODE_SIGN_IDENTITY="$DEV_ID_APPLICATION"

cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
EOF

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist build/ExportOptions.plist \
    -exportPath "$EXPORT"

APP="${EXPORT}/${SCHEME}.app"

xcrun notarytool submit "$APP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

xcrun stapler staple "$APP"

echo "Built signed + notarized app: $APP"
