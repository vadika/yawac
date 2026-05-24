import Foundation

struct PhoneSuggestion: Equatable, Identifiable {
    let jid: String
    let displayPhone: String
    var id: String { jid }
}
