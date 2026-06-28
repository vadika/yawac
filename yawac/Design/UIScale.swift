import SwiftUI

/// Discrete interface-scale steps. Centered on `.default` (factor 1.0) so the
/// middle step reproduces the app's pre-feature sizing.
///
/// macOS does NOT support Dynamic Type font scaling (`dynamicTypeSize` /
/// `Font.custom(relativeTo:)` are no-ops there), so scaling is done with an
/// explicit point-size multiplier (`scaleFactor`) applied via the
/// `uiScaleFactor` environment value + the `.scaledUI/.scaledMono/.scaledIcon`
/// font modifiers below.
enum UIScaleStep: Int, CaseIterable {
    case small = 0
    case compact
    case `default`
    case large
    case xLarge

    /// UserDefaults key for the persisted step (raw Int).
    static let storageKey = "yawac.uiScaleStep"

    /// Clamp an arbitrary stored Int into a valid step. Index-based so it
    /// stays correct even if raw values are ever renumbered non-contiguously.
    static func from(_ raw: Int) -> UIScaleStep {
        let index = min(max(raw, 0), allCases.count - 1)
        return allCases[index]
    }

    /// Point-size multiplier applied to every scalable font. `.default` is
    /// 1.0 — no change vs the pre-feature build.
    var scaleFactor: CGFloat {
        switch self {
        case .small:   return 0.88
        case .compact: return 0.95
        case .default: return 1.0
        case .large:   return 1.12
        case .xLarge:  return 1.23
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

// MARK: - Scale factor in the environment

private struct UIScaleFactorKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Current interface-scale multiplier. Injected at the app/window root
    /// from the stored `UIScaleStep`; read by the `.scaled*` font modifiers.
    var uiScaleFactor: CGFloat {
        get { self[UIScaleFactorKey.self] }
        set { self[UIScaleFactorKey.self] = newValue }
    }
}

// MARK: - Scalable font modifiers

/// Applies a Theme font at `size * uiScaleFactor`. Reading the factor from the
/// environment makes the view re-render (and the text resize) whenever the
/// scale changes — without touching view state.
private struct ScaledFontModifier: ViewModifier {
    enum Family { case ui, mono, icon }
    let family: Family
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.uiScaleFactor) private var scale

    func body(content: Content) -> some View {
        let s = size * scale
        let font: Font
        switch family {
        case .ui:   font = Theme.ui(s, weight: weight)
        case .mono: font = Theme.mono(s, weight: weight)
        case .icon: font = Theme.ui(s, weight: weight)
        }
        return content.font(font)
    }
}

extension View {
    /// `Theme.ui` at the current interface scale.
    func scaledUI(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFontModifier(family: .ui, size: size, weight: weight))
    }
    /// `Theme.mono` at the current interface scale.
    func scaledMono(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFontModifier(family: .mono, size: size, weight: weight))
    }
    /// `Theme.ui` for SF Symbols / glyphs at the current interface scale.
    func scaledIcon(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFontModifier(family: .icon, size: size, weight: weight))
    }
}
