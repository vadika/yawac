import Foundation
import SwiftData

/// V2 of the persisted-message schema — v0.9.61 onwards. Adds
/// compound / single-column `#Index<T>` declarations on the three
/// entities that previously took the full-table-scan hit
/// (PersistedMessage, PersistedReaction, PersistedPollVote).
///
/// Pair with `PersistedMessageMigrationPlan` so SwiftData runs the
/// V1 → V2 lightweight migration instead of treating the bumped
/// schema hash as "incompatible store" and (per v0.9.59) silently
/// dropping every indexed-entity row.
enum PersistedMessageSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [PersistedMessage.self, PersistedChat.self,
         PersistedReaction.self, PersistedPollVote.self]
    }
}
