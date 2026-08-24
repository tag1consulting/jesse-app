import XCTest
import SwiftData
@testable import Jesse
import JesseCore
import JesseNetworking
import JesseTodayDisplay

/// The iOS Today tab: the tab itself, the number on it, what its two conversation
/// actions actually send, and what a tap does with no bridge in reach.
///
/// The document, the optimistic overlay and the wire mapping are the package's tests
/// (`JesseTodayDisplayTests`, `JesseNetworkingTests`) and are not re-tested here.
/// What is only true on iOS — that there IS a third tab, that its badge is the
/// semantics' number, and that Discuss/Propagate reach `RunCoordinator` carrying the
/// FROZEN prompt text — is what this file pins.
@MainActor
final class TodayTabTests: XCTestCase {

    // MARK: - The tab

    /// The root tab bar has three tabs, Chats FIRST and Today second. The tab set is
    /// a `CaseIterable` enum that `RootTabView` renders by iterating, so this is an
    /// assertion about what the shell actually builds rather than about a constant
    /// kept next to it — including the order, which is the enum's case order and
    /// nothing else. The Mac's `MacShellView` is a hand-written list that mirrors it.
    func testTheRootTabBarLeadsWithChatsAndPutsTodaySecond() {
        XCTAssertEqual(RootTabView.Tab.allCases, [.chats, .today, .health])
        XCTAssertEqual(RootTabView.Tab.today.title, "Today")
    }

    /// The Today tab is a SUNRISE, not the flat midday sun it used to be: the tab is
    /// where the day gets started, so the glyph should say so. It deliberately shares
    /// its meaning with the day screen's empty state and the Health tab's
    /// Start-new-day button — one glyph, one claim, three places.
    func testTheTodayTabIsASunrise() {
        XCTAssertEqual(RootTabView.Tab.today.systemImage, "sunrise")
    }

    /// The app OPENS on Chats: the conversation is what it is opened for most of the
    /// time, and the day is one tap away with a badge that says whether it wants
    /// attention. Asserted against the same single definition the shell selects with,
    /// and pinned to the first case so the bar's leading tab and the launch tab can't
    /// drift apart.
    func testTheAppOpensOnTheLeadingTab() {
        XCTAssertEqual(RootTabView.defaultTab, .chats)
        XCTAssertEqual(RootTabView.Tab.allCases.first, RootTabView.defaultTab)
    }

    /// Two tabs sharing a glyph is a UI bug that no other test would catch.
    func testEveryTabHasItsOwnTitleAndSymbol() {
        let titles = RootTabView.Tab.allCases.map(\.title)
        let symbols = RootTabView.Tab.allCases.map(\.systemImage)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(Set(symbols).count, symbols.count)
    }

    // MARK: - The badge

    /// The number on the tab is the semantics' `tabBadge` — open Do Now work plus
    /// unseen briefing rows — and never a sum the view does for itself.
    func testTheBadgeIsTheSemanticsNumber() async {
        let model = TodayDashboardModel(makeClient: { StubTodayClient(day: Self.day()) })
        await model.load()

        // Two open Do Now items + one open lead item + one unseen report.
        XCTAssertEqual(model.tabBadgeCount, 4)
        XCTAssertEqual(model.tabBadgeCount, TodaySemantics.tabBadge(Self.day()))
    }

    func testTheBadgeIsZeroBeforeTheFirstLoad() {
        let model = TodayDashboardModel(makeClient: { StubTodayClient(day: Self.day()) })
        XCTAssertEqual(model.tabBadgeCount, 0)
    }

    // MARK: - Action routing

    /// Discuss opens an ASK turn carrying `TodayDiscuss.prompt` over the item's RAW
    /// markdown. The prompt wording is load-bearing (it is what keeps a discussion
    /// from tripping the morning routine), so the tab must never assemble its own.
    func testDiscussIsTheFrozenAskPrompt() {
        let item = Self.openItem
        let turn = TodayTurn.discuss(item: item)

        XCTAssertEqual(turn.mode, .ask)
        XCTAssertEqual(turn.text, TodayDiscuss.prompt(item: item.text))
        XCTAssertTrue(turn.text.contains(item.text), "the raw markdown, not the display lead")
    }

    /// Propagate is a TELL — it writes to the project file and the Dashboard — and
    /// carries the evidence the completion recorded.
    func testPropagateIsTheFrozenTellPromptWithItsEvidence() {
        let item = Self.doneItem
        let turn = TodayTurn.propagate(item: item, evidence: "shipped it")

        XCTAssertEqual(turn.mode, .tell)
        XCTAssertEqual(turn.text, TodayPropagate.prompt(item: item.text, evidence: "shipped it"))
    }

    /// No evidence still produces the builder's own "none" sentence rather than an
    /// empty quotation the agent has to interpret.
    func testPropagateWithoutEvidenceUsesTheBuildersOwnWording() {
        let turn = TodayTurn.propagate(item: Self.doneItem, evidence: nil)
        XCTAssertEqual(turn.text, TodayPropagate.prompt(item: Self.doneItem.text, evidence: nil))
        XCTAssertTrue(turn.text.contains(TodayPropagate.noEvidence))
    }

    /// A `[[wiki]]` chip has no in-app viewer in v1, so it opens a discussion seeded
    /// with the row that owns the link — the same frozen prompt, not a new one.
    func testAWikiChipOpensADiscussionSeededWithItsRow() {
        let origin = TodayLinkOrigin(link: TodayLink(target: "Projects/Kiln", kind: "wiki"),
                                     sourceText: Self.openItem.text)
        let turn = TodayTurn.openLink(origin)

        XCTAssertEqual(turn?.mode, .ask)
        XCTAssertEqual(turn?.text, TodayDiscuss.prompt(item: Self.openItem.text))
    }

    /// An http link is not a conversation: it opens in the browser, so the router
    /// answers with no turn at all.
    func testAWebChipIsNotATurn() {
        let origin = TodayLinkOrigin(link: TodayLink(target: "https://example.com/x", kind: "url"),
                                     sourceText: Self.openItem.text)
        XCTAssertNil(TodayTurn.openLink(origin))
    }

    // MARK: - Discuss opens; it does not fire

    /// End to end through the real coordinator: Discuss OPENS a conversation and runs
    /// NOTHING. There is nothing for the agent to do until Jeremy has said what he
    /// wants, and firing on tap made him wait out a whole turn before he could type.
    /// So the item rides along as ATTACHED CONTEXT on an empty thread, and no turn
    /// exists until he sends one.
    func testDiscussOpensAThreadAndFiresNoTurn() async throws {
        let context = try Self.makeContext()
        let fake = CapturingClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })
        let existing = try context.fetch(FetchDescriptor<JesseThread>()).count

        let thread = TodayThreadOpener.stage(.discuss(item: Self.openItem), coordinator: coordinator)

        XCTAssertEqual(thread.mode, JesseMode.ask.rawValue)
        XCTAssertTrue(thread.turns.isEmpty, "an empty composer, not a sent prompt")
        XCTAssertFalse(coordinator.isRunning(thread.id), "no turn was started on open")
        XCTAssertEqual(coordinator.attachedContext(for: thread.id),
                       TodayDiscuss.prompt(item: Self.openItem.text),
                       "the item, its links and the frozen framing are held for the first send")
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, existing,
                       "an abandoned discussion leaves no empty thread behind")
        await Self.settle()
        XCTAssertTrue(fake.sent.isEmpty, "nothing reached the bridge")
    }

    /// The first turn is Jeremy's own send, and the attached context goes WITH it —
    /// the item markdown and the frozen anti-routing framing are still what scopes
    /// the turn, so a discussion still can't trip the morning routine.
    func testTheFirstSendCarriesTheItemContextAndTheFrozenFraming() async throws {
        let context = try Self.makeContext()
        let fake = CapturingClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })
        let thread = TodayThreadOpener.stage(.discuss(item: Self.openItem), coordinator: coordinator)

        coordinator.send(thread: thread, text: "Why has this been stuck for a week?",
                         voice: false, context: context)
        await Self.settle()

        XCTAssertEqual(fake.sent.count, 1)
        XCTAssertEqual(fake.sent.first?.text,
                       TodayThreadContext.firstMessage(
                           context: TodayDiscuss.prompt(item: Self.openItem.text),
                           typed: "Why has this been stuck for a week?"))
        XCTAssertEqual(fake.sent.first?.mode, .ask)
        XCTAssertNil(fake.sent.first?.sessionId, "a fresh thread resumes nothing")
        XCTAssertTrue(fake.sent.first?.text.contains(Self.openItem.text) ?? false)
        XCTAssertTrue(fake.sent.first?.text.contains("Why has this been stuck for a week?") ?? false)
        XCTAssertNil(coordinator.attachedContext(for: thread.id), "consumed by the first send")
    }

    /// The one path that runs a turn on no prose of Jeremy's: an EXPLICIT send with
    /// an empty composer, which means "just look at it". It sends the attached
    /// context alone — the same frozen prompt the old tap-to-fire behavior sent —
    /// and only ever on his send, never on open.
    func testAnEmptySendIsTheExplicitJustLookAtIt() async throws {
        let context = try Self.makeContext()
        let fake = CapturingClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })
        let thread = TodayThreadOpener.stage(.discuss(item: Self.openItem), coordinator: coordinator)

        coordinator.send(thread: thread, text: "", voice: false, context: context)
        await Self.settle()

        XCTAssertEqual(fake.sent.first?.text, TodayDiscuss.prompt(item: Self.openItem.text))
        XCTAssertEqual(fake.sent.first?.mode, .ask)
    }

    /// An empty send on a thread with NO attached context is still nothing: the
    /// composer's own guard is not what makes this safe, so the coordinator holds it.
    func testAnEmptySendWithoutAttachedContextSendsNothing() async throws {
        let context = try Self.makeContext()
        let fake = CapturingClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        coordinator.send(thread: thread, text: "   ", voice: false, context: context)
        await Self.settle()

        XCTAssertTrue(fake.sent.isEmpty)
    }

    /// The context rides the FIRST message only. The thread resumes its session from
    /// there, so re-sending the item on every follow-up would just re-paste what the
    /// agent already has.
    func testTheSecondMessageDoesNotRepeatTheContext() async throws {
        let context = try Self.makeContext()
        let fake = CapturingClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })
        let thread = TodayThreadOpener.stage(.discuss(item: Self.openItem), coordinator: coordinator)

        coordinator.send(thread: thread, text: "First", voice: false, context: context)
        await Self.settle()
        coordinator.send(thread: thread, text: "Second", voice: false, context: context)
        await Self.settle()

        XCTAssertEqual(fake.sent.count, 2)
        XCTAssertEqual(fake.sent.last?.text, "Second")
    }

    // MARK: - Propagate still fires on tap

    /// Propagate is an EXECUTE action — Jeremy has already done the thing and is
    /// asking for it to be closed at source — so it fires its Tell turn the moment
    /// it is tapped, exactly as before. Unchanged by the Discuss correction.
    func testPropagateSendsTheTellPromptOnItsOwnThreadImmediately() async throws {
        let context = try Self.makeContext()
        let fake = CapturingClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })
        let existing = try context.fetch(FetchDescriptor<JesseThread>()).count

        let thread = TodayThreadOpener.run(
            .propagate(item: Self.doneItem, evidence: "shipped it"),
            coordinator: coordinator, context: context)

        XCTAssertEqual(thread.mode, JesseMode.tell.rawValue)
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, existing + 1,
                       "a NEW thread, never an append to whatever was last open")
        let firstMessage = thread.turns.filter(\.isUser).sorted { $0.createdAt < $1.createdAt }.first
        XCTAssertEqual(firstMessage?.text,
                       TodayPropagate.prompt(item: Self.doneItem.text, evidence: "shipped it"),
                       "the turn is on the transcript the instant the button is tapped")
        XCTAssertNil(coordinator.attachedContext(for: thread.id), "an execute action attaches nothing")
        await Self.settle()
        XCTAssertEqual(fake.sent.first?.text,
                       TodayPropagate.prompt(item: Self.doneItem.text, evidence: "shipped it"))
        XCTAssertEqual(fake.sent.first?.mode, .tell)
    }

    // MARK: - Process updates

    /// The batch prompt is the frozen one, over the RAW markdown of every checked item,
    /// as a TELL — it writes to project files, the Dashboard and the day file.
    func testProcessUpdatesIsTheFrozenBatchTellPrompt() {
        let turn = TodayTurn.processUpdates(items: [Self.doneItem, Self.openItem])

        XCTAssertEqual(turn.mode, .tell)
        XCTAssertEqual(turn.text,
                       TodayProcessUpdates.prompt(items: [Self.doneItem.text, Self.openItem.text]))
        XCTAssertTrue(turn.text.contains(Self.doneItem.text), "raw markdown, not the display lead")
    }

    /// **The whole action, end to end.** Confirming fires EXACTLY ONE turn carrying the
    /// frozen prompt over exactly the checked items, and when that turn settles the day
    /// is re-read — because the batch removed those rows from `Today.md` and may have
    /// added others, so the screen (and the tab badge) is stale until it is.
    ///
    /// One turn is the load-bearing half. n propagations would be n turns racing to
    /// rewrite one file, each with a stale idea of what the others removed.
    func testProcessUpdatesFiresOneTurnWithTheFrozenPromptAndRefetchesWhenItSettles() async throws {
        let context = try Self.makeContext()
        let fake = CapturingClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })
        let stub = StubTodayClient(day: Self.day())
        let day = TodayDashboardModel(makeClient: { stub })
        await day.load()

        let items = day.itemsToProcess
        XCTAssertEqual(items.map(\.id), ["item-done"], "only what is actually ticked")

        let run = TodayProcessRun()
        let thread = run.start(items: items, coordinator: coordinator, context: context)

        XCTAssertEqual(thread?.mode, JesseMode.tell.rawValue)
        let userTurns = thread?.turns.filter(\.isUser) ?? []
        XCTAssertEqual(userTurns.count, 1, "one turn, not one per item")
        XCTAssertEqual(userTurns.first?.text,
                       TodayProcessUpdates.prompt(items: items.map(\.text)))
        await Self.settle()
        XCTAssertEqual(fake.sent.count, 1, "exactly one turn reached the bridge")
        XCTAssertEqual(fake.sent.first?.mode, .tell)
        XCTAssertNil(fake.sent.first?.sessionId, "a fresh thread resumes nothing")

        let before = stub.fetchCount
        let handled = await run.settled(coordinator: coordinator, day: day)

        XCTAssertTrue(handled, "the settled turn was ours")
        XCTAssertEqual(stub.fetchCount, before + 1, "the day is re-read after the batch")
        XCTAssertNil(run.threadID, "and the run is finished, so the next one can start")
    }

    /// One batch at a time. Two concurrent ones would be two turns rewriting one file,
    /// each with a stale idea of what the other removed.
    func testASecondBatchIsRefusedWhileOneIsOutstanding() async throws {
        let context = try Self.makeContext()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in CapturingClient() })
        let run = TodayProcessRun()

        XCTAssertNotNil(run.start(items: [Self.doneItem], coordinator: coordinator,
                                  context: context))
        XCTAssertNil(run.start(items: [Self.doneItem], coordinator: coordinator,
                               context: context))
        await Self.settle()
    }

    /// Nothing ticked is nothing to do — never an empty turn asking the agent to
    /// process a list with no items in it.
    func testAnEmptyBatchFiresNothing() throws {
        let context = try Self.makeContext()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in CapturingClient() })
        let run = TodayProcessRun()

        XCTAssertNil(run.start(items: [], coordinator: coordinator, context: context))
        XCTAssertNil(run.threadID)
    }

    // MARK: - Per-device view state

    /// **The badge filter is remembered on this phone**, which is the whole of what the
    /// tab does with it: read the preference on appear, hand it to the model, write it
    /// back on every change. A fresh store over the same defaults domain is exactly what
    /// the next launch reads.
    ///
    /// Nothing about it reaches the bridge. Which view of the day a device is showing is
    /// a fact about the device, and a filter that followed the user to the Mac would be
    /// a view choice made for them.
    func testTheBadgeFilterSurvivesARelaunchOnThisDevice() async throws {
        let name = "jesse-ios-today-view-state-tests"
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

    // MARK: - Offline

    /// The tab hands its own reachability probe to the model, so the day goes
    /// read-only before a tap rather than after one fails. The gate is the Chats
    /// list's own `shouldShowOfflineBanner` — one definition of "offline", not two.
    func testTheProbeMakesTheDayReadOnly() async {
        let model = TodayDashboardModel(makeClient: { StubTodayClient(day: Self.day()) })
        await model.load()

        model.isNetworkUnreachable = shouldShowOfflineBanner(isConfigured: true,
                                                            reachability: .unreachable)
        XCTAssertTrue(model.isReadOnly)

        model.isNetworkUnreachable = shouldShowOfflineBanner(isConfigured: true,
                                                            reachability: .reachable)
        XCTAssertFalse(model.isReadOnly)
    }

    /// An unconfigured app is not "offline" — it is unpaired, and the pairing CTA
    /// covers that. Same rule the Chats list's banner uses.
    func testAnUnpairedAppIsNotCalledOffline() {
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: false, reachability: .unknown))
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: true, reachability: .unknown))
    }

    /// A tap made while the probe says unreachable is refused, not queued: nothing
    /// reaches the client and nothing is held to send later.
    func testATapWhileOfflineIsRefusedAndNotQueued() async {
        let stub = StubTodayClient(day: Self.day())
        let model = TodayDashboardModel(makeClient: { stub })
        await model.load()
        model.isNetworkUnreachable = true

        await model.check(id: "item-open", checked: true, evidence: "done")

        XCTAssertEqual(stub.checkCount, 0)
        XCTAssertTrue(model.overlay.isEmpty)
        XCTAssertEqual(model.snapshot?.item(id: "item-open")?.checked, false)
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

    /// A day with two open Do Now items, one done, one open lead item, and one
    /// unseen report: badge = 2 + 1 + 1 = 4.
    private static func day() -> TodaySnapshot {
        TodaySnapshot(
            title: "Today: Monday, August 10, 2026",
            date: "2026-08-10",
            narrative: "A short day.",
            leadItems: [TodayItem(id: "lead", lead: "TOP PRIORITY: finish the rebuild",
                                  text: "* [ ] **TOP PRIORITY: finish the rebuild**")],
            sections: [
                TodaySection(name: "Do Now", kind: "tasks", items: [
                    openItem,
                    TodayItem(id: "item-two", lead: "Reply to Ada",
                              text: "* [ ] **Reply to Ada**", sectionName: "Do Now"),
                    doneItem,
                ]),
                TodaySection(name: "Health", kind: "briefing", reports: [
                    TodayReport(id: "report-run", title: "Monday is a run day.",
                                kind: "health", sectionName: "Health", seen: false),
                ]),
            ],
            counts: TodayCounts(open: 3, done: 1, reportsUnseen: 1),
            etag: "\"tag-1\"")
    }

    private static func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// Let the coordinator's detached send task run. `send` is fire-and-forget by
    /// design (the turn survives navigation), so the assertion about what reached
    /// the client has to yield to it.
    private static func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Doubles

    /// A `TodayProviding` that serves one fixed day and counts what it was asked to
    /// change, so "nothing was sent" is assertable.
    private final class StubTodayClient: TodayProviding, @unchecked Sendable {
        let day: TodaySnapshot
        private(set) var fetchCount = 0
        private(set) var checkCount = 0
        private(set) var moveCount = 0
        private(set) var postponeCount = 0
        private(set) var glanceCount = 0

        init(day: TodaySnapshot) { self.day = day }

        func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult {
            fetchCount += 1
            return .snapshot(day)
        }
        func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                       day: String?, ifMatch: String) async throws -> TodayMutationResult {
            checkCount += 1
            return .snapshot(self.day)
        }
        func moveItem(id: String, op: TodayMoveOp, at: Date,
                      day: String?, ifMatch: String) async throws -> TodayMutationResult {
            moveCount += 1
            return .snapshot(self.day)
        }
        func postpone(id: String, deferred: Bool, at: Date,
                      day: String?, ifMatch: String) async throws -> TodayMutationResult {
            postponeCount += 1
            return .snapshot(self.day)
        }
        func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult {
            glanceCount += 1
            return .snapshot(day)
        }
    }

    /// Records every turn the coordinator dispatches, and answers immediately so no
    /// test waits on a poll loop.
    @MainActor
    private final class CapturingClient: JesseClientProtocol {
        struct Sent {
            let mode: JesseMode
            let text: String
            let sessionId: String?
        }
        private(set) var sent: [Sent] = []

        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?) async throws -> JesseSendResult {
            sent.append(Sent(mode: mode, text: text, sessionId: sessionId))
            return .reply(JesseReply(text: "ok", sessionId: "s-1"),
                          jobId: nil, conversationId: nil)
        }

        func result(jobId: String) async throws -> JesseResultState { .running }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}
