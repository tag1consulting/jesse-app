import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking
import JesseTodayDisplay

/// The Mac's Today tab: what its actions actually send, and on which thread.
///
/// The document, the optimistic overlay, the view sort and the wire mapping are the
/// package's tests (`JesseTodayDisplayTests`, `JesseNetworkingTests`) and are not
/// re-tested here — the whole point of the shared library is that they are asserted
/// once. What is only true on the Mac is what this file pins: that the shell hosts a
/// third tab at all, that Discuss OPENS without firing while Propagate and the batch
/// fire on the click, and that the frozen prompts reach `MacCoordinator` unaltered,
/// composed by the SHARED composition rule rather than a Mac spelling of it.
@MainActor
final class MacTodayTests: XCTestCase {

    // MARK: - Action routing

    /// Every action's prompt and mode come from the shared `TodayTurn`, which is the
    /// same mapping the iPhone routes through. These four assertions are what would
    /// break if the Mac ever grew a private copy of "what Discuss sends".
    func testDiscussIsTheFrozenAskPrompt() {
        let turn = TodayTurn.discuss(item: Self.openItem)
        XCTAssertEqual(turn.mode, .ask)
        XCTAssertEqual(turn.text, TodayDiscuss.prompt(item: Self.openItem.text))
        XCTAssertTrue(turn.text.contains(Self.openItem.text), "the raw markdown, not the lead")
    }

    func testPropagateIsTheFrozenTellPromptWithItsEvidence() {
        let turn = TodayTurn.propagate(item: Self.doneItem, evidence: "shipped it")
        XCTAssertEqual(turn.mode, .tell)
        XCTAssertEqual(turn.text,
                       TodayPropagate.prompt(item: Self.doneItem.text, evidence: "shipped it"))
    }

    /// A `[[wiki]]` chip has no in-app viewer, so it opens a discussion seeded with the
    /// row that owns the link. A web link is not a conversation at all.
    func testLinkChipsRouteTheSameWayTheyDoOnThePhone() {
        let wiki = TodayLinkOrigin(link: TodayLink(target: "Projects/Kiln", kind: "wiki"),
                                   sourceText: Self.openItem.text)
        XCTAssertEqual(TodayTurn.openLink(wiki)?.mode, .ask)
        XCTAssertEqual(TodayTurn.openLink(wiki)?.text,
                       TodayDiscuss.prompt(item: Self.openItem.text))

        let web = TodayLinkOrigin(link: TodayLink(target: "https://example.com/x", kind: "url"),
                                  sourceText: Self.openItem.text)
        XCTAssertNil(TodayTurn.openLink(web))
    }

    // MARK: - Discuss opens; it does not fire

    /// Discuss OPENS a conversation and runs NOTHING: the item rides along as attached
    /// context on an empty thread, and no turn exists until Jeremy sends one. An
    /// abandoned discussion also leaves no empty row behind in the sidebar — which is
    /// load-bearing on the Mac, where `pruneEmptyThreads` would otherwise be free to
    /// delete a staged thread out from under its open sheet.
    func testDiscussOpensAThreadAndFiresNoTurn() async throws {
        let (coordinator, fake, context) = try Self.harness()
        let before = try context.fetch(FetchDescriptor<JesseThread>()).count

        let thread = MacTodayThreadOpener.stage(.discuss(item: Self.openItem),
                                                coordinator: coordinator)

        XCTAssertEqual(thread.mode, JesseMode.ask.rawValue)
        XCTAssertTrue(thread.turns.isEmpty, "an empty composer, not a sent prompt")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertEqual(coordinator.attachedContext(for: thread.id),
                       TodayDiscuss.prompt(item: Self.openItem.text),
                       "the item, its links and the frozen framing wait for the first send")
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, before,
                       "a staged thread is not in the store until it is sent to")
        await Self.settle()
        XCTAssertTrue(fake.sentTexts.isEmpty, "nothing reached the bridge")
    }

    /// The first send carries the attached context AHEAD of what was typed, composed by
    /// the shared `TodayThreadContext` — the same bytes the phone would send, because a
    /// Mac spelling of the composition would be a second definition of what an item
    /// discussion is scoped to.
    func testTheFirstSendCarriesTheItemContextAndTheFrozenFraming() async throws {
        let (coordinator, fake, context) = try Self.harness()
        let thread = MacTodayThreadOpener.stage(.discuss(item: Self.openItem),
                                                coordinator: coordinator)

        await coordinator.send(text: "Why has this been stuck for a week?", mode: .ask,
                               thread: thread, context: context)

        XCTAssertEqual(fake.sentTexts.count, 1)
        XCTAssertEqual(fake.sentTexts.first,
                       TodayThreadContext.firstMessage(
                           context: TodayDiscuss.prompt(item: Self.openItem.text),
                           typed: "Why has this been stuck for a week?"))
        XCTAssertEqual(fake.sentModes.first, .ask)
        XCTAssertEqual(fake.sentSessionIds.first, String?.none, "a fresh thread resumes nothing")
        XCTAssertNil(coordinator.attachedContext(for: thread.id), "consumed by the first send")
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1,
                       "the first send is what persists a staged discussion")
    }

    /// An EXPLICIT empty send is "just look at it": the attached context goes out alone,
    /// byte for byte, never a dangling label with nothing under it.
    func testAnEmptySendIsTheExplicitJustLookAtIt() async throws {
        let (coordinator, fake, context) = try Self.harness()
        let thread = MacTodayThreadOpener.stage(.discuss(item: Self.openItem),
                                                coordinator: coordinator)

        await coordinator.send(text: "", mode: .ask, thread: thread, context: context)

        XCTAssertEqual(fake.sentTexts.first, TodayDiscuss.prompt(item: Self.openItem.text))
        XCTAssertEqual(fake.sentModes.first, .ask)
    }

    /// An empty send on a thread with NO attached context is still nothing. The
    /// composer's own guard is not what makes this safe, so the coordinator holds it.
    func testAnEmptySendWithoutAttachedContextSendsNothing() async throws {
        let (coordinator, fake, context) = try Self.harness()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        await coordinator.send(text: "   ", mode: .ask, thread: thread, context: context)

        XCTAssertTrue(fake.sentTexts.isEmpty)
    }

    /// The context rides the FIRST message only. The thread resumes its session from
    /// there, so re-sending the item on every follow-up would re-paste what the agent
    /// already has.
    func testTheSecondMessageDoesNotRepeatTheContext() async throws {
        let (coordinator, fake, context) = try Self.harness()
        let thread = MacTodayThreadOpener.stage(.discuss(item: Self.openItem),
                                                coordinator: coordinator)

        await coordinator.send(text: "First", mode: .ask, thread: thread, context: context)
        await coordinator.send(text: "Second", mode: .ask, thread: thread, context: context)

        XCTAssertEqual(fake.sentTexts.count, 2)
        XCTAssertEqual(fake.sentTexts.last, "Second")
    }

    /// Closing the sheet without sending drops the attachment, so the next thing typed
    /// into that thread is not silently prefixed with an item nobody is discussing.
    func testDismissingAStagedDiscussionDropsItsContext() throws {
        let (coordinator, _, _) = try Self.harness()
        let thread = MacTodayThreadOpener.stage(.discuss(item: Self.openItem),
                                                coordinator: coordinator)

        coordinator.clearAttachedContext(for: thread.id)

        XCTAssertNil(coordinator.attachedContext(for: thread.id))
    }

    // MARK: - Propagate fires on the click

    /// Propagate is an EXECUTE action — the work is already done and Jeremy is asking
    /// for it to be closed at source — so the turn is on the transcript the instant the
    /// button is clicked, on a NEW thread rather than whatever was last open.
    func testPropagateSendsTheTellPromptOnItsOwnThreadImmediately() async throws {
        let (coordinator, fake, context) = try Self.harness()
        let before = try context.fetch(FetchDescriptor<JesseThread>()).count

        let thread = MacTodayThreadOpener.run(
            .propagate(item: Self.doneItem, evidence: "shipped it"),
            coordinator: coordinator, context: context)
        await Self.settle()

        XCTAssertEqual(thread.mode, JesseMode.tell.rawValue)
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, before + 1)
        XCTAssertNil(coordinator.attachedContext(for: thread.id),
                     "an execute action attaches nothing")
        XCTAssertEqual(fake.sentTexts.first,
                       TodayPropagate.prompt(item: Self.doneItem.text, evidence: "shipped it"))
        XCTAssertEqual(fake.sentModes.first, .tell)
        XCTAssertEqual(fake.sentSessionIds.first, String?.none, "a fresh thread resumes nothing")
    }

    // MARK: - Process updates

    /// **The whole batch, end to end.** Confirming fires EXACTLY ONE turn carrying the
    /// frozen prompt over exactly the checked items, and when that turn returns the day
    /// is re-read unconditionally — the batch removed those rows from `Today.md` and may
    /// have added others, so the screen is stale until it is.
    ///
    /// One turn is the load-bearing half: n propagations would be n turns racing to
    /// rewrite one file, each with a stale idea of what the others removed.
    func testProcessUpdatesFiresOneTurnAndRefetchesTheDayWhenItLands() async throws {
        let (coordinator, fake, context) = try Self.harness()
        let stub = StubTodayClient(day: Self.day())
        let day = TodayDashboardModel(makeClient: { stub })
        await day.load()

        let items = day.itemsToProcess
        XCTAssertEqual(items.map(\.id), ["item-done"], "only what is actually ticked")

        let run = MacTodayProcessRun()
        let fetchesBefore = stub.fetchCount
        let thread = run.start(items: items, coordinator: coordinator, context: context, day: day)

        XCTAssertEqual(thread?.mode, JesseMode.tell.rawValue)
        XCTAssertTrue(run.isRunning, "the toolbar shows a batch is out")
        await Self.settle()

        XCTAssertEqual(fake.sentTexts.count, 1, "one turn, not one per item")
        XCTAssertEqual(fake.sentTexts.first,
                       TodayProcessUpdates.prompt(items: items.map(\.text)))
        XCTAssertEqual(fake.sentModes.first, .tell)
        XCTAssertEqual(stub.fetchCount, fetchesBefore + 1, "the day is re-read after the batch")
        XCTAssertNil(run.threadID, "and the run is finished, so the next one can start")
    }

    /// One batch at a time. Two concurrent ones would be two turns rewriting one file,
    /// each with a stale idea of what the other removed.
    func testASecondBatchIsRefusedWhileOneIsOutstanding() async throws {
        let (coordinator, _, context) = try Self.harness()
        let day = TodayDashboardModel(makeClient: { StubTodayClient(day: Self.day()) })
        let run = MacTodayProcessRun()

        XCTAssertNotNil(run.start(items: [Self.doneItem], coordinator: coordinator,
                                  context: context, day: day))
        XCTAssertNil(run.start(items: [Self.doneItem], coordinator: coordinator,
                               context: context, day: day))
        await Self.settle()
    }

    /// Nothing ticked is nothing to do — never an empty turn asking the agent to process
    /// a list with no items in it.
    func testAnEmptyBatchFiresNothing() throws {
        let (coordinator, _, context) = try Self.harness()
        let day = TodayDashboardModel(makeClient: { StubTodayClient(day: Self.day()) })
        let run = MacTodayProcessRun()

        XCTAssertNil(run.start(items: [], coordinator: coordinator, context: context, day: day))
        XCTAssertNil(run.threadID)
        XCTAssertFalse(run.isRunning)
    }

    // MARK: - Per-device view state

    /// **The badge filter is remembered on this Mac**, which is the whole of what the tab
    /// does with it: read the preference on appear, hand it to the model, write it back
    /// on every change. A fresh store over the same defaults domain is what the next
    /// launch reads.
    ///
    /// Per DEVICE, deliberately. The phone keeps its own answer in its own defaults, and
    /// neither goes near the bridge: which view of the day a window is showing is a fact
    /// about the window, not about the day.
    func testTheBadgeFilterSurvivesARelaunchOnThisMac() async throws {
        let name = "jesse-mac-today-view-state-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        let stub = StubTodayClient(day: Self.day())
        let model = TodayDashboardModel(makeClient: { stub })
        await model.load()

        model.isBadgeFilterOn = TodayViewPreferences(defaults: defaults).isBadgeFilterOn
        XCTAssertFalse(model.isBadgeFilterOn, "the day opens whole")

        model.isBadgeFilterOn = true
        TodayViewPreferences(defaults: defaults).isBadgeFilterOn = model.isBadgeFilterOn

        let relaunched = TodayDashboardModel(makeClient: { stub })
        relaunched.isBadgeFilterOn = TodayViewPreferences(defaults: defaults).isBadgeFilterOn
        XCTAssertTrue(relaunched.isBadgeFilterOn)
        XCTAssertEqual(stub.checkCount, 0, "and none of this touched the day")
    }

    // MARK: - Read-only

    /// A click made while the day is read-only is REFUSED, not queued: nothing reaches
    /// the client and nothing is held to send later. The tab asks the shared model the
    /// same question before opening the Process sheet's turn.
    func testAClickWhileOfflineIsRefusedAndNotQueued() async {
        let stub = StubTodayClient(day: Self.day())
        let model = TodayDashboardModel(makeClient: { stub })
        await model.load()
        model.isNetworkUnreachable = true

        XCTAssertTrue(model.refuseInteractionIfReadOnly())
        await model.check(id: "item-open", checked: true, evidence: "done")

        XCTAssertEqual(stub.checkCount, 0)
        XCTAssertTrue(model.overlay.isEmpty)
        XCTAssertEqual(model.notice, TodayDashboardModel.readOnlyNotice)
    }

    // MARK: - Fixtures

    private static let openItem = TodayItem(
        id: "item-open", checked: false, lead: "Order the thermocouple",
        text: "* [ ] **Order the thermocouple** from the supplier [[Projects/Kiln]] (Added 2026-08-01)",
        links: [TodayLink(target: "Projects/Kiln", kind: "wiki")],
        addedDate: "2026-08-01", sectionName: "Do Now")

    private static let doneItem = TodayItem(
        id: "item-done", checked: true, lead: "Return the clamps",
        text: "* [x] **Return the clamps** (Added 2026-08-02)",
        addedDate: "2026-08-02", sectionName: "Do Now")

    private static func day() -> TodaySnapshot {
        TodaySnapshot(
            title: "Today: Monday, August 10, 2026",
            date: "2026-08-10",
            narrative: "A short day.",
            sections: [
                TodaySection(name: "Do Now", kind: "tasks", items: [openItem, doneItem]),
            ],
            counts: TodayCounts(open: 1, done: 1, reportsUnseen: 0),
            etag: "\"tag-1\"")
    }

    /// A configured coordinator over a recording fake, plus a fresh in-memory store.
    private static func harness() throws
        -> (MacCoordinator, MacFakeBridgeClient, ModelContext) {
        let fake = MacFakeBridgeClient()
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())
        return (coordinator, fake, try MacTestFixtures.context())
    }

    /// Let the openers' detached send tasks run. `run` and `start` return the thread
    /// synchronously and send from a task, so an assertion about what reached the client
    /// has to yield to it.
    private static func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A `TodayProviding` that serves one fixed day and counts what it was asked to
    /// change, so "nothing was sent" and "the day was re-read" are both assertable.
    private final class StubTodayClient: TodayProviding, @unchecked Sendable {
        let day: TodaySnapshot
        private(set) var fetchCount = 0
        private(set) var checkCount = 0
        private(set) var postponeCount = 0

        init(day: TodaySnapshot) { self.day = day }

        func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult {
            fetchCount += 1
            return .snapshot(day)
        }
        func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                       ifMatch: String) async throws -> TodayMutationResult {
            checkCount += 1
            return .snapshot(day)
        }
        func moveItem(id: String, op: TodayMoveOp, at: Date,
                      ifMatch: String) async throws -> TodayMutationResult {
            .snapshot(day)
        }
        func postpone(id: String, deferred: Bool, at: Date,
                      ifMatch: String) async throws -> TodayMutationResult {
            postponeCount += 1
            return .snapshot(day)
        }
        func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult {
            .snapshot(day)
        }
    }
}
