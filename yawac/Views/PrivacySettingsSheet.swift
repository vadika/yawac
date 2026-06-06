import SwiftUI

/// Settings → Privacy. Five WhatsApp privacy knobs surfaced as
/// three-way menus (Everyone / My contacts / Nobody) plus a binary
/// Read receipts toggle. Each flip is optimistic: the picker updates
/// immediately and a detached task pushes the change to WhatsApp;
/// on failure the row reverts and the error string lands underneath
/// it.
///
/// Skips Online (redundant with Last Seen for v1 — only `all` and
/// `match_last_seen` are valid) and the blacklist value (more
/// complex UI, harder to explain). Skips CallAdd / Messages /
/// Defense / Stickers entirely for now.
struct PrivacySettingsSheet: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var settings: BridgePrivacySettings?
    @State private var loading = false
    @State private var loadError: String?
    @State private var rowError: [String: String] = [:]

    /// Wire-value tuples for the three-way visibility pickers.
    private let visibilityOptions: [(label: String, value: String)] = [
        ("Everyone",    "all"),
        ("My contacts", "contacts"),
        ("Nobody",      "none"),
    ]

    /// Read-receipts is on/off only — whatsmeow rejects "contacts".
    private let readReceiptOptions: [(label: String, value: String)] = [
        ("On",  "all"),
        ("Off", "none"),
    ]

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Privacy")
                    .scaledUI(15, weight: .semibold)
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }

            Text("Changes sync to your phone and other linked devices.")
                .scaledUI(11)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            content

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, height: 480)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .scaledUI(12)
                    .foregroundStyle(Theme.textMuted)
            }
        } else if let err = loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text(err)
                    .foregroundStyle(.red)
                    .scaledUI(12)
                Button("Retry") { Task { await reload() } }
            }
        } else if settings != nil {
            Form {
                row(label: "Last seen & Online",
                    name: "last",
                    selection: lastSeenBinding,
                    options: visibilityOptions)
                row(label: "Profile photo",
                    name: "profile",
                    selection: profileBinding,
                    options: visibilityOptions)
                row(label: "About",
                    name: "status",
                    selection: statusBinding,
                    options: visibilityOptions)
                row(label: "Read receipts",
                    name: "readreceipts",
                    selection: readReceiptsBinding,
                    options: readReceiptOptions)
                row(label: "Add me to groups",
                    name: "groupadd",
                    selection: groupAddBinding,
                    options: visibilityOptions)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }

    @ViewBuilder
    private func row(label: String,
                     name: String,
                     selection: Binding<String>,
                     options: [(label: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(label, selection: selection) {
                ForEach(options, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            if let err = rowError[label] {
                Text(err)
                    .scaledUI(10)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Bindings
    //
    // Per-field bindings explicitly typed rather than walking a
    // WritableKeyPath switch — that pattern hits a Swift compiler
    // gotcha where the empty-default `return ""` branch flips the
    // keypath into a read-only one. Spelling each one out also makes
    // the optimistic / revert plumbing in `commit` easier to follow.

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

    private var readReceiptsBinding: Binding<String> {
        binding(get: { $0.readReceipts },
                set: { $0.readReceipts = $1 },
                name: "readreceipts",
                label: "Read receipts")
    }

    private var groupAddBinding: Binding<String> {
        binding(get: { $0.groupAdd },
                set: { $0.groupAdd = $1 },
                name: "groupadd",
                label: "Add me to groups")
    }

    /// Optimistic binding factory: applies the picker change to local
    /// state immediately, kicks off a detached commit, and stashes a
    /// revert closure so a server failure can rewind the row.
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
