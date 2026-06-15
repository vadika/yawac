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
        // F82: raw m.id (no "m-" prefix) so ForEach's Identifiable id
        // matches what `proxy.scrollTo` / `.scrollPosition(id:)` are
        // called with. Without this, the explicit `.id(msg.id)`
        // modifier inside the row body had to fire — forcing
        // ForEachState.firstOffset to construct every row's body to
        // resolve its scroll-target id. WhatsApp messageIDs are
        // alphanumeric UUID-shaped — never collide with the "h-" header
        // prefix.
        case .message(let m):    return m.id
        }
    }
}
