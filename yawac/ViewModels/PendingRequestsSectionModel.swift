import Foundation
import Observation

/// Abstraction for batch-approving / rejecting join requests.
/// `WAClient` conforms in production; tests inject a stub that returns
/// canned per-row results so we can exercise the partial-failure path
/// without touching the bridge.
protocol RequestUpdater: AnyObject {
    /// Synchronous bridge call. Implementations must be safe to invoke
    /// from a detached task — the section model drives this off-main so
    /// a slow bridge round-trip never blocks the admin panel UI.
    func updateGroupJoinRequests(chatJID: String,
                                 action: String,
                                 jids: [String]) throws -> [BridgeJoinRequestResult]
}

extension WAClient: RequestUpdater {}

/// One row in the pending-requests section of the admin panel. Carries
/// just enough display state to render the row and surface a per-row
/// failure badge after a partial-failure batch.
struct PendingRequestRow: Identifiable, Hashable {
    let jid: String
    let displayName: String
    let requestedAt: Int64
    var failureCode: Int?
    var id: String { jid }
}

/// Drives the "Pending join requests" section of the admin panel.
/// Owns the visible row list, dispatches per-row and bulk approve/reject
/// to the bridge off-main, and decrements the shared `JoinRequestStore`
/// count so the chat-list badge stays in sync with the panel.
@MainActor
@Observable
final class PendingRequestsSectionModel {
    let chatJID: String
    var requests: [PendingRequestRow] = []
    var inFlightJIDs: Set<String> = []
    var bulkInFlight: Bool = false
    var error: String?

    private let updater: RequestUpdater
    private let store: JoinRequestStore

    init(chatJID: String, updater: RequestUpdater, store: JoinRequestStore) {
        self.chatJID = chatJID
        self.updater = updater
        self.store = store
    }

    func approve(jid: String) async { await apply(action: "approve", jids: [jid]) }
    func reject(jid: String) async  { await apply(action: "reject",  jids: [jid]) }
    func approveAll() async {
        let all = requests.map(\.jid)
        await apply(action: "approve", jids: all)
    }

    /// Single point of dispatch for both per-row and bulk operations.
    /// Successful rows drop out; per-row failures stay in place with
    /// `failureCode` populated so the UI can mark the row. The store is
    /// decremented only for the number of rows that actually applied so
    /// the chat-list badge never undercounts a partial-failure batch.
    private func apply(action: String, jids: [String]) async {
        if jids.count == 1, let only = jids.first { inFlightJIDs.insert(only) }
        else { bulkInFlight = true }
        defer {
            for j in jids { inFlightJIDs.remove(j) }
            bulkInFlight = false
        }
        do {
            let results = try await Task.detached { [updater, chatJID] in
                try updater.updateGroupJoinRequests(
                    chatJID: chatJID, action: action, jids: jids)
            }.value
            var failed: [String] = []
            for r in results {
                if r.errorCode == nil || r.errorCode == 0 {
                    requests.removeAll { $0.jid == r.jid }
                } else {
                    failed.append(r.jid)
                    if let idx = requests.firstIndex(where: { $0.jid == r.jid }) {
                        requests[idx].failureCode = r.errorCode
                    }
                }
            }
            let applied = jids.count - failed.count
            if applied > 0 { store.decrement(chatJID: chatJID, by: applied) }
            error = failed.isEmpty
                ? nil
                : "Couldn't apply \(failed.count) of \(jids.count)"
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }
}
