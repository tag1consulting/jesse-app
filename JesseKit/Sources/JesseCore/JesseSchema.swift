import Foundation
import SwiftData

// The app's SwiftData schema and its migration strategy.
//
// ── Migration strategy: AUTOMATIC lightweight, NOT a staged plan ─────────────
// The store is opened with SwiftData's automatic lightweight migration (see
// `AppModelContainer.load`, i.e. `ModelContainer(for:configurations:)` with NO
// `migrationPlan:`). Do NOT reintroduce a `SchemaMigrationPlan` for an additive
// change. Here is the hard-won reason, learned from a shipped break:
//
// A staged `SchemaMigrationPlan` keys each migration on a version's exact model
// CHECKSUM and can only migrate a store whose recorded checksum matches a version
// listed in the plan. But every `VersionedSchema` in this app references the SAME
// live `@Model` classes, so adding a property to an existing entity changes that
// version's checksum IN PLACE. A store already stamped with the old checksum then
// becomes an "unknown model version" and the open THROWS ("Cannot use staged
// migration with an unknown model version"), leaving the user stranded behind the
// store-error banner with an app that can't read its own history. That is a break on
// the FIRST additive property after a plan ships, and it did ship and break once.
//
// (The sibling failure mode, had we instead tried to give the property change its own
// `VersionedSchema`: because both versions reference the same live class they compute
// the SAME checksum, and SwiftData rejects the plan at open with "Duplicate version
// checksums detected." So neither staged option can even express a property-only
// change in this shared-`@Model` design.)
//
// Automatic migration sidesteps both: it infers a lightweight mapping by comparing the
// store's entity hashes to the current schema, with no version-checksum pinning. Every
// change the schema has ever taken is lightweight-compatible, so this Just Works:
//
//   • `JesseThread.isFavorite` (Bool = false), `favoritedAt` (Date?)
//   • `JesseThread.lastDeliveredJobId` (String?)
//   • `JesseThread.aiTitle` (String?), `titleSourceKey` (String?)
//   • `JesseThread.origin` (String = "phone")
//   • `JesseThread.isArchived` (Bool = false), `archivedAt` (Date?)  ← the archive fields
//   • `JesseThread.favoriteUpdatedMs` (Int = 0), `archivedUpdatedMs` (Int = 0)  ← the
//     never-cleared last-writer-wins clocks for cross-device favorite/archive sync
//   • `Turn.provenanceJSON` (String?)
//   • `Turn.attachments` → `TurnAttachment` (to-many, cascade, empty default)
//   • the `WrittenMeal` entity, then its `contentHash` / `tombstoned` fields
//   • the `OutboxItem` / `OutboxAttachment` entities (the send outbox)
//
// Each is a new property with a default, a new optional/relationship, or a new entity:
// nothing renamed, retyped, or dropped. A store written before any of them opens under
// the current schema with all prior rows intact and the new fields reading their
// defaults / new entities empty. `AppModelContainerMigrationTests` proves this by
// opening a populated on-disk store written the OLD way and asserting every field
// (including the archive fields defaulting correctly) survives.
//
// The ONLY change that needs a real migration is a NON-lightweight one: renaming or
// retyping a column, splitting/merging an entity, backfilling a derived value. THEN,
// and only then, reintroduce a `SchemaMigrationPlan` with a custom stage keyed to the
// model shape AT THAT POINT (which likely means freezing a copy of the old model
// types), never a lightweight stage for an additive change.
//
// The `VersionedSchema` enums below remain purely as the canonical, single-source
// model list (and as lineage documentation); they are not wired into a staged plan.
//
// Note: favorite and archive state are local-first (the store is the render source)
// and reconciled across devices through the bridge flags, last-writer-wins on the
// `favoriteUpdatedMs` / `archivedUpdatedMs` clocks (bridge 0.25.0; see `FlagReconciler`).

/// The original entity set (through the whole additive property lineage above, all
/// lightweight-compatible). Kept for lineage documentation.
public enum JesseSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self]
    }
}

/// The current entity set, adding the send outbox (`OutboxItem` + `OutboxAttachment`)
/// to V1. `jesseCurrentSchema` is derived from this so the container and the migration
/// test can never drift from the model list. Additive property changes (favorites,
/// origin, the archive fields, and the favorite/archive LWW-sync clocks) live on these
/// same entities and migrate automatically; they do not get their own version (see the
/// header note).
public enum JesseSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self,
         OutboxItem.self, OutboxAttachment.self]
    }
}

/// The app's live schema, derived from the current `VersionedSchema`. The container
/// and every migration-test open the store through THIS value so they can never drift
/// from the model list. Opened with automatic lightweight migration (no staged plan);
/// see the header note and `AppModelContainer.load`.
public var jesseCurrentSchema: Schema { Schema(versionedSchema: JesseSchemaV2.self) }
