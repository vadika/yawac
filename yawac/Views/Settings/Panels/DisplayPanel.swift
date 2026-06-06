import SwiftUI

/// Settings → Display. Interface-size segmented + appearance card
/// (Theme select + accent-color swatches).
///
/// **Interface size** binds to the existing `UIScaleStep` storage key
/// (so the rest of the app continues to react via `uiScaleFactor`).
/// The spec describes four pills (S/M/L/XL) but `UIScaleStep` has five
/// raw values — we expose four buttons here mapped S→small, M→default,
/// L→large, XL→xLarge, leaving `.compact` reachable only from prior
/// builds' continuous slider. Pressing any pill snaps to one of the
/// four canonical values.
///
/// **Theme** is a one-item Select today ("Graphite · Dark") — light
/// mode is roadmapped but unbuilt. The Select renders as a value chip
/// with a chevron even when there's only one option; that's deliberate
/// so the UI looks right once a second theme lands.
///
/// **Accent** is purely cosmetic in v0.9.13 — the stored color isn't
/// read by Theme/SettingsPalette yet. The swatch ring + binding is
/// here so the design exists end-to-end and the wiring can land in a
/// follow-up patch without re-shipping the Settings shell.
struct DisplayPanel: View {
    @AppStorage(UIScaleStep.storageKey) private var scaleStepRaw = UIScaleStep.default.rawValue
    @AppStorage("yawac.accentColor")    private var accentColor: Int = 0x6b8aff

    /// Discrete S/M/L/XL labels with stable identity for SettingsSegmented.
    private enum SizePill: String, CaseIterable, Identifiable {
        case s, m, l, xl
        var id: String { rawValue }
        var label: String {
            switch self {
            case .s: return "S"; case .m: return "M"
            case .l: return "L"; case .xl: return "XL"
            }
        }
        var step: UIScaleStep {
            switch self {
            case .s:  return .small
            case .m:  return .default
            case .l:  return .large
            case .xl: return .xLarge
            }
        }
        /// Preview point-size for the panel's "The quick brown fox" sample.
        /// These come from the design spec verbatim (13 / 15 / 18 / 22pt)
        /// rather than `step.scaleFactor * 14`, which would only span 12–17pt.
        var previewSize: CGFloat {
            switch self {
            case .s: return 13; case .m: return 15
            case .l: return 18; case .xl: return 22
            }
        }
        static func from(_ step: UIScaleStep) -> SizePill {
            switch step {
            case .small:   return .s
            case .compact: return .s   // legacy step — round down to nearest pill
            case .default: return .m
            case .large:   return .l
            case .xLarge:  return .xl
            }
        }
    }

    private var pillBinding: Binding<SizePill> {
        Binding(
            get: { SizePill.from(UIScaleStep.from(scaleStepRaw)) },
            set: { scaleStepRaw = $0.step.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            interfaceCard
            appearanceCard
        }
    }

    private var interfaceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Interface")
            SettingsCard {
                SettingsRow(label: "Interface size") {
                    SettingsSegmented(
                        selection: pillBinding,
                        options: SizePill.allCases,
                        label: { $0.label }
                    )
                }
                previewRow
            }
        }
    }

    private var previewRow: some View {
        let current = SizePill.from(UIScaleStep.from(scaleStepRaw))
        return HStack(spacing: 14) {
            Text("Aa")
                .font(.system(size: 18))
                .foregroundStyle(SettingsPalette.textFaint)
                .frame(width: 26, alignment: .leading)
            Text("The quick brown fox")
                .font(.system(size: current.previewSize))
                .foregroundStyle(SettingsPalette.text)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Appearance")
            SettingsCard {
                SettingsRow(label: "Theme") {
                    SettingsSelect(
                        selection: .constant("graphite"),
                        options: [("Graphite · Dark", "graphite")]
                    )
                }
                SettingsRow(label: "Accent color") {
                    swatchRow
                }
            }
        }
    }

    private var swatchRow: some View {
        HStack(spacing: 10) {
            ForEach(Self.swatches, id: \.self) { hex in
                let color = Color(hex: UInt32(hex))
                let selected = accentColor == hex
                Button {
                    accentColor = hex
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(selected ? color : .clear, lineWidth: 2)
                                .scaleEffect(1.45)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Four-swatch palette — blue / violet / teal / amber.
    private static let swatches: [Int] = [
        0x6b8aff, 0x9a7bff, 0x34d4b7, 0xf4b860,
    ]
}
