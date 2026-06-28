import SwiftUI

/// Settings → Privacy. Same five WhatsApp knobs as `PrivacySettingsSheet`
/// (last seen / profile photo / about / groups → three-way visibility,
/// read receipts → on/off) but laid out as inline Card rows inside the
/// Settings window — no modal.
///
/// The existing `PrivacySettingsSheet` is still kept (and reachable as
/// a modal from Account → Privacy) so command-bar / keyboard-shortcut
/// entry points that pre-date the redesign keep working. The two surfaces
/// share no code today; that's intentional — the modal lives behind a
/// dimmed/blurred parent and has different chrome (Done button, fixed
/// frame), and duplicating the few binding helpers is cheaper than
/// abstracting them.
///
/// Each picker change flows through the same optimistic-with-revert
/// pattern as the sheet: local state flips immediately, a detached task
/// pushes to whatsmeow, and a server failure rewinds the row + surfaces
/// the error under it.
struct PrivacyPanel: View {
    @Environment(SessionViewModel.self) private var session

    @State private var settings: BridgePrivacySettings?
    @State private var loading = false
    @State private var loadError: String?
    @State private var rowError: [String: String] = [:]

    private let visibilityOptions: [(label: String, value: String)] = [
        ("Everyone",    "all"),
        ("My contacts", "contacts"),
        ("Nobody",      "none"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Privacy")
            SettingsCard {
                if loading {
                    loadingRow
                } else if let err = loadError {
                    errorRow(err)
                } else if settings != nil {
                    SettingsRow(label: "Last seen & Online") {
                        SettingsSelect(selection: lastSeenBinding,
                                       options: visibilityOptions)
                    }
                    SettingsRow(label: "Profile photo") {
                        SettingsSelect(selection: profileBinding,
                                       options: visibilityOptions)
                    }
                    SettingsRow(label: "About") {
                        SettingsSelect(selection: statusBinding,
                                       options: visibilityOptions)
                    }
                    SettingsRow(label: "Add me to groups") {
                        SettingsSelect(selection: groupAddBinding,
                                       options: visibilityOptions)
                    }
                    SettingsRow(label: "Read receipts") {
                        SettingsSwitch(isOn: readReceiptsBinding)
                    }
                }
            }
            Text("Changes sync to your phone and other linked devices.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 4)
                .padding(.top, 4)
            errorList
        }
        .task { await reload() }
    }

    @ViewBuilder
    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading…")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func errorRow(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(err)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.danger)
            SettingsPillButton("Retry", style: .neutral) {
                Task { await reload() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var errorList: some View {
        if !rowError.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rowError.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    Text("\(entry.key): \(entry.value)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    // MARK: - Bindings

    private var lastSeenBinding: Binding<String> {
        binding(get: { $0.lastSeen },
                set: { $0.lastSeen = $1 },
                name: "last",
                label: "Last seen & Online")
    }
    private var profileBinding: Binding<String> {
        binding(get: { $0.profile },
                set: { $0.profile = $1 },
                name: "profile",
                label: "Profile photo")
    }
    private var statusBinding: Binding<String> {
        binding(get: { $0.status },
                set: { $0.status = $1 },
                name: "status",
                label: "About")
    }
    private var groupAddBinding: Binding<String> {
        binding(get: { $0.groupAdd },
                set: { $0.groupAdd = $1 },
                name: "groupadd",
                label: "Add me to groups")
    }

    /// Read-receipts is the only field that's a SettingsSwitch instead of
    /// a three-way Select. whatsmeow rejects "contacts" for read receipts,
    /// so the spec collapses it to a binary toggle that maps to "all" / "none".
    private var readReceiptsBinding: Binding<Bool> {
        Binding(
            get: { (settings?.readReceipts ?? "all") == "all" },
            set: { newValue in
                guard var s = settings else { return }
                let prior = s.readReceipts
                let newValue = newValue ? "all" : "none"
                guard prior != newValue else { return }
                s.readReceipts = newValue
                settings = s
                Task {
                    await commit(name: "readreceipts",
                                 value: newValue,
                                 label: "Read receipts",
                                 revert: { var s = $0; s.readReceipts = prior; return s })
                }
            }
        )
    }

    private func binding(get: @escaping (BridgePrivacySettings) -> String,
                         set: @escaping (inout BridgePrivacySettings, String) -> Void,
                         name: String,
                         label: String) -> Binding<String> {
        Binding(
            get: { settings.map(get) ?? "" },
            set: { newValue in
                guard var s = settings else { return }
                let prior = get(s)
                guard prior != newValue else { return }
                set(&s, newValue)
                settings = s
                Task {
                    await commit(name: name,
                                 value: newValue,
                                 label: label,
                                 revert: { var s = $0; set(&s, prior); return s })
                }
            }
        )
    }

    // MARK: - I/O

    @MainActor
    private func reload() async {
        guard let client = session.client else {
            loadError = "Not connected."
            return
        }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            settings = try await Task.detached {
                try client.getPrivacySettings()
            }.value
        } catch {
            loadError = (error as NSError).localizedDescription
        }
    }

    @MainActor
    private func commit(name: String,
                        value: String,
                        label: String,
                        revert: (BridgePrivacySettings) -> BridgePrivacySettings) async {
        guard let client = session.client else { return }
        rowError[label] = nil
        do {
            try await Task.detached {
                try client.setPrivacySetting(name: name, value: value)
            }.value
        } catch {
            if let s = settings {
                settings = revert(s)
            }
            rowError[label] = (error as NSError).localizedDescription
        }
    }
}
