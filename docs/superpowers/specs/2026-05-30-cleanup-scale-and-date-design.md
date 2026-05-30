# Cleanup: scaling holdouts + date display Design Spec

**Date:** 2026-05-30
**Status:** Approved (design)
**Topic:** Bundle two unrelated cleanup gaps — make the AppKit mic glyph + the
three `.system(size:, design:.monospaced)` labels participate in the
interface-scale multiplier; polish three date-display issues in
`Chat.lastTimestampShort`.

## Goal

Close two small UX gaps the interface-scale work and prior shipping left
behind:

1. **Scaling consistency.** The push-to-talk mic glyph (AppKit-drawn) and
   three monospaced labels stay fixed when the user changes interface size,
   creating visible mismatches at the X-Large step. Both become scalable
   without disturbing the rest of the layout.
2. **Date readability.** Three concrete issues in the sidebar timestamp:
   the hard-coded "Yest" string, no year on old dates, and forced 24-hour
   `HH:mm` regardless of the user's locale / system preference.

Neither piece adds a new feature; both reuse infrastructure that already
exists (`uiScaleFactor` env value, `.scaledMono` modifier, Swift
`Date.FormatStyle`).

## Out of scope

- **`vm.chats` refresh smarter.** Surveyed and rejected. The current
  `.onChange(of: vm.chats)` in `ChatListView` is required for delete →
  tombstone to reach active-search results; a sub-key gated on `jid`/`name`
  alone would regress the delete-tombstone fix (commit `761c746`). Equality
  on a few-hundred small `Chat` structs runs in sub-millisecond time. Leave
  the trigger as-is; this spec's rationale stands as the record.

## Component 1 — Mic + mono labels scale

### 1a. `MicNSButton` reads the interface scale

`ComposerView.swift` already wraps the AppKit `MicView` in an
`NSViewRepresentable`. Today it constructs an `NSImage.SymbolConfiguration`
with a fixed `pointSize: 14`. The fix:

- `ComposerView.micButton` reads `@Environment(\.uiScaleFactor)` (just like
  every `.scaledIcon`/`.scaledUI` modifier does internally) and passes the
  resolved point size into `MicNSButton`.
- `MicNSButton` gains a `symbolPointSize: CGFloat` parameter; `MicView`
  rebuilds `imageView.symbolConfiguration` from it in both `init` and
  `updateNSView(_:context:)` (so a scale change re-renders the symbol).
- The button container stays 32 × 32 — same as the neighboring send button's
  circle, which keeps its frame fixed and lets its `.scaledIcon` symbol grow
  inside. Consistent behavior, no layout shift.

Concretely, in `ComposerView.swift`:

```swift
private var micButton: some View {
    MicNSButton(
        symbolPointSize: 14 * uiScale,   // <-- new
        isRecording: recorder.state == .recording,
        onDown: { … },
        onMove: { dy in wantsCancel = dy > 40 },
        onUp: { … }
    )
    .frame(width: 32, height: 32)
}
```

with `@Environment(\.uiScaleFactor) private var uiScale` on `ComposerView`.

`MicView`'s init builds `symbolConfiguration = NSImage.SymbolConfiguration(
pointSize: symbolPointSize, weight: .semibold)`. `updateNSView` re-applies
the configuration when the prop changes.

### 1b. Mono labels switch to `.scaledMono`

Three call sites that today use `.font(.system(size: N, design: .monospaced))`
(or `weight + design`), do not scale, and sit next to scaling siblings:

- `yawac/Views/ReplyPreview.swift:109`
- `yawac/Views/SharedMediaCell.swift:47`
- `yawac/Views/MessageContextMenu.swift:182`

Replace each with `.scaledMono(N)` (preserving the original point size and
weight). `.scaledMono` uses `Theme.mono` (JetBrains Mono), which is already
the app's mono font everywhere else (`Theme.mono` ↔ `JetBrains Mono` is the
declared mapping). Switching SF Mono → JetBrains Mono at these three sites
also removes a font-family outlier; the visual difference at the default
scale step is negligible.

## Component 2 — Date display polish

All three fixes live in `Chat.lastTimestampShort` (the private extension at
the bottom of `yawac/Views/ChatListView.swift`).

### 2a. Localized "Yesterday"

Today the function returns the literal `"Yest"` for `cal.isDateInYesterday`.
Replace with a `RelativeDateTimeFormatter` that emits the locale-correct
named day:

```swift
private static let yesterdayFmt: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    f.dateTimeStyle = .named   // produces "Yesterday" / "Tomorrow"
    return f
}()
// …
} else if cal.isDateInYesterday(date) {
    return Self.yesterdayFmt.localizedString(from:
        DateComponents(day: -1))  // -> "Yesterday" / "Eilen" / …
}
```

The formatter is a static let so it's allocated once per session, not per
row render.

### 2b. Year on old dates

Today: dates older than 7 days are formatted as `d MMM` (e.g. `12 May`),
losing the year. Bump dates older than ~180 days to include the year:

```swift
} else if let days = cal.dateComponents([.day], from: date, to: Date()).day,
          days < 7 {
    f.dateFormat = "EEE"
} else if let days = cal.dateComponents([.day], from: date, to: Date()).day,
          days < 180 {
    f.dateFormat = "d MMM"
} else {
    f.dateFormat = "d MMM yy"
}
```

(Two-digit year keeps the sidebar tight; `yyyy` would shove the timestamp
column wider for older chats.)

### 2c. Respect system 12/24-hour preference

Today: same-day uses forced `"HH:mm"`. Use Swift's `FormatStyle` shorthand
which honors the user's locale + macOS 12/24-hour preference:

```swift
if cal.isDateInToday(date) {
    return date.formatted(date: .omitted, time: .shortened)
}
```

`date.formatted(date: .omitted, time: .shortened)` returns `"14:32"` on a
24-hour locale and `"2:32 PM"` on a 12-hour locale, without us having to
read `Locale.current.hourCycle` ourselves.

### Final shape of `lastTimestampShort`

```swift
private extension Chat {
    var lastTimestampShort: String {
        let date = Date(timeIntervalSince1970: TimeInterval(lastTimestamp))
        guard lastTimestamp > 0 else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(date) {
            return Self.yesterdayFmt.localizedString(from:
                DateComponents(day: -1))
        }
        let f = DateFormatter()
        if let days = cal.dateComponents([.day], from: date, to: Date()).day,
           days < 7 {
            f.dateFormat = "EEE"
        } else if let days = cal.dateComponents([.day], from: date, to: Date()).day,
                  days < 180 {
            f.dateFormat = "d MMM"
        } else {
            f.dateFormat = "d MMM yy"
        }
        return f.string(from: date)
    }

    private static let yesterdayFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()
}
```

## Testing

### Unit (`yawacTests/ChatLastTimestampShortTests.swift`, new)

Cover the four branches against a fixed reference `now`:

- Today (3 h ago) → matches `\d{1,2}[:\.]\d{2}` (locale-aware time pattern).
  Avoid asserting an exact string because the format depends on the test
  host's locale; assert the structural shape.
- Yesterday (1 day ago) → equals the formatter's output for "Yesterday" in
  the current locale (assert equal to the same `RelativeDateTimeFormatter`
  result computed in the test, not a hard-coded string — keeps the test
  locale-portable).
- 3 days ago → 3-letter weekday (regex `^[A-Za-zА-Яа-я]{3,4}$`).
- 30 days ago → `^\d+ [A-Za-zА-Яа-я]{3,4}$` (no year, `d MMM`).
- 200 days ago → ends in two digits (`^\d+ [A-Za-zА-Яа-я]{3,4} \d{2}$`).

Because `lastTimestampShort` reads `Date()` internally, the tests freeze the
reference indirectly: construct `lastTimestamp` as `now.addingTimeInterval(
-<offset>)`. Same-day / yesterday / N-days-ago all derive from "now",
matching how the function behaves at render time. Locale defaults will vary
on CI; tests stay structural rather than asserting language-specific strings.

### Manual

- Drag the interface-size slider to X-Large with a chat open: the mic
  symbol grows in lockstep with the send button's `paperplane.fill`; the
  three monospaced labels (a starred-section size tag, a shared-media size,
  a context-menu shortcut hint) scale with the rest.
- Switch the system to a 12-hour locale (e.g. `en_US`) and to a 24-hour
  locale (e.g. `en_GB`): today's timestamps reflect the choice without an
  app restart.
- Open a chat whose last message is from yesterday: shows "Yesterday" in
  the system language.
- Open an archived chat with a year-old last message: shows the year.

## Components touched

- `yawac/Views/ComposerView.swift` — `micButton` reads
  `@Environment(\.uiScaleFactor)`; `MicNSButton` + `MicView` gain
  `symbolPointSize` parameter.
- `yawac/Views/ReplyPreview.swift` — line 109: `.system(...)` → `.scaledMono`.
- `yawac/Views/SharedMediaCell.swift` — line 47: `.system(...)` → `.scaledMono`.
- `yawac/Views/MessageContextMenu.swift` — line 182: `.system(...)` → `.scaledMono`.
- `yawac/Views/ChatListView.swift` — `Chat.lastTimestampShort` rewrite + the
  `yesterdayFmt` static.
- `yawacTests/ChatLastTimestampShortTests.swift` — new, covers the four
  branches.

## Out of scope (will not do here)

- Changing `.scaledMono` itself (already correct).
- Other date sites — `DateSeparator` in ConversationView uses
  `.formatted(.dateTime.weekday().day().month(.abbreviated).year())` which
  already honors locale; not touched.
- Time-of-day rendering inside `MessageRow` bubble status row — separate
  concern; not requested.
- The `vm.chats.onChange` trigger — see Out of scope at the top.
