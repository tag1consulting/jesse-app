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
        struct Call: Equatable { let sessionId: String; let favorite: FlagWrite?; let archived: FlagWrite? }
        private let lock = NSLock()
        private var _calls: [Call] = []
        var calls: [Call] { lock.withLock { _calls } }

        let scriptedSessions: SessionsResult
        nonisolated init(sessions: SessionsResult = .notModified) { self.scriptedSessions = sessions }

        nonisolated var config: JesseConfig { JesseConfig(host: "studio", port: 8765, token: "tok") }

        nonisolated func listSessions(since: UInt64?, etag: String?) async throws -> SessionsResult {
            scriptedSessions
        }
        nonisolated func setFlags(sessionId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {
            lock.withLock { _calls.append(Call(sessionId: sessionId, favorite: favorite, archived: archived)) }
        }

        // Inert turn-running / hydrate surface — never exercised by the flag-sync path.
        nonisolated func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult { throw JesseError.notConfigured }
        nonisolated func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                              instructions: String?, floorOverride: String?,
                              attachments: [JesseRequest.Attachment], requestId: String?) async throws -> JesseSendResult {
            throw JesseError.notConfigured
        }
        nonisolated func result(jobId: String) async throws -> JesseResultState { throw JesseError.notConfigured }
        nonisolated func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        nonisolated func hydrate(sessionId: String, after: UInt64) async throws -> (turns: [HydratedTurn], nextOffset: UInt64) {
            throw JesseError.notConfigured
        }
        nonisolated func title(text: String, sessionId: String?) async -> String? { nil }
        nonisolated func cancelJob(jobId: String) async throws {}
        nonisolated func deleteSession(_ sessionId: String) async throws {}
        nonisolated func health() async throws -> BridgeHealth { BridgeHealth(version: nil) }
        nonisolated func fetchDietSnapshot(date: String?) async throws -> DietSnapshot { throw DietFetchError.notConfigured }
        nonisolated func fetchPrompts() async throws -> PromptDefaults { throw JesseError.notConfigured }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, TurnAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func makeCoordinator(_ fake: FakeBridgeClient) -> MacCoordinator {
        MacCoordinator(configStore: MacConfigStore(config: JesseConfig(host: "studio", port: 8765, token: "tok")),
                       makeFlagClient: { _ in fake })
    }

    private func summary(_ id: String, favorite: Bool = false, favoriteMs: UInt64 = 0,
                         archived: Bool = false, archivedMs: UInt64 = 0) -> SessionSummary {
        SessionSummary(sessionId: id, lastModified: 1_700_000_000, firstMessage: "hi", title: nil,
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
        thread.sessionId = "s1"
        thread.setFavorite(false, now: Date(timeIntervalSince1970: 0.1))    // local clock ms 100
        context.insert(thread)
        try context.save()

        let fake = FakeBridgeClient(sessions: .sessions([summary("s1", favorite: true, favoriteMs: 200)], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake)
        await coordinator.refreshSessions(context: context)

        XCTAssertTrue(thread.isFavorite, "a strictly-newer server favorite is adopted")
        XCTAssertEqual(thread.favoriteUpdatedMs, 200)
        XCTAssertTrue(fake.calls.isEmpty, "adopting the server value pushes nothing")
    }

    func testRefreshPushesNewerLocalArchived() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        thread.sessionId = "s1"
        thread.setArchived(true, now: Date(timeIntervalSince1970: 0.6))     // local clock ms 600
        context.insert(thread)
        try context.save()

        let fake = FakeBridgeClient(sessions: .sessions([summary("s1", archived: false, archivedMs: 200)], deleted: [], etag: "e1"))
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
        thread.sessionId = "s1"
        thread.toggleFavorite(now: Date(timeIntervalSince1970: 0.4))        // ms 400
        let fake = FakeBridgeClient()
        let coordinator = makeCoordinator(fake)

        coordinator.pushFavoriteChange(for: thread)
        await waitUntil("the favorite push to fire") { !fake.calls.isEmpty }

        XCTAssertEqual(fake.calls.first?.sessionId, "s1")
        XCTAssertEqual(fake.calls.first?.favorite, FlagWrite(value: true, updatedMs: 400))
    }

    func testPushSkippedWithoutSessionId() async throws {
        let thread = JesseThread(mode: .ask)   // no sessionId
        thread.toggleArchived()
        let fake = FakeBridgeClient()
        let coordinator = makeCoordinator(fake)

        coordinator.pushArchivedChange(for: thread)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(fake.calls.isEmpty, "no session_id → nothing to push")
    }
}
