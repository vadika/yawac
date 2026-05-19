#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$(go env GOPATH)/bin:$PATH"

OUT_DIR="build"
OUT="${OUT_DIR}/Bridge.xcframework"
mkdir -p "$OUT_DIR"
rm -rf "$OUT"

pushd bridge >/dev/null
gomobile bind \
  -target=macos \
  -o "../${OUT}" \
  -tags "sqlite_omit_load_extension" \
  -trimpath \
  -ldflags "-s -w" \
  ./...
popd >/dev/null

echo "Built: $OUT"
