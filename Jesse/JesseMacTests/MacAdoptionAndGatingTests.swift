import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseConversations
import JesseNetworking

/// Store-level adoption and the configured-gate that turn running / New Chat depend on.
///
/// Includes the reproduction for symptom 2 ("two same-name conversations collapse into
/// one"): driven end to end through `refreshSessions` -> `SessionReconciler` -> the shared
/// `threadListLayout`, two server sessions that share a title and a first message adopt as
/// TWO distinct threads and render as TWO rows. The collapse is NOT in adoption or the
/// layout (both key on session id / object identity, never title); the shared layer is
/// pinned separately in `SameTitleDistinctTests`.
@MainActor
final class MacAdoptionAndGatingTests: XCTestCase {

    private func threads(_ context: ModelContext) -> [JesseThread] {
        (try? context.fetch(FetchDescriptor<JesseThread>())) ?? []
    }
    private func rowCount(_ layout: ThreadListLayout) -> Int {
        switch layout {
        case .flat(let t): return t.count
        case .sectioned(let s): return s.reduce(0) { $0 + $1.threads.count }
        }
    }
    private func coordinator(_ fake: MacFakeBridgeClient,
                             config: MacConfigStore = MacTestFixtures.configured()) -> MacCoordinator {
        MacCoordinator(configStore: config, makeClient: { _ in fake },
                       sessionDeletionStore: MacTestFixtures.deletionStore())
    }

    // MARK: - Symptom 2: same-titled sessions stay distinct

    func testTwoSameTitledSessionsAdoptAsTwoDistinctThreadsAndRows() async throws {
        let context = try MacTestFixtures.context()
        let a = ConversationSummary(conversationId: "conv-A", sessionId: "sess-A",
                                    sessionIds: ["sess-A"], lastModified: 1_700_000_000,
                                    firstMessage: "Weekly sync", title: "Weekly sync")
        let b = ConversationSummary(conversationId: "conv-B", sessionId: "sess-B",
                                    sessionIds: ["sess-B"], lastModified: 1_700_000_050,
                                    firstMessage: "Weekly sync", title: "Weekly sync")
        let fake = MacFakeBridgeClient(conversations: .conversations([a, b], deleted: [], etag: "e1"))

        await coordinator(fake).refreshSessions(context: context)

        let all = threads(context)
        XCTAssertEqual(all.count, 2, "two same-titled sessions adopt as two distinct threads")
        XCTAssertEqual(Set(all.map(\.id)).count, 2, "distinct object identities")
        XCTAssertEqual(Set(all.compactMap(\.sessionId)), ["sess-A", "sess-B"])
        XCTAssertEqual(Set(all.compactMap(\.conversationId)), ["conv-A", "conv-B"],
                       "and each holds the bridge's conversation id, never the other's")

        let layout = MacThreadListModel().layout(all, now: Date(timeIntervalSince1970: 1_700_000_100),
                                                 calendar: .current)
        XCTAssertEqual(rowCount(layout), 2, "both render as two rows, never merged")
    }

    // MARK: - Adoption coverage

    func testUpdateRefreshesServerTitleOnMatchedThread() async throws {
        let context = try MacTestFixtures.context()
        // A PRE-UPGRADE row: a session id and no conversation id. The legacy-bind pass has to
        // match it to the remote conversation whose alias list contains that session, or it is
        // adopted as a duplicate of itself.
        let held = JesseThread(mode: .ask)
        held.conversationId = nil
        held.sessionId = "sess-1"
        held.aiTitle = "old"
        context.insert(held); try context.save()

        let summary = ConversationSummary(conversationId: "conv-1", sessionId: "sess-1",
                                          sessionIds: ["sess-1"], lastModified: 1_700_000_000,
                                          firstMessage: "hi", title: "fresh title")
        let fake = MacFakeBridgeClient(conversations: .conversations([summary], deleted: [], etag: "e1"))
        await coordinator(fake).refreshSessions(context: context)

        XCTAssertEqual(threads(context).count, 1, "a matched session updates, it does not duplicate")
        XCTAssertEqual(held.aiTitle, "fresh title")
        XCTAssertEqual(held.conversationId, "conv-1", "and it is now bound to the conversation")
    }

    func testAdoptIsIdempotentAcrossRefreshes() async throws {
        let context = try MacTestFixtures.context()
        let summary = ConversationSummary(conversationId: "conv-1", sessionId: "sess-1",
                                          sessionIds: ["sess-1"], lastModified: 1_700_000_000,
                                          firstMessage: "hi", title: nil)
        let fake = MacFakeBridgeClient(conversations: .conversations([summary], deleted: [], etag: "e1"))
        let coord = coordinator(fake)

        await coord.refreshSessions(context: context)
        // The coordinator short-circuits an unchanged list by ETag; drop the stored ETag so
        // the second pull actually re-runs the reconcile rather than 304-ing.
        UserDefaults.standard.removeObject(forKey: "sessions.etag")
        await coord.refreshSessions(context: context)

        XCTAssertEqual(threads(context).count, 1, "re-seeing a known session must not re-adopt it")
    }

    // MARK: - Symptom 5: the configured gate

    func testSendIsNoOpWhenUnconfigured() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let fake = MacFakeBridgeClient()
        let coord = coordinator(fake, config: MacTestFixtures.unconfigured())

        await coord.send(text: "hello", mode: .ask, thread: thread, context: context)

        XCTAssertTrue(thread.orderedTurns.isEmpty, "an unconfigured client cannot start a turn")
        XCTAssertFalse(coord.isRunning)
    }

    func testSendInsertsUserAndReplyWhenConfigured() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let sid = "sess-\(UUID().uuidString)"; defer { MacCursorStore.clear(sid) }
        let fake = MacFakeBridgeClient(
            sendResult: .reply(JesseReply(text: "reply from jesse", sessionId: sid), jobId: nil, conversationId: nil))
        let coord = coordinator(fake)

        await coord.send(text: "hello", mode: .ask, thread: thread, context: context)

        XCTAssertEqual(thread.orderedTurns.map(\.text), ["hello", "reply from jesse"])
        XCTAssertEqual(thread.sessionId, sid, "a fresh session id is adopted onto the thread")
    }

    func testNewChatGateFollowsConfigured() {
        // The New Chat toolbar button is `.disabled(!configStore.isConfigured)`; this pins
        // the exact predicate it reads.
        XCTAssertTrue(MacTestFixtures.configured().isConfigured)
        XCTAssertFalse(MacTestFixtures.unconfigured().isConfigured)
    }
}
