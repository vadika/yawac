import SwiftUI

/// Settings → Account. Profile header (avatar / name / phone / Edit
/// profile pill) followed by an Account card (Linked devices + Privacy
/// modals) and a Danger zone card (Delete account stub).
///
/// **Edit profile** opens the paired account's self-chat via
/// `session.requestSelectChat(ownJID)`. Avatar + About edit live in the
/// self-chat info pane (shipped in v0.9.1) so this re-uses that surface
/// rather than carving out a Settings-only profile editor. The Settings
/// window is left visible — closing it sits with the user; on macOS
/// the convention is "settings stay until you close them".
///
/// **Linked devices** and **Privacy** open the existing v0.9.11 and
/// v0.9.12 sheets respectively. They stay reachable from Settings even
/// though the spec inlines the Privacy panel — keyboard / command-bar
/// entry points still expect modals.
///
/// **Delete account** is intentionally not wired in v0.9.13. whatsmeow
/// can sign this device out (`client.logout()`) but real account deletion
/// is a phone-only operation, so the row surfaces a confirmation dialog
/// explaining that and stops there. Wiring an actual remote-delete flow
/// would need a separate spec.
struct AccountPanel: View {
    @Environment(SessionViewModel.self) private var session
    @State private var showLinkedDevices = false
    @State private var showPrivacy = false
    @State private var showDeleteDialog = false
    @State private var linkedDeviceCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            profileHeader
            accountCard
            dangerCard
        }
        .task { await refreshDeviceCount() }
        .sheet(isPresented: $showLinkedDevices) {
            LinkedDevicesSheet()
                .environment(session)
        }
        .sheet(isPresented: $showPrivacy) {
            PrivacySettingsSheet()
                .environment(session)
        }
        .confirmationDialog(
            "Delete WhatsApp account",
            isPresented: $showDeleteDialog,
            titleVisibility: .visible
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Account deletion is phone-only — open WhatsApp on your phone → Settings → Account → Delete my account. yawac will sign out automatically when the account is gone.")
        }
    }

    // MARK: - Profile header

    private var profileHeader: some View {
        let ownJID = session.client?.ownJID ?? ""
        let pushName = session.client?.ownPushName ?? ""
        return HStack(spacing: 14) {
            if !ownJID.isEmpty {
                AvatarView(jid: ownJID, name: pushName, size: 64)
                    .environment(session)
            } else {
                Circle()
                    .fill(SettingsPalette.surfaceAlt)
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(pushName.isEmpty ? "Yawac account" : pushName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(SettingsPalette.text)
                    .lineLimit(1)
                Text(formattedPhone(for: ownJID))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SettingsPalette.textMuted)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer()
            SettingsPillButton("Edit profile", style: .neutral) {
                guard !ownJID.isEmpty else { return }
                session.requestSelectChat(ownJID)
            }
            .disabled(ownJID.isEmpty)
        }
    }

    private func formattedPhone(for jid: String) -> String {
        guard !jid.isEmpty,
              let at = jid.firstIndex(of: "@") else { return "" }
        let user = String(jid[..<at])
        guard user.allSatisfy(\.isNumber), !user.isEmpty else { return "" }
        return BlockedPanel.formatPhone(user)
    }

    // MARK: - Account card

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Account")
            SettingsCard {
                SettingsRow(
                    icon: "laptopcomputer.and.iphone",
                    label: "Linked devices",
                    sublabel: linkedDevicesSublabel,
                    showChevron: true,
                    onTap: { showLinkedDevices = true }
                )
                SettingsRow(
                    icon: "lock.shield",
                    label: "Privacy",
                    sublabel: "Last seen, read receipts, groups",
                    showChevron: true,
                    onTap: { showPrivacy = true }
                )
                fullHistorySyncRow
            }
        }
    }

    // MARK: - Full history sync (F28)

    @ViewBuilder
    private var fullHistorySyncRow: some View {
        let s = session.fullSync
        SettingsRow(
            icon: "arrow.down.circle",
            label: "Full history sync",
            sublabel: fullSyncSublabel(s),
            showChevron: !s.inFlight,
            onTap: { session.startFullHistorySync() }
        )
        if s.inFlight {
            // F29: phone reports progress=0 on FULL_HISTORY_SYNC_ON_DEMAND
            // response chunks and progress=100 on every ON_DEMAND chunk —
            // neither rises through 1–99 like a real percent. Use the
            // determinate bar only when the phone reports something
            // useful (progress between 1 and 99); otherwise fall back to
            // the platform indeterminate animation so the user sees the
            // sync is alive even when the counters haven't ticked yet.
            Group {
                if s.progress > 0 && s.progress < 100 {
                    ProgressView(value: Double(s.progress), total: 100)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func fullSyncSublabel(_ s: SessionViewModel.FullSyncState) -> String {
        // F29: dropped the percent from in-flight sublabel — phone's
        // progress field is unreliable here (see F29 comment in
        // fullHistorySyncRow). Chunks + message count are honest.
        if s.inFlight {
            if s.chunks == 0 {
                return "Requesting history from phone…"
            }
            return "\(s.chunks) chunks • \(s.messages) messages"
        }
        if s.chunks > 0 {
            return "Last run: \(s.messages) messages across \(s.chunks) chunks"
        }
        if s.attempted {
            // Tap fired + 60 s silence + zero chunks. Phone either
            // rate-limited the FULL_HISTORY_SYNC_ON_DEMAND request or
            // had nothing newer than what we already hold.
            return "Phone replied with no new history"
        }
        return "Pull older messages from phone"
    }

    private var linkedDevicesSublabel: String {
        if let n = linkedDeviceCount {
            // WhatsApp allows 4 companion slots; the phone counts separately,
            // so we subtract 1 (the phone) from the total when present.
            let companions = max(n - 1, 0)
            return "\(companions) of 4 companion slots used"
        }
        return "View paired devices"
    }

    // MARK: - Danger zone

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Danger zone")
            SettingsCard {
                SettingsRow(
                    icon: "trash",
                    iconTint: SettingsPalette.danger,
                    label: "Delete account",
                    sublabel: "Phone-only — see info",
                    showChevron: true,
                    onTap: { showDeleteDialog = true }
                )
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func refreshDeviceCount() async {
        guard let client = session.client, session.state == .ready else { return }
        do {
            let devices = try await Task.detached {
                try client.listLinkedDevices()
            }.value
            linkedDeviceCount = devices.count
        } catch {
            // Sub-label gracefully degrades to a generic string; the
            // modal itself surfaces the real error on open.
            linkedDeviceCount = nil
        }
    }
}
