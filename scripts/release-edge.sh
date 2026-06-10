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
    # Sparkle's Autoupdate is a plain Mach-O helper inside the
    # framework, not a .app / .xpc / .bundle. The depth-first
    # container loop below won't match it, so sign explicitly
    # BEFORE the framework's outer seal happens (otherwise the
    # framework's signature is invalidated when Autoupdate is
    # signed after).
    SPARKLE_AUTOUPDATE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    if [ -f "$SPARKLE_AUTOUPDATE" ]; then
        echo "[sign] $SPARKLE_AUTOUPDATE"
        codesign --force --options=runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$SPARKLE_AUTOUPDATE"
    fi
    # Depth-first traversal: codesign of a container (.framework,
    # .xpc, .app, .bundle) seals its current contents. Re-signing a
    # nested container afterwards invalidates the parent. -depth
    # makes find emit leaves first so we sign innermost first.
    # Sparkle ships nested XPC services + Updater.app inside its
    # framework that triggered exactly this failure on first try.
    find -d "$APP" \
        \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" \
           -o -name "*.app" -o -name "*.bundle" \) \
        -print0 |
    while IFS= read -r -d '' path; do
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

# F41: Sparkle appcast. When SPARKLE_PRIVATE_KEY_FILE points at a
# readable PEM, sign the final zip with sign_update and emit a
# single-item appcast.xml alongside it for the workflow to upload
# as a release asset. Sparkle's auto-update client only needs the
# latest item to decide whether to update, so we don't need to
# preserve history.
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ] \
   && [ -r "$SPARKLE_PRIVATE_KEY_FILE" ]; then
    SIGN_UPDATE="${SIGN_UPDATE_BIN:-sign_update}"
    SIG_RAW=$("$SIGN_UPDATE" -f "$SPARKLE_PRIVATE_KEY_FILE" "$ZIP")
    # sign_update prints attrs: sparkle:edSignature="..." length="..."
    ZIP_LENGTH=$(stat -f%z "$ZIP")
    APPCAST="${DIST}/appcast.xml"
    DOWNLOAD_URL="https://github.com/vadika/yawac/releases/download/v${VERSION}/yawac-${VERSION}.zip"
    PUB_DATE=$(LANG=C date "+%a, %d %b %Y %H:%M:%S %z")
    cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>yawac</title>
        <link>https://github.com/vadika/yawac</link>
        <description>Most recent yawac update</description>
        <language>en</language>
        <item>
            <title>yawac ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="${DOWNLOAD_URL}" type="application/octet-stream" length="${ZIP_LENGTH}" ${SIG_RAW} />
        </item>
    </channel>
</rss>
EOF
    echo "wrote appcast: $APPCAST"
fi

echo "built: $ZIP"
