import Foundation

/// One row in the chronologically-rendered conversation view. Either a
/// per-day separator (`dateHeader`) or a real message (`message`).
///
/// Identifiable so `ForEach` can use the case payload as a stable
/// identity instead of an offset. Stable IDs let LazyVStack reuse row
/// containers across data mutations — the offset-based identity used
/// before caused full re-mounts on every change, including initial
/// chat open, which dominated chat-switch latency.
///
/// Lives at module scope (rather than nested in `ConversationView`) so
/// `ConversationViewModel` can cache `[TimelineItem]` and hand the
/// already-sectioned array back to the view on every body eval — see
/// `ConversationViewModel.timeline()`.
enum TimelineItem: Identifiable {
    case dateHeader(Date)
    case message(UIMessage)

    var id: String {
        switch self {
        case .dateHeader(let d): return "h-\(Int(d.timeIntervalSince1970))"
        case .message(let m):    return "m-\(m.id)"
        }
    }
}
