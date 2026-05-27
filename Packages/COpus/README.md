# COpus — vendored libopus + libopusenc

Local SwiftPM package wrapping:

- **libopus 1.5.2** (Xiph.Org / Mozilla, BSD-3-Clause) — Opus encoder/decoder
- **libopusenc 0.2.1** (Xiph.Org, BSD-3-Clause) — Ogg-Opus muxer

Built as a single C target `COpus` (no SIMD acceleration — pure C, scalar
float path) with a thin Swift wrapper module `Opus` exposing
`OpusFileEncoder` for one-shot voice-note recording.

## Why vendored

WhatsApp voice notes (PTT) require Opus in an Ogg container. macOS
AVFoundation has no Opus encoder. Vendoring opus + libopusenc as a
SwiftPM C target keeps the build hermetic (no Homebrew / system deps,
no ffmpeg-kit bulk).

## Sources

Upstream tarballs:

- https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
- https://downloads.xiph.org/releases/opus/libopusenc-0.2.1.tar.gz

Trimmed to: top-level encoder/decoder C sources, scalar CELT + SILK,
silk/float subset. SIMD (x86 SSE*, ARM NEON), arm/mips assembly, tests,
demos, and CMake/autotools build files removed.

## Configuration

Two `config.h` headers vendor-local:

- `Sources/COpus/config.h` — libopus build flags (OPUS_BUILD, VAR_ARRAYS,
  FLOATING_POINT, HAVE_LRINT, HAVE_LRINTF, USE_ALLOCA, PACKAGE_VERSION).
- `Sources/COpus/libopusenc/config.h` — libopusenc + bundled Speex
  resampler flags (OUTSIDE_SPEEX, RANDOM_PREFIX, FLOATING_POINT).

Both are picked up via `#include "config.h"` with quoted-include's
source-dir-first search rule.

## License compliance

`LICENSE.opus` and `LICENSE.libopusenc` reproduce the upstream BSD-3-Clause
notices. Required attribution.
