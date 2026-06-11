import Foundation
import SwiftData

/// V1 → V2 migration plan for the persisted-message store. V2's only
/// delta is `#Index<T>` declarations on PersistedMessage,
/// PersistedReaction, and PersistedPollVote — a lightweight stage
/// (index creation, no attribute renames / shape changes / type
/// coercions) is the documented Apple path for this kind of change.
///
/// If SwiftData ever refuses to lightweight-migrate this in the
/// field, fall back to `MigrationStage.custom(fromVersion:toVersion:
/// willMigrate:didMigrate:)` and use `willMigrate` to snapshot row
/// counts and `didMigrate` to assert post-migration parity. We
/// deliberately try lightweight first — simpler is safer than custom
/// migration code that has to handle 43k-row stores.
enum PersistedMessageMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PersistedMessageSchemaV1.self, PersistedMessageSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: PersistedMessageSchemaV1.self,
        toVersion: PersistedMessageSchemaV2.self)
}
