import Foundation

/// Minimal protocol JIDNormalize needs from a "client that can resolve
/// LIDs". WAClient conforms; tests pass a fake. Keeps this utility from
/// depending on the concrete bridge client and avoids any circular import.
protocol LIDResolving: AnyObject {
    func resolveLIDToPN(_ jid: String) -> String
    func resolvePNToLID(_ jid: String) -> String
}

/// JID identity primitives.
///
/// WhatsApp surfaces the same person under multiple JID strings:
///   - device suffix: `<user>:<device>@<server>` vs bare `<user>@<server>`
///   - privacy-LID duality: `<id>@lid` vs `<phone>@s.whatsapp.net` for the
///     same physical person, learned over time from group + sender events
///     into whatsmeow's local LID map.
///
/// Every consumer that compares JIDs, keys a collection by JID, or builds
/// a cache file name MUST go through one of these primitives. Raw `String`
/// equality on JIDs is unsafe — two strings can represent the same person
/// without being `==`.
///
/// **Pick the right primitive:**
///
/// - `bare(_:)` — cheap, strips only `:device`. Use when you only need to
///   collapse multi-device variants of the same JID (e.g. self-test).
/// - `canonical(_:client:)` — preferred display + storage key. Strips
///   device suffix, then resolves `@lid` → PN when the local map knows it.
///   Falls back to bare LID when the map is incomplete.
/// - `same(_:_:client:)` — equality across forms. Compares both directions
///   (LID→PN and PN→LID) so two JIDs match whenever the local map can
///   bridge either side. The right primitive for "is this me?" / "is this
///   the same person?" checks.
/// - `key(_:client:)` — alias for `canonical`. Documents intent at use
///   sites that key dictionaries / sets / cache files.
/// - `allForms(_:client:)` — all known string representations of a JID
///   (bare, canonical, reverse-mapped variant). Use for set-membership
///   tests against a set you can't rebuild with `key`.
///
/// Note: identity resolution is best-effort. The whatsmeow LID map is
/// populated lazily; `same(a, b)` may return false today and true tomorrow
/// once a relevant group event lands. Plan for that.
enum JIDNormalize {
    /// Strips a `:<device>` suffix from the user portion of a JID.
    static func bare(_ jid: String) -> String {
        guard let at = jid.firstIndex(of: "@") else { return jid }
        let user = jid[..<at]
        let server = jid[at...]
        if let colon = user.firstIndex(of: ":") {
            return String(user[..<colon]) + String(server)
        }
        return jid
    }

    /// Returns the canonical chat JID: bare + (if `@lid`) resolved to the
    /// PN form via the WAClient's local LID map. Falls back to `bare(jid)`
    /// when no PN mapping is known.
    static func canonical(_ jid: String, client: LIDResolving?) -> String {
        let stripped = bare(jid)
        guard stripped.hasSuffix("@lid"), let client else { return stripped }
        let resolved = client.resolveLIDToPN(stripped)
        return resolved == stripped ? stripped : bare(resolved)
    }

    /// Identity equality across LID↔PN. Returns true when `a` and `b`
    /// identify the same person, querying the local LID map in both
    /// directions so a match works whenever EITHER side resolves.
    static func same(_ a: String, _ b: String, client: LIDResolving?) -> Bool {
        let ab = bare(a)
        let bb = bare(b)
        if ab == bb { return true }
        // Canonical-vs-canonical handles LID→PN on either side.
        let ac = canonical(ab, client: client)
        let bc = canonical(bb, client: client)
        if ac == bc { return true }
        // Reverse direction: when one side is PN and the other is @lid
        // for the same person, canonical may have left @lid alone (no
        // forward mapping). Try resolving PN → LID to bridge from below.
        guard let client else { return false }
        if ab.hasSuffix("@s.whatsapp.net"), bb.hasSuffix("@lid") {
            return client.resolvePNToLID(ab) == bb
        }
        if bb.hasSuffix("@s.whatsapp.net"), ab.hasSuffix("@lid") {
            return client.resolvePNToLID(bb) == ab
        }
        return false
    }

    /// Stable key suitable for dictionaries, set elements, and cache
    /// filenames. Same person → same key whenever the LID map has the
    /// mapping; falls back to the bare JID otherwise. Documented alias
    /// for `canonical` so call sites read intent ("I'm keying by this").
    static func key(_ jid: String, client: LIDResolving?) -> String {
        canonical(jid, client: client)
    }

    /// All known string forms of `jid` (bare, canonical, reverse-resolved
    /// variant). Use for membership tests against an externally-keyed set
    /// you can't rebuild with `key` (e.g. an existing group's participant
    /// list whose JIDs come back from the server in whatever form the
    /// group's addressing mode uses).
    ///
    /// Returns `Set<String>` so callers can do `forms.contains(other)` for
    /// O(1) lookup, or intersect with another set.
    static func allForms(_ jid: String, client: LIDResolving?) -> Set<String> {
        var forms: Set<String> = [bare(jid)]
        let canon = canonical(jid, client: client)
        forms.insert(canon)
        // Reverse direction for the cases where canonical didn't bridge.
        if let client {
            if canon.hasSuffix("@lid") {
                let pn = client.resolveLIDToPN(canon)
                if pn != canon { forms.insert(bare(pn)) }
            }
            if canon.hasSuffix("@s.whatsapp.net") {
                let lid = client.resolvePNToLID(canon)
                if lid != canon { forms.insert(bare(lid)) }
            }
        }
        return forms
    }
}
