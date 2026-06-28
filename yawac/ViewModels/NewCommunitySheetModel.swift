import Foundation
import Observation

/// Drives the "new community" sheet: a single name field capped at the
/// server-side 25-character limit and an async `create()` that returns
/// the new community parent's JID via `createdJID`. Unlike groups, a
/// community parent has no initial participants — members are added by
/// linking or creating sub-groups inside it.
@MainActor
@Observable
final class NewCommunitySheetModel {

    /// Bridge call signature: synchronous, throwing, returns the new
    /// community parent's JID. `WAClient.createCommunity` (`nonisolated`)
    /// wires through in production; tests pass an inline closure that
    /// records the name.
    typealias CreateCommunity = @Sendable (String) throws -> String

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

    private let createCommunity: CreateCommunity

    init(createCommunity: @escaping CreateCommunity) {
        self.createCommunity = createCommunity
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
            let call = self.createCommunity
            let jid = try await Task.detached {
                try call(trimmed)
            }.value
            createdJID = jid
            error = nil
        } catch let err {
            error = (err as NSError).localizedDescription
        }
    }
}
