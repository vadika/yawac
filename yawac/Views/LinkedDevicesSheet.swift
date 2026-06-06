import SwiftUI

/// Settings → Linked devices. Lists every device paired to the account
/// (phone + companions) by calling whatsmeow's `GetUserDevices`. Remote
/// revoke is not exposed by whatsmeow — only the phone can remove a
/// companion. The sheet documents that and offers a self-only
/// "Sign out of this device" action that calls `session.logout()`.
struct LinkedDevicesSheet: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [BridgeLinkedDevice] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var confirmSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Linked devices")
                    .scaledUI(15, weight: .semibold)
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }

            Text("Devices linked to your WhatsApp account. yawac counts as one of the four companion slots WhatsApp allows. Remote revoke is phone-only — open WhatsApp on your phone → Settings → Linked devices to remove a companion.")
                .scaledUI(11)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .scaledUI(12)
                        .foregroundStyle(Theme.textMuted)
                }
            } else if let err = loadError {
                Text(err)
                    .foregroundStyle(.red)
                    .scaledUI(12)
            } else if devices.isEmpty {
                Text("No linked devices yet.")
                    .scaledUI(12)
                    .foregroundStyle(Theme.textMuted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(devices) { d in
                        deviceRow(d)
                    }
                }
            }

            Spacer(minLength: 0)

            Divider()
            HStack {
                Spacer()
                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    Label("Sign out of this device",
                          systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
        .task { await reload() }
        .confirmationDialog(
            "Sign out of yawac on this Mac?",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                Task { await signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to scan a QR code from your phone to pair again. Local message history is preserved.")
        }
    }

    @ViewBuilder
    private func deviceRow(_ d: BridgeLinkedDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: d.isPhone ? "iphone" : (d.isSelf ? "laptopcomputer" : "macbook"))
                .scaledIcon(16, weight: .regular)
                .foregroundStyle(d.isSelf ? Theme.accent : Theme.textMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(label(for: d))
                    .scaledUI(13, weight: .medium)
                    .foregroundStyle(Theme.text)
                Text(d.jid)
                    .scaledMono(10)
                    .foregroundStyle(Theme.textFaint)
                    .textSelection(.enabled)
            }
            Spacer()
            if d.isSelf {
                Text("THIS DEVICE")
                    .scaledUI(9, weight: .semibold)
                    .tracking(0.5)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accentSoft, in: Capsule())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func label(for d: BridgeLinkedDevice) -> String {
        if d.isPhone { return "Phone" }
        if d.isSelf { return "yawac · this Mac" }
        return "Companion device #\(d.deviceID)"
    }

    @MainActor
    private func reload() async {
        guard let client = session.client else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            devices = try await Task.detached {
                try client.listLinkedDevices()
            }.value
        } catch {
            loadError = (error as NSError).localizedDescription
        }
    }

    @MainActor
    private func signOut() async {
        // SessionViewModel.logout() owns the full teardown — bridge
        // logout RPC + state reset + connectivity stop + boot back into
        // the QR flow. Calling client.logout() directly here would skip
        // the reset half and leave the UI half-paired.
        dismiss()
        await session.logout()
    }
}
