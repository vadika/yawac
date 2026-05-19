import Foundation

struct Chat: Identifiable, Hashable {
    let jid: String
    var name: String
    var lastMessage: String
    var lastTimestamp: Int64
    var unread: Int
    var isGroup: Bool { jid.hasSuffix("@g.us") }
    var id: String { jid }
}
