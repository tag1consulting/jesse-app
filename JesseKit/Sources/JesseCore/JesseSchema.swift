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
// ── V2: the send outbox ────────────────────────────────────────────────────
// `JesseSchemaV2` adds two entities — `OutboxItem` and `OutboxAttachment` — so a
// message survives the pre-ACK window (a timeout / dead network / 429/5xx / a kill
// mid-POST) that used to lose it, along with its full-resolution attachment bytes.
// Both are new entities with fully-defaulted properties, so V1 → V2 is still a
// LIGHTWEIGHT migration (nothing renamed, retyped, or dropped): a V1-populated
// store opens under V2 with all prior rows intact and the two new (empty) entities
// added. We nonetheless make it an EXPLICIT version + stage rather than lean on the
// implicit lightweight open, per the migration-safety plan — so the populated-store
// migration test (`AppModelContainerMigrationTests`) exercises the V1 → V2 stage,
// and the next non-additive change has a stage to slot in beside this one.

/// The original version of the app's persistent schema (through the whole additive
/// lineage above — all lightweight-compatible).
public enum JesseSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self]
    }
}

/// V2 — adds the send outbox (`OutboxItem` + `OutboxAttachment`). Additive-only, so
/// V1 → V2 is a lightweight stage.
public enum JesseSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self,
         OutboxItem.self, OutboxAttachment.self]
    }
}

/// The app's live schema, derived from the current `VersionedSchema`. The container
/// and every migration-test open the store through THIS value so they can never
/// drift from the versioned model list.
public var jesseCurrentSchema: Schema { Schema(versionedSchema: JesseSchemaV2.self) }

/// The migration plan the container opens the store with: V1 → V2, a single
/// lightweight stage (the outbox entities are additive). Future schema versions
/// append a new version and a new stage here.
public enum JesseMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [JesseSchemaV1.self, JesseSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: JesseSchemaV1.self, toVersion: JesseSchemaV2.self)]
    }
}
