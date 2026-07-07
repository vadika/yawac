module github.com/vadikas/yawac/bridge

go 1.26.3

require (
	go.mau.fi/whatsmeow v0.0.0-20260630180629-b572e5bcb92b
	golang.org/x/mobile v0.0.0-20260514233045-7de0a8fa7f4d
	google.golang.org/protobuf v1.36.11
	modernc.org/sqlite v1.50.1
)

require (
	filippo.io/edwards25519 v1.2.0 // indirect
	github.com/beeper/argo-go v1.1.2 // indirect
	github.com/coder/websocket v1.8.15 // indirect
	github.com/dustin/go-humanize v1.0.1 // indirect
	github.com/elliotchance/orderedmap/v3 v3.1.0 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/ncruces/go-strftime v1.0.0 // indirect
	github.com/petermattis/goid v0.0.0-20260330135022-df67b199bc81 // indirect
	github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec // indirect
	github.com/rs/zerolog v1.35.1 // indirect
	github.com/vektah/gqlparser/v2 v2.5.27 // indirect
	go.mau.fi/libsignal v0.2.2 // indirect
	go.mau.fi/util v0.9.10 // indirect
	golang.org/x/crypto v0.53.0 // indirect
	golang.org/x/exp v0.0.0-20260611194520-c48552f49976 // indirect
	golang.org/x/mod v0.37.0 // indirect
	golang.org/x/net v0.56.0 // indirect
	golang.org/x/sync v0.21.0 // indirect
	golang.org/x/sys v0.46.0 // indirect
	golang.org/x/text v0.38.0 // indirect
	golang.org/x/tools v0.46.0 // indirect
	modernc.org/libc v1.72.3 // indirect
	modernc.org/mathutil v1.7.1 // indirect
	modernc.org/memory v1.11.0 // indirect
)

// Fork (github.com/vadika/whatsmeow) carries upstream PRs not yet
// merged into whatsmeow main: #1160 binary-decoder panic resilience,
// #1168 signal session lock (likely closes our issue #6), and #1171
// SkipBrokenAppStatePatches opt-in. (#1151 poll-vote extractor was
// closed upstream; its logic lives in bridge/history.go now.)
// See docs/whatsmeow-patches.md.
replace go.mau.fi/whatsmeow => github.com/vadika/whatsmeow v0.0.0-20260704062504-a0d4b7e975f9
