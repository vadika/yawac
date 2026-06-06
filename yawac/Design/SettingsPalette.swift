import SwiftUI

/// Graphite palette specific to the redesigned Settings window
/// (v0.9.13 — per Claude Design handoff
/// `docs/superpowers/specs/2026-06-06-settings-redesign-spec.md`).
/// Not the app-wide `Theme` — that palette is shared with chats / sidebar
/// and uses bundled custom fonts. `SettingsPalette` is namespaced
/// specifically to Settings so a future re-skin of either surface doesn't
/// cross-contaminate the other. Use `SettingsPalette` only inside
/// `SettingsView` and its sub-panels under `Views/Settings/`.
///
/// Hex values are duplicated rather than aliased to `Theme.*` deliberately:
/// the spec authored these as a closed system, and we want to track future
/// design updates against this enum alone without rippling into chat
/// visuals.
enum SettingsPalette {
    // ─── Surfaces ───────────────────────────────────────────────
    static let bg          = Color(hex: 0x0d0f12)
    static let sidebarBg   = Color(hex: 0x0f1216)
    static let surface     = Color(hex: 0x171a20)
    static let surfaceAlt  = Color(hex: 0x1c2027)
    static let border      = Color(hex: 0x23272f)
    static let hairline    = Color.white.opacity(0.05)

    // ─── Text ───────────────────────────────────────────────────
    static let text        = Color(hex: 0xe6e8ec)
    static let textMuted   = Color(hex: 0x8a909c)
    static let textFaint   = Color(hex: 0x5b616c)

    // ─── Accent / status ────────────────────────────────────────
    static let accent      = Color(hex: 0x6b8aff)
    static let accentSoft  = Color(hex: 0x6b8aff).opacity(0.14)
    static let accentText  = Color(hex: 0xaebcff)
    static let danger      = Color(hex: 0xe87167)
    static let installed   = Color(hex: 0x34d4b7)
    static let installedSoft = Color(hex: 0x34d4b7).opacity(0.14)
}
