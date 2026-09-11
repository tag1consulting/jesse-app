import Foundation
import SwiftData

// What is left of the draft's first shape: the SwiftData columns it used to live in, and
// the one-shot pass that moves anything still sitting in them into `ComposerDraftStore`.
//
// ── WHY THE COLUMNS ARE STILL DECLARED ───────────────────────────────────────────────
// They are dead weight and they stay. This store is opened with SwiftData's AUTOMATIC
// lightweight migration and NO staged plan, for the reasons `JesseSchema.swift` sets out
// at length: every `VersionedSchema` here references the same live `@Model` classes, so a
// staged plan cannot even express a property-only change, and reintroducing one has
// stranded users behind the store-error banner once already. Dropping an entity and four
// attributes is exactly the NON-lightweight change that would need such a plan.
//
// So V5 stays V5 on disk: `JesseThread.draftText`, `draftUpdatedAt`,
// `draftPendingRecording`, `draftContextLabel` and the `DraftAttachment` entity remain
// declared and are never written again. `ComposerDraftMigration` reads them once, hands
// what it finds to the file store, and clears them — after which they are nil forever and
// cost a few empty columns per row. That is the cheaper mistake.

/// Move any draft still held in the V5 SwiftData columns into `ComposerDraftStore`, once.
///
/// Runs at launch, before any composer can restore. Idempotent and guarded by a
/// `UserDefaults` flag, so the second launch does not even fetch.
@MainActor
public enum ComposerDraftMigration {

    public static let defaultsKey = "ComposerDraftMigratedToFileStore"

    /// - Returns: how many conversations were moved. Zero on every launch after the first.
    @discardableResult
    public static func runIfNeeded(context: ModelContext,
                                   store: ComposerDraftStore,
                                   defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: defaultsKey) else { return 0 }
        defer { defaults.set(true, forKey: defaultsKey) }
        guard let threads = try? context.fetch(FetchDescriptor<JesseThread>()) else { return 0 }
        var moved = 0
        for thread in threads {
            let text = thread.draftText
            let rows = thread.orderedDraftAttachments
            guard text != nil || !rows.isEmpty
                    || thread.draftPendingRecording != nil
                    || thread.draftContextLabel != nil else { continue }
            // A draft the file store already holds wins: it is the newer of the two by
            // construction (nothing writes the columns any more).
            if store.snapshot(for: thread.id).updatedAt == nil {
                store.write(text: text ?? "",
                            pendingRecording: thread.draftPendingRecording,
                            contextLabel: thread.draftContextLabel,
                            for: thread.id,
                            now: thread.draftUpdatedAt ?? Date())
                if !rows.isEmpty {
                    store.writeFiles(rows.map {
                        ComposerDraftFile(filename: $0.filename, mime: $0.mime, data: $0.data)
                    }, for: thread.id, now: thread.draftUpdatedAt ?? Date())
                }
                moved += 1
            }
            for row in rows { context.delete(row) }
            thread.draftAttachments = []
            thread.draftText = nil
            thread.draftUpdatedAt = nil
            thread.draftPendingRecording = nil
            thread.draftContextLabel = nil
        }
        store.flushAll()
        if moved > 0 || context.hasChanges { try? context.save() }
        return moved
    }
}

/// Put the conversation a draft belongs to ON DISK, once per composer.
///
/// A draft is keyed on `JesseThread.id` and stored outside the object graph, so a draft
/// whose conversation is not persisted is a file nothing can ever lead the user back to.
/// Two ways that happens, and this covers both:
///
///   * A STAGED conversation (a Health ask, a Today discussion) is deliberately not
///     inserted until its first send, so a bare `+`-then-back costs nothing. Typing into
///     one IS the intent a `+`-then-back was not, so the first character inserts it.
///   * A conversation the `+` button inserted but NOBODY SAVED. This is the one the first
///     cut of this change got wrong: the draft used to ride a debounced `context.save()`,
///     and that save was what quietly persisted the pending insert too. Removing it left a
///     brand-new conversation in memory only — so it vanished on relaunch, taking the
///     draft's way back with it, which `ComposerDraftUITests.testTheDraftSurvivesARelaunch`
///     caught.
///
/// Called ONCE per composer, on the first draft it records — never per keystroke. The
/// caller owns that guard (`didPersistThread` in both detail views), because only the view
/// knows when a composer began.
@MainActor
public enum ComposerDraftThreadInsertion {

    /// - Returns: whether anything was written.
    @discardableResult
    public static func persistIfNeeded(_ thread: JesseThread,
                                       in context: ModelContext,
                                       hasSomethingToKeep: Bool) -> Bool {
        guard hasSomethingToKeep else { return false }
        if thread.modelContext == nil { context.insert(thread) }
        // A pending insert is the whole point; a clean context is the common case and
        // costs nothing to skip.
        guard context.hasChanges else { return false }
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }
}
