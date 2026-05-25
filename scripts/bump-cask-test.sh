#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp)
cat > "$tmp" <<EOF
cask "yawac" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  url "https://example/"
end
EOF

CASK="$tmp" VERSION="1.2.3+abcdef0" \
SHA256="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
  ./scripts/bump-cask.sh

grep -q 'version "1.2.3+abcdef0"' "$tmp" || { echo "version not bumped"; exit 1; }
grep -q 'sha256 "deadbeef' "$tmp"        || { echo "sha256 not bumped"; exit 1; }
echo "bump-cask test OK"
rm "$tmp"
