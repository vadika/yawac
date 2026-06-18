import SwiftUI

/// Automatically nils-out an optional binding after a fixed duration
/// whenever it becomes non-nil.
///
/// Usage:
/// ```swift
/// .autodismiss($errorMessage)                    // default 6 s
/// .autodismiss($errorMessage, after: .seconds(3))
/// ```
struct AutoDismiss<T: Equatable & Sendable>: ViewModifier {
    @Binding var value: T?
    let after: Duration

    func body(content: Content) -> some View {
        content.task(id: value) {
            guard value != nil else { return }
            try? await Task.sleep(for: after)
            value = nil
        }
    }
}

extension View {
    func autodismiss<T: Equatable & Sendable>(
        _ value: Binding<T?>,
        after: Duration = .seconds(6)
    ) -> some View {
        modifier(AutoDismiss(value: value, after: after))
    }
}
