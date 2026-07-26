import XCTest
@testable import JesseNetworking

/// The bounded model-list retry, pinned at the layer of the defect: pure timing plus a
/// fully-injected loop, no network and no UI.
///
/// The defect these exist for: both model pickers used to run
/// `while !Task.isCancelled && state == nil { …fetch…; sleep(3) }`, whose only exit other
/// than cancellation was SUCCESS. Against a bridge that could not answer `GET /jesse/models`
/// — the usual state of a laptop, i.e. asleep — that re-fetched every 3 seconds for as long
/// as a conversation stayed open: measured at 44 requests in 135 s (19.6/min) with no
/// backoff and no end. An UNPAIRED app was worse still: it skipped the fetch and looped on
/// the sleep forever, spinning on a condition retrying could never satisfy.
///
/// So the load-bearing assertions here are the two the old loop failed: **it terminates**,
/// and **an unpaired app does no work at all**.
@MainActor
final class ModelListLoadTests: XCTestCase {

    private func state(_ id: String = "opus") -> ModelSwitchState {
        ModelSwitchState(active: id,
                         models: [ModelInfo(id: id, label: id, kind: "ambient",
                                            available: true, writesAllowed: true)])
    }

    // MARK: - The cadence

    func testDelaysAreFiniteAndBackOff() {
        XCTAssertEqual(ModelListRetry.delays, [1, 2, 4],
                       "a burst waits 1s, 2s, 4s — backed off, and it ENDS")
        XCTAssertNil(ModelListRetry.delay(afterAttempt: ModelListRetry.maxAttempts),
                     "there is no delay after the last attempt: the burst stops")
        XCTAssertEqual(ModelListRetry.delays.count, ModelListRetry.maxAttempts - 1,
                       "one fewer wait than attempts — no trailing sleep after the final try")
    }

    func testTheBurstIsBoundedInTotalTime() {
        // The whole point: an unreachable bridge costs a fixed, small amount of work, not a
        // standing poll. If someone widens the schedule, this is the line that argues back.
        XCTAssertLessThanOrEqual(ModelListRetry.delays.reduce(0, +), 30,
                                 "one burst spans well under half a minute in total")
    }

    // MARK: - The loop

    func testStopsAfterTheBoundedNumberOfAttemptsWhenTheBridgeNeverAnswers() async {
        var attempts = 0
        var waited: [TimeInterval] = []
        let result = await loadModelList(
            isConfigured: true,
            fetch: { attempts += 1; return nil },
            sleep: { waited.append($0) })

        XCTAssertNil(result)
        XCTAssertEqual(attempts, ModelListRetry.maxAttempts,
                       "a permanently unreachable bridge is tried a FIXED number of times")
        XCTAssertEqual(waited, ModelListRetry.delays,
                       "and the waits are the backed-off schedule, in order")
    }

    func testUnpairedAppDoesNoWorkAtAllRatherThanSpinning() async {
        var attempts = 0
        var sleeps = 0
        let result = await loadModelList(
            isConfigured: false,
            fetch: { attempts += 1; return nil },
            sleep: { _ in sleeps += 1 })

        XCTAssertNil(result)
        // The old loop skipped the fetch and slept forever. Both counters must be zero:
        // there is nothing to fetch, and sleeping to retry a fetch you will not make is
        // pure battery cost.
        XCTAssertEqual(attempts, 0, "an unpaired app never hits the network")
        XCTAssertEqual(sleeps, 0, "and never sleeps waiting to")
    }

    func testStopsImmediatelyOnTheFirstSuccess() async {
        var attempts = 0
        var sleeps = 0
        let result = await loadModelList(
            isConfigured: true,
            fetch: { attempts += 1; return self.state() },
            sleep: { _ in sleeps += 1 })

        XCTAssertEqual(result, state())
        XCTAssertEqual(attempts, 1, "a bridge that answers is asked exactly once")
        XCTAssertEqual(sleeps, 0, "and no wait is ever taken")
    }

    func testRecoversWithinTheBurstWhenTheBridgeComesBack() async {
        // The behaviour the retry exists for: a bridge that is slow or momentarily away
        // still fills the list in without the user doing anything.
        var attempts = 0
        var waited: [TimeInterval] = []
        let result = await loadModelList(
            isConfigured: true,
            fetch: {
                attempts += 1
                return attempts >= 3 ? self.state("glm-5.2") : nil
            },
            sleep: { waited.append($0) })

        XCTAssertEqual(result?.active, "glm-5.2")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(waited, [1, 2], "it stops waiting the moment it succeeds")
    }

    /// Closing the conversation cancels the picker's `.task`; the burst must stop there and
    /// not take its remaining attempts. (Measured: navigating back to the list already
    /// stopped the old loop, so this pins behaviour that worked and must keep working.)
    func testCancellationStopsTheBurstAtOnce() async {
        final class Box { var task: Task<ModelSwitchState?, Never>? }
        let box = Box()
        var attempts = 0
        var sleeps = 0
        box.task = Task { @MainActor in
            await loadModelList(
                isConfigured: true,
                fetch: {
                    attempts += 1
                    box.task?.cancel()   // the view went away mid-attempt
                    return nil
                },
                sleep: { _ in sleeps += 1 })
        }
        _ = await box.task?.value
        XCTAssertEqual(attempts, 1, "a cancelled burst makes no further attempt")
        XCTAssertEqual(sleeps, 0, "and takes no further wait")
    }
}
