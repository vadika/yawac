import Foundation

enum MessageLifecycle {
    static let editWindow:   TimeInterval = 15 * 60
    static let revokeWindow: TimeInterval = 48 * 60 * 60

    static func canEdit(_ m: UIMessage, now: Date = .init()) -> Bool {
        guard m.fromMe else { return false }
        guard case .text = m.body else { return false }
        guard m.revokedAt == nil, m.locallyDeleted == false else { return false }
        return now.timeIntervalSince(m.timestamp) <= editWindow
    }

    static func canRevoke(_ m: UIMessage, now: Date = .init()) -> Bool {
        guard m.fromMe else { return false }
        guard m.revokedAt == nil, m.locallyDeleted == false else { return false }
        return now.timeIntervalSince(m.timestamp) <= revokeWindow
    }
}
