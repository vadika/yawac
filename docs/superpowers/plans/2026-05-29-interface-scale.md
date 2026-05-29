# Interface Scale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user scale text + icons across yawac for readability via a stepped slider in Settings, using native Dynamic Type.

**Architecture:** Make the app's font helpers (`Theme.ui`/`Theme.mono`/new `Theme.icon`) scale `relativeTo: .body`, then drive the whole app from a single root `.dynamicTypeSize(...)` backed by an `@AppStorage` step. A `UIScaleStep` enum maps 5 discrete steps (Small…X-Large, centered on the current default) to `DynamicTypeSize`. A Settings "Display" slider sets the step.

**Tech Stack:** Swift, SwiftUI (Dynamic Type), `@AppStorage`/UserDefaults, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-05-29-interface-scale-design.md`

---

## File Structure

- **Create** `yawac/Design/UIScale.swift` — `UIScaleStep` enum: step↔`DynamicTypeSize` mapping, labels, clamp. Pure logic, unit-tested.
- **Create** `yawacTests/UIScaleStepTests.swift` — tests for the mapping + clamp.
- **Modify** `yawac/Design/Theme.swift` — `ui`/`mono` gain `relativeTo: .body`; add `icon(_:weight:)`.
- **Modify** 9 view files — convert raw `.font(.system(size:))` to `Theme.icon` (symbols) / `Theme.ui` (text).
- **Modify** `yawac/yawacApp.swift` — `@AppStorage` step + `.dynamicTypeSize(...)` on the `WindowGroup` content and the `Settings` content.
- **Modify** `yawac/Views/SettingsView.swift` — "Display" section with the stepped slider + live preview.

Build command used throughout:
`xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5` → expect `** BUILD SUCCEEDED **`.
Single-test command:
`xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test -only-testing:yawacTests/UIScaleStepTests CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15` → expect `** TEST SUCCEEDED **`.

Note: a NEW Swift file requires `xcodegen generate` before it's in the target (the `.xcodeproj` is generated + gitignored).

---

## Task 1: UIScaleStep enum + tests

**Files:**
- Create: `yawac/Design/UIScale.swift`
- Create: `yawacTests/UIScaleStepTests.swift`

- [ ] **Step 1: Write the failing test**

Create `yawacTests/UIScaleStepTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import yawac

final class UIScaleStepTests: XCTestCase {

    func testDefaultMapsToLarge() {
        // Default step must reproduce SwiftUI's default sizing so existing
        // users see no change on upgrade.
        XCTAssertEqual(UIScaleStep.default.dynamicTypeSize, .large)
    }

    func testAllStepsMap() {
        XCTAssertEqual(UIScaleStep.small.dynamicTypeSize, .small)
        XCTAssertEqual(UIScaleStep.compact.dynamicTypeSize, .medium)
        XCTAssertEqual(UIScaleStep.default.dynamicTypeSize, .large)
        XCTAssertEqual(UIScaleStep.large.dynamicTypeSize, .xLarge)
        XCTAssertEqual(UIScaleStep.xLarge.dynamicTypeSize, .xxLarge)
    }

    func testFromClampsBelow() {
        XCTAssertEqual(UIScaleStep.from(-3), .small)   // rawValue 0
    }

    func testFromClampsAbove() {
        XCTAssertEqual(UIScaleStep.from(99), .xLarge)  // last case
    }

    func testFromExact() {
        XCTAssertEqual(UIScaleStep.from(2), .default)
    }

    func testLabels() {
        XCTAssertEqual(UIScaleStep.default.label, "Default")
        XCTAssertEqual(UIScaleStep.xLarge.label, "X-Large")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test -only-testing:yawacTests/UIScaleStepTests CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: FAIL — `cannot find 'UIScaleStep' in scope` (also will need `xcodegen generate` once the impl file exists; see Step 3).

- [ ] **Step 3: Write minimal implementation**

Create `yawac/Design/UIScale.swift`:

```swift
import SwiftUI

/// Discrete interface-scale steps, mapped to Dynamic Type sizes. Centered on
/// `.default` (== SwiftUI's `.large`) so the middle step reproduces the
/// app's pre-feature sizing.
enum UIScaleStep: Int, CaseIterable {
    case small = 0
    case compact
    case `default`
    case large
    case xLarge

    /// UserDefaults key for the persisted step (raw Int).
    static let storageKey = "yawac.uiScaleStep"

    /// Clamp an arbitrary stored Int into a valid step.
    static func from(_ raw: Int) -> UIScaleStep {
        let clamped = min(max(raw, 0), allCases.count - 1)
        return UIScaleStep(rawValue: clamped) ?? .default
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small:   return .small
        case .compact: return .medium
        case .default: return .large
        case .large:   return .xLarge
        case .xLarge:  return .xxLarge
        }
    }

    var label: String {
        switch self {
        case .small:   return "Small"
        case .compact: return "Compact"
        case .default: return "Default"
        case .large:   return "Large"
        case .xLarge:  return "X-Large"
        }
    }
}
```

Then regenerate the project so the new files are in the targets:
Run: `xcodegen generate`

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test -only-testing:yawacTests/UIScaleStepTests CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **` (6 tests).

- [ ] **Step 5: Commit**

```bash
git add yawac/Design/UIScale.swift yawacTests/UIScaleStepTests.swift
git commit -m "scale: UIScaleStep enum + tests"
```

---

## Task 2: Scalable Theme fonts

**Files:**
- Modify: `yawac/Design/Theme.swift` (the `ui`/`mono` funcs around lines 64-72)

- [ ] **Step 1: Make the font helpers scale + add an icon helper**

In `yawac/Design/Theme.swift`, replace the `ui` and `mono` functions and add `icon`:

```swift
    /// Inter Tight at the given size + weight, scaling with Dynamic Type
    /// (relative to `.body`). At the default Dynamic Type size the rendered
    /// size equals `size`, so existing layouts are unchanged.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(FontFamily.ui, size: size, relativeTo: .body).weight(weight)
    }

    /// JetBrains Mono — for timestamps, JIDs, keyboard shortcut hints,
    /// vote counts, anything that benefits from tabular alignment. Scales
    /// with Dynamic Type.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(FontFamily.mono, size: size, relativeTo: .body).weight(weight)
    }

    /// Scalable font for SF Symbols / glyphs. SwiftUI sizes a symbol by its
    /// resolved font's point size, and a `relativeTo:` custom font's point
    /// size tracks Dynamic Type — so applying this to `Image(systemName:)`
    /// scales the glyph in lockstep with `Theme.ui` text. (The font *family*
    /// is irrelevant for symbols; only the point size matters.)
    static func icon(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(FontFamily.ui, size: size, relativeTo: .body).weight(weight)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (All 67 existing `Theme.ui`/`Theme.mono` call sites now scale — no call-site change needed. At default Dynamic Type they look identical to before.)

- [ ] **Step 3: Commit**

```bash
git add yawac/Design/Theme.swift
git commit -m "theme: scale ui/mono fonts with Dynamic Type, add icon()"
```

---

## Task 3: Convert raw system fonts to scalable Theme fonts

**Files (each has raw `.font(.system(size:))` calls to convert):**
- Modify: `yawac/Views/ReplyPreview.swift`
- Modify: `yawac/Views/MessageRow.swift`
- Modify: `yawac/Views/ChatListView.swift`
- Modify: `yawac/Views/ChatInfoView.swift`
- Modify: `yawac/Views/ConversationView.swift`
- Modify: `yawac/Views/SharedMediaCell.swift`
- Modify: `yawac/Views/ComposerView.swift`
- Modify: `yawac/Views/MessageContextMenu.swift`
- Modify: `yawac/Views/AvatarView.swift`

**Conversion rule** — for every `.font(.system(size: N))` / `.font(.system(size: N, weight: .W))`:
- If the modifier is on an **`Image(systemName:)`** (an SF Symbol / glyph) → use `Theme.icon`.
- If it is on a **`Text`** (or other text view) → use `Theme.ui`.

Both are scalable and keep the same point size at the default step. The split keeps glyphs as symbols and routes any stray SF-font text onto the app's UI font (Inter Tight), matching the rest of the UI.

- [ ] **Step 1: Convert each site (per file)**

For each file, find every `.font(.system(size: …))` (look at the view it modifies) and rewrite. Examples:

```swift
// On a glyph — BEFORE:
Image(systemName: "paperclip")
    .font(.system(size: 15, weight: .regular))
// AFTER:
Image(systemName: "paperclip")
    .font(Theme.icon(15, weight: .regular))

// On text — BEFORE:
Text(label)
    .font(.system(size: 13.5))
// AFTER:
Text(label)
    .font(Theme.ui(13.5))
```

Mechanical mapping (apply the Image-vs-Text rule to pick `icon` vs `ui`):
- `.font(.system(size: N))` → `.font(Theme.icon(N))` or `.font(Theme.ui(N))`
- `.font(.system(size: N, weight: .W))` → `.font(Theme.icon(N, weight: .W))` or `.font(Theme.ui(N, weight: .W))`

Do NOT touch:
- `NSImage.SymbolConfiguration(pointSize:)` in `ComposerView.swift`'s `MicNSButton` — that's AppKit-drawn and out of scope; it stays a fixed size (acceptable: the push-to-talk mic button doesn't need to scale).
- Any `.system(size:, design: …)` form (none exist today, but if encountered, leave it — `Theme.icon`/`ui` don't take a design axis).

- [ ] **Step 2: Verify no raw SwiftUI system fonts remain**

Run: `grep -rnE '\.font\(\.system\(size:' yawac --include='*.swift'`
Expected: **no output** (every SwiftUI `.font(.system(size:))` converted). `NSImage.SymbolConfiguration(pointSize:)` is unaffected by this grep — that's fine.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ReplyPreview.swift yawac/Views/MessageRow.swift yawac/Views/ChatListView.swift yawac/Views/ChatInfoView.swift yawac/Views/ConversationView.swift yawac/Views/SharedMediaCell.swift yawac/Views/ComposerView.swift yawac/Views/MessageContextMenu.swift yawac/Views/AvatarView.swift
git commit -m "views: route raw system fonts through scalable Theme.icon/ui"
```

---

## Task 4: Wire the scale (app root + Settings control)

**Files:**
- Modify: `yawac/yawacApp.swift`
- Modify: `yawac/Views/SettingsView.swift`

- [ ] **Step 1: Apply the stored scale at both scenes**

In `yawac/yawacApp.swift`, add the AppStorage property to the `YawacApp` struct (next to the other `@State`/`let` members, e.g. after `let container: ModelContainer`):

```swift
    @AppStorage(UIScaleStep.storageKey) private var scaleStepRaw = UIScaleStep.default.rawValue
```

In the `WindowGroup` content chain, add `.dynamicTypeSize(...)` to `AppRoot()` (place it before `.preferredColorScheme(.dark)`):

```swift
            AppRoot()
                .environment(session)
                .environment(translation)
                .modelContainer(container)
                .frame(minWidth: 900, minHeight: 600)
                .dynamicTypeSize(UIScaleStep.from(scaleStepRaw).dynamicTypeSize)
                .preferredColorScheme(.dark)
                .background(Theme.bg)
                .graphiteWindow()
                .onAppear { menuBar.install(session: session) }
```

In the `Settings` scene, add it to `SettingsView()`:

```swift
        Settings {
            SettingsView()
                .environment(translation)
                .environment(session)
                .dynamicTypeSize(UIScaleStep.from(scaleStepRaw).dynamicTypeSize)
        }
```

- [ ] **Step 2: Add the Display section to Settings**

In `yawac/Views/SettingsView.swift`, add the AppStorage property below the existing `@Environment`/`@AppStorage` declarations:

```swift
    @AppStorage(UIScaleStep.storageKey) private var scaleStepRaw = UIScaleStep.default.rawValue
```

Add a new `Section` as the FIRST section inside the `Form` (before `Section("Translation")`):

```swift
            Section("Display") {
                let step = UIScaleStep.from(scaleStepRaw)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Interface size")
                        Spacer()
                        Text(step.label).foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(scaleStepRaw) },
                            set: { scaleStepRaw = UIScaleStep.from(Int($0.rounded())).rawValue }
                        ),
                        in: 0...Double(UIScaleStep.allCases.count - 1),
                        step: 1
                    )
                    Text("Aa  The quick brown fox")
                        .font(Theme.ui(14))
                        .dynamicTypeSize(step.dynamicTypeSize)
                        .foregroundStyle(.secondary)
                }
            }
```

(The preview's explicit `.dynamicTypeSize` makes the sample resize live as the slider moves, even within the Settings panel.)

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add yawac/yawacApp.swift yawac/Views/SettingsView.swift
git commit -m "settings: interface-size slider driving root dynamicTypeSize"
```

---

## Task 5: Manual verification

**Files:** none.

- [ ] **Step 1: Launch the built app**

Build, then open the Debug `yawac.app` from DerivedData.

- [ ] **Step 2: Verify scaling**

Open Settings → Display. Drag the "Interface size" slider through all 5 steps. Confirm:
- The preview line resizes live and the label updates (Small → X-Large).
- The chat list, conversation bubbles, message-row glyphs (reply/forward/star/pin icons), composer icons, inspector, and right-click menu all grow/shrink **together** (text + icons).
- `Default` (middle step) looks identical to the previous build (no layout shift).
- At `X-Large`, layout stays usable (no clipped/overlapping rows).

- [ ] **Step 3: Verify persistence**

Set a non-default step, quit, relaunch → the chosen size is restored.

---

## Self-Review

**Spec coverage:**
- 5-step Small…X-Large centered on Default → Task 1 (`UIScaleStep`). ✓
- Default == `.large` (no change on upgrade) → Task 1 test `testDefaultMapsToLarge`. ✓
- `Theme.ui`/`mono` `relativeTo: .body` + new `Theme.icon` → Task 2. ✓
- Convert ~49 raw `.font(.system(size:))` icon/text sites → Task 3 (9 files). ✓
- Root `.dynamicTypeSize` on WindowGroup AND Settings scene → Task 4 Step 1. ✓
- Settings "Display" slider + live label + preview → Task 4 Step 2. ✓
- `@AppStorage` persistence + clamp → Task 1 (`from`) + Task 4. ✓
- Unit tests (mapping + clamp + default invariant) → Task 1. ✓
- Manual verify → Task 5. ✓
- Out-of-scope (continuous, padding/avatar/window scaling, accessibility steps) → not built. ✓

**Placeholder scan:** none. Task 3 uses a precise mechanical transform rule + worked examples + a grep gate, not a vague "convert the sites."

**Type consistency:** `UIScaleStep` cases (`.small/.compact/.default/.large/.xLarge`), `storageKey`, `from(_:)`, `dynamicTypeSize`, `label` are used identically in Tasks 1, 4, and the tests. `Theme.icon`/`Theme.ui`/`Theme.mono` signatures match between Task 2 (def) and Task 3 (use). `scaleStepRaw` AppStorage key (`UIScaleStep.storageKey`) consistent across yawacApp + SettingsView.
