# Interface Scale Design Spec

**Date:** 2026-05-29
**Status:** Approved (design)
**Topic:** User-adjustable interface scale for readability

## Goal

Let the user increase or decrease the size of text and icons across yawac for
readability, with a slider control in Settings. Scope is **text + icons** —
paddings, avatars, and the window itself stay fixed.

## Approach

Use macOS-native **Dynamic Type**. Make the app's font helpers scale relative
to `.body`, then drive the whole app from a single root `.dynamicTypeSize(...)`
environment value backed by an `@AppStorage` step. A Settings slider snaps
across 5 discrete steps centered on the current look.

Rejected alternatives:
- **Custom `@Environment(\.uiScale)` multiplier** — would give a continuous
  slider but requires converting ~116 call sites to a `.scaledFont` modifier.
  The user chose a stepped control, so the extra churn isn't justified.
- **Root `.scaleEffect` zoom** — blurs text at fractional scales and fights the
  window frame; also it scales spacing (out of scope).

## Scale steps

A `UIScaleStep` mapping a step index → `DynamicTypeSize` + label. Centered on
`.large` (SwiftUI's default), so step 2 reproduces today's exact sizing and
existing users see no change on upgrade.

| step | DynamicTypeSize | label     | ~relative |
|------|-----------------|-----------|-----------|
| 0    | `.small`        | Small     | 0.88      |
| 1    | `.medium`       | Compact   | 0.95      |
| 2    | `.large`        | Default   | 1.00      |
| 3    | `.xLarge`       | Large     | 1.12      |
| 4    | `.xxLarge`      | X-Large   | 1.23      |

Range is intentionally capped below the accessibility sizes (`.accessibility1`
…) because those scale aggressively enough to break the fixed-padding layout.

## Components

### 1. `UIScaleStep` (new, e.g. `yawac/Design/UIScale.swift`)

```swift
import SwiftUI

enum UIScaleStep: Int, CaseIterable {
    case small = 0, compact, `default`, large, xLarge

    static let storageKey = "yawac.uiScaleStep"
    static let fallback = UIScaleStep.default

    /// Clamp an arbitrary stored Int into a valid step.
    static func from(_ raw: Int) -> UIScaleStep {
        UIScaleStep(rawValue: min(max(raw, 0), allCases.count - 1)) ?? fallback
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small:    return .small
        case .compact:  return .medium
        case .default:  return .large
        case .large:    return .xLarge
        case .xLarge:   return .xxLarge
        }
    }

    var label: String {
        switch self {
        case .small:    return "Small"
        case .compact:  return "Compact"
        case .default:  return "Default"
        case .large:    return "Large"
        case .xLarge:   return "X-Large"
        }
    }
}
```

### 2. Font plumbing (`yawac/Design/Theme.swift`)

Make the two existing helpers scale, and add an icon helper:

```swift
static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    Font.custom(FontFamily.ui, size: size, relativeTo: .body).weight(weight)
}

static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    Font.custom(FontFamily.mono, size: size, relativeTo: .body).weight(weight)
}

/// Scalable font for SF Symbols / glyphs. SwiftUI sizes a symbol by the
/// resolved font's point size, and a `relativeTo:` custom font's point size
/// tracks Dynamic Type — so applying this to `Image(systemName:)` scales the
/// glyph in lockstep with `Theme.ui` text.
static func icon(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    Font.custom(FontFamily.ui, size: size, relativeTo: .body).weight(weight)
}
```

- The 67 `Theme.ui` / `Theme.mono` call sites need **no change** — they scale automatically.
- The ~49 raw `.font(.system(size: N))` / `.font(.system(size: N, weight: W))` icon
  calls are converted to `.font(Theme.icon(N))` / `.font(Theme.icon(N, weight: W))`.
  This is the bulk of the mechanical work and the only call-site churn.

Note: a handful of `.font(.system(size:))` uses may be on text rather than
glyphs (e.g. menu rows). Converting them to `Theme.icon` still scales them
correctly (same relativeTo), so a blanket conversion of all `.system(size:)`
font calls is acceptable — they all become scalable.

### 3. Apply the scale (root)

In `yawac/yawacApp.swift`, both scenes read the stored step and apply it:

```swift
@AppStorage(UIScaleStep.storageKey) private var scaleStepRaw = UIScaleStep.default.rawValue

// in WindowGroup content and in the Settings scene content:
.dynamicTypeSize(UIScaleStep.from(scaleStepRaw).dynamicTypeSize)
```

Applying to both the main `WindowGroup` and the `Settings` scene means the
inspector, menus, dialogs, and the Settings panel itself all scale (macOS
`Settings` scenes don't inherit the WindowGroup environment).

### 4. Settings control (`yawac/Views/SettingsView.swift`)

A new `Section("Display")` above the Translation sections:

```swift
@AppStorage(UIScaleStep.storageKey) private var scaleStepRaw = UIScaleStep.default.rawValue

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
        // Live preview — scales with the chosen step.
        Text("Aa  The quick brown fox")
            .font(Theme.ui(14))
            .dynamicTypeSize(step.dynamicTypeSize)
            .foregroundStyle(.secondary)
    }
}
```

The slider snaps to integer steps; the label + preview update live as the user
drags. The preview's explicit `.dynamicTypeSize` shows the chosen size even
before the change propagates to the rest of the app.

## Data flow

`@AppStorage` step ← Settings slider → root `.dynamicTypeSize` → every
`Theme.ui`/`mono`/`icon` font resolves at the scaled point size → text + glyphs
resize, layout reflows. Persists across launches via UserDefaults.

## Error handling

- `UIScaleStep.from(_:)` clamps any out-of-range / legacy stored value to a
  valid step (defaults to `.default`).
- No failure modes beyond that — Dynamic Type is a pure presentation concern.

## Testing

- **Unit (`UIScaleStepTests`):** `from(_:)` clamps below 0 and above the max to
  the end steps; each step maps to the expected `DynamicTypeSize`; `default`
  maps to `.large` (the no-op-on-upgrade invariant).
- **Manual:** drag the slider through all 5 steps; confirm text + icons grow/
  shrink together in the chat list, conversation, inspector, menus, and the
  Settings panel itself; confirm the setting survives relaunch; confirm
  `Default` looks identical to the pre-feature build.

## Out of scope (YAGNI)

- Continuous (non-stepped) scaling.
- Scaling paddings / avatars / window chrome.
- Per-chat or per-window scale.
- Accessibility-size steps (`.accessibility1`+) — capped to protect the
  fixed-padding layout.
