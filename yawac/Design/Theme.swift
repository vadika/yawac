import SwiftUI

/// Graphite design tokens. Sourced from the Yawac Redesign handoff
/// bundle (claude.ai/design). Refined dark, Linear-style — cool gray
/// scale with a soft blue accent, mono metadata, soft bubbles. Custom
/// fonts (Inter Tight + JetBrains Mono + Instrument Serif) are bundled
/// and auto-registered via Info.plist's ATSApplicationFontsPath.
enum Theme {
    // ─── Surfaces ────────────────────────────────────────────────────
    static let bg            = Color(hex: 0x0d0f12)
    static let sidebarBg     = Color(hex: 0x0f1216)
    static let surface       = Color(hex: 0x171a20)
    static let surfaceAlt    = Color(hex: 0x1c2027)
    static let border        = Color(hex: 0x23272f)
    static let hairline      = Color.white.opacity(0.05)

    // ─── Text ────────────────────────────────────────────────────────
    static let text          = Color(hex: 0xe6e8ec)
    static let textMuted     = Color(hex: 0x8a909c)
    static let textFaint     = Color(hex: 0x5b616c)

    /// Background tint for messages matching the active in-chat find query.
    static let findHighlight        = Color(red: 0.95, green: 0.84, blue: 0.27)
                                          .opacity(0.28)
    /// Stronger tint for the current find-bar selection (↑/↓ cursor).
    static let findHighlightCurrent = Color(red: 0.95, green: 0.84, blue: 0.27)
                                          .opacity(0.55)

    // ─── Accent (soft blue) ──────────────────────────────────────────
    static let accent        = Color(hex: 0x6b8aff)
    static let accentSoft    = Color(red: 107/255, green: 138/255, blue: 255/255, opacity: 0.14)
    static let accentText    = Color(hex: 0xaebcff)

    // ─── Message bubbles ─────────────────────────────────────────────
    static let ownBubble     = Color(red: 107/255, green: 138/255, blue: 255/255, opacity: 0.16)
    static let ownText       = Color(hex: 0xdde3ff)
    static let ownBorder     = Color(red: 107/255, green: 138/255, blue: 255/255, opacity: 0.28)
    static let otherBubble   = Color(hex: 0x1a1e25)
    static let otherText     = Color(hex: 0xdadde2)
    static let otherBorder   = Color.white.opacity(0.04)

    // ─── Status / chrome ─────────────────────────────────────────────
    static let titleColor    = Color(hex: 0xe6e8ec).opacity(0.95)
    static let titlebarBg    = Color(hex: 0x0a0c0f)
    static let titlebarText  = Color(hex: 0x9aa1ad)
    static let onlineDot     = Color(hex: 0x22c55e)

    // ─── Role badges ─────────────────────────────────────────────────
    static let superRole     = Color(hex: 0xa78bfa)
    static let adminRole     = accent

    // ─── Geometry ────────────────────────────────────────────────────
    static let radius: CGFloat        = 10
    static let bubbleRadius: CGFloat  = 12
    static let sidebarItemRadius: CGFloat = 8
    static let pillRadius: CGFloat    = 22

    // ─── Typography ──────────────────────────────────────────────────
    // Font families resolve to the bundled TTFs registered via
    // ATSApplicationFontsPath = "Fonts" in Info.plist.
    enum FontFamily {
        static let ui      = "Inter Tight"
        static let mono    = "JetBrains Mono"
        static let display = "Inter Tight" // Graphite uses UI font for display
        static let serif   = "Instrument Serif" // reserved for Paper variant
    }

    /// Inter Tight at the given size + weight. Interface scaling multiplies
    /// `size` upstream in the `.scaledUI` modifier (macOS has no Dynamic Type),
    /// so this stays a plain fixed-size font.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(FontFamily.ui, size: size).weight(weight)
    }

    /// JetBrains Mono — for timestamps, JIDs, keyboard shortcut hints,
    /// vote counts, anything that benefits from tabular alignment.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(FontFamily.mono, size: size).weight(weight)
    }

    /// Font for SF Symbols / glyphs (point size only matters for symbols, so
    /// it reuses the ui() font). Interface scaling is applied via `.scaledIcon`.
    static func icon(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        ui(size, weight: weight)
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >>  8) & 0xff) / 255
        let b = Double( hex        & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
