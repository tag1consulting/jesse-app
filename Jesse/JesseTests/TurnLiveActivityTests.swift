import XCTest
@testable import Jesse

/// The pure turn-state → Live Activity mapping. The ActivityKit calls
/// (`request`/`update`/`end`) need a real device, but the *decision* of when to
/// begin, update, end, or do nothing — and the content it carries — is pure and
/// pinned here.
@MainActor
final class TurnLiveActivityTests: XCTestCase {

    private let started = Date(timeIntervalSince1970: 1_000_000)

    func testRunningWithNoLiveActivityBegins() {
        let step = TurnLiveActivity.step(isRunning: true, isLive: false,
                                         startedAt: started, activityLine: "Reading the vault…")
        XCTAssertEqual(step, .begin(.init(activityLine: "Reading the vault…", startedAt: started)))
    }

    func testRunningWithLiveActivityUpdates() {
        let step = TurnLiveActivity.step(isRunning: true, isLive: true,
                                         startedAt: started, activityLine: "Running a command…")
        XCTAssertEqual(step, .update(.init(activityLine: "Running a command…", startedAt: started)))
    }

    func testNotRunningWithLiveActivityEnds() {
        let step = TurnLiveActivity.step(isRunning: false, isLive: true,
                                         startedAt: nil, activityLine: nil)
        XCTAssertEqual(step, .end)
    }

    func testNotRunningWithNoActivityIsIdle() {
        let step = TurnLiveActivity.step(isRunning: false, isLive: false,
                                         startedAt: nil, activityLine: nil)
        XCTAssertEqual(step, .idle)
    }

    func testRunningWithoutStartDateIsIdle() {
        // No start instant ⇒ nothing to anchor the timer to; don't begin.
        let step = TurnLiveActivity.step(isRunning: true, isLive: false,
                                         startedAt: nil, activityLine: "x")
        XCTAssertEqual(step, .idle)
    }

    func testMissingActivityLineFallsBackToWaitingLine() {
        // A just-started turn has no tool-use line yet — the content must still be
        // meaningful, not blank.
        let begun = TurnLiveActivity.step(isRunning: true, isLive: false,
                                          startedAt: started, activityLine: nil)
        XCTAssertEqual(begun, .begin(.init(activityLine: TurnLiveActivity.waitingLine, startedAt: started)))

        let empty = TurnLiveActivity.step(isRunning: true, isLive: false,
                                          startedAt: started, activityLine: "")
        XCTAssertEqual(empty, .begin(.init(activityLine: TurnLiveActivity.waitingLine, startedAt: started)))
    }
}
