import XCTest
import SwiftUI
@testable import Jesse

/// The send button's clock, pinned at the layer of the defect: a pure cadence function and
/// a `TimelineSchedule` whose entry sequence can be enumerated with no view host.
///
/// The defect these exist for: the button was driven by
/// `TimelineView(.animation(minimumInterval: 1/30, paused: !running))`. `.animation` is the
/// display-link-backed schedule, so for the ENTIRE duration of a turn the app was woken on
/// every display frame (120 Hz on ProMotion) — `minimumInterval` throttles the body
/// re-evaluation, not the wakeup. Measured on an idle simulator with one turn in flight and
/// a completely static screen: **121–141 interrupt wakeups/second and ~4% CPU, sustained**,
/// attributed by `sample` to `CADisplayLink → TimelineView.UpdateFilter → SendButton.body`.
/// Jesse turns routinely run for minutes.
///
/// Nothing on the button changes at that rate. The fill sweep finishes at
/// `fillSweepSeconds` and is a constant full-width rectangle afterwards; the only other
/// time-varying thing is a whole-second counter. So the tests below pin the two properties
/// that make the wakeups proportional to what is actually animating:
///  1. the cadence drops to 1 Hz once the sweep is done, and
///  2. an idle button (no turn running) schedules NOTHING.
@MainActor
final class SendButtonCadenceTests: XCTestCase {

    // MARK: - Cadence

    func testSmoothWhileTheSweepIsAnimating() {
        XCTAssertEqual(SendButtonCadence.tickInterval(elapsed: 0),
                       SendButtonCadence.sweepInterval)
        XCTAssertEqual(SendButtonCadence.tickInterval(elapsed: 5),
                       SendButtonCadence.sweepInterval)
        XCTAssertEqual(
            SendButtonCadence.tickInterval(elapsed: SendButtonCadence.fillSweepSeconds - 0.01),
            SendButtonCadence.sweepInterval,
            "still sweeping right up to the boundary")
    }

    func testDropsToOnceASecondOnceTheSweepIsComplete() {
        // The sweep width is `min(elapsed / fillSweepSeconds, 1)`, so from here on it is
        // pinned at 1 and the only thing that changes is `Int(elapsed)`.
        XCTAssertEqual(
            SendButtonCadence.tickInterval(elapsed: SendButtonCadence.fillSweepSeconds),
            SendButtonCadence.settledInterval)
        XCTAssertEqual(SendButtonCadence.tickInterval(elapsed: 600),
                       SendButtonCadence.settledInterval,
                       "a ten-minute turn ticks once a second, not once a frame")
    }

    func testSettledCadenceIsAWholeSecondBecauseThatIsWhatTheCounterNeeds() {
        XCTAssertEqual(SendButtonCadence.settledInterval, 1,
                       "the label shows whole seconds; a faster clock cannot change a pixel")
    }

    // MARK: - Schedule

    /// Enumerate the schedule's first `count` entries.
    private func entries(turnStart: Date?, from: Date, count: Int) -> [Date] {
        var it = SendButtonSchedule(turnStart: turnStart).entries(from: from, mode: .normal)
        var out: [Date] = []
        for _ in 0..<count {
            guard let d = it.next() else { break }
            out.append(d)
        }
        return out
    }

    /// The load-bearing one: with no turn running the schedule ENDS, so SwiftUI schedules no
    /// further update and the button holds no clock of any kind while the app is idle.
    func testIdleButtonSchedulesExactlyOneEntryAndThenStops() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        var it = SendButtonSchedule(turnStart: nil).entries(from: now, mode: .normal)
        XCTAssertEqual(it.next(), now, "renders once")
        XCTAssertNil(it.next(), "and never asks to be woken again")
    }

    func testRunningTurnStartsAtTheSweepCadence() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let got = entries(turnStart: start, from: start, count: 4)
        XCTAssertEqual(got.count, 4)
        for (a, b) in zip(got, got.dropFirst()) {
            XCTAssertEqual(b.timeIntervalSince(a), SendButtonCadence.sweepInterval, accuracy: 1e-9)
        }
    }

    func testScheduleCrossesOverToTheSettledCadenceAfterTheSweep() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        // Start enumerating from just past the sweep, the way SwiftUI re-asks mid-turn.
        let from = start.addingTimeInterval(SendButtonCadence.fillSweepSeconds + 0.5)
        let got = entries(turnStart: start, from: from, count: 3)
        for (a, b) in zip(got, got.dropFirst()) {
            XCTAssertEqual(b.timeIntervalSince(a), SendButtonCadence.settledInterval, accuracy: 1e-9)
        }
    }

    /// Low Power Mode asks for the cheap cadence; the sweep gives up its frame rate rather
    /// than the mode being ignored.
    func testLowFrequencyModeUsesTheSettledCadenceEvenDuringTheSweep() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var it = SendButtonSchedule(turnStart: start).entries(from: start, mode: .lowFrequency)
        let a = it.next()!
        let b = it.next()!
        XCTAssertEqual(b.timeIntervalSince(a), SendButtonCadence.settledInterval, accuracy: 1e-9)
    }

    func testEntriesAreStrictlyIncreasing() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let got = entries(turnStart: start, from: start, count: 500)
        XCTAssertEqual(got.count, 500)
        for (a, b) in zip(got, got.dropFirst()) {
            XCTAssertLessThan(a, b, "a TimelineSchedule must hand back increasing dates")
        }
    }

    /// The measured win, expressed as a bound the schedule must keep: over a two-minute
    /// turn the button asks to be woken on the order of a hundred times, not the ~14,400 a
    /// 120 Hz display link delivered.
    func testWakeupsOverALongTurnAreProportionalToWhatActuallyAnimates() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let horizon = start.addingTimeInterval(120)
        var it = SendButtonSchedule(turnStart: start).entries(from: start, mode: .normal)
        var ticks = 0
        while let d = it.next(), d <= horizon { ticks += 1 }

        // 10s of sweep at 30Hz (~300) plus 110 one-second ticks.
        XCTAssertLessThan(ticks, 500, "got \(ticks) ticks for a 2-minute turn")
        // And most of the turn must be the cheap cadence, not the sweep cadence.
        let sweepTicks = SendButtonCadence.fillSweepSeconds / SendButtonCadence.sweepInterval
        XCTAssertLessThan(Double(ticks) - sweepTicks, 130,
                          "after the sweep, a 110-second tail costs ~110 ticks")
    }
}
