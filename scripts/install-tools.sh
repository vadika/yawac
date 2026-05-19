#!/usr/bin/env bash
set -euo pipefail

if ! command -v go >/dev/null; then
  echo "go missing — brew install go" >&2; exit 1
fi

go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest

GOBIN="$(go env GOPATH)/bin"
export PATH="$GOBIN:$PATH"

gomobile init
echo "gomobile installed at $GOBIN/gomobile"
echo "Add this to your shell rc: export PATH=\"$GOBIN:\$PATH\""
