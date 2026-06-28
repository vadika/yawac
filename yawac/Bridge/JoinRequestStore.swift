import Foundation
import Observation

/// Observable pending-count cache per group JID. The store owns the
/// canonical count surfaced in the chat list badge and in the admin
/// panel header. Live `joinRequest`/`joinApprovalModeChanged` events
/// nudge it via `set`/`decrement`/`clear`; the admin panel and chat
/// list pull a fresh snapshot via `refresh` / `refreshAllAdmin`.
@MainActor
@Observable
final class JoinRequestStore {

    /// Bridge call signature: synchronous, throwing.
    /// `WAClient.getGroupJoinRequests` (`nonisolated`) wires through in
    /// production; tests pass an inline closure that returns canned
    /// rows and (optionally) records concurrency for the bounded
    /// fan-out assertion.
    typealias FetchJoinRequests = @Sendable (String) throws -> [BridgeJoinRequest]

    private(set) var counts: [String: Int] = [:]
    private let fetchJoinRequests: FetchJoinRequests?

    init(fetchJoinRequests: FetchJoinRequests? = nil) {
        self.fetchJoinRequests = fetchJoinRequests
    }

    /// Overwrites the pending count for `chatJID`. Clamped at zero so a
    /// stale negative delta from a malformed event cannot underflow.
    func set(chatJID: String, count: Int) {
        counts[chatJID] = max(0, count)
    }

    /// Decrements the pending count by `n`, clamped at zero. No-op if
    /// no entry exists for `chatJID` — callers should `set` first or
    /// `refresh` to seed the count.
    func decrement(chatJID: String, by n: Int) {
        guard let current = counts[chatJID] else { return }
        counts[chatJID] = max(0, current - n)
    }

    /// Drops the entry for `chatJID`. Used when approval-mode flips off
    /// or the user leaves the group — the badge should disappear, not
    /// stick at zero.
    func clear(chatJID: String) {
        counts.removeValue(forKey: chatJID)
    }

    /// Pulls the current queue for one group and updates `counts`.
    /// Silent on error: a transient bridge failure should not wipe a
    /// previously-known count from the UI.
    func refresh(chatJID: String) async {
        guard let fetchJoinRequests else { return }
        let count = await Self.fetchCount(fetch: fetchJoinRequests, chatJID: chatJID).1
        if let count { counts[chatJID] = count }
    }

    /// Refreshes a batch of admin groups with bounded concurrency so we
    /// don't fan out one detached task per group on login. Cap of 4
    /// keeps the bridge responsive when a user admins dozens of groups.
    func refreshAllAdmin(chatJIDs: [String]) async {
        guard let fetchJoinRequests, !chatJIDs.isEmpty else { return }
        let maxConcurrent = 4
        await withTaskGroup(of: (String, Int?).self) { group in
            var iterator = chatJIDs.makeIterator()
            var dispatched = 0
            while dispatched < maxConcurrent, let next = iterator.next() {
                dispatched += 1
                group.addTask {
                    await Self.fetchCount(fetch: fetchJoinRequests, chatJID: next)
                }
            }
            while let (jid, count) = await group.next() {
                if let count { self.counts[jid] = count }
                if let next = iterator.next() {
                    group.addTask {
                        await Self.fetchCount(fetch: fetchJoinRequests, chatJID: next)
                    }
                }
            }
        }
    }

    /// Runs the synchronous bridge call on a detached task so the main
    /// actor stays free. Failures collapse to `nil` so the caller can
    /// distinguish "no fresh data" from "queue is empty".
    private static func fetchCount(fetch: @escaping FetchJoinRequests,
                                   chatJID: String) async -> (String, Int?) {
        do {
            let rows = try await Task.detached {
                try fetch(chatJID)
            }.value
            return (chatJID, rows.count)
        } catch {
            return (chatJID, nil)
        }
    }
}
