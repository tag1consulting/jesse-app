import Foundation
import SwiftData
import JesseCore
import JesseDietDisplay

// How a Health-tab "Ask about this" becomes a conversation ON iOS.
//
// The split is the same one `TodayThreadOpener` draws, and for the same reason: WHAT the
// turn says is a fact about the screen and lives in the shared package
// (`HealthAskContext.promptText`, built from the frozen `HealthAskPrompt`); HOW it reaches
// a conversation touches this app's coordinator and store, so it stays here.
//
// An ask STAGES, it never fires. There is nothing for the agent to do until the user has
// said what they want to know — firing on the long-press would make them wait out a full
// turn before they could type a word, and would burn a turn on every idle poke at a card.
// The snapshot waits as attached context and rides their first message.
@MainActor
enum HealthAskOpener {

    /// Open a conversation for `context` — resuming today's conversation about the very
    /// same reading if there is one, else staging a fresh thread.
    ///
    /// RESUME is keyed on `HealthAskContext.scopeKey`, which is (area, scope, time range,
    /// subject) with the range's own anchor date inside it. So a second press on the same
    /// meal an hour later continues the conversation, and the same press tomorrow starts a
    /// new one — because tomorrow it is a different reading.
    ///
    /// A resumed conversation is re-attached with a FRESH snapshot. The numbers may have
    /// moved since the morning (a meal logged, a workout added), and the coordinator
    /// composes an attachment ahead of every send it is present for — so the next message
    /// carries the current screen rather than leaving the agent arguing from a stale one.
    ///
    /// Only conversations that were actually HAD can be resumed: a staged thread is not
    /// inserted into the store until its first send (see `stage` below), so an ask that
    /// was opened and abandoned leaves nothing to come back to. That is the intent.
    @discardableResult
    static func open(_ context: HealthAskContext, coordinator: RunCoordinator,
                     modelContext: ModelContext, now: Date = Date()) -> JesseThread {
        if let existing = resumable(context, modelContext: modelContext, now: now) {
            coordinator.attach(context.attachment, to: existing.id)
            return existing
        }
        return stage(context, coordinator: coordinator)
    }

    /// Today's conversation about this exact reading, if one was started and sent.
    ///
    /// "Today" is the DEVICE's calendar day, not the dashboard's — this is about what the
    /// user did earlier today, so it follows their clock. The most recently updated match
    /// wins; archived conversations are excluded, because archiving one is how the user
    /// says they are done with it.
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
    /// Deliberately NOT inserted into the store, exactly as a Today discussion is not: a
    /// staged thread has no turns, so inserting it would leave a stray empty conversation
    /// the moment the user changes their mind — and the Chats list's `pruneEmpty` reaps
    /// turn-less threads on appear, which could delete this one out from under the open
    /// sheet. `RunCoordinator.send` inserts on the first send.
    ///
    /// The TITLE is set here rather than derived on send. Every other conversation is
    /// named after its first message, which for an ask would be a page of serialized
    /// numbers; naming it after the scope means the header says what "this" refers to the
    /// moment it opens, and the Chats list later reads "Lunch · Aug 22" instead of a wall
    /// of macros.
    @discardableResult
    static func stage(_ context: HealthAskContext, coordinator: RunCoordinator) -> JesseThread {
        // ASK, not Tell: the turn's purpose is a conversation about a reading, and Ask
        // carries the floor that forbids task-work nobody requested — which is exactly the
        // protection wanted around a screen whose numbers a Tell might decide to "fix".
        let thread = JesseThread(mode: .ask)
        thread.title = context.title
        thread.askScopeKey = context.scopeKey
        thread.askScopeTitle = context.title
        coordinator.attach(context.attachment, to: thread.id)
        return thread
    }
}
