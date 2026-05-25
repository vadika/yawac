#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?VERSION required}"
: "${SHA256:?SHA256 required}"

CASK="${CASK:-Casks/yawac.rb}"

tmp=$(mktemp)
awk -v ver="$VERSION" -v sum="$SHA256" '
  /^[[:space:]]*version "/ { print "  version \"" ver "\""; next }
  /^[[:space:]]*sha256 "/  { print "  sha256 \"" sum "\""; next }
  { print }
' "$CASK" > "$tmp"
mv "$tmp" "$CASK"
echo "bumped $CASK to $VERSION"
