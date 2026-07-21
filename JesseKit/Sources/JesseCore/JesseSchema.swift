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
//
// ── Local archive state (additive properties, absorbed into V2) ─────────────
// `JesseThread` gains two properties, `isArchived` (Bool = false) and `archivedAt`
// (Date?), which back the per-device "hide this conversation from my list" feature
// (the Archived view). Like the V1-era additive properties above, these are ABSORBED
// into the current version (V2) rather than given their own VersionedSchema, and for
// a hard platform reason: a `VersionedSchema`'s checksum is computed from the live
// `@Model` types, and a new version whose model list differs from V2 ONLY by two
// added properties on the shared `JesseThread` class produces a checksum IDENTICAL to
// V2's (both reference the same live type), which SwiftData rejects at store-open
// with "Duplicate version checksums detected." A new VersionedSchema is therefore only
// viable when the ENTITY SET changes (as V2 did by adding the outbox entities), not
// for a property-only addition. So the archive fields ride in V2 exactly as
// `isFavorite`/`origin`/`aiTitle` rode in V1: a store written before they existed
// opens under the current schema with every prior row intact and `isArchived` reading
// its `false` default, a LIGHTWEIGHT migration with zero migration code, proven by
// the populated-store test. Archive state is deliberately NOT synced through the
// bridge (which syncs only sessions/transcripts/titles); it is local to each device,
// exactly like favorite state.

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

/// The app's live schema, derived from the current `VersionedSchema` (V2, which now
/// carries `JesseThread`'s archive fields as absorbed additive properties; see the
/// header note on why a property-only change does not get its own version). The
/// container and every migration-test open the store through THIS value so they can
/// never drift from the versioned model list.
public var jesseCurrentSchema: Schema { Schema(versionedSchema: JesseSchemaV2.self) }

/// The migration plan the container opens the store with: V1 → V2, a single
/// lightweight stage (the outbox entities are additive). Additive PROPERTY changes
/// (favorites, origin, and now the archive fields) ride within the current version
/// via SwiftData's implicit lightweight open and need no stage; the next change to
/// the ENTITY SET appends a new version and a new stage here.
public enum JesseMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [JesseSchemaV1.self, JesseSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: JesseSchemaV1.self, toVersion: JesseSchemaV2.self)]
    }
}
