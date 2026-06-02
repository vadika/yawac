import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct InviteLinkSheet: View {
    let chatJID: String
    let chatName: String
    let isAdmin: Bool
    let client: WAClient
    var onClose: () -> Void

    @State private var link: String? = nil
    @State private var loadError: String? = nil
    @State private var loading: Bool = true
    @State private var confirmRevoke: Bool = false
    @State private var revokeCooldownUntil: Date? = nil

    var body: some View {
        VStack(spacing: 14) {
            Text("Invite to \"\(chatName)\"")
                .scaledUI(13, weight: .semibold)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 18) {
                qrSquare
                rightColumn
            }
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task { await refresh(reset: false) }
        .confirmationDialog("Revoke link?",
                            isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) {
                Task { await refresh(reset: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone holding the current link won't be able to join with it.")
        }
    }

    @ViewBuilder
    private var qrSquare: some View {
        Group {
            if let link, let img = makeQR(link) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(width: 140, height: 140)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anyone with this link can join.")
                .scaledUI(11)
                .foregroundStyle(Theme.textMuted)
            if loading {
                ProgressView().controlSize(.small)
            } else if let err = loadError {
                Text(err)
                    .scaledUI(12)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            } else if let link {
                Text(link)
                    .scaledMono(11)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.surface,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .textSelection(.enabled)
            }
            // Hide all action buttons when there's no link — disabled
            // outlines clutter the error state and Share would publish nil.
            if link != nil {
                Button("Copy link") { copy() }
                    .buttonStyle(.bordered)
                ShareButton(link: link)
                if isAdmin {
                    Button("Revoke link") { confirmRevoke = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(revokeOnCooldown())
                }
            }
        }
    }

    private func revokeOnCooldown() -> Bool {
        guard let until = revokeCooldownUntil else { return false }
        return Date() < until
    }

    private func copy() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func refresh(reset: Bool) async {
        loading = true
        loadError = nil
        let chatJID = self.chatJID
        let client = self.client
        do {
            let l = try client.getGroupInviteLink(chatJID: chatJID, reset: reset)
            link = l
            if reset {
                revokeCooldownUntil = Date().addingTimeInterval(3)
            }
        } catch {
            loadError = error.localizedDescription
            link = nil
        }
        loading = false
    }

    private func makeQR(_ s: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(s.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: .init(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// Bridges `NSSharingServicePicker` so the SwiftUI button anchors the
/// macOS share sheet correctly.
private struct ShareButton: NSViewRepresentable {
    let link: String?

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(title: "Share…", target: context.coordinator,
                           action: #selector(Coordinator.share(_:)))
        btn.bezelStyle = .rounded
        return btn
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.isEnabled = link != nil
        context.coordinator.link = link
    }

    func makeCoordinator() -> Coordinator { Coordinator(link: link) }

    final class Coordinator: NSObject {
        var link: String?
        init(link: String?) { self.link = link }
        @objc func share(_ sender: NSButton) {
            guard let link else { return }
            let picker = NSSharingServicePicker(items: [link])
            picker.show(relativeTo: sender.bounds,
                        of: sender, preferredEdge: .minY)
        }
    }
}
