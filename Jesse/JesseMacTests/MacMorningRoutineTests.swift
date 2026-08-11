import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

/// The Mac's "Good morning" sidebar button: what it sends, on what kind of thread, and
/// what its confirmation says.
///
/// The prompt's own wording is pinned once, in `JesseCoreTests/MorningRoutineTests`,
/// and is not re-asserted here — the point of putting it in the shared package is that
/// both platforms send the same bytes by construction. What is only true on the Mac is
/// what this file covers: that the button's action reaches `MacCoordinator.send` with
/// the shared prompt and a Tell mode, that it is gated on being paired, and that the
/// sidebar's pruner cannot take the thread it just opened.
///
/// The toolbar PLACEMENT is not covered here and cannot be: the Mac has no XCUITest
/// target. The iPhone's `ChatsToolbarUITests` covers the equivalent placement claim,
/// and the Mac's was verified by hand.
@MainActor
final class MacMorningRoutineTests: XCTestCase {

    /// Monday 2026-08-10, 06:30 UTC — the same fixed instant the package tests use.
    private let instant = Date(timeIntervalSince1970: 1_786_343_400)

    private func harness() throws -> (MacCoordinator, MacFakeBridgeClient, ModelContext) {
        let fake = MacFakeBridgeClient()
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())
        return (coordinator, fake, try MacTestFixtures.context())
    }

    /// `MacRootView.startMorningRoutine`, minus the `selection` assignment and the
    /// `@AppStorage` stamp (both are view state with no seam). Everything that leaves
    /// the app is here.
    @discardableResult
    private func fire(includeHealth: Bool,
                      _ coordinator: MacCoordinator,
                      _ context: ModelContext) async -> JesseThread {
        let thread = JesseThread(mode: .tell)
        context.insert(thread)
        try? context.save()
        let text = MorningRoutine.prompt(now: instant, includeHealthNewDay: includeHealth)
        await coordinator.send(text: text, mode: .tell, thread: thread, context: context)
        return thread
    }

    // MARK: - What goes out

    /// A plain confirm sends the DEFAULT body — the one that excludes the health and
    /// diet refresh — on a Tell thread. A Mac that grew its own copy of "what the
    /// morning button sends" is exactly what the shared constant exists to prevent, so
    /// the expectation is that constant rather than a literal.
    func testAPlainConfirmSendsTheDefaultBodyAsATellTurn() async throws {
        let (coordinator, fake, context) = try harness()

        let thread = await fire(includeHealth: false, coordinator, context)

        XCTAssertEqual(fake.sentTexts.count, 1)
        XCTAssertEqual(fake.sentTexts.first, MorningRoutine.prompt(now: instant))
        XCTAssertEqual(fake.sentModes.first, .tell,
                       "an instruction that does a large amount of work, not a question")
        XCTAssertEqual(thread.mode, JesseMode.tell.rawValue)
    }

    /// The opt-in confirm sends the OTHER body. Asserting equality against the shared
    /// builder is what makes a silent divergence — a Mac that always sent the default,
    /// say — a failure rather than a thing nobody notices until a morning goes wrong.
    func testTheOptInConfirmSendsTheBodyThatRunsHealthFirst() async throws {
        let (coordinator, fake, context) = try harness()

        await fire(includeHealth: true, coordinator, context)

        XCTAssertEqual(fake.sentTexts.first,
                       MorningRoutine.prompt(now: instant, includeHealthNewDay: true))
        XCTAssertNotEqual(fake.sentTexts.first, MorningRoutine.prompt(now: instant),
                          "the two actions must not send the same turn")
        XCTAssertEqual(fake.sentModes.first, .tell)
    }

    /// The button is `.disabled(!configStore.isConfigured)`, matching New Chat. This
    /// pins the coordinator half of that gate: an unpaired send is refused outright, so
    /// a confirmation that somehow got through would still not reach the bridge.
    func testAnUnpairedMacSendsNothing() async throws {
        let fake = MacFakeBridgeClient()
        let coordinator = MacCoordinator(configStore: MacTestFixtures.unconfigured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())
        let context = try MacTestFixtures.context()

        await fire(includeHealth: false, coordinator, context)

        XCTAssertTrue(fake.sentTexts.isEmpty)
        XCTAssertFalse(MacTestFixtures.unconfigured().isConfigured,
                       "and the toolbar button is disabled on the same condition")
    }

    // MARK: - The thread it opens

    /// `MacRootView.pruneEmptyThreads` deletes never-used empty threads, and the thread
    /// this button opens is empty for as long as the turn takes to produce one. It must
    /// be unreachable by that rule — deleting it would take away the conversation
    /// Jeremy is sitting there waiting to read.
    func testThePrunerCannotTakeTheThreadTheButtonJustOpened() async throws {
        let (coordinator, _, context) = try harness()
        let thread = await fire(includeHealth: false, coordinator, context)

        // The predicate from `MacRootView.pruneEmptyThreads`, mirrored as
        // `MacPruneEmptyTests` mirrors it (the prune lives in the view, which owns the
        // @Query and the selection).
        let prunable = thread.turns.isEmpty
            && (thread.sessionId ?? "").isEmpty
            && thread.registeredAt == nil
            && !(coordinator.isRunning && coordinator.activeThreadID == thread.id)
        XCTAssertFalse(prunable, "a thread that has been sent to is never abandoned")
    }

    // MARK: - The confirmation

    /// The Mac and the phone read the same `@AppStorage` key and resolve it through the
    /// same shared function, so "already ran today" means one thing across both. The
    /// note never becomes a lock: start of day may have run from the phone or from a
    /// scheduled task, neither of which this app can see.
    func testTheAlreadyFiredNoteIsAWordingChangeAndNothingElse() {
        XCTAssertEqual(MorningRoutine.lastFiredDayKey, "morningRoutineLastFiredDay")

        let today = MorningRoutine.dayStamp(instant)
        XCTAssertEqual(MorningRoutine.confirmationMessage(lastFiredDay: today, now: instant),
                       MorningRoutine.alreadyFiredMessage)
        XCTAssertEqual(MorningRoutine.confirmationMessage(lastFiredDay: nil, now: instant),
                       MorningRoutine.message)
        // Both actions are offered either way — the copy is all that moves.
        XCTAssertEqual(MorningRoutine.startAction, "Start the day")
        XCTAssertEqual(MorningRoutine.includeHealthAction, "Include health and diet first")
    }
}
