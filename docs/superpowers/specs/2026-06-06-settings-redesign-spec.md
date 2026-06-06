# Yawac — Settings Redesign · Implementation Spec

Target: SwiftUI (macOS 14+). Replaces the current single-scroll Settings dialog.
Visual reference: `Yawac — Settings.html` in the design project.

---

## 0. Design tokens

Define these once (e.g. `Theme.swift`) and use everywhere. Dark "Graphite" palette.

```swift
enum YТ {                       // Yawac Theme
    static let bg          = Color(hex: 0x0d0f12)
    static let sidebarBg   = Color(hex: 0x0f1216)
    static let surface     = Color(hex: 0x171a20)
    static let surfaceAlt  = Color(hex: 0x1c2027)
    static let border      = Color(hex: 0x23272f)
    static let hairline    = Color.white.opacity(0.05)

    static let text        = Color(hex: 0xe6e8ec)
    static let textMuted   = Color(hex: 0x8a909c)
    static let textFaint   = Color(hex: 0x5b616c)

    static let accent      = Color(hex: 0x6b8aff)
    static let accentSoft   = Color(hex: 0x6b8aff).opacity(0.14)
    static let accentText  = Color(hex: 0xaebcff)
    static let danger      = Color(hex: 0xe87167)
    static let installed   = Color(hex: 0x34d4b7)
}
```

Fonts: UI = system (SF). Metadata / JIDs / section labels = SF Mono. Sizes/weights are called out per component below.

---

## 1. Window structure — two panes

Replace the single scrolling dialog with a **category rail + content pane** (macOS System Settings pattern).

```
┌──────────┬───────────────────────────────┐
│ Settings │  Display                       │  ← content header (44pt, hairline bottom)
│          ├───────────────────────────────┤
│ ⚙ General│                                │
│ ▢ Display│   [ grouped card ]             │  ← scrolling content, max 620pt centered
│ ⊕ Transl.│   [ grouped card ]             │
│ 🔒 Privacy│                                │
│ �siaslash Blocked│                          │
│ 👤 Account│                                │
└──────────┴───────────────────────────────┘
```

- Use `NavigationSplitView`. Sidebar **fixed 200pt** (`.navigationSplitViewColumnWidth(200)`).
- Window: `titleBarStyle = .hiddenInset` (traffic lights overlay the rail's top 44pt). Background `YТ.bg`.
- Categories (in order): **General, Display, Translation, Privacy, Blocked, Account**.
- Rail item: 13.5pt, icon (15pt SF Symbol) + label, 7pt vertical padding, 7pt corner radius. Active = `YТ.accentSoft` bg + `YТ.accentText` text + accent-tinted icon. Inactive icon `YТ.textMuted`.
- Rail header: "Settings" 15pt semibold above the list.
- Content header: category name, 14pt semibold, 44pt tall, hairline bottom.
- Content body: `ScrollView`, inner column `maxWidth: 620`, centered, 24/28pt padding, 26pt gap between sections.

SF Symbols for rail: `gearshape`, `display`, `globe`, `lock`, `nosign`, `person.crop.circle`.

---

## 2. Reusable building blocks

### Card (inset-grouped)
`VStack(spacing: 0)` · bg `YТ.surface` · 1pt `YТ.border` · 12pt radius · `clipped`.
Between rows: 1pt `YТ.hairline` divider, inset 16pt on the left only.

### Row
`HStack(spacing: 12)`, min height 48pt, padding `12×16`.
Optional 26pt rounded icon tile (`YТ.surfaceAlt` bg). Label 13.5pt. Optional sub-label 11.5pt `YТ.textFaint`. Trailing slot for control. Optional chevron (`chevron.right`, 13pt, `YТ.textFaint`) when the row pushes a subview.

### SectionLabel
10.5pt **SF Mono**, `YТ.textFaint`, uppercase, 1.4 tracking, **`lineLimit(1)`**. Optional trailing count (mono, also nowrap).

### Controls
- **Segmented** — `Picker().pickerStyle(.segmented)` OR custom: pill group, active segment = `YТ.accent` bg / white text.
- **Select (pop-up)** — `YТ.surfaceAlt` bg, 7pt radius, value text + up/down chevrons (`chevron.up.chevron.down`, `YТ.textMuted`).
- **Switch** — `Toggle().tint(YТ.accent)`.
- **PillButton** — 7pt radius. Default: `surfaceAlt` bg. Danger: `danger.opacity(0.10)` bg + danger text. Primary: `accent` bg + white.

---

## 3. Panels

### Display
1. **Interface** card:
   - Row "Interface size" → **segmented S / M / L / XL** (replace the old continuous slider — discrete stops are clearer).
   - Preview row: "Aa" (18pt, faint) + "The quick brown fox" whose point-size reflects the selected step (13 / 15 / 18 / 22).
2. **Appearance** card:
   - Row "Theme" → Select ("Graphite · Dark").
   - Row "Accent color" → 4 tappable 20pt swatches (blue/violet/teal/amber); selected gets a 2pt ring in its own color.

### Translation
1. **Translation** card: "Target language" → Select; "Translate automatically" → Switch.
2. **Never translate** card: empty-state line "No languages excluded." + "Add language" row (chevron-down affordance).
3. **Translation model** card (custom content, not a Row):
   - 34pt rounded accent icon tile · name "Qwen2.5-3B-Instruct" · mono sub "4-bit · on-device · 1.9 GB" · **INSTALLED** badge (mono 10pt, `installed` color, teal-soft bg).
   - Buttons: `Update` (default pill) + `Delete` (danger pill).

### Privacy (also available as modal — see §4)
One card: "Last seen & Online", "Profile photo", "About", "Add me to groups" → Selects; "Read receipts" → Switch.
Footer caption (11.5pt faint): "Changes sync to your phone and other linked devices."

### Blocked  ← **most important fix**
**Never display a raw JID.** Resolve each entry's display string in this order:
1. Saved contact name (e.g. "Mathew Freeman").
2. Formatted phone number via libphonenumber (e.g. `+358 40 123 4567`).
3. If the id is not a dialable number (an internal LID/JID), show a masked form (`+109 95 452 47744…`) and a secondary label **"Not in contacts"**.

Layout:
- Section label "Blocked contacts" + trailing count ("9 blocked", nowrap).
- Search field (`YТ.surface`, magnifier icon) filtering by resolved display string.
- Card of rows: 34pt avatar (gradient + initial when named; neutral `#` tile when unknown) · display string (13.5pt) · secondary line (mono 11pt — formatted number, or "Not in contacts") · `Unblock` pill (small).

### Account
- Profile header (outside cards): 64pt avatar, name "Krista" (19pt semibold), mono phone `+358 50 305 2224` (**nowrap**), `Edit profile` pill on the right.
- **Account** card: "Linked devices" (sub "4 of 4 companion slots used", chevron → devices modal) · "Privacy" (sub "Last seen, read receipts, groups", chevron → privacy modal).
- **Danger zone** card (own section): "Delete account" row, danger styling, trash icon, chevron.

### General
- **General** card: "Launch at login", "Show in menu bar", "Keep in dock" → Switches.
- **Notifications** card: "Message notifications", "Show preview text" → Switches; "Notification sound" → Select.

---

## 4. Sub-dialogs (modals)

Both are centered sheets over a **dimmed + blurred** parent (`.blur(radius: 6)` on the window content + `Color.black.opacity(0.5)` scrim). Sheet: `YТ.surface`, 16pt radius, heavy shadow. Header = title (19pt semibold) + **"Done"** (accent, top-right). Optional subtitle (12.5pt muted).

### Linked devices  (width ~560)
- Subtitle: explain yawac uses one of WhatsApp's four companion slots; remote revoke is phone-only.
- Device rows (cards, 11pt radius, `surfaceAlt`): 40pt icon tile (phone vs laptop SF Symbol) · name (14pt semibold) · mono JID (11pt faint, nowrap).
  - "This device" → accent-fill badge (nowrap). "Primary" → outline badge (nowrap).
  - **This-device row** is accent-tinted (`accentSoft` bg, accent border).
- Footer: full-width danger button "Sign out of this device" (door/arrow icon, nowrap).
- **Note**: JIDs ARE shown here (power users want them) — unlike the Blocked list.

### Privacy  (width ~480)
- Subtitle: "Changes sync to your phone and other linked devices."
- One grouped card identical to the Privacy panel (§3).

---

## 5. Behaviors

- Rail selection drives the content pane; remember last category across launches.
- Segmented interface-size updates the whole app's type scale live.
- Search in Blocked filters in real time on the resolved display string (so typing a name finds it even if stored as a number).
- Modals dismiss on Done, Esc, or scrim click. Reduce-motion: no scale/blur transition.
- All badges, phone numbers, and section labels are **single-line** (`lineLimit(1)`, `nowrap`) — they wrap badly otherwise.

## 6. Don'ts
- ❌ No raw JIDs/LIDs in the Blocked list or anywhere user-facing except the Linked-devices technical rows.
- ❌ No continuous slider for interface size — use discrete segments.
- ❌ Don't stack everything in one scroll — the rail is the point.
- ❌ Don't invent new colors — use the tokens in §0.
- ❌ Don't let badges/labels wrap to a second line.

---

## 7. `Color(hex:)` helper (if not present)
```swift
extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8)  & 0xff) / 255,
            blue:  Double( hex        & 0xff) / 255,
            opacity: alpha)
    }
}
```
