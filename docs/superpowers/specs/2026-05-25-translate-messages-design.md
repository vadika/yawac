# Translate Messages — Design

**Date:** 2026-05-25
**Status:** Approved
**Scope:** Per-message "Translate" footer link for foreign-language messages, with "See original" toggle. On-device inference via MLX Swift + Gemma 3 4B (4-bit). User-configurable target language + per-language denylist. Settings window (⌘,) manages model download.

## Goal

Show a small "Translate" link under every chat message whose detected language differs from the user's target language and isn't on the user's denylist. Tapping translates the body using a local MLX-hosted LLM and swaps the rendered text in place. A "See original" link toggles back. Covers text bodies, media captions, poll questions, and poll option labels.

## Non-goals

- Cloud translation providers (DeepL, OpenAI, etc.) — on-device only.
- Persistent translation cache — in-memory per session.
- Automatic full-chat translation mode — manual per surface only.
- Language learning / vocabulary features.
- Re-translation when source text edits (we don't track edits).
- Translation of own outgoing messages — only inbound.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ SwiftUI views                                                │
│   MessageRow                                                 │
│     ├ body view (text / media caption / poll)                │
│     ├ footer: "Translate" link  (when language ≠ target      │
│     │   and not in user's denylist)                          │
│     └ context menu item: "Never translate <Language>"        │
│   SettingsView (new, opens via ⌘,)                           │
│     ├ Target language picker                                 │
│     ├ Denylist editor                                        │
│     └ Model status + Download / Update / Delete              │
└────────────┬─────────────────────────────────────────────────┘
             │
   ┌─────────▼──────────────────┐
   │ TranslationViewModel       │  @Observable @MainActor
   │   targetLang: String       │  @AppStorage
   │   denylist: Set<String>    │  @AppStorage (JSON)
   │   modelState                │
   │   store: TranslationStore  │  in-memory cache
   └─────┬──────────────────────┘
         │
   ┌─────▼─────────────┐   ┌─────────────────────────┐
   │ TranslationEngine │   │ LanguageDetector        │
   │   actor           │   │   wraps NLLanguageRecog │
   │   loaded model    │   │   sync, pure, on-device │
   │   .translate(...) │   └─────────────────────────┘
   └─────┬─────────────┘
         │
   ┌─────▼─────────────┐
   │ MLXSwift          │   external package
   │   gemma-3-4b-4bit │
   │   ~2.3GB on disk  │
   └───────────────────┘
```

**Data flow:**

1. `MessageRow` renders body text and asks `LanguageDetector.detect(text)` (sync, microseconds, `NLLanguageRecognizer` + 64-entry NSCache).
2. If `detected ∉ {target} ∪ denylist`, render the footer link.
3. Tap link → call `TranslationViewModel.translate(surfaceID, text, source: detected)`.
4. VM checks `TranslationStore` cache. Hit → swap body. Miss → call `TranslationEngine.translate(...)` async, store result, swap body.
5. Footer toggles between `See original` and `Show translation`.
6. Context-menu "Never translate <Language>" adds detected BCP-47 code to denylist (persisted JSON). All currently-rendered links for that language vanish via Observation re-render.

## Components

### New: `yawac/Services/LanguageDetector.swift`

```swift
import NaturalLanguage

enum LanguageDetector {
    /// Returns BCP-47 lang code (e.g. "de", "fi", "en") or nil if undetectable
    /// or text too short. Pure, synchronous, on-device.
    static func detect(_ text: String) -> String?
}
```

- Reject input shorter than 10 visible characters.
- Reject `NLLanguageRecognizer` confidence below 0.6.
- Cache last 64 detections in a static `NSCache` keyed by text hash.

### New: `yawac/Services/TranslationEngine.swift`

```swift
actor TranslationEngine {
    enum State { case unloaded, loading, ready, failed(String) }
    private(set) var state: State = .unloaded

    /// Loads the MLX model from on-disk path. Idempotent.
    func load(modelDir: URL) async throws

    /// Translates `text` from `source` (BCP-47) to `target`. Throws if
    /// not ready.
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}
```

Backed by `MLXLLM` from `mlx-swift-examples`. Prompt template:

```
Translate the following <source-lang-name> text to <target-lang-name>.
Output ONLY the translation, no commentary.

<text>
```

`<source-lang-name>` / `<target-lang-name>` resolved via `Locale.current.localizedString(forLanguageCode:)`. Streams generated tokens; joins to a final string. Hard cap inputs at 2000 chars; truncate and append `…` if exceeded.

### New: `yawac/Services/TranslationStore.swift`

```swift
@Observable @MainActor
final class TranslationStore {
    struct Entry: Equatable {
        let original: String
        let translated: String
        let sourceLang: String
        var showingTranslated: Bool
    }
    private(set) var byMessageID: [String: Entry] = [:]
    private(set) var inFlight: Set<String> = []

    func entry(for id: String) -> Entry?
    func startInFlight(_ id: String) -> Bool   // false if already in flight
    func finish(_ id: String, with entry: Entry)
    func fail(_ id: String)
    func toggle(_ id: String)
}
```

In-memory, per-session. Keys are `surfaceID` strings (see Data flow below).

### New: `yawac/Services/TranslationModelManager.swift`

```swift
@Observable @MainActor
final class TranslationModelManager {
    enum State {
        case absent
        case downloading(progress: Double)   // 0…1
        case ready(URL)
        case failed(String)
    }
    private(set) var state: State = .absent

    func refreshState()                  // checks Application Support
    func download() async                // streams from HF, updates progress
    func delete() async
    var localDir: URL { ... }            // ~/Library/Application Support/yawac/models/gemma-3-4b-it-4bit
}
```

- Source repo: `mlx-community/gemma-3-4b-it-4bit` on HuggingFace.
- Manifest fetch (`config.json`, `tokenizer.json`, `weights/*.safetensors`).
- `URLSession` with delegate for progress. Sharded weights downloaded sequentially.
- Resume via `Range:` header against partial temp files; ETag stored alongside.
- Atomic move from temp → final dir on success.

### New: `yawac/ViewModels/TranslationViewModel.swift`

```swift
@Observable @MainActor
final class TranslationViewModel {
    @ObservationIgnored @AppStorage("yawac.translate.targetLang")
        var targetLang: String = "en"
    @ObservationIgnored @AppStorage("yawac.translate.denyJSON")
        var denyJSON: String = "[]"
    var denylist: Set<String> { get/set via denyJSON encode/decode }

    let store: TranslationStore
    let model: TranslationModelManager
    let engine: TranslationEngine

    func shouldOfferTranslate(text: String) -> (offer: Bool, lang: String?)
    func translate(surfaceID: String, text: String) async
    func toggle(surfaceID: String)
    func denyLanguage(_ code: String)
}
```

### Modify: `yawac/Views/MessageRow.swift`

- Add `@Environment(TranslationViewModel.self) private var translation`.
- New private helper `translatableText(surfaceID: String, raw: String) -> some View`:
  - Computes `(offer, lang) = translation.shouldOfferTranslate(text: raw)`.
  - Renders the displayed text (translated if `store.entry?.showingTranslated == true`, else original).
  - Renders the footer link with the state-appropriate label.
- Apply helper to body text, media caption, poll question, each poll option (using surfaceIDs `"\(message.id):text"`, `":caption"`, `":poll-q"`, `":poll-opt-\(idx)"`).
- Context menu on bubble gains a `Button("Never translate \(localizedLangName)")` item when `lang` is non-nil and not already in denylist.

### New: `yawac/Views/SettingsView.swift`

Three sections:

- **Target language** — Picker with the top 30 BCP-47 codes (DE, FI, EN, RU, FR, ES, IT, PT, NL, ZH, JA, KO, AR, TR, UK, PL, SV, NO, DA, EL, HE, HI, ID, MS, RO, CS, HU, BG, TH, VI). Default `en`.
- **Never translate** — List of denylisted languages with remove buttons. Add picker beneath.
- **Translation model** — Status text + buttons:
  - `Absent` → "Download (≈ 2.3 GB)" primary button.
  - `Downloading` → progress bar + cancel.
  - `Ready` → disk usage display + "Update" + "Delete" secondary buttons.
  - `Failed` → red error text + "Retry" button.

### Modify: `yawac/yawacApp.swift`

- Add `@State private var translation = TranslationViewModel(...)`.
- Inject `.environment(translation)` on `AppRoot`.
- Add a `Settings { SettingsView().environment(translation) }` scene.

### Modify: `project.yml`

- Add Swift Package dependency `https://github.com/ml-explore/mlx-swift-examples` pinned to a tagged release. Pull `MLXLLM` + `MLXLMCommon` libraries.

## Data flow & UX details

### Render-time language detection

For each translatable surface (text body, media caption, poll question, poll option):

- Build the raw string.
- Call `LanguageDetector.detect(raw)`.
- Reject empty, `< 10` chars, or confidence `< 0.6`.
- Result cached statically (NSCache, 64 entries, keyed by text hash).

### Decide to show "Translate" link

Show iff all true:

- Detection succeeded.
- `detected != targetLang`.
- `detected ∉ denylist`.

Style: `Theme.ui(11)`, `Theme.accent`, ~4pt above bubble bottom edge.

### Footer states (per `surfaceID`)

| State | Label | Click |
|---|---|---|
| Initial | `Translate` | Start translation |
| Loading | `Translating…` (disabled, dim) | — |
| Done + showing translated | `See original` | Toggle |
| Done + showing original | `Show translation` | Toggle |
| Failed | `Translation failed · retry` | Retry |

### `surfaceID` keys

- Text body: `"\(message.id):text"`
- Media caption: `":caption"`
- Poll question: `":poll-q"`
- Poll option `n`: `":poll-opt-\(n)"`

### Tap → translate flow

1. View calls `translationVM.translate(surfaceID:, text:, source:)`.
2. VM checks `model.state == .ready`. If not, show a one-shot alert "Translation model not installed" with **Open Settings…** + **Cancel**.
3. VM checks `store.entry(surfaceID)`. Hit with same text → toggle state; done.
4. VM checks `store.startInFlight(surfaceID)`. False → another tap is racing; bail.
5. Engine call: `try await engine.translate(text, from: source, to: targetLang)`.
6. Success → `store.finish(surfaceID, Entry(original, translated, source, showingTranslated: true))`.
7. Failure → `store.fail(surfaceID)`, NSLog the error.

### Batching short surfaces

Poll option labels are short. For one message's poll, the VM joins all options with `\n---\n`, sends one engine call, splits the response back. Single prompt cuts overhead.

### "Never translate <Language>" context menu

Right-click bubble. If detected lang exists, ≠ target, and not in denylist:

- Append `Button("Never translate \(Locale.current.localizedString(forLanguageCode: lang)))")`.
- Tap → `translationVM.denyLanguage(detected)` → adds code to denylist, persists via `denyJSON`. Observation triggers re-render; links vanish across all messages for that language.

### Model download

- Settings → **Download** → `model.download()`.
- `URLSession` delegate updates `state = .downloading(p)` continuously.
- Stored in `Application Support/yawac/models/gemma-3-4b-it-4bit/`.
- Includes `config.json`, `tokenizer.json`, `weights/*.safetensors` shards.
- Atomic rename from temp on completion.
- **Update** = delete + redownload. **Delete** = wipe local dir.

### Engine load

- On app launch, `model.refreshState()`.
- If `.ready`, schedule `engine.load(modelDir:)` on a low-priority Task.
- Load takes 1-3s on M-series. First translation after launch may show `Translating…` for that load window.
- If `.absent`, engine stays `.unloaded`; translate calls early-return with "model not installed".

### Concurrency

- Engine is an actor → serial. One translation at a time.
- Bulk taps queue; each footer shows `Translating…` until its turn.
- Chat switches mid-translation don't cancel; result lands in store keyed by `surfaceID`; visible if/when user returns.

## Error handling & edge cases

- **Model not downloaded** → alert with "Open Settings…" button. Subsequent taps in session re-alert only if state still absent.
- **Model load failure** → `engine.state = .failed`. Settings shows red text + "Re-download" CTA.
- **Network failure during download** → `state = .failed(msg)`. Resume via ETag + `Range:` on next click.
- **Disk full** → `state = .failed("Not enough disk space")`. No auto-retry.
- **Translation inference failure (OOM / bad output)** → `store.fail`, footer flips to retry. NSLog. No alert (would spam).
- **Language misdetection** → safeguarded by 0.6 confidence threshold and user denylist add. No auto-correction.
- **Empty / whitespace / emoji-only** → detector returns nil → no link.
- **Embedded URLs / @mentions** → passed verbatim to model; Gemma 3 preserves them in practice.
- **Long text (> 2000 chars)** → truncate, append `…`, log.
- **Concurrent taps on different messages** → actor serializes; progressive completion visible.
- **Tap during in-flight** → `store.startInFlight` returns false → no-op.
- **Chat switch mid-translation** → task continues; result keyed by surfaceID; visible when user returns.
- **Quit during download** → partial files in temp; `refreshState` checks manifest + all shards next launch. Missing → `.absent`. Re-click Download resumes via Range.
- **Memory** → engine holds model (~2.3GB resident). No idle unload — reload latency outweighs savings.

## Testing

### Unit tests (`yawacTests/`)

- `LanguageDetectorTests`
  - German sentence → `"de"`.
  - Finnish sentence → `"fi"`.
  - English sentence → `"en"`.
  - `"Hi"` → nil (too short).
  - `"👍😊"` → nil (no script).
  - Mixed-language → highest-confidence wins or nil if `< 0.6`.
  - Cache hit returns same result without re-running (verify via spy counter).
- `TranslationStoreTests`
  - `startInFlight` returns true once, false on second call.
  - `finish` clears in-flight, stores entry.
  - `toggle` flips `showingTranslated`.
  - `fail` clears in-flight, no entry stored.
- `TranslationViewModelTests`
  - `shouldOfferTranslate` returns false when target == detected.
  - Returns false when detected lang in denylist.
  - Returns true otherwise.
  - `denyLanguage` persists to AppStorage and updates `denylist`.
  - `translate` short-circuits on model absent.
- `TranslationModelManagerTests`
  - `refreshState` returns `.absent` when dir missing.
  - Returns `.ready` when manifest + all shards present.
  - `delete` removes dir + flips state.
- `TranslationEngineTests` — **CI-skipped** (model not present). Gated behind `YAWAC_RUN_ML_TESTS=1`. When enabled: load → translate `"Hallo Welt"` DE→EN → assert response contains "hello" + "world" case-insensitive.

### Manual smoke

1. Open Settings (⌘,) → see target picker, empty denylist, model `Absent`.
2. Click Download → progress bar → finishes `Ready`.
3. Open a German message → "Translate" link under bubble.
4. Tap → "Translating…" → swaps to English → "See original" link.
5. Tap "See original" → swaps back.
6. Right-click German message → "Never translate German" → German links vanish.
7. Settings → remove German from denylist → links return.
8. Open Finnish message → translate works.
9. Open English-only chat → no links.
10. Quit + relaunch → translations gone (in-memory), model still Ready.

### Bridge / Go side

No changes. No new Go tests.

## File touch list

| File | Action |
|---|---|
| `yawac/Services/LanguageDetector.swift` | new |
| `yawac/Services/TranslationEngine.swift` | new |
| `yawac/Services/TranslationStore.swift` | new |
| `yawac/Services/TranslationModelManager.swift` | new |
| `yawac/ViewModels/TranslationViewModel.swift` | new |
| `yawac/Views/MessageRow.swift` | modify (footer link, context menu, surface helper) |
| `yawac/Views/SettingsView.swift` | new |
| `yawac/yawacApp.swift` | modify (instantiate VM, inject env, Settings scene) |
| `project.yml` | modify (add `mlx-swift-examples` SPM dep) |
| `yawacTests/LanguageDetectorTests.swift` | new |
| `yawacTests/TranslationStoreTests.swift` | new |
| `yawacTests/TranslationViewModelTests.swift` | new |
| `yawacTests/TranslationModelManagerTests.swift` | new |
| `yawacTests/TranslationEngineTests.swift` | new (CI-gated) |
