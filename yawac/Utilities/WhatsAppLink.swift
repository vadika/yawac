import Foundation

enum WhatsAppLink: Equatable {
    case app
    case chat(phone: String, text: String?)
    case share(text: String)
    case invite(code: String)

    static func parse(_ url: URL) -> WhatsAppLink? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased() else { return nil }
        // Query strings use form encoding; decode literal '+' as a space while
        // preserving percent-encoded plus signs in the actual message text.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let items = parts.queryItems ?? []
        for key in ["phone", "text", "code"] where items.filter({ $0.name == key }).count > 1 {
            return nil
        }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        let path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path

        if scheme == "whatsapp" {
            guard path.isEmpty else { return nil }
            switch host {
            case "app": return .app
            case "send": return compose(phone: value("phone"), text: value("text"))
            case "chat": return invite(value("code"))
            default: return nil
            }
        }
        guard scheme == "https" || scheme == "http" else { return nil }
        switch host {
        case "wa.me":
            if path.isEmpty { return compose(phone: nil, text: value("text")) }
            return compose(phone: String(path.dropFirst()), text: value("text"))
        case "api.whatsapp.com", "web.whatsapp.com":
            guard path == "/send" else { return nil }
            return compose(phone: value("phone"), text: value("text"))
        case "chat.whatsapp.com":
            return invite(String(path.dropFirst()))
        default: return nil
        }
    }

    private static func compose(phone: String?, text: String?) -> WhatsAppLink? {
        if let phone, !phone.isEmpty {
            let allowed = CharacterSet(charactersIn: "+-() 0123456789")
            guard phone.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
            let digits = String(phone.filter { $0 >= "0" && $0 <= "9" })
            guard !digits.isEmpty, digits.count <= 15, digits.first != "0" else { return nil }
            return .chat(phone: digits, text: text)
        }
        return .share(text: text ?? "")
    }

    private static func invite(_ code: String?) -> WhatsAppLink? {
        guard let code, !code.isEmpty,
              code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return .invite(code: code)
    }
}
