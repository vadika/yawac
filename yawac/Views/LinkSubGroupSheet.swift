import SwiftUI

/// Modal sheet for linking an existing WhatsApp group as a sub-group of
/// a community parent. Shows a search field and a list of viable
/// candidates (already filtered by `LinkSubGroupSheetModel.candidates`
/// to exclude parents, groups already linked under *this* community,
/// and groups where the caller is not an admin). Selecting a candidate
/// already linked under a *different* community trips the
/// cross-community confirmation gate before the bridge call.
///
/// Confirm calls `model.confirmLink()`; on success the sheet forwards
/// via `onLinked` and dismisses.
struct LinkSubGroupSheet: View {
    @Bindable var model: LinkSubGroupSheetModel
    /// Display name of the parent community, rendered in the sheet
    /// title and confirmation copy. Pure presentation — the bridge call
    /// uses `model.parentChatJID` which is fixed at init.
    let parentName: String
    /// Resolves a parent community JID to its display name for the
    /// "already linked under <X>" warning row and the cross-community
    /// confirmation message. Caller typically wires this to
    /// `ChatListViewModel.communityName(for:)`.
    let resolveCommunityName: (String) -> String
    /// Invoked once the bridge confirms the link. Caller is expected
    /// to dismiss any container sheet binding and refresh the parent.
    var onLinked: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showCrossCommunityConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchField
            candidateList
            if let err = model.error {
                Text(err)
                    .scaledUI(11)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.sidebarBg)
        .confirmationDialog(
            "Move \u{201C}\(model.selectedGroup?.name ?? "")\u{201D} between communities?",
            isPresented: $showCrossCommunityConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to \u{201C}\(parentName)\u{201D}", role: .destructive) {
                Task { await performLink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let g = model.selectedGroup,
               let other = g.linkedParentJID, !other.isEmpty {
                Text("\u{201C}\(g.name)\u{201D} is currently linked to \u{201C}\(resolveCommunityName(other))\u{201D}. Moving it removes it from there.")
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Link group to \u{201C}\(parentName)\u{201D}")
                .scaledUI(15, weight: .semibold)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
    }

    // MARK: - Search field

    @ViewBuilder
    private var searchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search")
                .scaledUI(11).foregroundStyle(Theme.textFaint)
            TextField("Filter groups", text: $model.query)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Candidate list

    @ViewBuilder
    private var candidateList: some View {
        List(model.candidates, selection: $model.selected) { g in
            VStack(alignment: .leading, spacing: 2) {
                Text(g.name)
                    .scaledUI(12)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let parent = g.linkedParentJID, !parent.isEmpty {
                    Text("\u{26A0} in \u{201C}\(resolveCommunityName(parent))\u{201D}")
                        .scaledUI(10)
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("\(g.participants.count) members")
                        .scaledUI(10)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .tag(g.jid as String?)
        }
        .frame(minHeight: 220)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if model.inFlight {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .disabled(model.inFlight)
            Button("Link") {
                if model.needsCrossCommunityConfirmation {
                    showCrossCommunityConfirm = true
                } else {
                    Task { await performLink() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.selected == nil || model.inFlight)
        }
    }

    // MARK: - Link dispatch

    private func performLink() async {
        await model.confirmLink()
        if model.didLink {
            onLinked()
            dismiss()
        }
    }
}
