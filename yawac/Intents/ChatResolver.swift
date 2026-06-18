import Foundation

/// F97: chat-input resolver shared by all Shortcut intents. Pure
/// function — testable without an App Intents harness. Tries
/// phone-parse first, falls back to case-insensitive substring name
/// match. Errors on zero or multiple name matches.
enum ChatResolveError: Error, LocalizedError {
    case notPaired
    case notFound(input: String)
    case ambiguous(input: String, matches: [String])

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "No WhatsApp account is paired."
        case .notFound(let input):
            return "No chat matched \"\(input)\"."
        case .ambiguous(let input, let matches):
            let preview = matches.prefix(5).joined(separator: ", ")
            let extra = matches.count > 5 ? " and \(matches.count - 5) more" : ""
            return "\"\(input)\" matched \(matches.count) chats: \(preview)\(extra). Be more specific."
        }
    }
}

enum ChatResolver {
    static func resolveChat(_ input: String, in chats: [Chat]) throws -> Chat {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatResolveError.notFound(input: input) }

        // Phone path: keep digits only, try both @s.whatsapp.net + @lid.
        let digits = String(trimmed.filter(\.isNumber))
        if !digits.isEmpty {
            for suffix in ["@s.whatsapp.net", "@lid"] {
                if let hit = chats.first(where: { $0.jid == "\(digits)\(suffix)" }) {
                    return hit
                }
            }
        }

        // Name path: case-insensitive substring match.
        let lower = trimmed.lowercased()
        let nameMatches = chats.filter { $0.name.lowercased().contains(lower) }
        switch nameMatches.count {
        case 0:
            throw ChatResolveError.notFound(input: input)
        case 1:
            return nameMatches[0]
        default:
            throw ChatResolveError.ambiguous(input: input, matches: nameMatches.map(\.name))
        }
    }
}
