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

# ditto preserves framework symlinks + xattrs; plain `zip` corrupts them.
ZIP="${DIST}/yawac-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "built: $ZIP"
