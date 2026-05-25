import Foundation
import NaturalLanguage

/// On-device, synchronous language detection. Wraps Apple's
/// `NLLanguageRecognizer` with a small static cache and explicit
/// reject rules so chat UI can call this once per re-render
/// without measurable cost.
enum LanguageDetector {
    private static let cache: NSCache<NSNumber, NSString> = {
        let c = NSCache<NSNumber, NSString>()
        c.countLimit = 64
        return c
    }()

    /// Minimum confidence the recognizer must report before we
    /// trust the top hypothesis. Empirically 0.6 filters out
    /// short-string false positives without rejecting normal
    /// sentences.
    private static let minConfidence: Double = 0.6

    /// Minimum visible character count below which detection is
    /// considered unreliable.
    private static let minChars: Int = 10

    /// Returns the BCP-47 code (e.g. `"de"`, `"fi"`, `"en"`) of the
    /// dominant language in `text`, or `nil` if the text is too short,
    /// has no script characters, or the recognizer's confidence is
    /// below threshold.
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minChars else { return nil }

        let key = NSNumber(value: trimmed.hashValue)
        if let cached = cache.object(forKey: key) {
            return cached as String
        }

        let r = NLLanguageRecognizer()
        r.processString(trimmed)
        guard let top = r.languageHypotheses(withMaximum: 1).max(by: {
            $0.value < $1.value
        }) else {
            return nil
        }
        guard top.value >= minConfidence else { return nil }

        let code = top.key.rawValue
        cache.setObject(code as NSString, forKey: key)
        return code
    }
}
