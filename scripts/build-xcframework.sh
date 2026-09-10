#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$(go env GOPATH)/bin:$PATH"
# Match project.yml even when building with a newer SDK. CPPFLAGS also
# makes the deployment target part of Go's cgo compilation cache key.
export MACOSX_DEPLOYMENT_TARGET=14.0
export CGO_CPPFLAGS="${CGO_CPPFLAGS:-} -mmacosx-version-min=14.0"

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
