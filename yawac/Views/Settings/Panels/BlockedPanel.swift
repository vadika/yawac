import SwiftUI

/// Settings → Blocked. Lists everyone currently on the WhatsApp blocklist
/// with their human display string + a quick Unblock action.
///
/// **The point of the v0.9.13 redesign** (per spec §3): the prior
/// `SettingsView` rendered each blocklist entry as `session.displayName(for: jid)`,
/// which for a non-contact LID/JID degraded to the raw `<digits>@s.whatsapp.net`
/// (or worse, `<rand>@lid`). That leaked an internal identifier into the UI
/// and looked broken next to saved-contact rows.
///
/// `BlockedPanel.resolve(jid:)` enforces a strict three-step priority:
///   1. Saved contact name (e.g. "Mathew Freeman").
///   2. Formatted phone number for dialable `<digits>@s.whatsapp.net` JIDs,
///      via `Self.formatPhone` — a deliberately-naive heuristic since
///      libphonenumber is not a project dependency and we don't want to
///      add one for a settings cosmetic.
///   3. A masked form `+109 95 452 47744…` + the secondary tag
///      "Not in contacts" for anything else (typically `@lid` JIDs).
///
/// The search field filters on the *resolved* string, not the raw JID,
/// so typing a contact name finds them even when whatsmeow stored their
/// row as a bare number.
struct BlockedPanel: View {
    @Environment(SessionViewModel.self) private var session
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionLabel("Blocked contacts",
                                 trailing: "\(session.blockedJIDs.count) blocked")
            searchField
            content
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.textFaint)
            TextField("Search blocked", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(SettingsPalette.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(SettingsPalette.surface,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(SettingsPalette.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        let entries = filteredEntries
        if entries.isEmpty {
            SettingsCard {
                HStack {
                    Text(session.blockedJIDs.isEmpty
                         ? "No blocked contacts."
                         : "No matches.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsPalette.textMuted)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        } else {
            SettingsCard {
                ForEach(entries, id: \.jid) { entry in
                    BlockedRow(entry: entry) {
                        session.setBlocked(entry.jid, blocked: false)
                    }
                }
            }
        }
    }

    private var filteredEntries: [ResolvedEntry] {
        let resolved = session.blockedJIDs.sorted().map { resolve(jid: $0) }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return resolved
        }
        let q = query.lowercased()
        return resolved.filter { entry in
            entry.display.lowercased().contains(q)
                || entry.secondary.lowercased().contains(q)
        }
    }

    // MARK: - Resolution

    struct ResolvedEntry {
        let jid: String
        let display: String
        let secondary: String
        let isSaved: Bool
    }

    private func resolve(jid: String) -> ResolvedEntry {
        let saved = session.isSavedContact(jid)
        let name = session.displayName(for: jid)
        let user = userPart(of: jid)
        let isPhoneJID = jid.hasSuffix("@s.whatsapp.net")
                            && user.allSatisfy(\.isNumber)
                            && !user.isEmpty

        if saved {
            let secondary = isPhoneJID ? Self.formatPhone(user) : "Not in contacts"
            return ResolvedEntry(jid: jid,
                                 display: name,
                                 secondary: secondary,
                                 isSaved: true)
        }
        if isPhoneJID {
            // Unknown phone-JID — show the formatted number as the primary
            // line, "Not in contacts" as the secondary.
            return ResolvedEntry(jid: jid,
                                 display: Self.formatPhone(user),
                                 secondary: "Not in contacts",
                                 isSaved: false)
        }
        // LID or other non-dialable JID — render a masked form so users
        // can vaguely tell entries apart without leaking the raw id.
        return ResolvedEntry(jid: jid,
                             display: Self.maskedID(user),
                             secondary: "Not in contacts",
                             isSaved: false)
    }

    private func userPart(of jid: String) -> String {
        if let at = jid.firstIndex(of: "@") {
            return String(jid[..<at])
        }
        return jid
    }

    /// Heuristic phone formatter. Yawac doesn't ship libphonenumber and
    /// adding it for a settings cosmetic isn't worth the binary cost, so
    /// this groups digits using a deliberately-naive country-code split:
    /// 1–3 leading digits become the country code, the remainder is
    /// chunked into groups of 2–3. Wrong for some NANP and Italian
    /// regional plans but correct enough for the >95% of WhatsApp users
    /// whose stored JID matches `+CC NNN NNN NNNN`. Good citizen pattern:
    /// always shown with a `+`, always single-line.
    static func formatPhone(_ digits: String) -> String {
        guard !digits.isEmpty else { return "" }
        // Country code: try 3 / 2 / 1 in that order against a tiny known
        // set so common cases (FI=358, RU=7, US=1) come out right. Fall
        // back to a 1-digit CC.
        let knownCC2: Set<String> = [
            "30","31","32","33","34","36","39","40","41","43","44","45","46",
            "47","48","49","51","52","53","54","55","56","57","58","60","61",
            "62","63","64","65","66","81","82","84","86","90","91","92","93",
            "94","95","98",
        ]
        let knownCC3: Set<String> = [
            "212","213","216","218","220","221","222","223","224","225","226",
            "227","228","229","230","231","232","233","234","235","236","237",
            "238","239","240","241","242","243","244","245","246","247","248",
            "249","250","251","252","253","254","255","256","257","258","260",
            "261","262","263","264","265","266","267","268","269","290","291",
            "297","298","299","350","351","352","353","354","355","356","357",
            "358","359","370","371","372","373","374","375","376","377","378",
            "380","381","382","383","385","386","387","389","420","421","423",
            "500","501","502","503","504","505","506","507","508","509","590",
            "591","592","593","594","595","596","597","598","599","670","672",
            "673","674","675","676","677","678","679","680","681","682","683",
            "685","686","687","688","689","690","691","692","850","852","853",
            "855","856","880","886","960","961","962","963","964","965","966",
            "967","968","970","971","972","973","974","975","976","977","992",
            "993","994","995","996","998",
        ]
        let cc: String
        let rest: String
        if digits.count > 3, knownCC3.contains(String(digits.prefix(3))) {
            cc = String(digits.prefix(3))
            rest = String(digits.dropFirst(3))
        } else if digits.count > 2, knownCC2.contains(String(digits.prefix(2))) {
            cc = String(digits.prefix(2))
            rest = String(digits.dropFirst(2))
        } else if digits.count > 1 {
            cc = String(digits.prefix(1))
            rest = String(digits.dropFirst(1))
        } else {
            return "+" + digits
        }
        // Group rest into chunks of 3 from the left, with the last chunk
        // possibly shorter. Switch to chunks of 2 if the total tail is ≤6.
        let chunkSize = rest.count <= 6 ? 2 : 3
        var groups: [String] = []
        var idx = rest.startIndex
        while idx < rest.endIndex {
            let end = rest.index(idx, offsetBy: chunkSize, limitedBy: rest.endIndex)
                ?? rest.endIndex
            groups.append(String(rest[idx..<end]))
            idx = end
        }
        return "+\(cc) " + groups.joined(separator: " ")
    }

    /// Mask a non-phone JID user part so the row still feels uniquely
    /// keyed without leaking the full id. Format mirrors the spec
    /// (`+109 95 452 47744…`) — leading `+` keeps it visually consistent
    /// with the formatted phone rows.
    static func maskedID(_ id: String) -> String {
        guard id.count > 6 else { return "+" + id }
        let head = id.prefix(3)
        let mid1 = id.dropFirst(3).prefix(2)
        let mid2 = id.dropFirst(5).prefix(3)
        let tail = id.dropFirst(8).prefix(5)
        return "+\(head) \(mid1) \(mid2) \(tail)…"
    }
}

// MARK: - Row

private struct BlockedRow: View {
    let entry: BlockedPanel.ResolvedEntry
    let onUnblock: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.display)
                    .font(.system(size: 13.5))
                    .foregroundStyle(SettingsPalette.text)
                    .lineLimit(1)
                Text(entry.secondary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SettingsPalette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SettingsPillButton("Unblock", style: .neutral, action: onUnblock)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
    }

    @ViewBuilder
    private var avatar: some View {
        if entry.isSaved {
            initialAvatar
        } else {
            ZStack {
                Circle().fill(SettingsPalette.surfaceAlt)
                Image(systemName: "number")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsPalette.textFaint)
            }
            .frame(width: 34, height: 34)
        }
    }

    private var initialAvatar: some View {
        ZStack {
            LinearGradient(
                colors: [SettingsPalette.accent, SettingsPalette.accentText],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initial(of: entry.display))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }

    private func initial(of s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return "?" }
        return String(first).uppercased()
    }
}
