import SwiftUI

// MARK: - SettingsCard
//
// Inset-grouped container in the System Settings style. A `VStack` of
// `SettingsRow`s (or arbitrary children) sitting on `SettingsPalette.surface`
// with a 1pt border, 12pt corner radius, and a 1pt `hairline` divider between
// children inset 16pt on the left only (matches macOS Settings, where the
// leading 16pt aligns the divider with the row label rather than the icon).
//
// The card uses `_VariadicView_Tree` to slice up the contents and intersperse
// dividers — the same trick `Form` / `List` use internally. Each child is
// wrapped in a `Group` so consumers can stack arbitrary SwiftUI views without
// our needing a custom protocol.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        _VariadicView.Tree(SettingsCardLayout()) {
            content
        }
    }
}

private struct SettingsCardLayout: _VariadicView_UnaryViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                if idx > 0 {
                    Rectangle()
                        .fill(SettingsPalette.hairline)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
                child
            }
        }
        .background(SettingsPalette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SettingsPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - SettingsRow
//
// 48pt min height row. Optional leading 26pt icon tile (rounded
// `surfaceAlt` square), 13.5pt label + optional 11.5pt faint sub-label,
// trailing control slot, optional `chevron.right` for navigation rows.
// `onTap` makes the whole row tappable (and shows a pointer cursor on
// hover — the chevron alone is too small a target).
struct SettingsRow<Trailing: View>: View {
    let icon: String?
    let iconTint: Color
    let label: String
    let sublabel: String?
    let showChevron: Bool
    let onTap: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    init(icon: String? = nil,
         iconTint: Color = SettingsPalette.textMuted,
         label: String,
         sublabel: String? = nil,
         showChevron: Bool = false,
         onTap: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.icon = icon
        self.iconTint = iconTint
        self.label = label
        self.sublabel = sublabel
        self.showChevron = showChevron
        self.onTap = onTap
        self.trailing = trailing()
    }

    var body: some View {
        let row = HStack(spacing: 12) {
            if let icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(SettingsPalette.surfaceAlt)
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(iconTint)
                }
                .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(SettingsPalette.text)
                if let sublabel {
                    Text(sublabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsPalette.textFaint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .contentShape(Rectangle())

        if let onTap {
            Button(action: onTap) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }
}

// MARK: - SettingsSectionLabel
//
// Tight mono uppercase header sitting above a card. `lineLimit(1)` is
// deliberate — section labels with a trailing count badge ("9 BLOCKED")
// otherwise wrap badly when the rail compresses the content column.
struct SettingsSectionLabel: View {
    let text: String
    let trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 10.5, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(SettingsPalette.textFaint)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing.uppercased())
                    .font(.system(size: 10.5, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(SettingsPalette.textFaint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - SettingsPillButton
//
// Small 7pt-radius action button used inside rows (Remove / Unblock /
// Update / Delete / etc). Three styles cover the spec's needs — the
// danger variant uses a soft red tint instead of a solid fill so it
// reads as "consequential but reversible" rather than "submit-y".
struct SettingsPillButton: View {
    enum Style { case neutral, danger, primary }

    let title: String
    let style: Style
    let action: () -> Void

    init(_ title: String,
         style: Style = .neutral,
         action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(bg, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var bg: Color {
        switch style {
        case .neutral: return SettingsPalette.surfaceAlt
        case .danger:  return SettingsPalette.danger.opacity(0.10)
        case .primary: return SettingsPalette.accent
        }
    }
    private var textColor: Color {
        switch style {
        case .neutral: return SettingsPalette.text
        case .danger:  return SettingsPalette.danger
        case .primary: return .white
        }
    }
}

// MARK: - SettingsSelect (pop-up button)
//
// Drop-in replacement for `Picker(.menu)` that paints in the Graphite
// palette. The native `.menu` style ignores foreground/background tints
// on macOS, so we wrap a `Menu` and render the value text + a paired
// up/down chevron ourselves. The menu items themselves do use system
// styling — overriding the popover is a private API call we don't want
// to tangle with.
struct SettingsSelect<T: Hashable>: View {
    @Binding var selection: T
    let options: [(label: String, value: T)]

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { opt in
                Button(opt.label) { selection = opt.value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsPalette.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SettingsPalette.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SettingsPalette.surfaceAlt,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? "—"
    }
}

// MARK: - SettingsSegmented
//
// Pill-segment group used for the Display panel's S / M / L / XL
// interface-size selector (and elsewhere if needed). The spec showed
// an old-school `.segmented` `Picker`, but `.segmented` on macOS
// inherits the system control look and can't be tinted — so we draw
// our own segment row.
struct SettingsSegmented<T: Hashable & Identifiable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { opt in
                let active = opt == selection
                Button {
                    selection = opt
                } label: {
                    Text(label(opt))
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.white : SettingsPalette.textMuted)
                        .frame(minWidth: 36)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(active ? SettingsPalette.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(SettingsPalette.surfaceAlt,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - SettingsSwitch
//
// Theme-tinted toggle. Wraps SwiftUI's native `Toggle` so VoiceOver,
// keyboard focus, and the macOS reduce-motion easing all come along
// for free.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(SettingsPalette.accent)
            .controlSize(.small)
    }
}
