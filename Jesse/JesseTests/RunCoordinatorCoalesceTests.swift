import XCTest
import SwiftData
@testable import Jesse

/// Streaming re-eval perf: the coordinator publishes the observable `partialText`
/// at most ~10Hz regardless of how fast delta chunks arrive, so a long reply no
/// longer re-evaluates the transcript body (and fires its auto-scroll) once per
/// chunk. The coalescing is throttled by *rate only* — never by dropping content:
/// the final published text must equal the exact concatenation of every chunk, and
/// the last chunk must always flush.
///
/// Both facts are driven deterministically through injected seams: a frozen `now`
/// (so every delta after the first lands inside the same cooldown window) and a
/// long `flushSleep` (so the single deferred flush can't fire before the stream
/// ends and cancels it). The observed publish count is then exactly two — the first
/// delta's immediate publish plus the terminal tail flush — for any number of
/// chunks.
@MainActor
final class RunCoordinatorCoalesceTests: XCTestCase {

    /// A hand-driven streaming client (mirrors `RunCoordinatorStreamTests`), kept
    /// local so this file's determinism assumptions (poll never resolves) are
    /// self-contained.
    @MainActor
    private final class StreamingFakeClient: JesseClientProtocol {
        var onStreamStarted: (() -> Void)?
        private var continuation: AsyncThrowingStream<JesseStreamEvent, Error>.Continuation?

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            .running(jobId: "job-coalesce")
        }

        // The poll never resolves, so `partialText` is never cleared by a terminal
        // outcome — the test can assert the coalesced buffer after the stream ends.
        func result(jobId: String) async throws -> JesseResultState { .running }
        func cancelJob(jobId: String) async throws {}

        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { cont in
                self.continuation = cont
                self.onStreamStarted?()
            }
        }

        func emit(_ event: JesseStreamEvent) { continuation?.yield(event) }
        func finishStream() { continuation?.finish() }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }

    /// Poll until `condition` holds or the timeout elapses — robust to the slower CI
    /// runner where a fixed sleep would flake.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func testRapidDeltasPublishFarFewerTimesThanChunksAndFinalTextIsExact() async throws {
        let context = try makeContext()
        let fake = StreamingFakeClient()
        let opened = expectation(description: "stream opened")
        fake.onStreamStarted = { opened.fulfill() }

        // A frozen clock: every delta after the first is inside the cooldown, so the
        // coalescer publishes once immediately and defers the rest. A long flush
        // sleep guarantees the single deferred flush can't fire on its own before
        // the stream ends and cancels it — keeping the publish count deterministic.
        let frozen = Date(timeIntervalSince1970: 1_000_000)
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            now: { frozen },
            flushSleep: { _ in try? await Task.sleep(for: .seconds(30)) })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "stream a long reply", voice: false, context: context)
        await fulfillment(of: [opened], timeout: 2)

        // Fire a burst of deltas far faster than any redraw cadence.
        let n = 200
        let chunks = (0..<n).map { "c\($0) " }
        for chunk in chunks { fake.emit(.delta(chunk)) }
        let expected = chunks.joined()

        // Wait until the consume loop has drained the burst (the first delta's
        // immediate publish landed) — but the frozen clock + long flush sleep mean
        // no further publish can occur, so the count stays pinned at one.
        await waitUntil { coordinator.partialText(for: thread.id) != nil }

        // The rate is bounded: the burst produced one publish, not one per chunk.
        XCTAssertLessThan(coordinator.partialPublishCount, n / 10,
                          "publish count must be ≪ the delta count — the coalescing win")
        XCTAssertEqual(coordinator.partialPublishCount, 1,
                       "a frozen clock collapses the whole burst into one immediate publish")

        // End the stream bare (no terminal frame): the tail must flush so the final
        // published text is the exact concatenation, with nothing left in the buffer.
        fake.finishStream()
        await waitUntil { coordinator.partialText(for: thread.id) == expected }

        XCTAssertEqual(coordinator.partialText(for: thread.id), expected,
                       "the final partial must equal the exact concatenation of every chunk")
        XCTAssertEqual(coordinator.partialPublishCount, 2,
                       "one immediate publish + one terminal tail flush — no per-chunk churn")
    }

    /// The deferred flush surfaces a chunk that arrived inside the cooldown even if
    /// no further delta and no terminal frame follows — the tail is never stranded.
    /// Uses the real (default) clock + a short real flush sleep and simply waits past
    /// the interval boundary.
    @MainActor
    func testDeferredFlushSurfacesTailWithoutAFurtherDelta() async throws {
        let context = try makeContext()
        let fake = StreamingFakeClient()
        let opened = expectation(description: "stream opened")
        fake.onStreamStarted = { opened.fulfill() }
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "tail", voice: false, context: context)
        await fulfillment(of: [opened], timeout: 2)

        // First delta publishes immediately.
        fake.emit(.delta("first "))
        await waitUntil { coordinator.partialText(for: thread.id) == "first " }
        XCTAssertEqual(coordinator.partialText(for: thread.id), "first ")

        // A second delta lands inside the cooldown → deferred, not yet published. The
        // deferred flush must surface it within one interval, with no further delta
        // and no terminal frame.
        fake.emit(.delta("second"))
        await waitUntil { coordinator.partialText(for: thread.id) == "first second" }
        XCTAssertEqual(coordinator.partialText(for: thread.id), "first second",
                       "a buffered tail must surface within one interval via the deferred flush")
    }
}
