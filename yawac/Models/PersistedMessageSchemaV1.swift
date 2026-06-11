import Foundation
import SwiftData

/// V1 of the persisted-message schema — the shape that shipped through
/// v0.9.60 (i.e. NO `#Index<T>` macros on PersistedMessage /
/// PersistedReaction / PersistedPollVote). Kept as the migration
/// source so v0.9.61 can lightweight-migrate an existing on-disk
/// store forward without losing rows.
///
/// SwiftData treats a VersionedSchema as a snapshot of the entity
/// graph: same model classes referenced from V1 and V2 are fine —
/// what changes is the `versionIdentifier` plus the index/attribute
/// metadata SwiftData reads off the type when building the schema.
/// Since the V1 build of these models had no `#Index` declarations
/// AND the v0.9.61 build does, the model graph SwiftData computes
/// when it sees `versionIdentifier == (1, 0, 0)` ends up index-free
/// — which matches the on-disk store every existing user has.
enum PersistedMessageSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [PersistedMessage.self, PersistedChat.self,
         PersistedReaction.self, PersistedPollVote.self]
    }
}
