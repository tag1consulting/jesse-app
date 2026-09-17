import XCTest
@testable import JesseCore

/// The decisions behind the two turns the iPhone fires by itself when new health data lands.
///
/// The observer queries cannot be unit-tested (and background delivery does not run on the
/// Simulator at all), so every rule about WHEN to fire is a pure function in
/// `HealthAutoFire.swift`, and this is where it is held down. Dates are built in a fixed zone
/// so the 04:00 diet-day boundary is asserted against a wall clock, not against UTC.
final class HealthAutoFireTests: XCTestCase {

    private let rome: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }()

    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        rome.date(from: DateComponents(year: 2026, month: month, day: day,
                                       hour: hour, minute: minute))!
    }

    private func fires(sample: Date, lastFired: String?, now: Date) -> Bool {
        HealthAutoFire.shouldFireMorningRefresh(newestSampleDate: sample, lastFiredDay: lastFired,
                                                now: now, calendar: rome)
    }

    // MARK: - The diet day

    func testTheDietDayTurnsOverAtFourInTheMorning() {
        XCTAssertEqual(DietDay.stamp(for: at(9, 8, 3, 59), calendar: rome), "2026-09-07")
        XCTAssertEqual(DietDay.stamp(for: at(9, 8, 4, 0), calendar: rome), "2026-09-08")
        XCTAssertEqual(DietDay.stamp(for: at(9, 8, 0, 30), calendar: rome), "2026-09-07",
                       "half past midnight is the end of an evening, not the start of a day")
    }

    /// The stamp is compared with the bridge's ISO `dietDay` and stored; a phone on another
    /// calendar system must not spell the year differently.
    func testTheDietDayIsAlwaysGregorian() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = rome.timeZone
        XCTAssertEqual(DietDay.stamp(for: at(9, 8, 9), calendar: buddhist), "2026-09-08")
    }

    // MARK: - Body mass → the morning refresh

    func testTodaysFirstReadingFires() {
        XCTAssertTrue(fires(sample: at(9, 8, 6, 15), lastFired: nil, now: at(9, 8, 6, 16)))
    }

    func testASecondReadingOnADayAlreadyFiredDoesNot() {
        XCTAssertFalse(fires(sample: at(9, 8, 16, 0), lastFired: "2026-09-08", now: at(9, 8, 16, 1)))
    }

    /// THE case that matters: a phone syncing an old reading from a scale must not roll
    /// anything, whatever the last-fired day says.
    func testAReadingFromYesterdayNeverFires() {
        XCTAssertFalse(fires(sample: at(9, 7, 7, 0), lastFired: nil, now: at(9, 8, 6, 16)))
        XCTAssertFalse(fires(sample: at(9, 7, 7, 0), lastFired: "2026-09-06", now: at(9, 8, 6, 16)))
    }

    func testTodaysReadingFiresWhenTheLastFireWasYesterday() {
        XCTAssertTrue(fires(sample: at(9, 8, 9, 30), lastFired: "2026-09-07", now: at(9, 8, 9, 31)))
    }

    /// Amendment one. A 00:30 reading belongs to the PREVIOUS diet day: seen that same night
    /// after the day's refresh already ran, or seen the next morning, it fires nothing. A plain
    /// calendar-day rule would fire in both cases.
    func testAHalfPastMidnightReadingBelongsToThePreviousDietDay() {
        XCTAssertFalse(fires(sample: at(9, 8, 0, 30), lastFired: "2026-09-07", now: at(9, 8, 0, 31)))
        XCTAssertFalse(fires(sample: at(9, 8, 0, 30), lastFired: "2026-09-07", now: at(9, 8, 6, 0)))
    }

    func testAHalfPastFourReadingBelongsToToday() {
        XCTAssertTrue(fires(sample: at(9, 8, 4, 30), lastFired: "2026-09-07", now: at(9, 8, 4, 31)))
    }

    /// The app suspended across the boundary and woke on the far side of it: a reading taken
    /// before 04:00 and delivered after is yesterday's, and one taken after is today's.
    func testADayBoundaryCrossedWhileSuspended() {
        XCTAssertFalse(fires(sample: at(9, 8, 3, 50), lastFired: "2026-09-07", now: at(9, 8, 4, 10)))
        XCTAssertFalse(fires(sample: at(9, 7, 22, 0), lastFired: "2026-09-07", now: at(9, 8, 9, 0)))
        XCTAssertTrue(fires(sample: at(9, 8, 6, 10), lastFired: "2026-09-07", now: at(9, 8, 9, 0)))
    }

    // MARK: - Workouts → the workout log

    private func workout(_ id: String, endingAt end: Date) -> ObservedWorkout {
        ObservedWorkout(id: id, end: end)
    }

    /// Observe, wait out the settle, fire, and mark fired — what the trigger does.
    private func fireAfterSettling(_ observed: [ObservedWorkout], ledger: WorkoutLedger,
                                   at time: Date) -> (due: [ObservedWorkout], ledger: WorkoutLedger) {
        let first = WorkoutAutoLog.workoutsToFire(observed: observed, ledger: ledger, now: time)
        XCTAssertTrue(first.due.isEmpty, "nothing fires on the notification itself")
        let settled = time.addingTimeInterval(WorkoutAutoLog.settle)
        let second = WorkoutAutoLog.workoutsToFire(observed: [], ledger: first.ledger, now: settled)
        return (second.due, WorkoutAutoLog.markFired(second.due, in: second.ledger, now: settled))
    }

    /// 2026-09-08: a 10:04 run and treadmill walks at 11:51 and 16:43. A day guard would have
    /// logged one of the three; identity logs all three.
    func testThreeDistinctWorkoutsOnOneDietDayAllFire() {
        let run = workout("run", endingAt: at(9, 8, 10, 40))
        let walk1 = workout("walk-1151", endingAt: at(9, 8, 12, 20))
        let walk2 = workout("walk-1643", endingAt: at(9, 8, 17, 10))

        var ledger = WorkoutLedger()
        var turns: [[ObservedWorkout]] = []
        for (w, seen) in [(run, at(9, 8, 10, 41)), (walk1, at(9, 8, 12, 21)), (walk2, at(9, 8, 17, 11))] {
            let result = fireAfterSettling([w], ledger: ledger, at: seen)
            turns.append(result.due)
            ledger = result.ledger
        }
        XCTAssertEqual(turns, [[run], [walk1], [walk2]], "one turn per session, three turns")
        XCTAssertEqual(Set(ledger.fired.keys), ["run", "walk-1151", "walk-1643"])
    }

    func testTheSameWorkoutObservedTwiceFiresOnce() {
        let run = workout("run", endingAt: at(9, 8, 10, 40))
        let result = fireAfterSettling([run, run], ledger: WorkoutLedger(), at: at(9, 8, 10, 41))
        XCTAssertEqual(result.due, [run])

        let again = WorkoutAutoLog.workoutsToFire(observed: [run], ledger: result.ledger,
                                                  now: at(9, 8, 11, 0))
        XCTAssertTrue(again.due.isEmpty)
        XCTAssertTrue(again.ledger.pending.isEmpty, "a fired workout is not even held as pending")
        XCTAssertNil(again.nextCheck)
    }

    func testAWorkoutAlreadyFiredDoesNotFire() {
        let run = workout("run", endingAt: at(9, 8, 10, 40))
        let ledger = WorkoutLedger(fired: ["run": run.end])
        let later = at(9, 8, 20, 0)
        let decision = WorkoutAutoLog.workoutsToFire(observed: [run], ledger: ledger, now: later)
        XCTAssertTrue(decision.due.isEmpty)
        let settled = WorkoutAutoLog.workoutsToFire(observed: [], ledger: decision.ledger,
                                                    now: later.addingTimeInterval(3600))
        XCTAssertTrue(settled.due.isEmpty)
    }

    /// Imports land minutes apart; everything inside the settle window is ONE turn.
    func testABurstInsideTheSettleWindowIsOneTurn() {
        let t0 = at(9, 8, 17, 0)
        let a = workout("a", endingAt: t0.addingTimeInterval(-3600))
        let b = workout("b", endingAt: t0.addingTimeInterval(-1800))
        let c = workout("c", endingAt: t0.addingTimeInterval(-60))

        var decision = WorkoutAutoLog.workoutsToFire(observed: [a], ledger: WorkoutLedger(), now: t0)
        XCTAssertEqual(decision.nextCheck, t0.addingTimeInterval(WorkoutAutoLog.settle))
        decision = WorkoutAutoLog.workoutsToFire(observed: [b], ledger: decision.ledger,
                                                 now: t0.addingTimeInterval(30))
        XCTAssertTrue(decision.due.isEmpty)
        XCTAssertEqual(decision.nextCheck, t0.addingTimeInterval(WorkoutAutoLog.settle),
                       "the window is measured from the burst's FIRST workout, so it cannot slide")
        decision = WorkoutAutoLog.workoutsToFire(observed: [c], ledger: decision.ledger,
                                                 now: t0.addingTimeInterval(90))
        XCTAssertTrue(decision.due.isEmpty)

        let settled = WorkoutAutoLog.workoutsToFire(observed: [], ledger: decision.ledger,
                                                    now: t0.addingTimeInterval(WorkoutAutoLog.settle))
        XCTAssertEqual(settled.due, [a, b, c], "one turn for the whole burst, oldest first")
        XCTAssertNil(settled.nextCheck)
    }

    /// Backfill is not a reason to skip: a workout that reaches HealthKit three days late and
    /// was never fired for is new data.
    func testAWorkoutThatEndedThreeDaysAgoAndNeverFiredDoesFire() {
        let old = workout("backfilled", endingAt: at(9, 5, 9, 0))
        let result = fireAfterSettling([old], ledger: WorkoutLedger(), at: at(9, 8, 12, 0))
        XCTAssertEqual(result.due, [old])
    }

    /// A workout past the horizon never fires: its fired entry would be forgotten at once, and
    /// it would fire again on every observation after.
    func testAWorkoutPastTheHorizonNeverFires() {
        let ancient = workout("ancient", endingAt: at(8, 1, 9, 0))
        let result = fireAfterSettling([ancient], ledger: WorkoutLedger(), at: at(9, 8, 12, 0))
        XCTAssertTrue(result.due.isEmpty)
        XCTAssertTrue(result.ledger.pending.isEmpty)
    }

    func testTheFiredSetStaysBounded() {
        let now = at(9, 8, 12, 0)
        // Aged out: every entry older than the horizon is dropped.
        let stale = WorkoutLedger(fired: ["old": now.addingTimeInterval(-WorkoutAutoLog.horizon - 60),
                                          "fresh": now.addingTimeInterval(-3600)])
        let aged = WorkoutAutoLog.workoutsToFire(observed: [], ledger: stale, now: now).ledger
        XCTAssertEqual(Set(aged.fired.keys), ["fresh"])

        // Capped: however many there are, at most `maxFired` survive — the newest.
        var many: [String: Date] = [:]
        for i in 0..<(WorkoutAutoLog.maxFired + 40) {
            many["w\(i)"] = now.addingTimeInterval(-Double(i) * 60)
        }
        let capped = WorkoutAutoLog.markFired([], in: WorkoutLedger(fired: many), now: now)
        XCTAssertEqual(capped.fired.count, WorkoutAutoLog.maxFired)
        XCTAssertNotNil(capped.fired["w0"], "the newest is kept")
        XCTAssertNil(capped.fired["w\(WorkoutAutoLog.maxFired + 39)"], "the oldest is dropped")
    }

    func testAnEmptyObservationProducesNoTurn() {
        let decision = WorkoutAutoLog.workoutsToFire(observed: [], ledger: WorkoutLedger(),
                                                     now: at(9, 8, 12, 0))
        XCTAssertTrue(decision.due.isEmpty)
        XCTAssertNil(decision.nextCheck)
        XCTAssertEqual(decision.ledger, WorkoutLedger())
    }

    /// The first observation on a fresh install is what was already there, not news.
    func testTheBaselineCountsExistingWorkoutsAsFired() {
        let now = at(9, 8, 12, 0)
        let existing = [workout("a", endingAt: at(9, 7, 9, 0)), workout("b", endingAt: at(9, 8, 8, 0))]
        let ledger = WorkoutAutoLog.baseline(existing, in: WorkoutLedger(), now: now)
        let decision = WorkoutAutoLog.workoutsToFire(observed: existing, ledger: ledger,
                                                     now: now.addingTimeInterval(3600))
        XCTAssertTrue(decision.due.isEmpty)
        XCTAssertTrue(decision.ledger.pending.isEmpty)
    }

    /// A workout that lands while the previous burst's turn is in flight is not swept into it
    /// without its own settle.
    func testALeftoverAfterAFireStartsItsOwnSettle() {
        let t0 = at(9, 8, 17, 0)
        let a = workout("a", endingAt: t0.addingTimeInterval(-600))
        let late = workout("late", endingAt: t0.addingTimeInterval(100))
        let first = WorkoutAutoLog.workoutsToFire(observed: [a], ledger: WorkoutLedger(), now: t0)
        let settledAt = t0.addingTimeInterval(WorkoutAutoLog.settle)
        let due = WorkoutAutoLog.workoutsToFire(observed: [], ledger: first.ledger, now: settledAt)
        // `late` arrives while the turn for `a` is being sent.
        let during = WorkoutAutoLog.workoutsToFire(observed: [late], ledger: due.ledger,
                                                   now: settledAt.addingTimeInterval(1))
        let after = WorkoutAutoLog.markFired(due.due, in: during.ledger,
                                             now: settledAt.addingTimeInterval(2))
        XCTAssertEqual(Array(after.pending.keys), ["late"])
        let next = WorkoutAutoLog.workoutsToFire(observed: [], ledger: after,
                                                 now: settledAt.addingTimeInterval(3))
        XCTAssertTrue(next.due.isEmpty, "the leftover waits out a settle of its own")
        XCTAssertEqual(next.nextCheck, settledAt.addingTimeInterval(2 + WorkoutAutoLog.settle))
    }

    func testTheLedgerRoundTripsThroughJSON() throws {
        let ledger = WorkoutLedger(fired: ["a": at(9, 8, 10, 0)], pending: ["b": at(9, 8, 11, 0)],
                                   burstStartedAt: at(9, 8, 11, 1))
        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutLedger.self, from: data), ledger)
    }

    // MARK: - Send, hold, or say it already ran

    /// A day that already ran stops the automatic weigh-in whether or not the bridge is
    /// reachable. The button never asks with `true`; `HealthTurnTests` pins that it sends.
    func testADayThatAlreadyRanWinsOnlineAndOffline() {
        XCTAssertEqual(HealthTurnRoute.decide(alreadyRanToday: false, isReadOnly: false), .send)
        XCTAssertEqual(HealthTurnRoute.decide(alreadyRanToday: true, isReadOnly: false), .alreadyRan)
        XCTAssertEqual(HealthTurnRoute.decide(alreadyRanToday: true, isReadOnly: true), .alreadyRan)
    }

    func testOfflineHoldsRatherThanSends() {
        XCTAssertEqual(HealthTurnRoute.decide(alreadyRanToday: false, isReadOnly: true), .capture)
    }

    // MARK: - The prompts

    /// The automatic weigh-in and the button send the same bytes; the thread's origin is what
    /// tells them apart, so no prefix is needed and this stays a plain equality.
    @MainActor
    func testTheAutomaticWeighInSendsTheButtonsExactText() {
        XCTAssertEqual(HealthAutoTurn.morningRefresh.prompt, HealthNewDay.prompt)
    }

    @MainActor
    func testTheWorkoutLogPromptKeepsItsLoadBearingWords() {
        let prompt = HealthAutoTurn.workoutLog.prompt
        XCTAssertEqual(prompt, HealthWorkoutLog.prompt)
        let words = Set(prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        for word in ["log", "exercise", "workout", "health"] {
            XCTAssertTrue(words.contains(word), "'\(word)' must stay a whole word in the prompt")
        }
        XCTAssertTrue(prompt.contains("Do only this."), "it names its own scope")
        XCTAssertTrue(prompt.contains("Do not run start of day"))
        XCTAssertTrue(prompt.contains("diet-logs/exercise-log.csv"),
                      "it diffs against the CSV rather than trusting the app")
    }
}
