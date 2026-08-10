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

    /// The root tab bar has three tabs, and Today is one of them. The tab set is a
    /// `CaseIterable` enum that `RootTabView` renders by iterating, so this is an
    /// assertion about what the shell actually builds rather than about a constant
    /// kept next to it.
    func testTheRootTabBarHasAThirdTabForToday() {
        XCTAssertEqual(RootTabView.Tab.allCases, [.chats, .health, .today])
        XCTAssertEqual(RootTabView.Tab.today.title, "Today")
        XCTAssertEqual(RootTabView.Tab.today.systemImage, "sun.max")
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

    /// End to end through the real coordinator: a Discuss action creates a NEW
    /// thread whose first message IS the frozen builder output, and sends it.
    func testDiscussCreatesANewThreadWhoseFirstMessageIsTheFrozenPrompt() async throws {
        let context = try Self.makeContext()
        let fake = CapturingClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })
        let existing = try context.fetch(FetchDescriptor<JesseThread>()).count

        let thread = TodayThreadOpener.open(.discuss(item: Self.openItem),
                                            coordinator: coordinator, context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, existing + 1,
                       "a NEW thread, never an append to whatever was last open")
        XCTAssertEqual(thread.mode, JesseMode.ask.rawValue)
        let firstMessage = thread.turns.filter(\.isUser).sorted { $0.createdAt < $1.createdAt }.first
        XCTAssertEqual(firstMessage?.text, TodayDiscuss.prompt(item: Self.openItem.text))
        await Self.settle()
        XCTAssertEqual(fake.sent.first?.text, TodayDiscuss.prompt(item: Self.openItem.text))
        XCTAssertEqual(fake.sent.first?.mode, .ask)
        XCTAssertNil(fake.sent.first?.sessionId, "a fresh thread resumes nothing")
    }

    func testPropagateSendsTheTellPromptOnItsOwnThread() async throws {
        let context = try Self.makeContext()
        let fake = CapturingClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })

        let thread = TodayThreadOpener.open(
            .propagate(item: Self.doneItem, evidence: "shipped it"),
            coordinator: coordinator, context: context)

        XCTAssertEqual(thread.mode, JesseMode.tell.rawValue)
        await Self.settle()
        XCTAssertEqual(fake.sent.first?.text,
                       TodayPropagate.prompt(item: Self.doneItem.text, evidence: "shipped it"))
        XCTAssertEqual(fake.sent.first?.mode, .tell)
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
        private(set) var checkCount = 0
        private(set) var moveCount = 0
        private(set) var glanceCount = 0

        init(day: TodaySnapshot) { self.day = day }

        func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult { .snapshot(day) }
        func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                       ifMatch: String) async throws -> TodayMutationResult {
            checkCount += 1
            return .snapshot(day)
        }
        func moveItem(id: String, op: TodayMoveOp, at: Date,
                      ifMatch: String) async throws -> TodayMutationResult {
            moveCount += 1
            return .snapshot(day)
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
