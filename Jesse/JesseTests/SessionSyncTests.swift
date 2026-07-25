import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// Two-way conversation sync on iOS, driven through the real `RunCoordinator` + an in-memory
/// store + a fake client (no server): the phone adopts brand-new bridge conversations,
/// hydrates their transcripts on open with the seeding rule that stops it re-importing its
/// own turns, merges duplicates already on the device, binds a pre-upgrade thread to its
/// conversation, and honors cross-device deletion tombstones. The pure adopt/update/delete
/// decision itself is covered in the package (`ConversationReconcilerTests`); these assert
/// the iOS wiring.
@MainActor
final class SessionSyncTests: XCTestCase {

    /// A canonical conversation id, in exactly the shape the bridge validates.
    private static func cid(_ n: Int) -> String {
        String(format: "%08x-2222-4333-8444-555555555555", n)
    }

    /// A fake bridge client that models `listConversations`, `hydrate`, and `send`.
    /// `transcripts[cid] = (turns, endCursor)`: a hydrate returns the full turns when the
    /// cursor differs from `endCursor` (first sight) and nothing when it matches (already at
    /// the tail), mirroring the real opaque-cursor delta.
    @MainActor
    private final class FakeSyncClient: JesseClientProtocol {
        var scriptedConversations: ConversationsResult = .notModified
        var transcripts: [String: (turns: [HydratedTurn], end: String)] = [:]
        var sendResult: JesseSendResult = .reply(JesseReply(text: "", sessionId: nil),
                                                 jobId: nil, conversationId: nil)
        /// When set, `send` echoes THIS conversation id instead of the one it was given,
        /// exercising the bridge's authority to override.
        var overrideConversationId: String?
        private(set) var hydrateCalls: [(cid: String, after: String?)] = []
        private(set) var sentConversationIds: [String] = []
        private(set) var sentRequestIds: [UUID] = []
        private(set) var listCalls = 0
        /// When true, `result` never resolves, so a turn stays genuinely IN FLIGHT for the
        /// tests that need to sync mid-turn.
        var pollStaysRunning = false
        /// Set to make `listConversations` suspend until `releaseList()` is called, so two
        /// refreshes genuinely OVERLAP rather than running back to back.
        private var listGate: CheckedContinuation<Void, Never>?
        var gateList = false

        func listConversations(etag: String?) async throws -> ConversationsResult {
            listCalls += 1
            if gateList {
                await withCheckedContinuation { self.listGate = $0 }
            }
            return scriptedConversations
        }

        /// Let a gated `listConversations` finish.
        func releaseList() {
            listGate?.resume()
            listGate = nil
        }

        func hydrate(conversationId: String, after cursor: String?) async throws
            -> (turns: [HydratedTurn], nextCursor: String) {
            hydrateCalls.append((conversationId, cursor))
            guard let t = transcripts[conversationId] else { throw JesseError.badResponse(404, "") }
            if cursor == t.end { return ([], t.end) }
            return (t.turns, t.end)
        }

        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?) async throws -> JesseSendResult {
            sentConversationIds.append(conversationId)
            sentRequestIds.append(requestId)
            let echo = overrideConversationId ?? conversationId
            switch sendResult {
            case let .reply(reply, jobId, _):
                return .reply(reply, jobId: jobId, conversationId: echo)
            case let .running(jobId, _):
                return .running(jobId: jobId, conversationId: echo)
            }
        }
        func result(jobId: String) async throws -> JesseResultState {
            pollStaysRunning ? .running : .done(JesseReply(text: "", sessionId: nil))
        }
        func cancelJob(jobId: String) async throws {}
        nonisolated func setFlags(conversationId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, TurnAttachment.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func scratchCursorStore() -> HydrationCursorStore {
        HydrationCursorStore(defaults: UserDefaults(suiteName: "SessionSyncTests.cursor.\(UUID().uuidString)")!)
    }

    private func scratchDeletionStore() -> PendingSessionDeletionStore {
        PendingSessionDeletionStore(defaults: UserDefaults(suiteName: "SessionSyncTests.del.\(UUID().uuidString)")!)
    }

    @MainActor
    private func makeCoordinator(_ fake: FakeSyncClient,
                                 cursor: HydrationCursorStore,
                                 deletion: PendingSessionDeletionStore) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            sessionDeletionStore: deletion,
            hydrationCursorStore: cursor)
    }

    private func summary(_ id: String, title: String? = nil, sessionId: String? = nil,
                        sessionIds: [String] = [], lastModified: UInt64 = 1_700_000_000,
                        favorite: Bool = false, favoriteUpdatedMs: UInt64 = 0)
        -> ConversationSummary {
        ConversationSummary(conversationId: id, sessionId: sessionId,
                            sessionIds: sessionIds.isEmpty ? [sessionId].compactMap { $0 } : sessionIds,
                            lastModified: lastModified, firstMessage: "hello \(id)", title: title,
                            favorite: favorite, favoriteUpdatedMs: favoriteUpdatedMs)
    }

    private func turn(_ role: String, _ text: String, _ key: String = "") -> HydratedTurn {
        HydratedTurn(role: role, text: text, timestamp: nil, turnKey: key)
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 4, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func threads(_ context: ModelContext) -> [JesseThread] {
        (try? context.fetch(FetchDescriptor<JesseThread>())) ?? []
    }

    private func threadCount(_ context: ModelContext) -> Int { threads(context).count }

    private func thread(_ cid: String, in context: ModelContext) -> JesseThread? {
        threads(context).first { $0.conversationId == cid }
    }

    // MARK: - Registration on send

    func testFirstSendRegistersConversationIdAndSetsRegisteredAt() async throws {
        let context = try makeContext()
        let fake = FakeSyncClient()
        fake.sendResult = .running(jobId: "job-1", conversationId: nil)
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        let t = JesseThread(mode: .ask)
        let minted = try XCTUnwrap(t.conversationId)
        XCTAssertFalse(minted.isEmpty, "the model mints the conversation id at init")
        XCTAssertEqual(minted, minted.lowercased(), "canonical LOWERCASE, which the bridge requires")
        XCTAssertNil(t.registeredAt, "nothing has been accepted yet")
        context.insert(t)
        try context.save()

        coordinator.send(thread: t, text: "hi", voice: false, context: context)
        await waitUntil("the 202 to be handled") { t.registeredAt != nil }

        XCTAssertEqual(fake.sentConversationIds, [minted], "the turn carried the thread's id")
        XCTAssertEqual(t.conversationId, minted, "and the echoed id is the same one")
        XCTAssertNotNil(t.registeredAt, "the first ACK stamps the registration time")
        XCTAssertEqual(fake.sentRequestIds.count, 1, "the outbox id rode along as the request id")
    }

    func testConversationIdIsSentOnFollowUpTurnsToo() async throws {
        let context = try makeContext()
        let fake = FakeSyncClient()
        fake.sendResult = .running(jobId: "job-1", conversationId: nil)
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        let t = JesseThread(mode: .ask)
        let minted = try XCTUnwrap(t.conversationId)
        t.sessionId = "sess-1"          // an established thread
        context.insert(t)
        try context.save()

        coordinator.send(thread: t, text: "one", voice: false, context: context)
        await waitUntil("the first turn to be accepted") { fake.sentConversationIds.count == 1 }
        let firstStamp = t.registeredAt
        coordinator.cancel(t.id)
        coordinator.send(thread: t, text: "two", voice: false, context: context)
        await waitUntil("the follow-up to be accepted") { fake.sentConversationIds.count == 2 }

        XCTAssertEqual(fake.sentConversationIds, [minted, minted],
                       "every turn carries the id, first and follow-up alike")
        XCTAssertEqual(t.registeredAt, firstStamp,
                       "registeredAt is set ONCE, not re-stamped as a last-activity time")
    }

    func testBridgeReturnedConversationIdOverridesTheLocalOne() async throws {
        // The bridge is authoritative and stays free to override the requested id (it does
        // exactly that when binding a legacy transcript), so the client always writes back
        // whatever came home.
        let context = try makeContext()
        let fake = FakeSyncClient()
        fake.sendResult = .running(jobId: "job-1", conversationId: nil)
        fake.overrideConversationId = Self.cid(0xABCD)
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        let t = JesseThread(mode: .ask)
        let minted = try XCTUnwrap(t.conversationId)
        context.insert(t)
        try context.save()

        coordinator.send(thread: t, text: "hi", voice: false, context: context)
        await waitUntil("the override to be adopted") { t.conversationId == Self.cid(0xABCD) }
        XCTAssertEqual(fake.sentConversationIds, [minted], "the client sent its own id…")
        XCTAssertEqual(t.conversationId, Self.cid(0xABCD), "…and adopted the bridge's answer")
    }

    // MARK: - The headline regression

    func testSyncDuringInFlightFirstTurnDoesNotAdoptADuplicate() async throws {
        // THE bug. A thread's first turn is still running; the bridge already lists that
        // conversation (it registered it at accept time). A sync landing in that window must
        // recognize the thread it already holds, not adopt a second one. Before the bridge
        // owned conversation identity there was nothing to recognize it BY: the client had no
        // session id yet, so the matcher classified its own thread as unknown.
        let context = try makeContext()
        let fake = FakeSyncClient()
        fake.sendResult = .running(jobId: "job-1", conversationId: nil)
        // The poll never resolves, so the turn stays genuinely in flight while we sync.
        fake.pollStaysRunning = true
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        let t = JesseThread(mode: .ask)
        let cid = try XCTUnwrap(t.conversationId)
        context.insert(t)
        try context.save()

        coordinator.send(thread: t, text: "the first question", voice: false, context: context)
        await waitUntil("the turn to be accepted") { t.registeredAt != nil }
        XCTAssertTrue(coordinator.isRunning(t.id), "the turn is still in flight")

        // The bridge advertises the conversation with NO session yet, exactly as it does
        // while the turn runs.
        fake.scriptedConversations = .conversations(
            [summary(cid, title: "In Flight", sessionId: nil)], deleted: [], etag: "e1")
        await coordinator.refreshSessions(context: context)
        // And again, as backgrounding and reopening the app does.
        coordinator.sessionsETagForTesting = nil
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 1, "exactly one thread: \(threads(context).map(\.title))")
        XCTAssertEqual(threads(context).first?.id, t.id, "and it is the ORIGINAL, not an adopted copy")
        XCTAssertEqual(threads(context).first?.aiTitle, "In Flight", "which was updated, not duplicated")
    }

    func testAdoptOnlyWhenConversationIdUnknown() async throws {
        let context = try makeContext()
        let fake = FakeSyncClient()
        let held = JesseThread(mode: .ask)
        let heldId = try XCTUnwrap(held.conversationId)
        context.insert(held)
        try context.save()

        fake.scriptedConversations = .conversations(
            [summary(heldId, title: "Held"), summary(Self.cid(0x99), title: "Fresh")],
            deleted: [], etag: "e1")
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 2, "only the unknown id was adopted")
        XCTAssertEqual(thread(heldId, in: context)?.aiTitle, "Held")
        XCTAssertEqual(thread(Self.cid(0x99), in: context)?.aiTitle, "Fresh")
    }

    func testLegacyThreadWithSessionIdBindsToRemoteConversationIdAndIsNotReAdopted() async throws {
        // A pre-upgrade row: it has a session id and NO conversation id. The legacy-bind pass
        // must adopt the conversation whose alias list contains that session, BEFORE the plan
        // runs, or the thread is classified unknown and adopted as a duplicate of itself.
        let context = try makeContext()
        let fake = FakeSyncClient()
        let legacy = JesseThread(mode: .ask)
        legacy.conversationId = nil
        legacy.sessionId = "sess-old"
        let u = Turn(role: .user, text: "an old question"); u.thread = legacy
        context.insert(legacy); context.insert(u)
        try context.save()

        let remoteId = Self.cid(0x77)
        fake.scriptedConversations = .conversations(
            [summary(remoteId, title: "Bound", sessionId: "sess-new",
                     sessionIds: ["sess-old", "sess-new"])],
            deleted: [], etag: "e1")
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 1, "bound, not re-adopted: \(threadCount(context)) threads")
        let bound = try XCTUnwrap(threads(context).first)
        XCTAssertEqual(bound.conversationId, remoteId, "it adopted the remote conversation id")
        XCTAssertEqual(bound.sessionId, "sess-new", "and the CURRENT session, which the fork moved")
        XCTAssertEqual(bound.turns.count, 1, "its history is intact")
        XCTAssertEqual(bound.aiTitle, "Bound")
    }

    // MARK: - Repairing duplicates already on the device

    func testExistingDuplicateThreadsMergeIntoOneWithAllTurnsPreserved() async throws {
        let context = try makeContext()
        let fake = FakeSyncClient()
        let cid = Self.cid(0x55)
        // The original, with the first exchange.
        let original = JesseThread(title: "Original", mode: .ask,
                                   createdAt: Date(timeIntervalSince1970: 1_000))
        original.conversationId = cid
        let a = Turn(role: .user, text: "q1", createdAt: Date(timeIntervalSince1970: 1_001))
        a.sourceKey = "s:0"; a.thread = original
        let b = Turn(role: .jesse, text: "a1", createdAt: Date(timeIntervalSince1970: 1_002))
        b.sourceKey = "s:60"; b.thread = original
        // The duplicate a mid-turn sync adopted, holding a LATER exchange the original
        // never saw (this is why the merge cannot just delete it).
        let dupe = JesseThread(title: "Duplicate", mode: .ask,
                               createdAt: Date(timeIntervalSince1970: 2_000))
        dupe.conversationId = cid
        let c = Turn(role: .user, text: "q2", createdAt: Date(timeIntervalSince1970: 2_001))
        c.sourceKey = "s:120"; c.thread = dupe
        for m in [original, dupe] { context.insert(m) }
        for t in [a, b, c] { context.insert(t) }
        try context.save()
        XCTAssertEqual(threadCount(context), 2)

        fake.scriptedConversations = .conversations(
            [summary(cid, title: "Merged", sessionId: "sess-1")], deleted: [], etag: "e1")
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 1, "the duplicates collapsed into one")
        let survivor = try XCTUnwrap(threads(context).first)
        XCTAssertEqual(survivor.title, "Original", "the OLDEST thread wins")
        XCTAssertEqual(survivor.orderedTurns.map(\.text), ["q1", "a1", "q2"],
                       "every turn survives, in order, none duplicated")
        XCTAssertEqual(survivor.sessionId, "sess-1", "the current session comes from the remote row")
    }

    func testMergePrefersOldestThreadAndResolvesFlagsByLatestClock() async throws {
        let context = try makeContext()
        let fake = FakeSyncClient()
        let cid = Self.cid(0x56)
        let original = JesseThread(title: "Original", mode: .ask,
                                   createdAt: Date(timeIntervalSince1970: 1_000))
        original.conversationId = cid
        original.setFavorite(false, now: Date(timeIntervalSince1970: 1))     // ms 1000
        let dupe = JesseThread(title: "Duplicate", mode: .ask,
                               createdAt: Date(timeIntervalSince1970: 2_000))
        dupe.conversationId = cid
        dupe.setFavorite(true, now: Date(timeIntervalSince1970: 5))          // ms 5000, NEWER
        dupe.setArchived(true, now: Date(timeIntervalSince1970: 6))          // ms 6000
        dupe.aiTitle = "A Minted Title"
        context.insert(original); context.insert(dupe)
        try context.save()

        fake.scriptedConversations = .conversations(
            [summary(cid, sessionId: "sess-1")], deleted: [], etag: "e1")
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        let survivor = try XCTUnwrap(threads(context).first)
        XCTAssertEqual(survivor.title, "Original", "oldest wins the identity")
        XCTAssertTrue(survivor.isFavorite, "but the NEWER favorite clock wins the flag")
        XCTAssertEqual(survivor.favoriteUpdatedMs, 5_000)
        XCTAssertNotNil(survivor.favoritedAt, "carrying its display timestamp")
        XCTAssertTrue(survivor.isArchived)
        XCTAssertEqual(survivor.archivedUpdatedMs, 6_000)
        XCTAssertEqual(survivor.aiTitle, "A Minted Title",
                       "an empty winner title takes the loser's")
    }

    func testThreadsWithTheSameTitleButDifferentConversationsAreNeverMerged() async throws {
        // The merge keys on the conversation id and NEVER on the title: two conversations can
        // legitimately share a title, and merging those would destroy real content.
        let context = try makeContext()
        let fake = FakeSyncClient()
        let one = JesseThread(title: "Weekly Review", mode: .ask)
        let two = JesseThread(title: "Weekly Review", mode: .ask)
        let idOne = try XCTUnwrap(one.conversationId)
        let idTwo = try XCTUnwrap(two.conversationId)
        context.insert(one); context.insert(two)
        try context.save()

        fake.scriptedConversations = .conversations(
            [summary(idOne), summary(idTwo)], deleted: [], etag: "e1")
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 2, "same title, different conversations, both kept")
    }

    func testOverlappingRefreshDoesNotApplyThePlanTwice() async throws {
        // `ContentView` fires a refresh on `onAppear` AND on `scenePhase == .active`, and both
        // can leave holding the same stale ETag.
        let context = try makeContext()
        let fake = FakeSyncClient()
        fake.scriptedConversations = .conversations(
            [summary(Self.cid(0x11), title: "Once")], deleted: [], etag: "e1")
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())

        // Two GENUINELY overlapping refreshes: the fake's list call suspends, so the second
        // call lands while the first is still in progress and must observe its flag. Started as
        // MainActor-isolated child tasks so the non-Sendable `ModelContext` never crosses an
        // isolation boundary, which is also how the app fires them (both from MainActor view
        // lifecycle hooks).
        fake.gateList = true
        let first = Task { @MainActor in await coordinator.refreshSessions(context: context) }
        // Let the first reach its suspended list call.
        await waitUntil("the first refresh to be in flight") { fake.listCalls == 1 }
        let second = Task { @MainActor in await coordinator.refreshSessions(context: context) }
        await second.value
        XCTAssertEqual(fake.listCalls, 1, "the overlapping refresh never issued its own fetch")
        fake.releaseList()
        await first.value

        XCTAssertEqual(threadCount(context), 1, "the overlapping pass did not adopt a second copy")
        XCTAssertEqual(fake.listCalls, 1, "and the redundant fetch was skipped outright")
    }

    // MARK: - Hydration seeding

    func testPhoneStartedThreadWithTurnsSeedsAndImportsNothing() async throws {
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        let cid = Self.cid(1)
        // A phone-started thread: it already holds its own two turns and has no cursor.
        let t = JesseThread(mode: .ask); t.conversationId = cid
        let u = Turn(role: .user, text: "hi"); u.thread = t
        let j = Turn(role: .jesse, text: "hello"); j.thread = t
        context.insert(t); context.insert(u); context.insert(j)
        try context.save()
        fake.transcripts[cid] = ([turn("user", "hi", "s:0"), turn("assistant", "hello", "s:60")], "0:500")

        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        await coordinator.hydrateOnOpen(thread: t, context: context)

        XCTAssertEqual(t.turns.count, 2, "a phone-started thread must NOT re-import its own turns")
        XCTAssertEqual(cursor.cursor(cid), "0:500", "the cursor is seeded to the transcript end")
    }

    func testAdoptedStubImportsFullTranscriptThenOnlyDelta() async throws {
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        let cid = Self.cid(2)
        // An adopted stub: a conversation id, no local turns, no cursor.
        let t = JesseThread(mode: .ask); t.conversationId = cid
        context.insert(t)
        try context.save()
        fake.transcripts[cid] = ([turn("user", "q1", "s:0"), turn("assistant", "a1", "s:60")], "0:300")

        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        await coordinator.hydrateOnOpen(thread: t, context: context)

        XCTAssertEqual(t.turns.count, 2, "an adopted stub imports the full transcript")
        XCTAssertEqual(cursor.cursor(cid), "0:300")

        // A subsequent open with the cursor present imports only the delta (none here).
        await coordinator.hydrateOnOpen(thread: t, context: context)
        XCTAssertEqual(t.turns.count, 2, "a re-open past the cursor imports nothing new")
        XCTAssertEqual(fake.hydrateCalls.last?.after, "0:300",
                       "the second hydrate asks only for the delta")
    }

    func testHydrateBindsKeyToOptimisticTurnInsteadOfDuplicating() async throws {
        // The transcript-flush-lag scenario. The thread already holds the turns it rendered
        // optimistically, with no keys, and the cursor is absent-but-with-turns... except the
        // cursor is PRESENT at the start, which is what happens after a delivery advanced it
        // to a position the transcript has since grown past. iOS used to append every
        // hydrated turn unconditionally here, producing a double bubble.
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        let cid = Self.cid(3)
        let t = JesseThread(mode: .ask); t.conversationId = cid
        let u = Turn(role: .user, text: "hi"); u.thread = t
        let j = Turn(role: .jesse, text: "hello"); j.thread = t
        context.insert(t); context.insert(u); context.insert(j)
        try context.save()
        cursor.setCursor(cid, "0:0")
        fake.transcripts[cid] = ([turn("user", "hi", "s:0"), turn("assistant", "hello", "s:60")], "0:500")

        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        await coordinator.hydrateOnOpen(thread: t, context: context)

        XCTAssertEqual(t.turns.count, 2, "the rendered turns were BOUND, not duplicated")
        XCTAssertEqual(t.orderedTurns.map(\.sourceKey), ["s:0", "s:60"],
                       "and each acquired its stable transcript key")
        // A second hydrate from the start is now a pure no-op: the keys are held.
        cursor.setCursor(cid, "0:0")
        await coordinator.hydrateOnOpen(thread: t, context: context)
        XCTAssertEqual(t.turns.count, 2, "re-hydrating keyed turns changes nothing")
    }

    func testHydrateAcrossSegmentBoundaryImportsEachTurnOnce() async throws {
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        let cid = Self.cid(4)
        let t = JesseThread(mode: .ask); t.conversationId = cid
        context.insert(t)
        try context.save()
        // Two segments' worth of turns, keyed on their own session ids.
        fake.transcripts[cid] = ([turn("user", "q1", "s0:0"), turn("assistant", "a1", "s0:60"),
                                  turn("user", "q2", "s1:0"), turn("assistant", "a2", "s1:60")],
                                 "1:200")

        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        await coordinator.hydrateOnOpen(thread: t, context: context)
        XCTAssertEqual(t.orderedTurns.map(\.text), ["q1", "a1", "q2", "a2"])
        XCTAssertEqual(cursor.cursor(cid), "1:200", "the cursor names the segment, not a byte offset")

        // Re-hydrating from the start imports nothing: every key is held.
        cursor.setCursor(cid, "0:0")
        await coordinator.hydrateOnOpen(thread: t, context: context)
        XCTAssertEqual(t.turns.count, 4, "no turn is imported twice across the boundary")
    }

    func testRepeatedIdenticalUserMessagesAreBothKept() async throws {
        // The guard against OVER-dedup, which is what a content hash gets wrong: asking the
        // same question twice is two turns.
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        let cid = Self.cid(5)
        let t = JesseThread(mode: .ask); t.conversationId = cid
        context.insert(t)
        try context.save()
        fake.transcripts[cid] = ([turn("user", "same", "s:0"), turn("user", "same", "s:64")], "0:200")

        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        await coordinator.hydrateOnOpen(thread: t, context: context)

        XCTAssertEqual(t.orderedTurns.map(\.text), ["same", "same"],
                       "two identical messages are two turns")
        XCTAssertEqual(Set(t.orderedTurns.compactMap(\.sourceKey)).count, 2, "with distinct keys")
    }

    // MARK: - Adoption + delete via refresh

    func testRefreshAdoptsUnknownConversation() async throws {
        let context = try makeContext()
        let fake = FakeSyncClient()
        let cid = Self.cid(6)
        fake.scriptedConversations = .conversations(
            [summary(cid, title: "From the Mac", sessionId: "sess-mac")], deleted: [], etag: "e1")

        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(), deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        let adopted = thread(cid, in: context)
        XCTAssertNotNil(adopted, "an unknown bridge conversation is adopted as a local thread")
        XCTAssertEqual(adopted?.aiTitle, "From the Mac")
        XCTAssertEqual(adopted?.sessionId, "sess-mac")
        XCTAssertEqual(adopted?.conversationId, cid,
                       "the adopted thread must NOT keep the id its initializer minted")
        XCTAssertTrue(adopted?.turns.isEmpty ?? false, "it is a stub, no transcript until opened")
    }

    func testRefreshWithTombstoneRemovesHeldThreadAndClearsCursor() async throws {
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        let cid = Self.cid(7)
        let t = JesseThread(mode: .ask); t.conversationId = cid
        let u = Turn(role: .user, text: "x"); u.thread = t
        context.insert(t); context.insert(u)
        try context.save()
        cursor.setCursor(cid, "0:100")
        XCTAssertEqual(threadCount(context), 1)

        fake.scriptedConversations = .conversations(
            [], deleted: [ConversationTombstone(conversationId: cid, deletedMs: 1)], etag: "e1")
        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 0, "a tombstoned held thread is removed")
        XCTAssertNil(cursor.cursor(cid), "its hydration cursor is cleared")
    }

    func testPendingDeleteConversationIsNotReAdopted() async throws {
        let context = try makeContext()
        let deletion = scratchDeletionStore()
        let cid = Self.cid(8)
        deletion.enqueue(cid)   // the user deleted it locally; remote delete not drained
        let fake = FakeSyncClient()
        // The bridge still lists it (delete hasn't propagated). It must NOT be re-created.
        fake.scriptedConversations = .conversations([summary(cid)], deleted: [], etag: "e1")

        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(), deletion: deletion)
        await coordinator.refreshSessions(context: context)

        XCTAssertNil(thread(cid, in: context), "a just-deleted conversation is never resurrected")
        XCTAssertEqual(threadCount(context), 0)
    }

    // MARK: - The turn phase behind the delivery caption

    func testPhaseIsSendingBeforeAckAndAcceptedAfter() async throws {
        let context = try makeContext()
        let fake = FakeSyncClient()
        fake.sendResult = .running(jobId: "job-1", conversationId: nil)
        // The poll must NOT resolve: the default fake answers `.done` with an empty reply,
        // which surfaces a recoverable error and clears the phase before it can be observed.
        fake.pollStaysRunning = true
        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(),
                                          deletion: scratchDeletionStore())
        let t = JesseThread(mode: .ask)
        context.insert(t)
        try context.save()

        XCTAssertNil(coordinator.phase(t.id), "nothing in flight, no caption")
        coordinator.send(thread: t, text: "hi", voice: false, context: context)
        // `send` marks the run started synchronously, before the POST is awaited.
        XCTAssertEqual(coordinator.phase(t.id), .sending,
                       "pre-ACK: the message could still be lost with the POST")
        await waitUntil("the 202") { coordinator.phase(t.id) == .accepted }
        XCTAssertEqual(coordinator.phase(t.id), .accepted,
                       "post-ACK: the turn is durably the server's")
        // `isRunning` deliberately cannot tell these apart, which is why `phase` exists.
        XCTAssertTrue(coordinator.isRunning(t.id))
    }

    // MARK: - Delivery cursor advance (invariant)

    func testDeliveredReplyBindsTheKeysAndAdvancesTheCursor() async throws {
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        let t = JesseThread(mode: .ask)
        let cid = try XCTUnwrap(t.conversationId)
        fake.sendResult = .reply(JesseReply(text: "an answer", sessionId: "s9"),
                                 jobId: nil, conversationId: nil)
        fake.transcripts[cid] = ([turn("user", "ask", "s9:0"),
                                  turn("assistant", "an answer", "s9:60")], "0:999")

        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        context.insert(t)
        try context.save()

        coordinator.send(thread: t, text: "ask", voice: false, context: context)
        await waitUntil("the delivered reply's cursor to advance to the transcript end") {
            cursor.cursor(cid) == "0:999"
        }
        XCTAssertEqual(cursor.cursor(cid), "0:999")
        XCTAssertEqual(t.turns.count, 2,
                       "hydrating right after a delivery binds the keys rather than duplicating")
        XCTAssertEqual(t.orderedTurns.compactMap(\.sourceKey).count, 2,
                       "both delivered turns acquired their stable transcript keys")
    }
}
