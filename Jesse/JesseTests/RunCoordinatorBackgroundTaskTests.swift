import XCTest
import SwiftData
import UIKit
@testable import Jesse
import JesseCore

/// (M7) The background-task expiration handler must always end the *granted*
/// identifier, even when it fires before `send` records the handle. Pre-fix the
/// handler ended whatever the `backgroundIDs` dict held; if expiration raced
/// ahead of the store, the dict was empty and the assertion leaked.
@MainActor
final class RunCoordinatorBackgroundTaskTests: XCTestCase {

    /// A background tasker that, on `beginTask`, sets the granted id into the handle
    /// and then immediately fires the expiration handler — modeling the system
    /// calling expiration *during* `beginBackgroundTask`, i.e. before the caller
    /// (`send`) has stored the handle in its dictionary.
    @MainActor
    private final class RacingTasker: BackgroundTasking {
        let granted = UIBackgroundTaskIdentifier(rawValue: 42)
        var ended: [UIBackgroundTaskIdentifier] = []

        func beginTask(name: String, handle: BackgroundTaskHandle, expiration: @escaping @MainActor @Sendable () -> Void) {
            handle.id = granted
            // Fire expiration synchronously, before this returns to `send` and
            // therefore before `send` stores the handle in `backgroundIDs`.
            expiration()
        }

        func endTask(_ id: UIBackgroundTaskIdentifier) { ended.append(id) }
    }

    /// A client that completes the turn promptly (no parking), so the turn unwinds
    /// cleanly within the test and the task tail's own `endBackground` runs too —
    /// which must NOT double-end the grant.
    @MainActor
    private final class DoneClient: JesseClientProtocol {
        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            .running(jobId: "job-bg")
        }
        func result(jobId: String) async throws -> JesseResultState {
            .done(JesseReply(text: "ok", sessionId: "sess"))
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @MainActor
    func testExpirationBeforeStoreEndsGrantedID() async throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let tasker = RacingTasker()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in DoneClient() },
            backgroundTasker: tasker)

        let thread = JesseThread(mode: .ask)
        // `send` is synchronous up to spawning the turn task; the racing tasker
        // fires expiration during `beginTask`, before the handle is stored.
        coordinator.send(thread: thread, text: "a question", voice: false, context: context)

        // Synchronously after `send`, only the expiration-fired end has run — and it
        // ended the granted id despite the race (pre-fix this was empty → a leak).
        XCTAssertEqual(tasker.ended, [tasker.granted],
                       "the expiration handler must end the granted id even when it fires before the store")

        // Let the turn complete; its task tail also calls endBackground, which must
        // be a no-op (the grant is released exactly once).
        let deadline = Date().addingTimeInterval(4)
        while coordinator.isRunning(thread.id) {
            if Date() > deadline { XCTFail("turn did not complete"); break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(tasker.ended, [tasker.granted],
                       "the grant is ended exactly once — the task tail must not double-end it")
    }
}
