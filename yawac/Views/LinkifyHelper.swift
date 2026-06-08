import Foundation
import SwiftUI

/// Converts a plain string to an `AttributedString` with bare URLs
/// auto-linked. Used by surfaces that render user-authored blob text —
/// e.g. group description.
enum Linkify {
    /// Process-scoped detector. Reused on every call to avoid the
    /// per-call NSDataDetector allocation. F24.
    private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let str = String(attr.characters)
        guard let detector else { return attr }
        let nsRange = NSRange(str.startIndex..<str.endIndex, in: str)
        detector.enumerateMatches(in: str, range: nsRange) { match, _, _ in
            guard let match, let url = match.url,
                  let range = Range(match.range, in: str),
                  let attrRange = attr.range(of: String(str[range])) else { return }
            attr[attrRange].link = url
            attr[attrRange].foregroundColor = Color.accentColor
            attr[attrRange].underlineStyle = .single
        }
        return attr
    }
}
