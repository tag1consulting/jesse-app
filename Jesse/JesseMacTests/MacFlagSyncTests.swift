import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

/// Cross-device favorite/archive convergence on the Mac: `MacCoordinator.refreshSessions`
/// reconciles server flags into local threads (last-writer-wins) and the toggle push
/// mirrors a local change up. Driven through a fake `BridgeClientProtocol` injected via
/// the coordinator's flag-client seam. The pure LWW rule is covered in the JesseCore
/// package (`FlagReconcilerTests`); these assert the Mac wiring.
@MainActor
final class MacFlagSyncTests: XCTestCase {

    /// Records `setFlags` off the main actor and serves a scripted session list. Only the
    /// two flag-sync methods do real work; the rest are inert stubs the sync path never
    /// calls.
    private final class FakeBridgeClient: BridgeClientProtocol, @unchecked Sendable {
        struct Call: Equatable { let conversationId: String; let favorite: FlagWrite?; let archived: FlagWrite? }
        private let lock = NSLock()
        private var _calls: [Call] = []
        var calls: [Call] { lock.withLock { _calls } }

        let scriptedConversations: ConversationsResult
        nonisolated init(conversations: ConversationsResult = .notModified) { self.scriptedConversations = conversations }

        nonisolated var config: JesseConfig { JesseConfig(host: "studio", port: 8765, token: "tok") }

        nonisolated func listConversations(since: UInt64?, etag: String?) async throws -> ConversationsResult {
            scriptedConversations
        }
        nonisolated func setFlags(conversationId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {
            lock.withLock { _calls.append(Call(conversationId: conversationId, favorite: favorite, archived: archived)) }
        }

        // Inert turn-running / hydrate surface — never exercised by the flag-sync path.
        nonisolated func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult { throw JesseError.notConfigured }
        nonisolated func send(mode: JesseMode, text: String, sessionId: String?,
                              conversationId: String, voice: Bool,
                              instructions: String?, floorOverride: String?,
                              attachments: [JesseRequest.Attachment], requestId: String,
                              model: String?) async throws -> JesseSendResult {
            throw JesseError.notConfigured
        }
        nonisolated func result(jobId: String) async throws -> JesseResultState { throw JesseError.notConfigured }
        nonisolated func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        nonisolated func hydrate(conversationId: String, after cursor: String?) async throws
            -> (turns: [HydratedTurn], nextCursor: String) {
            throw JesseError.notConfigured
        }
        nonisolated func title(text: String, conversationId: String?) async -> String? { nil }
        nonisolated func cancelJob(jobId: String) async throws {}
        nonisolated func deleteConversation(_ conversationId: String) async throws {}
        nonisolated func health() async throws -> BridgeHealth { BridgeHealth(version: nil) }
        nonisolated func fetchDietSnapshot(date: String?) async throws -> DietSnapshot { throw DietFetchError.notConfigured }
        nonisolated func fetchPrompts() async throws -> PromptDefaults { throw JesseError.notConfigured }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, TurnAttachment.self, TurnArtifact.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func makeCoordinator(_ fake: FakeBridgeClient) -> MacCoordinator {
        MacCoordinator(configStore: MacConfigStore(config: JesseConfig(host: "studio", port: 8765, token: "tok")),
                       makeClient: { _ in fake })
    }

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
        thread.setFavorite(false, now: Date(timeIntervalSince1970: 0.1))    // local clock ms 100
        context.insert(thread)
        try context.save()

        let fake = FakeBridgeClient(conversations: .conversations([summary("s1", favorite: true, favoriteMs: 200)], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake)
        await coordinator.refreshSessions(context: context)

        XCTAssertTrue(thread.isFavorite, "a strictly-newer server favorite is adopted")
        XCTAssertEqual(thread.favoriteUpdatedMs, 200)
        XCTAssertTrue(fake.calls.isEmpty, "adopting the server value pushes nothing")
    }

    func testRefreshPushesNewerLocalArchived() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        thread.conversationId = "s1"
        thread.sessionId = "sess-s1"
        thread.setArchived(true, now: Date(timeIntervalSince1970: 0.6))     // local clock ms 600
        context.insert(thread)
        try context.save()

        let fake = FakeBridgeClient(conversations: .conversations([summary("s1", archived: false, archivedMs: 200)], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake)
        await coordinator.refreshSessions(context: context)

        XCTAssertTrue(thread.isArchived, "local wins → not overwritten")
        XCTAssertEqual(fake.calls.count, 1, "the newer local value is pushed up")
        XCTAssertEqual(fake.calls.first?.archived, FlagWrite(value: true, updatedMs: 600))
        XCTAssertNil(fake.calls.first?.favorite, "only the changed flag is pushed")
    }

    // MARK: - Optimistic push on toggle

    func testToggleFavoriteIssuesPush() async throws {
        let thread = JesseThread(mode: .ask)
        thread.conversationId = "s1"
        thread.sessionId = "sess-s1"
        thread.toggleFavorite(now: Date(timeIntervalSince1970: 0.4))        // ms 400
        let fake = FakeBridgeClient()
        let coordinator = makeCoordinator(fake)

        coordinator.pushFavoriteChange(for: thread)
        await waitUntil("the favorite push to fire") { !fake.calls.isEmpty }

        XCTAssertEqual(fake.calls.first?.conversationId, "s1")
        XCTAssertEqual(fake.calls.first?.favorite, FlagWrite(value: true, updatedMs: 400))
    }

    /// A thread the sync has not bound to a conversation cannot push a flag: there is no key
    /// to push it under.
    ///
    /// The gate MOVED here, and deliberately narrowed. It used to be "no `sessionId`", which
    /// meant a brand-new conversation could not sync its flags until a reply landed; it is now
    /// "no `conversationId`", which a thread acquires at creation, so a new conversation's
    /// flags sync from its first turn. The only threads skipped are pre-upgrade rows the first
    /// sync has not bound yet.
    func testPushSkippedWithoutAConversationId() async throws {
        let thread = JesseThread(mode: .ask)
        thread.conversationId = nil   // a pre-upgrade row, not yet bound by a sync
        thread.toggleArchived()
        let fake = FakeBridgeClient()
        let coordinator = makeCoordinator(fake)

        coordinator.pushArchivedChange(for: thread)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(fake.calls.isEmpty, "no conversation id, nothing to push under")
    }

    /// The other half of that change: a brand-new conversation, with no session id at all,
    /// DOES push, because it already has its conversation identity.
    func testPushHappensForANewConversationWithNoSessionYet() async throws {
        let thread = JesseThread(mode: .ask)
        thread.sessionId = nil
        thread.toggleArchived()
        let fake = FakeBridgeClient()
        let coordinator = makeCoordinator(fake)

        coordinator.pushArchivedChange(for: thread)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fake.calls.count, 1,
                       "a conversation can sync its flags before its first reply lands")
        XCTAssertEqual(fake.calls.first?.conversationId, thread.conversationId)
    }
}
