# Cleanup: scaling holdouts + date display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the AppKit mic glyph + three monospaced labels participate in
the existing interface-scale multiplier, and replace three concrete
shortcomings in the sidebar date display (hard-coded "Yest", missing year on
old dates, forced 24-hour clock).

**Architecture:** Reuses the existing `@Environment(\.uiScaleFactor)` value
already injected at the app root. `MicNSButton` (an
`NSViewRepresentable` wrapping a custom `NSView`) gains a `symbolPointSize`
parameter; `ComposerView` reads the env value and passes `14 * uiScale`. The
three `.font(.system(size:, design:.monospaced))` call sites switch to the
existing `.scaledMono` view modifier. `Chat.lastTimestampShort` is rewritten
to use `RelativeDateTimeFormatter` for "Yesterday" (locale-correct) and
`Date.formatted(date: .omitted, time: .shortened)` for today's time-of-day
(honors the system 12/24-hour preference), plus a 180-day branch that
appends a two-digit year.

**Tech Stack:** Swift 5.10, SwiftUI on macOS 14+, AppKit (`NSView`,
`NSImage.SymbolConfiguration`), `RelativeDateTimeFormatter`, `Foundation`
`Date.FormatStyle`. Existing test target: `yawacTests` (XCTest).

---

## File Map

- `yawac/Views/ChatListView.swift` — rewrite `private extension Chat`'s
  `lastTimestampShort` (lines 489–509).
- `yawacTests/ChatLastTimestampShortTests.swift` — NEW. Five branch tests
  (today / yesterday / 3 days ago / 30 days ago / 200 days ago).
- `yawac/Views/ReplyPreview.swift` — line 109: replace
  `.font(.system(size: 11, design: .monospaced))` → `.scaledMono(11)`.
- `yawac/Views/SharedMediaCell.swift` — line 47: replace
  `.font(.system(size: 10, weight: .semibold, design: .monospaced))` →
  `.scaledMono(10, weight: .semibold)`.
- `yawac/Views/MessageContextMenu.swift` — line 182: replace
  `.font(.system(size: 10.5, design: .monospaced))` → `.scaledMono(10.5)`.
- `yawac/Views/ComposerView.swift` — `MicNSButton` (≈336–356), `MicView`
  (≈358–411), `micButton` (≈232–254): add `symbolPointSize: CGFloat` param
  threaded through `init` + `updateNSView`; `ComposerView` reads
  `@Environment(\.uiScaleFactor)` and passes `14 * uiScale`.

Order chosen: date polish first (it has a real unit-test loop and is fully
isolated), then the three mono-label flips (mechanical, build-only verify),
then the mic plumbing (touches one file but spans Swift/AppKit boundary).

---

## Task 1: Date display polish (`lastTimestampShort`)

**Files:**
- Create: `yawacTests/ChatLastTimestampShortTests.swift`
- Modify: `yawac/Views/ChatListView.swift:489-509`

- [ ] **Step 1: Write the failing test file**

Create `yawacTests/ChatLastTimestampShortTests.swift` with:

```swift
import XCTest
@testable import yawac

final class ChatLastTimestampShortTests: XCTestCase {

    // Build a Chat whose lastTimestamp is `offset` seconds before now.
    private func chat(secondsAgo offset: TimeInterval) -> Chat {
        let ts = Int64(Date().timeIntervalSince1970 - offset)
        return Chat(
            jid: "test@s.whatsapp.net",
            name: "Test",
            lastMessage: "",
            lastTimestamp: ts,
            unread: 0
        )
    }

    private func chat(daysAgo days: Int) -> Chat {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let ts = Int64(date.timeIntervalSince1970)
        return Chat(
            jid: "test@s.whatsapp.net",
            name: "Test",
            lastMessage: "",
            lastTimestamp: ts,
            unread: 0
        )
    }

    // Today → locale-aware time. Must NOT be the literal "Yest" / weekday /
    // "d MMM" forms. Time format varies by locale (HH:mm vs h:mm a) so the
    // assertion is structural: it contains at least one ':' and at least
    // one digit.
    func testTodayUsesLocaleAwareTime() {
        let s = chat(secondsAgo: 3 * 3600).lastTimestampShort
        XCTAssertTrue(s.contains(":"), "expected time-of-day, got \(s)")
        XCTAssertTrue(s.contains(where: \.isNumber), "expected digits, got \(s)")
        XCTAssertNotEqual(s, "Yest")
    }

    // Yesterday → matches the RelativeDateTimeFormatter named-style output
    // for "1 day ago" in the current locale. Recomputed in the test so it
    // is locale-portable (en → "Yesterday", de → "Gestern", …).
    func testYesterdayIsLocalizedNamedDay() {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        let expected = f.localizedString(from: DateComponents(day: -1))
        let s = chat(daysAgo: 1).lastTimestampShort
        XCTAssertEqual(s, expected)
        XCTAssertNotEqual(s, "Yest", "must not emit the old hard-coded literal")
    }

    // 3 days ago → weekday abbreviation, no digits.
    func testThreeDaysAgoIsWeekday() {
        let s = chat(daysAgo: 3).lastTimestampShort
        XCTAssertFalse(s.contains(where: \.isNumber), "weekday should have no digits, got \(s)")
        XCTAssertFalse(s.isEmpty)
    }

    // 30 days ago → day + month, no year (must not end with two digits).
    func testThirtyDaysAgoHasNoYear() {
        let s = chat(daysAgo: 30).lastTimestampShort
        XCTAssertTrue(s.contains(where: \.isNumber), "expected a day number, got \(s)")
        let trailing = s.suffix(3) // " yy" if year present
        XCTAssertFalse(trailing.first == " " && trailing.dropFirst().allSatisfy(\.isNumber),
                       "30-day form should not include year, got \(s)")
    }

    // 200 days ago → day + month + two-digit year (ends with " <2 digits>").
    func testTwoHundredDaysAgoIncludesYear() {
        let s = chat(daysAgo: 200).lastTimestampShort
        let parts = s.split(separator: " ")
        XCTAssertGreaterThanOrEqual(parts.count, 3, "expected '<d> <MMM> <yy>', got \(s)")
        let yearToken = parts.last.map(String.init) ?? ""
        XCTAssertEqual(yearToken.count, 2, "year token should be 2 digits, got \(yearToken)")
        XCTAssertTrue(yearToken.allSatisfy(\.isNumber), "year token should be numeric, got \(yearToken)")
    }

    // Sanity: zero timestamp returns empty (preserved from current behavior).
    func testZeroTimestampReturnsEmpty() {
        let s = chat(secondsAgo: 0).lastTimestampShort
        // Caller passed seconds=0, so ts=now → must be non-empty (today).
        XCTAssertFalse(s.isEmpty)
        // And the explicit zero case stays empty:
        let zeroed = Chat(
            jid: "x", name: "x", lastMessage: "",
            lastTimestamp: 0, unread: 0
        )
        XCTAssertEqual(zeroed.lastTimestampShort, "")
    }
}
```

- [ ] **Step 2: Run the test file to confirm it fails**

```bash
xcodebuild test \
  -project yawac.xcodeproj \
  -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatLastTimestampShortTests \
  2>&1 | tail -40
```

Expected: failures in `testTodayUsesLocaleAwareTime` (today path returns
forced `"HH:mm"` which still contains `:` — so this one may pass
unexpectedly; the real check is `testYesterdayIsLocalizedNamedDay` returning
`"Yest"` ≠ expected, and `testTwoHundredDaysAgoIncludesYear` returning `"d
MMM"` without a year token).

- [ ] **Step 3: Rewrite `lastTimestampShort`**

In `yawac/Views/ChatListView.swift`, replace the existing private extension
(lines 489–509) with the version below. The extension drops the `private`
modifier so `yawacTests` can call `lastTimestampShort`; everything else in
the extension was already file-internal in spirit (no other file imports it).

```swift
extension Chat {
    /// Compact "HH:mm" or locale-equivalent / "Mon" / "12 May" / "12 May 24"
    /// style string for the row's right-aligned mono timestamp. Mirrors
    /// WhatsApp/iMessage behavior; honors the system 12/24-hour preference
    /// and current locale.
    var lastTimestampShort: String {
        let date = Date(timeIntervalSince1970: TimeInterval(lastTimestamp))
        guard lastTimestamp > 0 else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(date) {
            return Self.yesterdayFmt.localizedString(from: DateComponents(day: -1))
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

    fileprivate static let yesterdayFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test \
  -project yawac.xcodeproj \
  -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatLastTimestampShortTests \
  2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add yawac/Views/ChatListView.swift \
        yawacTests/ChatLastTimestampShortTests.swift
git commit -m "chatlist: localize 'Yesterday', add year to old dates, honor 12/24h"
```

---

## Task 2: Mono labels scale via `.scaledMono`

**Files:**
- Modify: `yawac/Views/ReplyPreview.swift:109`
- Modify: `yawac/Views/SharedMediaCell.swift:47`
- Modify: `yawac/Views/MessageContextMenu.swift:182`

This task has no unit-test coverage: SwiftUI font modifiers are not
meaningfully unit-testable without snapshot infrastructure that the project
doesn't have. Verification is build + manual visual.

- [ ] **Step 1: Update `ReplyPreview.swift`**

In `yawac/Views/ReplyPreview.swift` line 109, replace:

```swift
            Text(label)
                .font(.system(size: 11, design: .monospaced))
```

with:

```swift
            Text(label)
                .scaledMono(11)
```

- [ ] **Step 2: Update `SharedMediaCell.swift`**

In `yawac/Views/SharedMediaCell.swift` line 47, replace:

```swift
                            Text(badgeText)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
```

with:

```swift
                            Text(badgeText)
                                .scaledMono(10, weight: .semibold)
```

- [ ] **Step 3: Update `MessageContextMenu.swift`**

In `yawac/Views/MessageContextMenu.swift` line 182, replace:

```swift
                    Text(shortcut)
                        .font(.system(size: 10.5, design: .monospaced))
```

with:

```swift
                    Text(shortcut)
                        .scaledMono(10.5)
```

- [ ] **Step 4: Build to verify compilation**

```bash
xcodebuild build \
  -project yawac.xcodeproj \
  -scheme yawac \
  -destination 'platform=macOS' \
  2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add yawac/Views/ReplyPreview.swift \
        yawac/Views/SharedMediaCell.swift \
        yawac/Views/MessageContextMenu.swift
git commit -m "views: route 3 mono labels through scaledMono so they scale"
```

---

## Task 3: Mic glyph scales with `uiScaleFactor`

**Files:**
- Modify: `yawac/Views/ComposerView.swift` — `MicNSButton` (≈lines 336–356),
  `MicView` (≈lines 358–411), `micButton` computed property (≈lines 232–254).

The `MicView` is a custom `NSView`; its symbol size is set via
`NSImage.SymbolConfiguration(pointSize:)`. The 16×16 image-view layout
constraints stay (they bound the rendered symbol within the 32×32 button —
matching the send-button frame). Only the symbol-rendering point size scales.

- [ ] **Step 1: Add `symbolPointSize` parameter to `MicNSButton`**

In `yawac/Views/ComposerView.swift`, replace the `MicNSButton` struct
declaration + `makeNSView` + `updateNSView` (lines 336–356) with:

```swift
private struct MicNSButton: NSViewRepresentable {
    let symbolPointSize: CGFloat
    let isRecording: Bool
    let onDown: () -> Void
    let onMove: (CGFloat) -> Void
    let onUp: () -> Void

    func makeNSView(context: Context) -> MicView {
        let v = MicView()
        v.symbolPointSize = symbolPointSize
        v.isRecording = isRecording
        v.onDown = onDown
        v.onMove = onMove
        v.onUp = onUp
        return v
    }

    func updateNSView(_ v: MicView, context: Context) {
        v.symbolPointSize = symbolPointSize
        v.isRecording = isRecording
        v.onDown = onDown
        v.onMove = onMove
        v.onUp = onUp
    }
```

- [ ] **Step 2: Thread `symbolPointSize` into `MicView`'s configuration**

In the same file, replace the `MicView` class body (lines 358–410) with:

```swift
    final class MicView: NSView {
        var onDown: (() -> Void)?
        var onMove: ((CGFloat) -> Void)?
        var onUp: (() -> Void)?
        var symbolPointSize: CGFloat = 14 {
            didSet {
                guard symbolPointSize != oldValue else { return }
                applySymbolConfiguration()
            }
        }
        var isRecording: Bool = false {
            didSet {
                imageView.image = NSImage(systemSymbolName: isRecording ? "mic.fill" : "mic",
                                          accessibilityDescription: nil)
                layer?.backgroundColor = (isRecording ? NSColor.systemRed
                                                       : NSColor.controlAccentColor).cgColor
            }
        }
        private var startY: CGFloat = 0
        private let imageView = NSImageView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 16
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor

            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
            applySymbolConfiguration()
            imageView.contentTintColor = .white
            imageView.imageScaling = .scaleProportionallyDown
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startY = event.locationInWindow.y
            onDown?()
        }
        override func mouseDragged(with event: NSEvent) {
            onMove?(event.locationInWindow.y - startY)
        }
        override func mouseUp(with event: NSEvent) {
            onUp?()
        }

        private func applySymbolConfiguration() {
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: symbolPointSize, weight: .semibold)
        }
    }
}
```

- [ ] **Step 3: Read `uiScaleFactor` in `ComposerView` and pass to `MicNSButton`**

Two edits in `yawac/Views/ComposerView.swift`.

3a. Near the top of `ComposerView` (around line 7 where other
`@Environment` declarations live), add:

```swift
    @Environment(\.uiScaleFactor) private var uiScale
```

3b. Replace the `micButton` computed property body (lines 232–254) with:

```swift
    /// Push-and-hold mic, drawn entirely by AppKit. Pure NSView keeps
    /// SwiftUI's _ButtonGesture machinery from touching the click — on
    /// macOS 26 that pipeline crashes inside `MainActor.assumeIsolated`
    /// when its host view re-renders during dispatch.
    private var micButton: some View {
        MicNSButton(
            symbolPointSize: 14 * uiScale,
            isRecording: recorder.state == .recording,
            onDown: {
                Task { @MainActor in
                    guard await recorder.requestPermission() else { return }
                    recorder.start()
                }
            },
            onMove: { dy in wantsCancel = dy > 40 },
            onUp: {
                if wantsCancel || recorder.state != .recording {
                    recorder.cancel()
                } else if let r = try? recorder.finish() {
                    Task { await vm.sendVoiceNote(r) }
                } else {
                    recorder.cancel()
                }
                wantsCancel = false
            }
        )
        .frame(width: 32, height: 32)
    }
```

- [ ] **Step 4: Build to verify compilation**

```bash
xcodebuild build \
  -project yawac.xcodeproj \
  -scheme yawac \
  -destination 'platform=macOS' \
  2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add yawac/Views/ComposerView.swift
git commit -m "composer: scale mic glyph with uiScaleFactor"
```

---

## Task 4: Run the full test suite

Sanity gate before declaring done — ensures no neighboring test broke from
the `Chat` initializer assumptions in Task 1 or the view edits in Tasks 2/3.

- [ ] **Step 1: Run all `yawacTests`**

```bash
xcodebuild test \
  -project yawac.xcodeproj \
  -scheme yawac \
  -destination 'platform=macOS' \
  2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. If a pre-existing test fails, confirm
it's unrelated to these changes (e.g., known flake — check `git stash`
+ re-run on the previous commit); if related, debug before declaring done.

---

## Task 5: Manual visual verification

No commit; just an interactive check before merging.

- [ ] **Step 1: Launch the app and open Settings → Interface size**
- [ ] **Step 2: Drag the slider to X-Large**
- [ ] **Step 3: Open any chat. Confirm:**
  - The mic button's symbol is visibly larger (compare to the
    default-step screenshot, or to the send button's `paperplane.fill`).
  - The mic's 32 × 32 outer circle is unchanged.
  - The starred-section badge in a reply preview, the size badge on a
    shared-media thumbnail, and the keyboard-shortcut hint in a message
    context menu all grew with the rest of the UI.
- [ ] **Step 4: Drag back to Small. Confirm the mic symbol shrinks
      proportionally and nothing clips.**
- [ ] **Step 5: Open a chat whose last message arrived yesterday in the
      sidebar. Confirm it reads "Yesterday" (or your system locale's
      equivalent), not "Yest".**
- [ ] **Step 6: Open System Settings → General → Date & Time → "24-hour
      time" off. Restart the app. Confirm today's sidebar timestamps render
      as `2:32 PM` rather than `14:32`.**
- [ ] **Step 7: If you have a chat with a last message from > 6 months ago
      (e.g., an archived one), confirm its timestamp now shows the
      two-digit year (e.g., `12 Nov 25`).**

---

## Done When

- All four `xcodebuild` commands above succeed.
- All five manual checks in Task 5 pass.
- Five commits land on the branch (Tasks 1, 2, 3 — Task 4 and 5 are gates,
  not commits).
