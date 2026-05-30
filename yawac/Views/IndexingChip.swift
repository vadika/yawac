import SwiftUI

/// Slim "Indexing… N / M" chip shown above the sidebar search field
/// while `MessageIndex.shared.progress == .running`. Auto-hides on
/// `.done` / `.idle`.
struct IndexingChip: View {

    @Bindable var index: MessageIndex = .shared

    var body: some View {
        switch index.progress {
        case .running(let indexed, let total):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Indexing… \(indexed) / \(total)")
                    .scaledUI(11)
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.surfaceAlt, in: Capsule())
            .padding(.horizontal, 8)
        case .idle, .done:
            EmptyView()
        }
    }
}
