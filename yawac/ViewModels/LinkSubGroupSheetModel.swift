import Foundation
import Observation

/// Drives the "link an existing group as a community sub-group" sheet.
///
/// Filters the caller-supplied list of joined groups down to viable
/// link candidates (not the parent itself, not already linked under
/// this parent, caller is admin/super-admin) and exposes a
/// cross-community confirmation gate when the selected group already
/// belongs to a different community. `confirmLink()` dispatches the
/// synchronous bridge call off the main actor and surfaces success
/// via `didLink` or failure via `error`.
@MainActor
@Observable
final class LinkSubGroupSheetModel {

    /// Bridge call signature: synchronous, throwing.
    /// `WAClient.linkSubGroup` (`nonisolated`) wires through in
    /// production; tests pass an inline closure that records the last
    /// `(parentJID, subJID)` pair.
    typealias LinkSubGroup = @Sendable (String, String) throws -> Void

    /// Community parent under which the selected sub-group will be linked.
    let parentChatJID: String

    /// Caller's own JID — used to gate candidates on admin/super-admin.
    private let myJID: String

    /// Pre-fetched list of groups the caller is a member of. Filtered
    /// into `candidates` lazily.
    private let availableGroups: [BridgeGroupModel]

    private let linkSubGroup: LinkSubGroup

    /// LID resolver used to match `myJID` against participant JIDs across
    /// the LID ↔ PN identity split. Optional so tests can pass `nil` and
    /// rely on the bare-equality fast path in `JIDNormalize.same`.
    private let client: LIDResolving?

    /// Search query applied to candidate names (case-insensitive).
    var query: String = ""

    /// JID of the candidate the user has selected, or `nil`.
    var selected: String?

    /// Set while `confirmLink()` is in flight so the sheet can disable
    /// the confirm button and show a spinner.
    var inFlight: Bool = false

    /// Localized error string from the last `confirmLink()` attempt, or `nil`.
    var error: String?

    /// Flipped to `true` once the bridge confirms the link. The
    /// presenter observes this to dismiss and refresh the parent.
    private(set) var didLink: Bool = false

    init(parentChatJID: String,
         myJID: String,
         availableGroups: [BridgeGroupModel],
         linkSubGroup: @escaping LinkSubGroup,
         client: LIDResolving? = nil) {
        self.parentChatJID = parentChatJID
        self.myJID = myJID
        self.availableGroups = availableGroups
        self.linkSubGroup = linkSubGroup
        self.client = client
    }

    /// Groups the caller can link under `parentChatJID`:
    /// not a community parent themselves, not already linked under
    /// *this* parent, caller is admin (or super-admin), and the name
    /// matches `query` if one is set. Groups already linked under a
    /// *different* community remain candidates but trigger the
    /// cross-community confirmation gate when selected.
    var candidates: [BridgeGroupModel] {
        availableGroups
            .filter { !$0.isParent }
            .filter { ($0.linkedParentJID ?? "") != parentChatJID }
            .filter { isAdmin(of: $0) }
            .filter {
                query.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(query)
            }
    }

    private func isAdmin(of group: BridgeGroupModel) -> Bool {
        // JIDNormalize.same bridges the LID ↔ PN identity split so the
        // gate still fires when the participant entry came back in
        // `@lid` form but `myJID` is the PN (or vice versa). Mirrors the
        // canonical pattern in ChatListViewModel.isCurrentUserAdmin /
        // ChatInfoView.isCurrentUserAdmin.
        group.participants.contains {
            guard $0.isAdmin || $0.isSuper else { return false }
            return JIDNormalize.same($0.jid, myJID, client: client)
        }
    }

    /// Resolves the currently-selected JID back to a `BridgeGroupModel`
    /// for the cross-community gate.
    var selectedGroup: BridgeGroupModel? {
        guard let selected else { return nil }
        return availableGroups.first(where: { $0.jid == selected })
    }

    /// True when the selected candidate is already linked under a
    /// *different* community — linking will detach it from the old
    /// parent, so the sheet should require an explicit confirmation.
    var needsCrossCommunityConfirmation: Bool {
        guard let g = selectedGroup else { return false }
        return !(g.linkedParentJID ?? "").isEmpty
    }

    /// Dispatches the synchronous bridge link call off the main actor,
    /// then sets `didLink` on success or `error` on failure. Idempotent
    /// on the in-flight guard.
    func confirmLink() async {
        guard let selected, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let call = self.linkSubGroup
            let parent = parentChatJID
            try await Task.detached {
                try call(parent, selected)
            }.value
            didLink = true
            error = nil
        } catch let err {
            error = (err as NSError).localizedDescription
        }
    }
}
