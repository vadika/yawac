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
