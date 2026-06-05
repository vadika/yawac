import SwiftUI

/// Horizontal pill strip rendering sender / kind / date / chat filter
/// chips. Drives both the in-chat ⌘F bar and the sidebar ⌘K Messages
/// section through a single `MessageIndex.SearchFilters` binding. Chip
/// menus drop down on click; the date chip's "Custom…" item presents
/// a sheet with two `DatePicker`s.
///
/// The `chatJID` binding stays separate from `filters` because the
/// chat scope is a chat-name picker (not part of `SearchFilters`'
/// SQL contract) — see `ChatSearchViewModel.globalChatFilter`.
struct SearchFilterChips: View {

    @Binding var filters: MessageIndex.SearchFilters
    let availableSenders: [(jid: String, name: String)]
    let showChatChip: Bool
    let availableChats: [(jid: String, name: String)]
    let chatJID: Binding<String?>?

    /// Fixed list — the FTS column stores PersistedMessage.kind verbatim.
    /// Order matches the spec's UX ordering (Text first, then visual
    /// media, then non-media kinds).
    private static let knownKinds: [(value: String, label: String)] = [
        ("text",     "Text"),
        ("image",    "Image"),
        ("video",    "Video"),
        ("audio",    "Audio"),
        ("voice",    "Voice"),
        ("document", "Document"),
        ("location", "Location"),
        ("contact",  "Contact"),
        ("poll",     "Poll"),
        ("sticker",  "Sticker"),
    ]

    @State private var customDateOpen = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                senderChip
                kindChip
                dateChip
                if showChatChip, let chatJID {
                    chatChipView(binding: chatJID)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $customDateOpen) {
            DateRangeSheet(
                initialFrom: filters.fromTimestamp,
                initialTo:   filters.toTimestamp
            ) { from, to in
                filters.fromTimestamp = from
                filters.toTimestamp   = to
            }
        }
    }

    // MARK: - Chips

    private var senderChip: some View {
        let selected = filters.sender
        return FilterChipShell(
            label: "Sender",
            selectedLabel: selected,
            isDisabled: availableSenders.isEmpty,
            onClear: { filters.sender = nil }
        ) {
            ForEach(availableSenders, id: \.jid) { item in
                Button(item.name) { filters.sender = item.name }
            }
            if !availableSenders.isEmpty {
                Divider()
                Button("Clear") { filters.sender = nil }
            }
        }
    }

    private var kindChip: some View {
        let selected = filters.kind.flatMap { value in
            Self.knownKinds.first(where: { $0.value == value })?.label
        }
        return FilterChipShell(
            label: "Kind",
            selectedLabel: selected,
            isDisabled: false,
            onClear: { filters.kind = nil }
        ) {
            ForEach(Self.knownKinds, id: \.value) { item in
                Button(item.label) { filters.kind = item.value }
            }
            Divider()
            Button("Clear") { filters.kind = nil }
        }
    }

    private var dateChip: some View {
        let selected = dateLabel
        return FilterChipShell(
            label: "Date",
            selectedLabel: selected,
            isDisabled: false,
            onClear: {
                filters.fromTimestamp = nil
                filters.toTimestamp   = nil
            }
        ) {
            Button("Today")         { applyPreset(.today) }
            Button("Last 7 days")   { applyPreset(.last7) }
            Button("Last 30 days")  { applyPreset(.last30) }
            Button("Last 90 days")  { applyPreset(.last90) }
            Divider()
            Button("Custom…")       { customDateOpen = true }
            Divider()
            Button("Clear") {
                filters.fromTimestamp = nil
                filters.toTimestamp   = nil
            }
        }
    }

    @ViewBuilder
    private func chatChipView(binding: Binding<String?>) -> some View {
        let selectedName: String? = {
            guard let jid = binding.wrappedValue else { return nil }
            return availableChats.first(where: { $0.jid == jid })?.name ?? jid
        }()
        FilterChipShell(
            label: "Chat",
            selectedLabel: selectedName,
            isDisabled: availableChats.isEmpty,
            onClear: { binding.wrappedValue = nil }
        ) {
            ForEach(availableChats, id: \.jid) { item in
                Button(item.name) { binding.wrappedValue = item.jid }
            }
            if !availableChats.isEmpty {
                Divider()
                Button("Clear") { binding.wrappedValue = nil }
            }
        }
    }

    // MARK: - Date helpers

    private enum DatePreset { case today, last7, last30, last90 }

    private func applyPreset(_ p: DatePreset) {
        let now = Date()
        let cal = Calendar.current
        let from: Date = {
            switch p {
            case .today:  return cal.startOfDay(for: now)
            case .last7:  return now.addingTimeInterval(-7  * 86_400)
            case .last30: return now.addingTimeInterval(-30 * 86_400)
            case .last90: return now.addingTimeInterval(-90 * 86_400)
            }
        }()
        filters.fromTimestamp = Int64(from.timeIntervalSinceReferenceDate)
        filters.toTimestamp   = nil
    }

    private var dateLabel: String? {
        let f = filters
        guard f.fromTimestamp != nil || f.toTimestamp != nil else { return nil }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        if let from = f.fromTimestamp, let to = f.toTimestamp {
            let fd = Date(timeIntervalSinceReferenceDate: TimeInterval(from))
            let td = Date(timeIntervalSinceReferenceDate: TimeInterval(to))
            return "\(df.string(from: fd)) – \(df.string(from: td))"
        }
        if let from = f.fromTimestamp {
            let fd = Date(timeIntervalSinceReferenceDate: TimeInterval(from))
            // Match a "since X" preset to a friendly label.
            let secs = Date().timeIntervalSince(fd)
            if secs < 86_400 * 1.5 { return "Today" }
            if abs(secs - 7  * 86_400) < 3600 { return "Last 7 days" }
            if abs(secs - 30 * 86_400) < 3600 { return "Last 30 days" }
            if abs(secs - 90 * 86_400) < 3600 { return "Last 90 days" }
            return "Since \(df.string(from: fd))"
        }
        if let to = f.toTimestamp {
            let td = Date(timeIntervalSinceReferenceDate: TimeInterval(to))
            return "Until \(df.string(from: td))"
        }
        return nil
    }
}

/// Single pill-shaped chip: label + dropdown chevron when empty;
/// selected value + xmark clear button when set. Wraps a Menu so the
/// caller passes the menu items as a trailing builder.
private struct FilterChipShell<Content: View>: View {
    let label: String
    let selectedLabel: String?
    let isDisabled: Bool
    let onClear: () -> Void
    @ViewBuilder let menu: () -> Content

    var body: some View {
        if let selected = selectedLabel {
            HStack(spacing: 4) {
                Menu {
                    menu()
                } label: {
                    Text("\(label): \(selected)")
                        .scaledUI(11, weight: .medium)
                        .foregroundStyle(Theme.accentText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledIcon(10, weight: .medium)
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.accentSoft, in: Capsule())
        } else {
            Menu {
                menu()
            } label: {
                HStack(spacing: 4) {
                    Text(label)
                        .scaledUI(11)
                        .foregroundStyle(Theme.textMuted)
                    Image(systemName: "chevron.down")
                        .scaledIcon(8, weight: .medium)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.4 : 1)
        }
    }
}
