import Foundation

// The DECISIONS behind the two turns the iPhone fires by itself when new health data lands:
// when a body-mass reading should run the morning refresh, and which new workouts should
// send the workout log. A peer of `HealthNewDay.swift` and `HealthWorkoutLog.swift`.
//
// Everything that can be wrong about WHEN to fire lives here, as functions of plain values,
// because the part that cannot be tested is the part that talks to HealthKit: observer and
// anchored queries have no seam, and background delivery does not run on the Simulator at
// all. The iOS file that owns those queries only gathers dates and identifiers and asks.
//
// ISOLATION. This target defaults to MainActor. The pure decisions are `nonisolated`, as in
// `MorningRoutine.swift`, so a plain synchronous test can call them. `HealthAutoTurn` keeps
// the default, because it reads `HealthNewDay.prompt`, which does too.

// MARK: - The diet day

/// **The diet day** an instant belongs to: the calendar date, in the calendar's zone, of the
/// instant minus four hours.
///
/// The one definition bridge 0.92.0 settled on for the diet path, reproduced here rather than
/// approximated. Four in the morning is where nobody is eating, so a snack at 01:00 belongs to
/// the evening before it, and a weigh-in at 00:30 is the last reading of yesterday rather than
/// the first of today. Treating "today" as the plain calendar date is the class of bug 0.92.0
/// removed on the bridge's side of the same boundary.
public nonisolated enum DietDay {
    /// Where the diet day turns over, in hours after local midnight.
    public static let boundaryHours = 4

    /// The diet day of `date`, spelled `yyyy-MM-dd` exactly as the bridge's `dietDay` is.
    ///
    /// Always GREGORIAN, in the given calendar's zone: the stamp is compared with the
    /// bridge's ISO date and stored as the last-fired day, and a phone set to a Buddhist or
    /// Japanese calendar must not spell the year differently from the vault.
    public static func stamp(for date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let shifted = date.addingTimeInterval(-TimeInterval(boundaryHours) * 3600)
        let c = gregorian.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Body mass → the morning refresh

public nonisolated enum HealthAutoFire {
    /// **Whether a new body-mass reading should run the morning refresh.**
    ///
    /// True only when the newest reading belongs to TODAY's diet day and this device has not
    /// already run the refresh for that day. The guard is on the ROUTINE, not the reading:
    /// `weight-log.csv` holds one row per date, the row's notes analyse an assumed fasted
    /// morning weigh-in, and the refresh audits yesterday and rolls the day — so the first
    /// reading of the day runs it and every later one, on that day, runs nothing.
    ///
    /// A reading from any other diet day is refused outright. That is the case that matters
    /// most: a phone syncing last week's readings from a scale, or a 00:30 reading that
    /// belongs to the evening before, must not roll anything.
    ///
    /// `lastFiredDay` is written by BOTH the automatic path and the Start-new-day button, so
    /// the two are one operation requested twice rather than two operations.
    public static func shouldFireMorningRefresh(newestSampleDate: Date,
                                                lastFiredDay: String?,
                                                now: Date,
                                                calendar: Calendar = .current) -> Bool {
        let today = DietDay.stamp(for: now, calendar: calendar)
        guard DietDay.stamp(for: newestSampleDate, calendar: calendar) == today else { return false }
        return lastFiredDay != today
    }
}

// MARK: - Workouts → the workout log

/// One workout HealthKit reported, reduced to the two things the decision needs: its
/// identity and when it ended. Deliberately NOT a summary: the app never interprets a
/// workout, it only notices one. The figures reach the vault through the ordinary health
/// block on the turn this causes.
public nonisolated struct ObservedWorkout: Equatable, Hashable, Codable, Sendable {
    /// `HKWorkout.uuid`, as a string.
    public var id: String
    public var end: Date

    public init(id: String, end: Date) {
        self.id = id
        self.end = end
    }
}

/// What this device remembers about the workouts it has noticed. Persisted whole, as one
/// JSON value, in the app's own defaults — it is dates and identifiers, not a secret.
public nonisolated struct WorkoutLedger: Equatable, Codable, Sendable {
    /// Workouts a turn has already been sent or queued for: id → when the workout ended.
    /// Bounded by `WorkoutAutoLog.horizon` and `WorkoutAutoLog.maxFired`.
    public var fired: [String: Date]
    /// Workouts noticed but not yet sent for, waiting out the settle window.
    public var pending: [String: Date]
    /// When the first workout of the current burst was noticed. `nil` whenever nothing is
    /// pending. The settle window is measured from HERE, not from each notification, so a
    /// burst that keeps arriving cannot postpone its own turn forever.
    public var burstStartedAt: Date?

    public init(fired: [String: Date] = [:], pending: [String: Date] = [:],
                burstStartedAt: Date? = nil) {
        self.fired = fired
        self.pending = pending
        self.burstStartedAt = burstStartedAt
    }
}

/// The answer to one evaluation.
public nonisolated struct WorkoutFireDecision: Equatable, Sendable {
    /// The workouts ONE turn should be sent for now, oldest first. Empty means no turn.
    public var due: [ObservedWorkout]
    /// The ledger with this evaluation's observations recorded as pending. `due` is NOT yet
    /// marked fired: that happens only once the turn is actually sent or queued
    /// (`WorkoutAutoLog.markFired`), so a send that is refused leaves them to try again.
    public var ledger: WorkoutLedger
    /// When the pending burst settles, if it has not yet. The caller asks to be woken then.
    public var nextCheck: Date?
}

/// **Which new workouts should send the workout log, and when.**
///
/// Deduplicated by workout IDENTITY, never by day: 2026-09-08 held a 10:04 run and treadmill
/// walks at 11:51 and 16:43, and a day guard would have logged one of the three.
public nonisolated enum WorkoutAutoLog {
    /// How long after the first workout of a burst is noticed before its turn is sent.
    ///
    /// A workout is written when it ends and then filled in: Apple Watch and Runna backfill
    /// the route, heart rate and running dynamics afterwards, and third-party imports land
    /// minutes apart. Sending on the first notification would read a half-filled workout, and
    /// the CSV diff would never re-log it. Two minutes is a starting guess, not a measurement.
    public static let settle: TimeInterval = 2 * 60

    /// How far back a workout may have ended and still be new. Also how long a fired entry is
    /// remembered — the two MUST be the same number, or a workout older than the memory but
    /// younger than the horizon would fire, be forgotten, and fire again.
    public static let horizon: TimeInterval = 14 * 24 * 3600

    /// The most fired entries kept, whatever their age. Far above any real fortnight.
    public static let maxFired = 256

    /// Record `observed` and answer what is due.
    ///
    /// A workout is a candidate when it ended within `horizon` and has never been fired for,
    /// however late it reached HealthKit: a workout backfilled three days late is still new
    /// data. The same workout observed twice is one candidate. Nothing is due until the
    /// burst has settled, and then EVERYTHING pending is due together, as one turn.
    public static func workoutsToFire(observed: [ObservedWorkout],
                                      ledger: WorkoutLedger,
                                      now: Date,
                                      settle: TimeInterval = settle) -> WorkoutFireDecision {
        var next = pruned(ledger, now: now)
        for workout in observed
        where isWithinHorizon(workout, now: now) && next.fired[workout.id] == nil {
            next.pending[workout.id] = workout.end
        }
        guard !next.pending.isEmpty else {
            next.burstStartedAt = nil
            return WorkoutFireDecision(due: [], ledger: next, nextCheck: nil)
        }
        let started = next.burstStartedAt ?? now
        next.burstStartedAt = started
        let settlesAt = started.addingTimeInterval(settle)
        guard now >= settlesAt else {
            return WorkoutFireDecision(due: [], ledger: next, nextCheck: settlesAt)
        }
        let due = next.pending
            .map { ObservedWorkout(id: $0.key, end: $0.value) }
            .sorted { ($0.end, $0.id) < ($1.end, $1.id) }
        return WorkoutFireDecision(due: due, ledger: next, nextCheck: nil)
    }

    /// Record that a turn was sent (or queued) for `due`: out of pending, into the fired set,
    /// and the burst closed.
    ///
    /// Anything STILL pending arrived after `due` was decided — while its turn was being sent
    /// — so it starts a burst of its own, now. Inheriting the closed burst's start would make it
    /// due at once, with none of the settle it needs.
    public static func markFired(_ due: [ObservedWorkout], in ledger: WorkoutLedger,
                                 now: Date) -> WorkoutLedger {
        var next = ledger
        for workout in due {
            next.pending[workout.id] = nil
            next.fired[workout.id] = workout.end
        }
        next.burstStartedAt = next.pending.isEmpty ? nil : now
        return pruned(next, now: now)
    }

    /// Everything already in HealthKit when observation first starts counts as fired.
    ///
    /// "New" means arrived after the feature was switched on. Without a baseline, the first
    /// observation on a fresh install would send a turn for a fortnight of workouts that are
    /// already in the log.
    public static func baseline(_ observed: [ObservedWorkout], in ledger: WorkoutLedger,
                                now: Date) -> WorkoutLedger {
        markFired(observed.filter { isWithinHorizon($0, now: now) }, in: ledger, now: now)
    }

    /// Drop entries past the horizon, cap the fired set, and close an empty burst.
    static func pruned(_ ledger: WorkoutLedger, now: Date) -> WorkoutLedger {
        var next = ledger
        next.fired = next.fired.filter { now.timeIntervalSince($0.value) <= horizon }
        next.pending = next.pending.filter { now.timeIntervalSince($0.value) <= horizon }
        if next.fired.count > maxFired {
            let newest = next.fired.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(maxFired)
            next.fired = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        if next.pending.isEmpty { next.burstStartedAt = nil }
        return next
    }

    private static func isWithinHorizon(_ workout: ObservedWorkout, now: Date) -> Bool {
        now.timeIntervalSince(workout.end) <= horizon
    }
}

// MARK: - Send, hold, or say it already ran

/// **What a Health turn does when it is asked for**, whoever asks: the Start-new-day button,
/// the body-mass observer, or the workout observer. One decision, so the button and the
/// automatic paths cannot drift apart.
public nonisolated enum HealthTurnRoute: Equatable, Sendable {
    /// Open a fresh thread and send the turn.
    case send
    /// Hold it in the offline capture queue; the bridge cannot be reached.
    case capture
    /// This device already ran it for this diet day. Nothing is sent and nothing is held.
    case alreadyRan

    /// `alreadyRanToday` wins over everything, including being offline: a Start-new-day
    /// already sent or already held is the same operation, and asking again means "did that
    /// go?", not "do it twice". The workout log passes `false` — it guards by workout
    /// identity instead, before it ever asks.
    public static func decide(alreadyRanToday: Bool, isReadOnly: Bool) -> HealthTurnRoute {
        if alreadyRanToday { return .alreadyRan }
        return isReadOnly ? .capture : .send
    }
}

/// The two automatic turns and the text each one sends.
///
/// `morningRefresh` returns `HealthNewDay.prompt` ITSELF rather than a copy: the automatic
/// weigh-in and the button must send byte-identical text, and the thread's `origin` is what
/// tells them apart. A test pins the equality.
public enum HealthAutoTurn: Sendable {
    case morningRefresh
    case workoutLog

    public var prompt: String {
        switch self {
        case .morningRefresh: return HealthNewDay.prompt
        case .workoutLog: return HealthWorkoutLog.prompt
        }
    }
}
