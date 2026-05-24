import Foundation

/// Substitutes `@<digits>` mentions in `text` with `@<DisplayName>` using
/// `resolver(jid)`. Tries both `@s.whatsapp.net` and `@lid` JID variants.
/// Falls back to the raw `@<digits>` when no name is known.
///
/// `\d{5,}` matches WhatsApp's mention syntax — short enough to skip `@1`
/// shorthands, long enough to catch real JID prefixes.
func resolveMentionsText(_ text: String, resolver: (String) -> String) -> String {
    guard text.contains("@"),
          let regex = try? NSRegularExpression(pattern: "@(\\d{5,})") else {
        return text
    }
    var out = text
    let matches = regex.matches(
        in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    for m in matches.reversed() {
        guard m.numberOfRanges >= 2,
              let full = Range(m.range, in: out),
              let digits = Range(m.range(at: 1), in: out) else { continue }
        let phone = String(out[digits])
        var replacement = "@\(phone)"
        for jid in ["\(phone)@s.whatsapp.net", "\(phone)@lid"] {
            let name = resolver(jid)
            if name != phone, !name.isEmpty {
                replacement = "@\(name)"
                break
            }
        }
        out.replaceSubrange(full, with: replacement)
    }
    return out
}
