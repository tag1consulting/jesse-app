import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// Cross-device favorite/archive convergence on iOS: the session-list pull reconciles
/// server-authoritative flags into local threads last-writer-wins, and a local toggle
/// best-effort pushes its change up. Driven through the real `RunCoordinator` + an
/// in-memory store + a fake client — no server. The pure LWW rule itself is covered in
/// the JesseCore package (`FlagReconcilerTests`); these assert the iOS wiring.
@MainActor
final class SessionFlagSyncTests: XCTestCase {

    /// Records `setFlags` off the main actor (the requirement is nonisolated) and serves a
    /// scripted session list. Only the methods the flag-sync path touches do real work; the
    /// turn-running methods are inert stubs.
    private final class FlagRecorder: @unchecked Sendable {
        struct Call: Equatable { let conversationId: String; let favorite: FlagWrite?; let archived: FlagWrite? }
        private let lock = NSLock()
        private var _calls: [Call] = []
        func record(_ c: Call) { lock.withLock { _calls.append(c) } }
        var calls: [Call] { lock.withLock { _calls } }
    }

    @MainActor
    private final class FakeFlagClient: JesseClientProtocol {
        let conversations: ConversationsResult
        let recorder = FlagRecorder()
        init(conversations: ConversationsResult = .notModified) { self.conversations = conversations }

        func listConversations(etag: String?) async throws -> ConversationsResult { conversations }
        nonisolated func setFlags(conversationId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {
            recorder.record(.init(conversationId: conversationId, favorite: favorite, archived: archived))
        }

        // Inert turn-running surface — never exercised by the flag-sync path.
        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?) async throws -> JesseSendResult {
            .reply(JesseReply(text: "", sessionId: nil), jobId: nil, conversationId: nil)
        }
        func result(jobId: String) async throws -> JesseResultState { .done(JesseReply(text: "", sessionId: nil)) }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func makeCoordinator(_ fake: FakeFlagClient) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake })
    }

    @MainActor
    private func summary(_ id: String, favorite: Bool = false, favoriteMs: UInt64 = 0,
                         archived: Bool = false, archivedMs: UInt64 = 0) -> ConversationSummary {
        ConversationSummary(conversationId: id, sessionId: "sess-\(id)", sessionIds: ["sess-\(id)"],
                            lastModified: 1_700_000_000, firstMessage: "hi", title: nil,
                       favorite: favorite, favoriteUpdatedMs: favoriteMs,
                       archived: archived, archivedUpdatedMs: archivedMs)
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 4, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Pull reconcile

    func testRefreshAdoptsNewerServerFavorite() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        thread.conversationId = "s1"
        thread.sessionId = "sess-s1"
        thread.setFavorite(false, now: Date(timeIntervalSince1970: 0.1))   // local clock ms 100
        context.insert(thread)
        try context.save()

        let fake = FakeFlagClient(conversations: .conversations([summary("s1", favorite: true, favoriteMs: 200)], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake)
        await coordinator.refreshSessions(context: context)

        XCTAssertTrue(thread.isFavorite, "a strictly-newer server favorite is adopted")
        XCTAssertEqual(thread.favoriteUpdatedMs, 200)
        XCTAssertTrue(fake.recorder.calls.isEmpty, "adopting the server value pushes nothing")
    }

    func testRefreshFlipsArchivedFromServer() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        thread.conversationId = "s1"
        thread.sessionId = "sess-s1"
        // No local archive change yet → zero clock, so any server clock wins.
        context.insert(thread)
        try context.save()

        let fake = FakeFlagClient(conversations: .conversations([summary("s1", archived: true, archivedMs: 50)], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake)
        await coordinator.refreshSessions(context: context)

        XCTAssertTrue(thread.isArchived, "the server archived flag flips the local thread")
        XCTAssertEqual(thread.archivedUpdatedMs, 50)
    }

    func testRefreshPushesNewerLocalFavorite() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        thread.conversationId = "s1"
        thread.sessionId = "sess-s1"
        thread.setFavorite(true, now: Date(timeIntervalSince1970: 0.3))    // local clock ms 300
        context.insert(thread)
        try context.save()

        let fake = FakeFlagClient(conversations: .conversations([summary("s1", favorite: false, favoriteMs: 200)], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake)
        await coordinator.refreshSessions(context: context)

        XCTAssertTrue(thread.isFavorite, "local wins → not overwritten")
        XCTAssertEqual(fake.recorder.calls.count, 1, "the newer local value is pushed up")
        XCTAssertEqual(fake.recorder.calls.first?.favorite, FlagWrite(value: true, updatedMs: 300))
    }

    func testRefreshSkipsThreadsWithoutSessionId() async throws {
        let context = try makeContext()
        let localOnly = JesseThread(mode: .ask)     // a pre-upgrade row the sync has not bound
        localOnly.conversationId = nil
        localOnly.setFavorite(true, now: Date(timeIntervalSince1970: 0.3))
        context.insert(localOnly)
        try context.save()

        // Server lists some other session; the local-only thread must be untouched.
        let fake = FakeFlagClient(conversations: .conversations([summary("other", favorite: false, favoriteMs: 999)], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake)
        await coordinator.refreshSessions(context: context)

        XCTAssertTrue(localOnly.isFavorite, "a thread with no session_id never reconciles")
        XCTAssertTrue(fake.recorder.calls.isEmpty)
    }

    // MARK: - Optimistic push on toggle

    func testToggleFavoriteIssuesPush() async throws {
        let thread = JesseThread(mode: .ask)
        thread.conversationId = "s1"
        thread.sessionId = "sess-s1"
        thread.toggleFavorite(now: Date(timeIntervalSince1970: 0.4))       // local user action, ms 400
        let fake = FakeFlagClient()
        let coordinator = makeCoordinator(fake)

        coordinator.pushFavoriteChange(for: thread)
        await waitUntil("the favorite push to fire") { !fake.recorder.calls.isEmpty }

        XCTAssertEqual(fake.recorder.calls.count, 1)
        XCTAssertEqual(fake.recorder.calls.first?.conversationId, "s1")
        XCTAssertEqual(fake.recorder.calls.first?.favorite, FlagWrite(value: true, updatedMs: 400))
        XCTAssertNil(fake.recorder.calls.first?.archived, "only the changed flag is pushed")
    }

    func testToggleArchivedIssuesPush() async throws {
        let thread = JesseThread(mode: .ask)
        thread.conversationId = "s1"
        thread.sessionId = "sess-s1"
        thread.toggleArchived(now: Date(timeIntervalSince1970: 0.7))       // ms 700
        let fake = FakeFlagClient()
        let coordinator = makeCoordinator(fake)

        coordinator.pushArchivedChange(for: thread)
        await waitUntil("the archived push to fire") { !fake.recorder.calls.isEmpty }

        XCTAssertEqual(fake.recorder.calls.first?.archived, FlagWrite(value: true, updatedMs: 700))
        XCTAssertNil(fake.recorder.calls.first?.favorite)
    }

    /// A thread the sync has not bound to a conversation cannot push: there is no key to push
    /// it under.
    ///
    /// The gate MOVED from `sessionId` to `conversationId`, and narrowed: a thread acquires its
    /// conversation id at creation, so the only threads skipped now are pre-upgrade rows the
    /// first sync has not bound yet. See the companion test below for the other half.
    func testPushSkippedWithoutAConversationId() async throws {
        let thread = JesseThread(mode: .ask)
        thread.conversationId = nil   // a pre-upgrade row, not yet bound by a sync
        thread.toggleFavorite()
        let fake = FakeFlagClient()
        let coordinator = makeCoordinator(fake)

        coordinator.pushFavoriteChange(for: thread)
        // Give any (erroneously-scheduled) task a moment; there should be none.
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(fake.recorder.calls.isEmpty, "no conversation id, nothing to push under")
    }

    /// The other half: a brand-new conversation with NO session id at all does push, because it
    /// already holds its conversation identity. Under the old `sessionId` gate this was silently
    /// dropped until a reply landed.
    func testPushHappensForANewConversationWithNoSessionYet() async throws {
        let thread = JesseThread(mode: .ask)
        thread.sessionId = nil
        thread.toggleFavorite()
        let fake = FakeFlagClient()
        let coordinator = makeCoordinator(fake)

        coordinator.pushFavoriteChange(for: thread)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fake.recorder.calls.count, 1,
                       "a conversation can sync its flags before its first reply lands")
        XCTAssertEqual(fake.recorder.calls.first?.conversationId, thread.conversationId)
    }
}
