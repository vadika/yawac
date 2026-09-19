import Foundation

/// One conversation row: a date separator, a message, or a media album.
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
    case album([UIMessage])

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
        case .album(let messages): return messages[0].id
        }
    }
}


extension TimelineItem {
    private struct AlbumKey: Hashable {
        let id: String
        let chat: String
        let sender: String
        let fromMe: Bool

        init?(_ message: UIMessage) {
            guard let id = message.albumID, !id.isEmpty, !message.isViewOnce,
                  case .media(let kind, _, _, _, _, _) = message.body,
                  kind == "image" || kind == "video" else { return nil }
            self.id = id
            chat = message.chatJID
            sender = message.fromMe ? "me" : message.senderJID
            fromMe = message.fromMe
        }
    }

    static func sectioned(_ messages: [UIMessage]) -> [TimelineItem] {
        var albums: [AlbumKey: [UIMessage]] = [:]
        for message in messages {
            if let key = AlbumKey(message) { albums[key, default: []].append(message) }
        }
        var emitted: Set<AlbumKey> = []
        var rows: [TimelineItem] = []
        rows.reserveCapacity(messages.count + 8)
        let calendar = Calendar.current
        var lastDay: DateComponents?
        for message in messages {
            let row: TimelineItem
            if let key = AlbumKey(message), let members = albums[key], members.count > 1 {
                guard emitted.insert(key).inserted else { continue }
                // History may arrive in ID order within a second. Use the wire
                // index when present, preserving arrival order for older albums.
                let ordered = members.enumerated().sorted {
                    let left = $0.element.albumIndex ?? $0.offset
                    let right = $1.element.albumIndex ?? $1.offset
                    return left == right ? $0.offset < $1.offset : left < right
                }.map(\.element)
                row = .album(ordered)
            } else {
                row = .message(message)
            }
            let day = calendar.dateComponents([.year, .month, .day], from: message.timestamp)
            if day != lastDay {
                if let date = calendar.date(from: day) { rows.append(.dateHeader(date)) }
                lastDay = day
            }
            rows.append(row)
        }
        return rows
    }
}
