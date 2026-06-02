import Foundation

/// Extracts a WhatsApp invite-link code from the URL forms the desktop
/// commonly sees on the clipboard. Returns `nil` for anything that isn't
/// either a known invite-URL host or a bare 16+ char alphanumeric token.
/// The host allow-list is hard-coded — only chat.whatsapp.com and wa.me
/// resolve to real invite codes, and matching other hosts would surface
/// preview rows for unrelated URLs the user pastes into search.
enum InviteLink {
    private static let minBareCodeLength = 16

    static func parseCode(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var body = trimmed
        if let r = body.range(of: "://") {
            let scheme = body[..<r.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            body = String(body[r.upperBound...])
        }

        let knownHosts = ["chat.whatsapp.com/", "wa.me/"]
        for host in knownHosts where body.lowercased().hasPrefix(host) {
            let codeStart = body.index(body.startIndex, offsetBy: host.count)
            return extractCode(String(body[codeStart...]))
        }
        if body.contains("/") {
            // Has a path but matches no known host → reject.
            return nil
        }
        return bareCode(body)
    }

    /// Strips trailing query / fragment / extra path segments and validates
    /// the leading run is plain alphanumerics.
    private static func extractCode(_ s: String) -> String? {
        var head = s
        for delimiter in ["?", "#", "/"] {
            if let r = head.range(of: delimiter) {
                head = String(head[..<r.lowerBound])
            }
        }
        guard !head.isEmpty,
              head.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return head
    }

    /// Bare-code path: must be `[A-Za-z0-9]+` and at least `minBareCodeLength`
    /// chars so single-word search queries (names, common words) don't fire
    /// a preview round-trip.
    private static func bareCode(_ s: String) -> String? {
        guard s.count >= minBareCodeLength,
              s.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return s
    }
}
