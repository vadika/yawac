import Foundation
import Observation

/// Drives the "new group" sheet: name field with a 25-character cap (the
/// server-side WhatsApp limit), a chip list of selected contacts, and an
/// async `create()` that returns the new group's JID via `createdJID`.
@MainActor
@Observable
final class NewGroupSheetModel {

    /// Bridge call signature: synchronous, throwing, returns the new
    /// group's JID. `WAClient.createGroup` (`nonisolated`) wires through
    /// in production; tests pass an inline closure that records the
    /// `(name, jids)` pair.
    typealias CreateGroup = @Sendable (String, [String]) throws -> String

    /// Group name. Self-trimming to 25 chars via `didSet` so the bound
    /// `TextField` cannot drift past the cap even if the user pastes.
    var name: String = "" {
        didSet {
            if name.count > 25 { name = String(name.prefix(25)) }
        }
    }

    /// Currently-selected participants surfaced as chips above the picker.
    var chips: [BridgeContact] = []

    /// Search query for the participant picker.
    var query: String = ""

    /// Set while `create()` is in flight so the sheet can disable the
    /// confirm button and show a spinner.
    var inFlight: Bool = false

    /// Localized error string from the last `create()` attempt, or `nil`.
    var error: String?

    /// JID returned by the bridge on a successful create. The presenter
    /// observes this to dismiss and navigate to the new chat.
    private(set) var createdJID: String?

    private let createGroup: CreateGroup

    init(createGroup: @escaping CreateGroup) {
        self.createGroup = createGroup
    }

    /// True iff a trimmed name is present and no create is in flight.
    /// WhatsApp permits creating a group with zero participants (you can
    /// add later), so the chip list is not part of the gate.
    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !inFlight
    }

    /// Dispatches the synchronous bridge call off the main actor, then
    /// surfaces the result via `createdJID` / `error`. Idempotent on the
    /// in-flight guard so a double-tap on confirm cannot double-create.
    func create() async {
        guard canCreate else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let jids = chips.map(\.jid)
        inFlight = true
        defer { inFlight = false }
        do {
            let call = self.createGroup
            let jid = try await Task.detached {
                try call(trimmed, jids)
            }.value
            createdJID = jid
            error = nil
        } catch let err {
            error = (err as NSError).localizedDescription
        }
    }
}
