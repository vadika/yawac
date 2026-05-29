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
        // Symbols size by point size only; reuse the scalable ui() font.
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
