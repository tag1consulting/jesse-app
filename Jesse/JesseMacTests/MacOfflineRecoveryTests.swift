import XCTest
import SwiftUI
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

// **The Mac's half of "works offline, and notices when it's back."**
//
// The Mac was the worst place to be offline: no reachability probe at all, so no banner,
// no read-only day, and — the part that made the rest pointless — no way to notice the
// bridge had come back. A laptop that slept never leaves `scenePhase == .active`, and the
// short client session has `waitsForConnectivity = false`, so the first request after a
// lid-open fails instantly and nothing re-asks.
//
// Three things are fixed here and asserted below: a success CLEARS the sticky error
// instead of only a send doing so, the session-list ETag is stored only AFTER the adopt
// it describes, and the wake/foreground trigger is a stated rule rather than a guess.

@MainActor
final class MacOfflineRecoveryTests: XCTestCase {

    private func coordinator(_ fake: MacFakeBridgeClient) -> MacCoordinator {
        MacCoordinator(configStore: MacTestFixtures.configured(),
                       makeClient: { _ in fake },
                       sessionDeletionStore: MacTestFixtures.deletionStore())
    }

    private func summary(_ id: String) -> ConversationSummary {
        ConversationSummary(conversationId: id, sessionId: "sess-\(id)",
                            sessionIds: ["sess-\(id)"], lastModified: 1_700_000_000,
                            firstMessage: "hi \(id)")
    }

    // MARK: - The sticky error

    /// One transient failure used to paint the window permanently "disconnected":
    /// `lastError` was cleared by `send` and by nothing else, so a sync that failed at 2am
    /// was still on screen at 9. A completed round trip is what clears it.
    func testASuccessfulSessionRefreshClearsAStickyError() async throws {
        let context = try MacTestFixtures.context()
        let fake = MacFakeBridgeClient(
            conversations: .conversations([summary("adopted")], deleted: [], etag: "e-new"))
        let c = coordinator(fake)
        c.lastError = "Couldn't reach “studio”."

        await c.refreshSessions(context: context)

        XCTAssertNil(c.lastError, "a completed round trip is what takes the red off")
    }

    /// A `304` is a completed round trip too — and it is the COMMON one, so a version of
    /// this fix that only cleared on the adopt path would leave the banner up on every
    /// quiet day.
    func testANotModifiedSessionRefreshAlsoClearsAStickyError() async throws {
        let context = try MacTestFixtures.context()
        let c = coordinator(MacFakeBridgeClient(conversations: .notModified))
        c.lastError = "Couldn't reach “studio”."

        await c.refreshSessions(context: context)

        XCTAssertNil(c.lastError)
    }

    /// Clearing on success must not become "never reports anything": a call that was
    /// never made clears nothing, so an unconfigured app keeps whatever it was showing.
    func testAnUnconfiguredRefreshClearsNothing() async throws {
        let context = try MacTestFixtures.context()
        let c = MacCoordinator(
            configStore: MacConfigStore(config: JesseConfig(host: "", port: 8765, token: "")),
            makeClient: { _ in MacFakeBridgeClient(conversations: .notModified) },
            sessionDeletionStore: MacTestFixtures.deletionStore())
        c.lastError = "held"

        await c.refreshSessions(context: context)

        XCTAssertEqual(c.lastError, "held",
                       "nothing was attempted, so there is nothing a success could clear")
    }

    /// Opening a thread that hydrates cleanly clears the error too, for the same reason.
    func testASuccessfulHydrateClearsAStickyError() async throws {
        let context = try MacTestFixtures.context()
        let turn = HydratedTurn(role: "assistant", text: "from the phone",
                                timestamp: "2026-08-21T12:00:00Z", turnKey: "k-1")
        let fake = MacFakeBridgeClient(hydrate: { _, _ in ([turn], "0:1") })
        let c = coordinator(fake)
        let t = JesseThread(mode: .ask)
        t.conversationId = "conv-1"
        context.insert(t)
        try context.save()
        c.lastError = "Couldn't reach “studio”."

        await c.hydrate(thread: t, context: context)

        XCTAssertNil(c.lastError)
    }

    /// An EMPTY hydrate is still a success — and it is the usual answer, so it has to
    /// clear the error as well.
    func testAnEmptyHydrateAlsoClearsAStickyError() async throws {
        let context = try MacTestFixtures.context()
        let fake = MacFakeBridgeClient(hydrate: { _, after in ([], after ?? "0:0") })
        let c = coordinator(fake)
        let t = JesseThread(mode: .ask)
        t.conversationId = "conv-2"
        context.insert(t)
        try context.save()
        c.lastError = "Couldn't reach “studio”."

        await c.hydrate(thread: t, context: context)

        XCTAssertNil(c.lastError)
    }

    // MARK: - The ETag is stored only after the adopt it describes

    /// The session-list ETag used to be written BEFORE `upsert` ran. A kill (or a sleep)
    /// part-way through the adopt then left the new tag stored against a list this device
    /// never finished applying, and every later pull was a cheap `304` describing threads
    /// the local store does not have.
    ///
    /// Asserted by observation, which is the only way to see an ordering: the fake reads
    /// the stored tag from INSIDE `upsert` (the flag push the adopt makes), and must see
    /// the OLD one.
    func testTheSessionETagIsWrittenAfterTheAdoptAndNotBefore() async throws {
        let context = try MacTestFixtures.context()
        let key = "sessions.etag"
        let previous = "e-before-\(UUID().uuidString)"
        UserDefaults.standard.set(previous, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // A local thread whose favorite clock is strictly newer than the server's, so the
        // reconciler PUSHES during `upsert` — which is the hook this test observes from.
        let t = JesseThread(mode: .ask)
        t.conversationId = "conv-push"
        t.isFavorite = true
        t.favoriteUpdatedMs = 2_000
        context.insert(t)
        try context.save()

        let observer = ETagObservingClient(
            conversations: .conversations(
                [ConversationSummary(conversationId: "conv-push", sessionId: "s",
                                     sessionIds: ["s"], lastModified: 1_700_000_000,
                                     firstMessage: "hi")],
                deleted: [], etag: "e-after"),
            key: key)

        let c = MacCoordinator(configStore: MacTestFixtures.configured(),
                               makeClient: { _ in observer },
                               sessionDeletionStore: MacTestFixtures.deletionStore())
        await c.refreshSessions(context: context)

        XCTAssertNotNil(observer.observedETag,
                        "the adopt must actually have pushed a flag, or this proves nothing")
        XCTAssertEqual(observer.observedETag, previous,
                       "the new tag must not be stored until the adopt it describes has run")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "e-after",
                       "and it IS stored once the adopt completed")
    }

    /// Reads the stored session ETag at the moment `upsert` pushes a flag, which is the
    /// only vantage point from inside the adopt. Standalone rather than a subclass of the
    /// shared fake: a one-test hook does not belong in `MacTestSupport`.
    private final class ETagObservingClient: BridgeClientProtocol, @unchecked Sendable {
        private let conversations: ConversationsResult
        private let key: String
        private let lock = NSLock()
        private var _observed: String?
        /// The tag stored at the moment the adopt ran. `nil` means the adopt never
        /// reached a flag push, which would make the test vacuous.
        var observedETag: String? { lock.withLock { _observed } }

        nonisolated init(conversations: ConversationsResult, key: String) {
            self.conversations = conversations
            self.key = key
        }

        nonisolated var config: JesseConfig { JesseConfig(host: "studio", port: 8765, token: "tok") }

        nonisolated func setFlags(conversationId: String, favorite: FlagWrite?,
                                  archived: FlagWrite?) async throws {
            let seen = UserDefaults.standard.string(forKey: key)
            lock.withLock { _observed = seen }
        }

        nonisolated func listConversations(since: UInt64?, etag: String?) async throws
            -> ConversationsResult { conversations }

        // Inert surface: nothing below is on the session-refresh path.
        nonisolated func deleteConversation(_ conversationId: String) async throws {}
        nonisolated func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult {
            throw JesseError.notConfigured
        }
        nonisolated func send(mode: JesseMode, text: String, sessionId: String?,
                              conversationId: String, voice: Bool, instructions: String?,
                              floorOverride: String?, attachments: [JesseRequest.Attachment],
                              requestId: String, model: String?) async throws -> JesseSendResult {
            throw JesseError.notConfigured
        }
        nonisolated func result(jobId: String) async throws -> JesseResultState { .cancelled }
        nonisolated func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        nonisolated func hydrate(conversationId: String, after cursor: String?) async throws
            -> (turns: [HydratedTurn], nextCursor: String) { ([], cursor ?? "0:0") }
        nonisolated func title(text: String, conversationId: String?) async -> String? { nil }
        nonisolated func cancelJob(jobId: String) async throws {}
        nonisolated func health() async throws -> BridgeHealth { BridgeHealth(version: nil) }
        nonisolated func fetchDietSnapshot(date: String?) async throws -> DietSnapshot {
            throw DietFetchError.notConfigured
        }
        nonisolated func fetchPrompts() async throws -> PromptDefaults {
            throw JesseError.notConfigured
        }
    }

    // MARK: - The wake / foreground rule

    /// Only a RETURN to the foreground counts. Without the `old` check this fires on every
    /// re-evaluation that happens to carry `.active`, which on a Mac is a refetch per
    /// window focus change.
    func testOnlyARealReturnToActiveTriggersARefresh() {
        XCTAssertTrue(MacReconnect.isReturnToActive(from: .background, to: .active))
        XCTAssertTrue(MacReconnect.isReturnToActive(from: .inactive, to: .active))
        XCTAssertFalse(MacReconnect.isReturnToActive(from: .active, to: .active))
        XCTAssertFalse(MacReconnect.isReturnToActive(from: .active, to: .inactive))
        XCTAssertFalse(MacReconnect.isReturnToActive(from: .active, to: .background))
    }
}
