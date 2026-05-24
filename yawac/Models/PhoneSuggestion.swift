import Foundation

struct PhoneSuggestion: Equatable, Hashable, Identifiable {
    let jid: String
    let displayPhone: String
    var id: String { jid }
}
