import Foundation
import SwiftData

// The app's SwiftData schema, versioned. Until now the store was opened over a
// bare `[JesseThread.self, Turn.self, …]` model list with no `VersionedSchema`
// and no `SchemaMigrationPlan`, so there was no structural home for migrations
// and — the real gap — no way to *test* opening a populated on-disk store across
// a schema change. This file is that home.
//
// ── Migration lineage (all lightweight so far) ─────────────────────────────
// The schema has grown only by **additive, defaulted** changes, each of which
// SwiftData lightweight-migrates with zero migration code:
//
//   • `JesseThread.isFavorite` (Bool = false), `favoritedAt` (Date?)
//   • `JesseThread.lastDeliveredJobId` (String?)
//   • `JesseThread.aiTitle` (String?), `titleSourceKey` (String?)
//   • `JesseThread.origin` (String = "phone")
//   • `Turn.provenanceJSON` (String?)
//   • `Turn.attachments` → `TurnAttachment` (to-many, cascade, empty default)
//   • the `WrittenMeal` entity, then its `contentHash` / `tombstoned` fields
//
// Every one of those is a new property with a default or a new optional/relationship,
// so no column is renamed, retyped, or dropped: a store written before any of them
// opens under the current schema with all prior rows intact and the new fields
// reading their defaults. That is exactly a **lightweight** migration.
//
// Because the whole lineage collapses to a single lightweight-compatible shape,
// there is only ONE version so far (`JesseSchemaV1`) and the plan has NO explicit
// stages — SwiftData performs the lightweight open automatically. This is a
// deliberate single-version scaffold, not missing work: the value it buys is the
// populated-store migration test (`AppModelContainerMigrationTests`) and the place
// to add a `MigrationStage` the day an additive-only change is no longer possible
// (a rename, a retype, a required de-defaulted field). When that day comes: add
// `JesseSchemaV2`, append it to `schemas`, and add a `.lightweight`/`.custom`
// stage from V1 to V2 — the test harness already opens a V1-populated store, so
// the new stage gets coverage the moment it exists.

/// The current (and, so far, only) version of the app's persistent schema.
enum JesseSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self]
    }
}

/// The app's live schema, derived from the current `VersionedSchema`. The container
/// and every migration-test open the store through THIS value so they can never
/// drift from the versioned model list.
var jesseCurrentSchema: Schema { Schema(versionedSchema: JesseSchemaV1.self) }

/// The migration plan the container opens the store with. Single-version today (see
/// the lineage note above): one schema, no explicit stages, so SwiftData does the
/// lightweight open. Future schema versions append here.
enum JesseMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [JesseSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
