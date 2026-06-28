import Foundation
import Observation

/// Drives the "new sub-group in community" sheet: parent-scoped name
/// field with a 25-character cap (the server-side WhatsApp limit), a
/// chip list of selected contacts, and an async `create()` that
/// returns the new sub-group's JID via `createdJID`. Mirrors
/// `NewGroupSheetModel` but pins a `parentJID` for the bridge call.
@MainActor
@Observable
final class NewSubGroupSheetModel {

    /// Bridge call signature: synchronous, throwing, returns the new
    /// sub-group's JID. `WAClient.createSubGroup` (`nonisolated`) wires
    /// through in production; tests pass an inline closure that records
    /// `(parentJID, name, participantJIDs)`.
    typealias CreateSubGroup = @Sendable (String, String, [String]) throws -> String

    /// Sub-group name. Self-trimming to 25 chars via `didSet` so the
    /// bound `TextField` cannot drift past the cap even if the user
    /// pastes.
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
    /// observes this to dismiss and navigate to the new sub-group chat.
    private(set) var createdJID: String?

    /// JID of the community parent under which the new sub-group is
    /// created. Held on the model so the sheet's confirm action stays
    /// argument-free.
    let parentJID: String

    private let createSubGroup: CreateSubGroup

    init(parentJID: String, createSubGroup: @escaping CreateSubGroup) {
        self.parentJID = parentJID
        self.createSubGroup = createSubGroup
    }

    /// True iff a trimmed name is present and no create is in flight.
    /// Like plain groups, WhatsApp permits creating with zero
    /// participants, so the chip list is not part of the gate.
    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !inFlight
    }

    /// Dispatches the synchronous bridge call off the main actor, then
    /// surfaces the result via `createdJID` / `error`. Idempotent on
    /// the in-flight guard so a double-tap on confirm cannot
    /// double-create.
    func create() async {
        guard canCreate else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let jids = chips.map(\.jid)
        let parent = parentJID
        inFlight = true
        defer { inFlight = false }
        do {
            let call = self.createSubGroup
            let jid = try await Task.detached {
                try call(parent, trimmed, jids)
            }.value
            createdJID = jid
            error = nil
        } catch let err {
            error = (err as NSError).localizedDescription
        }
    }
}
