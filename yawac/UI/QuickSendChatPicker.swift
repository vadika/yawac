import SwiftUI

/// Search field + filtered chat list for the menu-bar quick-send
/// popover. The filter / ordering logic is split into a static helper
/// so it can be unit-tested without mounting SwiftUI.
struct QuickSendChatPicker: View {

    /// Default cap on the "recents" view when the query is empty. The
    /// design doc settled on ~15 visible rows by default; the query
    /// path uncaps so search reaches every chat.
    static let defaultRecentLimit = 15

    @Binding var query: String
    @Binding var selectedChatJID: String?

    let chats: [Chat]
    let nameResolver: (Chat) -> String

    @State private var highlightIndex: Int = 0

    /// Cache of `chats` sorted DESC by `lastTimestamp`. Keyed on
    /// `chats.count` so per-keystroke body evals reuse the sort; only
    /// a chat-list mutation invalidates it.
    @State private var sortedCache: [Chat] = []
    @State private var sortedCacheKey: Int = -1

    /// Pure, testable. Sorts recents DESC by `lastTimestamp`, then
    /// truncates to `recentLimit` when the query is empty; with a
    /// non-empty query it filters the entire list (case-insensitive
    /// substring on `name`, or digit-prefix on the JID's user
    /// component) and preserves the DESC ordering.
    static func filter(chats: [Chat], query: String,
                       recentLimit: Int) -> [Chat] {
        let sorted = chats.sorted { $0.lastTimestamp > $1.lastTimestamp }
        return applyQuery(sorted: sorted, query: query,
                          recentLimit: recentLimit)
    }

    /// Query/recent-limit application against a pre-sorted list. Split
    /// out so the view can reuse a memoized sort across keystrokes.
    static func applyQuery(sorted: [Chat], query: String,
                           recentLimit: Int) -> [Chat] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(sorted.prefix(recentLimit))
        }
        let needle = trimmed.lowercased()
        let needleIsDigits = trimmed.allSatisfy(\.isNumber)
        return sorted.filter { chat in
            if chat.name.lowercased().contains(needle) { return true }
            if needleIsDigits {
                let user = chat.jid.prefix(while: { $0 != "@" })
                return user.hasPrefix(trimmed)
            }
            return false
        }
    }

    private var visible: [Chat] {
        if sortedCacheKey != chats.count {
            // Defer the cache write to next runloop; for THIS body eval,
            // do the sort inline.
            let fresh = chats.sorted { $0.lastTimestamp > $1.lastTimestamp }
            DispatchQueue.main.async {
                sortedCache = fresh
                sortedCacheKey = chats.count
            }
            return Self.applyQuery(sorted: fresh,
                                   query: query,
                                   recentLimit: Self.defaultRecentLimit)
        }
        return Self.applyQuery(sorted: sortedCache,
                               query: query,
                               recentLimit: Self.defaultRecentLimit)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search a chat…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .onChange(of: query) { _, _ in highlightIndex = 0 }
                .onSubmit { selectHighlighted() }

            if visible.isEmpty {
                emptyState
            } else {
                List(Array(visible.enumerated()), id: \.element.id) { idx, chat in
                    row(for: chat,
                        displayName: nameResolver(chat),
                        highlighted: idx == highlightIndex)
                        .contentShape(.rect)
                        .onTapGesture {
                            highlightIndex = idx
                            selectHighlighted()
                        }
                        .listRowInsets(.init(top: 4, leading: 10,
                                             bottom: 4, trailing: 10))
                }
                .listStyle(.plain)
                .frame(maxHeight: 260)
            }
        }
        .focusable()
        .onKeyPress(.upArrow) {
            highlightIndex = max(0, highlightIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            let cap = max(0, visible.count - 1)
            highlightIndex = min(cap, highlightIndex + 1)
            return .handled
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let isEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(spacing: 4) {
            Text(isEmpty ? "Search to find a chat" : "No chats match")
                .scaledUI(12)
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    @ViewBuilder
    private func row(for chat: Chat,
                     displayName: String,
                     highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: chat.isGroup ? "person.3.fill" : "person.crop.circle.fill")
                .scaledIcon(14, weight: .regular)
                .foregroundStyle(Theme.textFaint)
            Text(displayName)
                .scaledUI(13)
                .lineLimit(1)
            Spacer()
            Text(chat.isGroup ? "Group" : "Direct")
                .scaledUI(10)
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(highlighted ? Theme.accent.opacity(0.18)
                                : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func selectHighlighted() {
        guard !visible.isEmpty else { return }
        let idx = max(0, min(highlightIndex, visible.count - 1))
        selectedChatJID = visible[idx].jid
    }
}
