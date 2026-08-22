import Foundation
import SwiftData
import JesseCore
import JesseDietDisplay

// How a Health-tab "Ask about this" becomes a conversation ON THE MAC — the peer of the
// phone's `HealthAskOpener`, and the same split it draws.
//
// WHAT the turn says is shared: `HealthAskContext.promptText`, built in JesseDietDisplay
// from the frozen `HealthAskPrompt`. WHAT COUNTS AS THE SAME READING is shared too:
// `scopeKey`. Only the dispatch — this platform's coordinator and store — lives here, so
// the two shells cannot grow two ideas of what an ask is scoped to or when it resumes.
@MainActor
enum MacHealthAskOpener {

    /// Open a conversation for `context`, resuming today's conversation about the very
    /// same reading if there is one.
    ///
    /// A resumed conversation is re-attached with a FRESH snapshot: the numbers may have
    /// moved since it was started, and the coordinator composes an attachment ahead of
    /// every send it is present for, so the next message carries the current screen.
    @discardableResult
    static func open(_ context: HealthAskContext, coordinator: MacCoordinator,
                     modelContext: ModelContext, now: Date = Date()) -> JesseThread {
        if let existing = resumable(context, modelContext: modelContext, now: now) {
            coordinator.attach(context.attachment, to: existing.id)
            return existing
        }
        return stage(context, coordinator: coordinator)
    }

    /// Today's conversation about this exact reading, if one was started and sent. Only
    /// sent conversations exist to be found — a staged thread is not in the store.
    static func resumable(_ context: HealthAskContext, modelContext: ModelContext,
                          now: Date = Date()) -> JesseThread? {
        let key = context.scopeKey
        let dayStart = Calendar.current.startOfDay(for: now)
        var descriptor = FetchDescriptor<JesseThread>(
            predicate: #Predicate { thread in
                thread.askScopeKey == key && thread.createdAt >= dayStart && !thread.isArchived
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// A brand-new conversation carrying the snapshot as attached context, an empty
    /// composer, and no turn at all.
    ///
    /// Deliberately NOT inserted into the store, for the reason `MacTodayThreadOpener`
    /// writes down: `MacRootView.pruneEmptyThreads` reaps turn-less threads on appear and
    /// could delete this one out from under the open sheet. `MacCoordinator.send` inserts
    /// on the first send.
    @discardableResult
    static func stage(_ context: HealthAskContext, coordinator: MacCoordinator) -> JesseThread {
        // ASK, not Tell: the turn's purpose is a conversation about a reading, and Ask
        // carries the floor that forbids task-work nobody requested.
        let thread = JesseThread(mode: .ask)
        // Named after the SCOPE rather than derived from the first message, which for an
        // ask would be a page of serialized numbers. The header then says what "this"
        // refers to the moment it opens, and the sidebar later reads "Lunch · Aug 22".
        thread.title = context.title
        thread.askScopeKey = context.scopeKey
        thread.askScopeTitle = context.title
        coordinator.attach(context.attachment, to: thread.id)
        return thread
    }
}
