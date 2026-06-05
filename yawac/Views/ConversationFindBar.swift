import SwiftUI

/// Slim find bar that slides down from above the conversation scroll
/// view when `vm.findActive` is true. Highlights matches in-place;
/// ↑/↓ navigate.
struct ConversationFindBar: View {

    @Bindable var vm: ConversationViewModel
    @Environment(SessionViewModel.self) private var session
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    vm.findActive = false
                } label: {
                    Image(systemName: "xmark")
                        .scaledIcon(12, weight: .semibold)
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                TextField("Find in conversation", text: $vm.findQuery)
                    .textFieldStyle(.plain)
                    .scaledUI(13)
                    .focused($fieldFocused)
                    .onSubmit { vm.findNext() }

                counter

                Button { vm.findPrev() } label: {
                    Image(systemName: "chevron.up")
                        .scaledIcon(11, weight: .semibold)
                }
                .buttonStyle(.plain)
                .disabled(vm.findHits.isEmpty)
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button { vm.findNext() } label: {
                    Image(systemName: "chevron.down")
                        .scaledIcon(11, weight: .semibold)
                }
                .buttonStyle(.plain)
                .disabled(vm.findHits.isEmpty)
                .keyboardShortcut("g", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            SearchFilterChips(
                filters: $vm.findFilters,
                availableSenders: vm.knownSendersInChat(session: session),
                showChatChip: false,
                availableChats: [],
                chatJID: nil
            )
            .padding(.bottom, 4)
        }
        .background(Theme.surface)
        .overlay(Rectangle().frame(height: 1)
                    .foregroundStyle(Theme.border), alignment: .bottom)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder
    private var counter: some View {
        let q = vm.findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = !q.isEmpty || !vm.findFilters.isEmpty
        if !active {
            EmptyView()
        } else if vm.findHits.isEmpty {
            Text("No matches")
                .scaledUI(11)
                .foregroundStyle(Theme.textFaint)
        } else {
            Text("\(vm.findCurrentIdx + 1) / \(vm.findHits.count)")
                .scaledMono(11)
                .foregroundStyle(Theme.textMuted)
        }
    }
}
