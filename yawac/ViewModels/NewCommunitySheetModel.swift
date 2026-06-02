import Foundation
import Observation

/// Abstraction for the underlying community-create call. `WAClient`
/// conforms in production; tests inject a stub that records the name.
/// Method is synchronous and `nonisolated` on `WAClient` so the model
/// can dispatch it off the main actor.
protocol CommunityCreator: AnyObject {
    func createCommunity(name: String) throws -> String
}

extension WAClient: CommunityCreator {}

/// Drives the "new community" sheet: a single name field capped at the
/// server-side 25-character limit and an async `create()` that returns
/// the new community parent's JID via `createdJID`. Unlike groups, a
/// community parent has no initial participants — members are added by
/// linking or creating sub-groups inside it.
@MainActor
@Observable
final class NewCommunitySheetModel {

    /// Community name. Self-trimming to 25 chars via `didSet` so the
    /// bound `TextField` cannot drift past the cap even if the user
    /// pastes a longer string.
    var name: String = "" {
        didSet {
            if name.count > 25 { name = String(name.prefix(25)) }
        }
    }

    /// Set while `create()` is in flight so the sheet can disable the
    /// confirm button and show a spinner.
    var inFlight: Bool = false

    /// Localized error string from the last `create()` attempt, or `nil`.
    var error: String?

    /// JID returned by the bridge on a successful create. The presenter
    /// observes this to dismiss and navigate to the new community.
    private(set) var createdJID: String?

    private let creator: CommunityCreator

    init(creator: CommunityCreator) {
        self.creator = creator
    }

    /// True iff a trimmed name is present and no create is in flight.
    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !inFlight
    }

    /// Dispatches the synchronous bridge call off the main actor, then
    /// surfaces the result via `createdJID` / `error`. Idempotent on the
    /// in-flight guard so a double-tap on confirm cannot double-create.
    func create() async {
        guard canCreate else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        inFlight = true
        defer { inFlight = false }
        do {
            let creator = self.creator
            let jid = try await Task.detached {
                try creator.createCommunity(name: trimmed)
            }.value
            createdJID = jid
            error = nil
        } catch let err {
            error = (err as NSError).localizedDescription
        }
    }
}
