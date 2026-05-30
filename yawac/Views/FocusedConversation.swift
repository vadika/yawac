import SwiftUI

/// Focused-scene value carrying the currently-active conversation VM.
/// Used by the app-level "Find" menu command to reach the right
/// ConversationViewModel without prop drilling.
struct ActiveConversationKey: FocusedValueKey {
    typealias Value = ConversationViewModel
}

extension FocusedValues {
    var activeConversation: ConversationViewModel? {
        get { self[ActiveConversationKey.self] }
        set { self[ActiveConversationKey.self] = newValue }
    }
}
