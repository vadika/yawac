# Brew Edge Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-commit Homebrew Cask edge channel. On every push to `main`, CI builds an ad-hoc-signed yawac.app, zips it, publishes to a GH Release tagged `0.1.0+<sha>`, and rewrites `Casks/yawac.rb` with the new version + sha256. Users install via `brew tap vadika/yawac` + `brew install --cask`.

**Architecture:** New GitHub Actions workflow on push-to-main builds, signs, zips, releases, and commits the cask bump back. Two new shell scripts (`release-edge.sh`, `bump-cask.sh`) keep the workflow YAML thin and testable. A cask template (`Casks/yawac.rb`) lives in-repo; the install command is `brew install --cask vadika/yawac/yawac` after tapping the repo by URL.

**Tech Stack:** GitHub Actions (macos-15 runner), xcodebuild, gomobile, `ditto`, `awk`, `gh` CLI, Homebrew Cask DSL.

**Spec:** `docs/superpowers/specs/2026-05-25-brew-edge-installer-design.md`

---

## File Structure

| File | Role | New/Modify |
|---|---|---|
| `scripts/bump-cask.sh` | Atomic rewrite of `version`/`sha256` lines in a cask file | new |
| `scripts/bump-cask-test.sh` | Self-test for `bump-cask.sh` (runs in CI) | new |
| `Casks/yawac.rb` | Cask template; rewritten in place by every release | new |
| `scripts/release-edge.sh` | Build + ad-hoc-sign + zip pipeline | new |
| `.github/workflows/release.yml` | Per-commit release workflow | new |
| `.github/workflows/ci.yml` | Add `bump-cask-test.sh` step | modify |
| `README.md` | Install via Homebrew section | modify |

Decomposition rationale: every shell script does one thing (`bump-cask.sh` is text edit; `release-edge.sh` is build pipeline). The workflow YAML just orchestrates. The test script is plain bash, runs anywhere, validates the substitution logic without needing a real release.

---

## Task 1: `bump-cask.sh` + self-test (TDD)

**Files:**
- Create: `scripts/bump-cask.sh`
- Create: `scripts/bump-cask-test.sh`

- [ ] **Step 1: Write the failing test**

Create `scripts/bump-cask-test.sh`:

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

```bash
chmod +x scripts/bump-cask-test.sh
```

- [ ] **Step 2: Run test, expect failure (script doesn't exist yet)**

```bash
cd /Users/vadikas/Work/yawac && ./scripts/bump-cask-test.sh
```

Expected: `./scripts/bump-cask-test.sh: line 17: ./scripts/bump-cask.sh: No such file or directory`, non-zero exit.

- [ ] **Step 3: Implement `bump-cask.sh`**

Create `scripts/bump-cask.sh`:

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

```bash
chmod +x scripts/bump-cask.sh
```

- [ ] **Step 4: Run test, expect pass**

```bash
cd /Users/vadikas/Work/yawac && ./scripts/bump-cask-test.sh
```

Expected: `bumped /tmp/tmp.XXXXXXX to 1.2.3+abcdef0` then `bump-cask test OK`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/bump-cask.sh scripts/bump-cask-test.sh
git commit -m "feat(scripts): atomic cask version+sha256 bumper"
```

---

## Task 2: `Casks/yawac.rb` template

**Files:**
- Create: `Casks/yawac.rb`

- [ ] **Step 1: Create the cask file**

Create `Casks/yawac.rb`:

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

- [ ] **Step 2: Verify the bumper edits this exact file**

```bash
cd /Users/vadikas/Work/yawac
VERSION="0.1.0+test1234" \
SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  ./scripts/bump-cask.sh
grep -E 'version "0.1.0\+test1234"|sha256 "aaaaaaaa' Casks/yawac.rb
```

Expected: both lines present.

Then revert to template defaults:

```bash
git checkout Casks/yawac.rb
```

- [ ] **Step 3: Commit**

```bash
git add Casks/yawac.rb
git commit -m "feat(cask): yawac cask template with quarantine-strip postflight"
```

---

## Task 3: Wire `bump-cask-test.sh` into existing CI

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add the test step**

Open `.github/workflows/ci.yml`. After the `Go tests` step and before the `Build XCFramework` step, insert:

```yaml
      - name: Cask bumper self-test
        run: ./scripts/bump-cask-test.sh
```

The full `steps:` list ends up:

```yaml
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: bridge/go.mod
          cache-dependency-path: bridge/go.sum
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Install gomobile + init
        run: |
          go install golang.org/x/mobile/cmd/gomobile@latest
          go install golang.org/x/mobile/cmd/gobind@latest
          echo "$(go env GOPATH)/bin" >> $GITHUB_PATH
          gomobile init
      - name: Go tests
        run: |
          cd bridge
          go test -short -v ./...
      - name: Cask bumper self-test
        run: ./scripts/bump-cask-test.sh
      - name: Build XCFramework
        run: ./scripts/build-xcframework.sh
      - name: Generate Xcode project
        run: xcodegen generate
      - name: Xcode build & test
        run: |
          xcodebuild \
            -project yawac.xcodeproj \
            -scheme yawac \
            -destination 'platform=macOS' \
            -configuration Debug \
            build test \
            CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 2: Commit + push**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run cask-bump self-test on every push"
git push origin main
```

- [ ] **Step 3: Verify CI**

```bash
sleep 10 && gh run list --branch main --limit 1 --json databaseId,status
```

Then watch:

```bash
gh run watch <id> --exit-status 2>&1 | tail -3
gh run view <id> --json conclusion
```

Expected: `{"conclusion":"success"}`.

---

## Task 4: `release-edge.sh` build pipeline

**Files:**
- Create: `scripts/release-edge.sh`

- [ ] **Step 1: Create the script**

Create `scripts/release-edge.sh`:

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

```bash
chmod +x scripts/release-edge.sh
```

- [ ] **Step 2: Smoke test locally**

```bash
cd /Users/vadikas/Work/yawac && rm -rf build/yawac.xcarchive build/export build/dist
VERSION="0.1.0+local01" ./scripts/release-edge.sh 2>&1 | tail -5
```

Expected output ends with `built: build/dist/yawac-0.1.0+local01.zip`. Verify the zip exists:

```bash
ls -la build/dist/yawac-0.1.0+local01.zip
```

Expected: a non-zero-size .zip file.

- [ ] **Step 3: Verify the zip unpacks to a launchable app**

```bash
cd /tmp && rm -rf yawac-smoke && mkdir yawac-smoke && cd yawac-smoke
ditto -x -k /Users/vadikas/Work/yawac/build/dist/yawac-0.1.0+local01.zip .
ls
codesign -dv --verbose=2 yawac.app 2>&1 | grep -E "Signature|Identifier"
```

Expected: directory contains `yawac.app`; `codesign -dv` reports `Signature=adhoc` and `Identifier=dev.vadikas.yawac.yawac` (or similar).

- [ ] **Step 4: Cleanup local artefacts**

```bash
cd /Users/vadikas/Work/yawac && rm -rf build/dist build/export build/yawac.xcarchive build/ExportOptions.plist
rm -rf /tmp/yawac-smoke
```

- [ ] **Step 5: Commit**

```bash
git add scripts/release-edge.sh
git commit -m "feat(scripts): ad-hoc-signed release-edge build pipeline"
```

---

## Task 5: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/release.yml`:

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

- [ ] **Step 2: Commit + push**

```bash
git add .github/workflows/release.yml
git commit -m "ci(release): per-commit edge build + cask bump"
git push origin main
```

- [ ] **Step 3: Watch the FIRST release run end-to-end**

```bash
sleep 10 && gh run list --workflow=release.yml --branch main --limit 1 --json databaseId,status
```

Then:

```bash
gh run watch <id> --exit-status 2>&1 | tail -5
gh run view <id> --json conclusion
```

Expected: `{"conclusion":"success"}` (allow 10–20 min for first macos-15 build).

- [ ] **Step 4: Verify the artefacts**

```bash
gh release list --limit 3
git fetch origin main
git log --oneline origin/main | head -5
cat Casks/yawac.rb | grep -E 'version|sha256'
```

Expected:
- `gh release list` shows `0.1.0+<sha>` at the top.
- `git log` shows a `chore(cask): bump to 0.1.0+<sha> [skip ci]` commit by `github-actions[bot]` as the latest commit.
- `Casks/yawac.rb` shows the new version + non-zero sha256.

- [ ] **Step 5: Verify the loop-guard worked**

```bash
gh run list --workflow=release.yml --branch main --limit 3 --json databaseId,headSha,event
```

Expected: the cask-bump commit did NOT trigger a new run. Only one `release` run for the original commit.

- [ ] **Step 6: Pull bumped main locally**

```bash
git pull --rebase origin main
```

---

## Task 6: README install section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Insert the install section**

Open `README.md` and find the existing `## Build` section. Insert directly above it:

```markdown
## Install via Homebrew

```sh
brew tap vadika/yawac https://github.com/vadika/yawac
brew install --cask vadika/yawac/yawac
```

Builds are ad-hoc signed; the cask strips the macOS quarantine flag
automatically. Each push to `main` produces a new `0.1.0+<sha>` build.

```

(Note: the inner code block above uses three backticks. When inserting into the README, the surrounding fences must be properly nested.)

- [ ] **Step 2: Commit + push**

```bash
git add README.md
git commit -m "docs(readme): brew tap install instructions"
git push origin main
```

- [ ] **Step 3: Verify another release fires (README is not in paths-ignore)**

Actually `**/*.md` IS in paths-ignore for `release.yml`. So this README push should NOT trigger a release. Verify:

```bash
sleep 10 && gh run list --workflow=release.yml --branch main --limit 1 --json databaseId,headSha,event
```

Expected: latest run's `headSha` is NOT the README commit's SHA — confirms paths-ignore worked for `.md` paths.

---

## Task 7: End-to-end install verification

**Files:** none (smoke test only)

This task runs on the user's machine (the same Mac as the dev environment is fine; brew tap from a local path is OK but the spec calls for the GitHub URL).

- [ ] **Step 1: Tap the repo**

```bash
brew tap vadika/yawac https://github.com/vadika/yawac
```

Expected: tap added without errors.

- [ ] **Step 2: Install the cask**

```bash
brew install --cask vadika/yawac/yawac
```

Expected: brew downloads `yawac-0.1.0+<sha>.zip`, verifies sha256, expands, runs the postflight `xattr -dr com.apple.quarantine`, installs `/Applications/yawac.app`.

- [ ] **Step 3: Launch the app**

```bash
open /Applications/yawac.app
```

Expected: app launches without a Gatekeeper "yawac.app can't be opened" warning.

- [ ] **Step 4: Trigger an upgrade**

Push an unrelated commit to `main` (e.g., a small comment change in a `.swift` file). Wait for the `release` workflow to finish. Then:

```bash
brew update
brew upgrade --cask vadika/yawac/yawac
```

Expected: brew detects the new version, downloads, upgrades. New `/Applications/yawac.app` reflects the latest commit.

- [ ] **Step 5: Cleanup**

```bash
brew uninstall --cask --zap vadika/yawac/yawac
brew untap vadika/yawac
```

Expected: app removed, data dirs (Application Support, prefs, caches) zapped, tap removed.

---

## Notes for the executor

- **First release takes 10–20 min** on the macos-15 runner because of cold xcodebuild + MLX SPM resolution caches. Subsequent runs are 5–10 min.
- **GitHub Releases never auto-prune**, so this workflow will accumulate one release per commit on `main`. A future polish task can add a monthly cron that keeps only the last 30 releases via `gh release delete`. Out of scope here.
- **`paths-ignore` is the loop guard.** If you change which files are ignored, re-verify Task 5 Step 5: the cask-bump commit must NOT trigger a second run.
- **Apple Developer ID signing** is intentionally out of scope. If you later add a `DEV_ID_APPLICATION` secret + notarytool API key, swap `CODE_SIGN_IDENTITY="-"` for the real identity and add a `xcrun notarytool submit` + `xcrun stapler staple` after the `exportArchive` step. Cask can drop the `postflight` `xattr -dr com.apple.quarantine` once notarized.
- **Versioning:** to roll the base version (e.g. 0.1.0 → 0.2.0), edit `CFBundleShortVersionString` in `project.yml`. Next push picks it up automatically.
- **Re-running the workflow** on a SHA that already has a tag fails (`gh release create` refuses to overwrite). Use `gh release delete <tag>` first if you need a re-run.
- **`workflow_dispatch`** is included so the very first run can be triggered manually before any code change lands (good for end-to-end shakedown of the pipeline).
