import XCTest
import SwiftData
import JesseCore

/// `UnreadCounter`: the badge's number, and the four properties that make it cheap.
///
/// The rule itself is `UnreadReplyTests`' subject and is not re-tested here. What these
/// pin is everything the old shape got wrong: that the count is the SAME number the pure
/// rule gives, that a save which cannot change it invalidates nothing, that a burst of
/// saves costs one recount rather than one each, that a save on ANOTHER context still
/// moves it, and that counting never reaches a conversation's turns.
///
/// COUNTS, NEVER MILLISECONDS. Every assertion here is an integer — a publish count, a
/// recount count, a badge value — and the one place a wait is unavoidable (a notification
/// delivered on the main queue) polls for the value with a generous ceiling instead of
/// asserting a duration. A CI simulator is too noisy for anything else.
@MainActor
final class UnreadCounterTests: XCTestCase {

    // MARK: - Fixtures

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: JesseThread.self, Turn.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// A conversation with its two unread timestamps set directly through the model's own
    /// mutators, so the fixture cannot drift from what the app writes.
    private func thread(_ title: String, repliedAt replyMs: Int,
                        readThrough: Int? = nil, archived: Bool = false) -> JesseThread {
        let t = JesseThread(title: title, mode: .ask)
        if replyMs > 0 { t.noteReply(atUnixMillis: replyMs) }
        if let readThrough {
            if readThrough == 0 {
                // "Read, then marked unread by hand" — the mark that moves the value
                // BACKWARDS, which is why the LWW clock is a separate field.
                t.markRead(nowMs: 1)
                t.markUnread(nowMs: 2)
            } else {
                t.markRead(nowMs: 1)
            }
        }
        if archived { t.setArchived(true, now: Date(timeIntervalSince1970: 1)) }
        return t
    }

    /// The coalescing window, driven rather than waited out: `sleep` returns as soon as the
    /// task gets a turn. Used by every test that is not specifically about coalescing.
    private let immediately: (TimeInterval) async -> Void = { _ in await Task.yield() }

    /// Poll for a condition with a ceiling, for the one thing that genuinely is
    /// asynchronous: `ModelContext.didSave` is delivered on the main queue, so a save made
    /// on another context reaches the counter a turn later. A wait, not a timing assertion —
    /// the ceiling only decides how long a BROKEN build takes to fail.
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 1. Parity with the pure rule

    /// THE SAME NUMBER, by two roads. The counter asks the store to count rows matching a
    /// predicate; `jesseUnreadCount` walks objects in memory. They must agree over a
    /// fixture that covers every shape the rule distinguishes, or the badge and the dots
    /// behind it are two claims again.
    func testTheCountEqualsThePureRuleOverTheSameConversations() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let fixture = [
            thread("unread", repliedAt: 5_000),
            thread("read", repliedAt: 5_000, readThrough: 5_000),
            thread("archived and unread", repliedAt: 5_000, archived: true),
            thread("marked unread by hand", repliedAt: 5_000, readThrough: 0),
            thread("never replied", repliedAt: 0),
        ]
        for t in fixture { context.insert(t) }
        try context.save()

        let counter = UnreadCounter(container: container, sleep: immediately)

        XCTAssertEqual(counter.unreadCount, jesseUnreadCount(fixture),
                       "the count query and the pure rule are one claim")
        XCTAssertEqual(counter.unreadCount, 2,
                       "the unread one and the hand-marked one; the archived one is excluded")
        XCTAssertFalse(counter.didFallBackToPropertyFetch,
                       """
                       the `#Predicate` comparing two key paths (lastReplyMs > readThroughMs) \
                       is the path in use. A fallback here is not wrong, but it fetches every \
                       row's three columns instead of counting in the store, and the PR must \
                       say so.
                       """)
    }

    /// And it tracks the marks, in both directions, through a save.
    func testMarkingReadAndUnreadMovesTheCount() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let t = thread("unread", repliedAt: 5_000)
        context.insert(t)
        try context.save()

        let counter = UnreadCounter(container: container, sleep: immediately)
        XCTAssertEqual(counter.unreadCount, 1)

        t.markRead(nowMs: 10)
        try context.save()
        counter.recountNow()
        XCTAssertEqual(counter.unreadCount, 0, "reading it empties the badge")
        XCTAssertEqual(counter.publishCount, 1)

        t.markUnread(nowMs: 20)
        try context.save()
        counter.recountNow()
        XCTAssertEqual(counter.unreadCount, 1, "and marking it unread brings it back")
        XCTAssertEqual(counter.publishCount, 2)
    }

    // MARK: - 2. A save that cannot change the badge invalidates nothing

    /// THE REGRESSION GUARD. The old shape read every conversation row on the root view,
    /// so any save touching any thread re-evaluated the root's body and rebuilt all three
    /// tabs — a list refresh, a title arriving, a star. Here 50 conversations out of 500
    /// have their activity stamp, their AI title and their star changed and saved, and the
    /// observed count neither changes nor announces anything.
    func testSavesThatCannotChangeTheBadgePublishNothing() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var rows: [JesseThread] = []
        for i in 0..<500 {
            // All read: the badge is 0 and must stay 0 through everything below.
            let t = thread("c\(i)", repliedAt: 1_000 + i, readThrough: 1_000 + i)
            context.insert(t)
            rows.append(t)
        }
        try context.save()

        let counter = UnreadCounter(container: container, sleep: immediately)
        XCTAssertEqual(counter.unreadCount, 0)

        let flag = Flag()
        withObservationTracking {
            _ = counter.unreadCount
        } onChange: {
            flag.fired = true
        }

        for t in rows.prefix(50) {
            t.updatedAt = Date(timeIntervalSince1970: 9_000_000)
            t.aiTitle = "a title the bridge just minted"
            t.setFavorite(true, now: Date(timeIntervalSince1970: 9_000_000))
        }
        try context.save()
        counter.recountNow()

        XCTAssertFalse(flag.fired,
                       """
                       nothing that reads `unreadCount` was invalidated: 50 conversations \
                       changed, and none of the changes was to whether a conversation holds \
                       an unseen reply.
                       """)
        XCTAssertEqual(counter.publishCount, 0, "no value was published")
        XCTAssertEqual(counter.unreadCount, 0)
        XCTAssertGreaterThanOrEqual(counter.recountCount, 1,
                                    "it did look — the silence is the answer, not a skipped check")
    }

    // MARK: - 3. One publish per real change, whatever the burst

    /// A sync pass mutates many conversations and saves several times inside one run. The
    /// window collapses the burst into ONE recount, and because only the last save changes
    /// the answer, exactly one value is published.
    ///
    /// The window is held open by an injected gate rather than by a real 250 ms, so the
    /// burst is genuinely inside one window on any machine.
    func testABurstOfSavesCostsOneRecountAndOnePublish() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var rows: [JesseThread] = []
        for i in 0..<20 {
            let t = thread("c\(i)", repliedAt: 1_000 + i, readThrough: 1_000 + i)
            context.insert(t)
            rows.append(t)
        }
        try context.save()

        let gate = Gate()
        let counter = UnreadCounter(container: container, sleep: { _ in await gate.wait() })
        XCTAssertEqual(counter.unreadCount, 0)

        for i in 0..<20 {
            if i == 19 {
                // The one save in the burst that changes the answer: a reply nobody has seen.
                context.insert(thread("the new reply", repliedAt: 9_000))
            } else {
                rows[i].aiTitle = "title \(i)"
            }
            try context.save()
            counter.noteStoreChanged()
        }

        XCTAssertEqual(counter.recountCount, 0,
                       "nothing was recounted while the window was open")

        gate.release()
        await waitUntil("the coalesced recount") { counter.recountCount >= 1 }

        XCTAssertEqual(counter.unreadCount, 1, "the burst's final answer, not an intermediate one")
        XCTAssertEqual(counter.publishCount, 1,
                       "20 saves, one changed value, one publish")
    }

    // MARK: - 4. Saves from any context

    /// The badge must be right when the change did not come from the view's own context: a
    /// reply delivered on the background context, a read mark converging from the Mac
    /// through a sync, an archive made in another window. `ModelContext.didSave` is posted
    /// for every context on the container, which is the reach this needs.
    func testASaveOnAnotherContextMovesTheCount() async throws {
        let container = try makeContainer()
        let seeding = ModelContext(container)
        seeding.insert(thread("read", repliedAt: 1_000, readThrough: 1_000))
        try seeding.save()

        let counter = UnreadCounter(container: container, sleep: immediately)
        XCTAssertEqual(counter.unreadCount, 0)

        // A SECOND context on the same container — the shape of `BackgroundDelivery`'s.
        let delivery = ModelContext(container)
        delivery.insert(thread("a reply that just landed", repliedAt: 7_000))
        try delivery.save()

        await waitUntil("the badge to follow the other context's save") {
            counter.unreadCount == 1
        }
        XCTAssertEqual(counter.publishCount, 1)
    }

    // MARK: - 5. Counting never reaches a conversation's turns

    /// The old count read `isArchived` and the two stamps off every thread OBJECT, which
    /// meant materializing every conversation; a badge must not pull the whole history into
    /// memory. `fetchCount` returns an Int from the store and materializes nothing at all,
    /// and the descriptor it runs carries no `propertiesToFetch` and no relationship key
    /// path — so there is no road from it to a `Turn`.
    ///
    /// What this asserts is the descriptor's shape and the count's correctness over
    /// conversations that DO hold turns. It cannot observe SwiftData's row cache, so it is
    /// not a proof that no object was materialized; the API contract of `fetchCount` is
    /// what carries that, and the fallback's `propertiesToFetch` is pinned here for the day
    /// the predicate path stops working.
    func testTheCountsFetchCarriesNoRelationship() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for i in 0..<50 {
            let t = i.isMultiple(of: 2)
                ? thread("unread \(i)", repliedAt: 5_000)
                : thread("read \(i)", repliedAt: 5_000, readThrough: 5_000)
            context.insert(t)
            for j in 0..<3 {
                let turn = Turn(role: j == 0 ? .user : .jesse, text: "turn \(j)",
                                createdAt: Date(timeIntervalSince1970: TimeInterval(j)))
                turn.thread = t
                context.insert(turn)
            }
        }
        try context.save()

        let counter = UnreadCounter(container: container, sleep: immediately)
        XCTAssertEqual(counter.unreadCount, 25, "counted right, with 150 turns in the store")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Turn>()), 150,
                       "the turns are really there — this is not a count over an empty store")

        let descriptor = UnreadCounter.unreadDescriptor()
        XCTAssertTrue(descriptor.propertiesToFetch.isEmpty,
                      "a count query fetches no properties at all")
        XCTAssertNil(descriptor.sortBy.first, "and sorts nothing")

        let turns: PartialKeyPath<JesseThread> = \JesseThread.turns
        XCTAssertFalse(UnreadCounter.countedProperties.contains(turns),
                       "the fallback never asks for the turns relationship")
        XCTAssertEqual(UnreadCounter.countedProperties.count, 3,
                       "three scalar columns: archived, last reply, read through")
    }
}

/// A `withObservationTracking` `onChange` handler must be `@Sendable`, so the flag it sets
/// cannot be a captured local. One reference type, set on the main actor and read on the
/// main actor, is the smallest thing that satisfies both.
private final class Flag: @unchecked Sendable {
    var fired = false
}

/// A coalescing window held open until a test says otherwise. It stands in for the 250 ms
/// wait, so "these twenty saves are inside one window" is a fact rather than a race.
@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }
}
