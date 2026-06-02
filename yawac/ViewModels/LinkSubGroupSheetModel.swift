import Foundation
import Observation

/// Abstraction for the underlying link-sub-group bridge call. `WAClient`
/// conforms in production; tests inject a stub that records the last
/// `(parentJID, subJID)` pair. The bridge call is synchronous and
/// `nonisolated` on `WAClient` so the model can dispatch it off the
/// main actor.
protocol SubGroupLinker: AnyObject {
    func linkSubGroup(parentJID: String, subJID: String) throws
}

extension WAClient: SubGroupLinker {}

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

    /// Community parent under which the selected sub-group will be linked.
    let parentChatJID: String

    /// Caller's own JID — used to gate candidates on admin/super-admin.
    private let myJID: String

    /// Pre-fetched list of groups the caller is a member of. Filtered
    /// into `candidates` lazily.
    private let availableGroups: [BridgeGroupModel]

    private let linker: SubGroupLinker

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
         linker: SubGroupLinker) {
        self.parentChatJID = parentChatJID
        self.myJID = myJID
        self.availableGroups = availableGroups
        self.linker = linker
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
        group.participants.contains {
            $0.jid == myJID && ($0.isAdmin || $0.isSuper)
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
            let linker = self.linker
            let parent = parentChatJID
            try await Task.detached {
                try linker.linkSubGroup(parentJID: parent, subJID: selected)
            }.value
            didLink = true
            error = nil
        } catch let err {
            error = (err as NSError).localizedDescription
        }
    }
}
