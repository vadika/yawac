# Brew Edge Installer — Design

**Date:** 2026-05-25
**Status:** Approved
**Scope:** GitHub Actions workflow that, on every push to `main`, builds yawac, ad-hoc signs it, uploads a per-commit zip as a GitHub Release asset, and rewrites an inline Homebrew Cask (`Casks/yawac.rb`) with the new version + sha256. Users install via `brew tap vadika/yawac` + `brew install --cask`. Macos quarantine bit is stripped during cask install.

## Goal

Make `yawac` installable in two commands on a clean macOS machine and keep that install in sync with the tip of `main` automatically. Each commit produces a new versioned, downloadable build that `brew upgrade` picks up.

## Non-goals

- Apple Developer ID signing or notarization. Builds are ad-hoc signed; the cask strips quarantine.
- Stable / channel split (no `yawac-stable` alongside `yawac-edge`).
- Mirroring to a separate `homebrew-yawac` tap repo.
- Auto-pruning old GH Releases.
- Self-update inside the app.
- DMG / pkg artefacts.

## Architecture

```
push to main (non-cask)
        │
        ▼
┌──────────────────────────────────────────────┐
│ .github/workflows/release.yml                │
│   - resolve version: 0.1.0+<short-sha>       │
│   - build xcframework                        │
│   - xcodegen generate                        │
│   - xcodebuild archive (Release)             │
│     CODE_SIGN_IDENTITY="-"  (ad-hoc)         │
│   - exportArchive → build/export/yawac.app   │
│   - ditto -c -k --keepParent → yawac.zip     │
│   - sha256sum yawac.zip                      │
│   - gh release create "$VERSION" yawac.zip   │
│   - sed -i Casks/yawac.rb (version/url/sha)  │
│   - git commit -m "chore(cask): bump …       │
│       [skip ci]"                             │
│   - git push origin main                     │
└──────────────────────────────────────────────┘
        │
        ▼
   GH Release "0.1.0+abc1234"
     └── yawac-0.1.0+abc1234.zip  (asset)

User flow:
    brew tap vadika/yawac https://github.com/vadika/yawac
    brew install --cask vadika/yawac/yawac
        │
        ▼
   brew reads Casks/yawac.rb @ main
        │   url → GH release asset
        │   sha256 → pinned in cask
        ▼
   Download .zip, verify sha256, unzip
        │
        ▼
   postflight: xattr -dr com.apple.quarantine yawac.app
```

**Trigger gating:** workflow runs on `push: branches: [main]` with `paths-ignore: ['Casks/**', 'docs/**', '**/*.md']`. The cask-bump commit only touches `Casks/yawac.rb` → workflow ignores its own push → no loop.

**Concurrency:** `concurrency: { group: release-main, cancel-in-progress: true }`. Rapid commits cancel earlier in-flight builds; only the head commit produces a release.

## Components

### New: `.github/workflows/release.yml`

```yaml
name: release
on:
  push:
    branches: [main]
    paths-ignore:
      - "Casks/**"
      - "docs/**"
      - "**/*.md"
  workflow_dispatch:
concurrency:
  group: release-main
  cancel-in-progress: true
permissions:
  contents: write
jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}
      - uses: actions/setup-go@v5
        with:
          go-version-file: bridge/go.mod
          cache-dependency-path: bridge/go.sum
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Install gomobile
        run: |
          go install golang.org/x/mobile/cmd/gomobile@latest
          go install golang.org/x/mobile/cmd/gobind@latest
          echo "$(go env GOPATH)/bin" >> $GITHUB_PATH
          gomobile init
      - name: Compute version
        id: ver
        run: |
          BASE=$(awk -F'"' '/CFBundleShortVersionString/{print $2; exit}' project.yml)
          SHA=$(git rev-parse --short=7 HEAD)
          echo "version=${BASE}+${SHA}" >> "$GITHUB_OUTPUT"
          echo "sha=${SHA}" >> "$GITHUB_OUTPUT"
      - name: Build + sign + zip
        env:
          VERSION: ${{ steps.ver.outputs.version }}
        run: ./scripts/release-edge.sh
      - name: SHA256
        id: sum
        run: |
          SUM=$(shasum -a 256 "build/dist/yawac-${{ steps.ver.outputs.version }}.zip" | awk '{print $1}')
          echo "sha256=${SUM}" >> "$GITHUB_OUTPUT"
      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          VERSION: ${{ steps.ver.outputs.version }}
        run: |
          gh release create "$VERSION" \
            "build/dist/yawac-${VERSION}.zip" \
            --title "$VERSION" \
            --notes "Edge build from $(git rev-parse HEAD)"
      - name: Bump cask
        env:
          VERSION: ${{ steps.ver.outputs.version }}
          SHA256: ${{ steps.sum.outputs.sha256 }}
        run: ./scripts/bump-cask.sh
      - name: Commit cask
        env:
          VERSION: ${{ steps.ver.outputs.version }}
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add Casks/yawac.rb
          if git diff --cached --quiet; then
            echo "no cask change"
            exit 0
          fi
          git commit -m "chore(cask): bump to ${VERSION} [skip ci]"
          git push origin main
```

### New: `scripts/release-edge.sh`

```bash
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
```

### New: `scripts/bump-cask.sh`

```bash
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
```

`CASK` env var lets the test script point at a temp copy.

### New: `scripts/bump-cask-test.sh`

```bash
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
```

### New: `Casks/yawac.rb`

```ruby
cask "yawac" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/vadika/yawac/releases/download/#{version}/yawac-#{version}.zip"
  name "yawac"
  desc "Yet Another WhatsApp Client — native macOS SwiftUI"
  homepage "https://github.com/vadika/yawac"

  depends_on macos: ">= :sonoma"

  app "yawac.app"

  # Ad-hoc signed builds are quarantined by macOS Gatekeeper on first
  # launch. Strip the quarantine bit so the app opens normally.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/yawac.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/yawac",
    "~/Library/Preferences/dev.vadikas.yawac.plist",
    "~/Library/Caches/dev.vadikas.yawac",
  ]
end
```

### Modify: `.github/workflows/ci.yml`

Add a step calling `scripts/bump-cask-test.sh` so a regression in the awk substitution is caught before it ships a malformed cask.

### Modify: `README.md`

Add an "Install via Homebrew" section above the existing "Build" section:

```markdown
## Install via Homebrew

```sh
brew tap vadika/yawac https://github.com/vadika/yawac
brew install --cask vadika/yawac/yawac
```

Builds are ad-hoc signed; the cask strips the macOS quarantine flag
automatically. Each push to `main` produces a new `0.1.0+<sha>` build.
```

## Data flow & versioning

- **Base version:** `CFBundleShortVersionString` from `project.yml` (currently `0.1.0`). Bump there to roll major/minor.
- **Per-commit suffix:** `+` then 7-char short SHA. Full version: `0.1.0+abc1234`. Used as GH tag, cask `version`, zip filename.
- **Build:** ad-hoc sign (`CODE_SIGN_IDENTITY="-"`), hardened runtime stays on, ExportOptions `method=mac-application`.
- **Zip:** `ditto -c -k --sequesterRsrc --keepParent` (preserves symlinks + xattrs).
- **Cask bump:** `awk` rewrites `version` and `sha256` lines via tempfile + atomic mv.
- **Commit author:** `github-actions[bot]`. Commit message `chore(cask): bump to <ver> [skip ci]`.
- **Trigger loop guard:** workflow's `paths-ignore` excludes `Casks/**`; cask-bump commit only touches that path; loop broken.
- **Concurrency:** `cancel-in-progress: true` on rapid pushes.

## Error handling & edge cases

- **Build / archive failure:** workflow fails, no release, no cask bump. Existing users keep last good build.
- **`gh release create` tag collision:** tag includes SHA → unique per commit. Re-run on same SHA fails loudly; operator deletes tag and re-runs.
- **Cask bump finds no matching lines:** awk produces identical file → `git diff --cached --quiet` is true → workflow exits 0 with "no cask change" message. Release exists but cask unchanged — operator notices and fixes the template.
- **`git push` race:** another commit landed after checkout. Push fails, workflow fails. Next push's workflow picks up both commits and bumps cask to the newer SHA.
- **Brew sha256 mismatch:** zip tampered or replaced. Brew refuses install. Workflow keeps zip + bump atomic so divergence only via manual asset edit.
- **First-ever install with template defaults:** cask says `version "0.0.0"` → URL 404 → brew install fails. Expected; README warns the tap needs at least one CI run first.
- **`xattr` postflight failure:** rare (read-only volume). Brew surfaces error; user can run `xattr -dr com.apple.quarantine /Applications/yawac.app` manually.
- **macOS version:** `depends_on macos: ">= :sonoma"` gates installs on 13 or older. Runtime guard via `LSMinimumSystemVersion: 14.0` covers manual installs.
- **Architecture:** existing `build-xcframework.sh` produces universal slices (arm64 + x86_64). xcodebuild archive produces a universal binary by default. Cask works on both Apple silicon and Intel.
- **MLX model:** ~1.8 GB Qwen 2.5 downloaded on user demand from Settings. Cask installs app shell only.
- **Disable single commit:** push with `[skip ci]` in subject (GH Actions honors). Or push only paths-ignored files. Or push to a non-`main` branch.

## Testing

### Automated (added to `ci.yml`)

- `scripts/bump-cask-test.sh` — verifies awk substitution against a synthetic cask. Catches regression before it ships a malformed cask.

### Manual first-run verification

1. Push a commit to main.
2. Watch `release` workflow finish green (~5–10 min on macos-15 runner).
3. Verify GH Releases page shows `0.1.0+<sha>` with `yawac-0.1.0+<sha>.zip`.
4. Verify new commit `chore(cask): bump to 0.1.0+<sha> [skip ci]` lands on main.
5. Verify `Casks/yawac.rb` has updated `version` and `sha256`.
6. Verify `release` workflow did NOT re-trigger on the cask-bump commit.
7. On a clean macOS machine:
   ```sh
   brew tap vadika/yawac https://github.com/vadika/yawac
   brew install --cask vadika/yawac/yawac
   open /Applications/yawac.app
   ```
   App launches without Gatekeeper warning.
8. Push another commit, wait, run `brew upgrade --cask vadika/yawac/yawac`. New build picked up.
9. `brew uninstall --cask --zap vadika/yawac/yawac` removes app + zaps data dirs.

## File touch list

| File | Action |
|---|---|
| `.github/workflows/release.yml` | new |
| `.github/workflows/ci.yml` | modify (add bump-cask-test step) |
| `scripts/release-edge.sh` | new |
| `scripts/bump-cask.sh` | new |
| `scripts/bump-cask-test.sh` | new |
| `Casks/yawac.rb` | new (template) |
| `README.md` | modify (Install via Homebrew section) |
