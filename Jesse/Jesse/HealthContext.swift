import Foundation

// Health context — the pure, Foundation-only core of "attach my recent Apple
// Health to every turn." Two labeled subsections in one block: a DAILY SUMMARY
// (latest vitals/sleep/activity, one line per metric) followed by the existing
// RECENT WORKOUTS subsection (see `WorkoutContext.swift`), with running-dynamics
// detail added to run lines.
//
// Everything here is `nonisolated` and deterministic so it is fully unit-tested;
// the ONLY code that touches HealthKit lives behind `HealthContextProviding` in
// `HealthContextProvider.swift`. Shape:
//   - `DailySummary` (+ its member value types) — the daily metrics, each optional.
//   - `HealthSnapshot` — daily summary + workouts, what the provider returns.
//   - `DailySummaryFormatter` — one line per present metric, fixed order.
//   - `HealthContextFormatter` — composes both subsections under the 3 KiB cap.
//   - `HealthContextPolicy` / `HealthContextResolver` — the attach decision + wiring.
//   - `HealthContextTimeout` / `HealthContextGather` / `HealthMetricFetches` — the
//     single combined bounded gather with per-metric failure isolation.
//   - `HealthContextSettings` — the persisted toggle.

// MARK: - Daily-summary value types

/// One night of sleep, attributed to the wake date. Stage minutes are optional
/// (a source that reports only "asleep" leaves them nil). `isNap` marks a short,
/// off-hours session so it is never presented as the night.
nonisolated struct SleepSummary: Equatable, Sendable {
    var totalMinutes: Double
    var deepMinutes: Double?
    var remMinutes: Double?
    var coreMinutes: Double?
    var awakeMinutes: Double?
    var isNap: Bool
}

/// A scalar reading paired with the instant it was recorded, for the sparse series
/// (VO2 max, HR recovery, weight) whose recency the formatter re-checks against now.
nonisolated struct DatedValue: Equatable, Sendable {
    var value: Double
    var date: Date
}

/// The three irregular heart-rhythm notification kinds Apple Health records.
nonisolated enum HREventKind: String, Equatable, Sendable, CaseIterable {
    case low, high, irregular
    /// Fixed render order and label.
    var label: String {
        switch self {
        case .low: return "low"
        case .high: return "high"
        case .irregular: return "irregular"
        }
    }
}

/// A count of one HR-event kind over the lookback window plus its most recent time.
nonisolated struct HREventSummary: Equatable, Sendable {
    var kind: HREventKind
    var count: Int
    var mostRecent: Date
}

/// Overnight vitals for last night. All optional; the line is omitted when all nil.
nonisolated struct OvernightVitals: Equatable, Sendable {
    /// Breaths per minute.
    var respiratoryRate: Double?
    /// Blood-oxygen average as a FRACTION 0…1 (rendered as a percent).
    var oxygenSaturation: Double?
    /// Wrist-temperature DEVIATION from baseline, in °C (may be negative).
    var wristTemperatureDeviation: Double?

    var isEmpty: Bool {
        respiratoryRate == nil && oxygenSaturation == nil && wristTemperatureDeviation == nil
    }
}

/// Mobility signals rendered on one shared line. Both optional.
nonisolated struct MobilitySummary: Equatable, Sendable {
    /// Apple Walking Steadiness classification (e.g. "OK", "Low", "Very Low").
    var steadiness: String?
    /// Walking asymmetry as a PERCENT (0…100).
    var asymmetryPercent: Double?

    var isEmpty: Bool { steadiness == nil && asymmetryPercent == nil }
}

/// The whole daily-summary section as pure data — every metric optional so an
/// unreadable one is simply omitted (never an error or a placeholder). `hrEvents`
/// is empty in the common case (no events).
nonisolated struct DailySummary: Equatable, Sendable {
    var sleep: SleepSummary?
    /// Resting heart rate, BPM.
    var restingHeartRateBPM: Double?
    /// Heart-rate variability (SDNN), milliseconds.
    var hrvSDNNms: Double?
    var hrEvents: [HREventSummary]
    /// VO2 max, mL/(kg·min), with its date.
    var vo2Max: DatedValue?
    /// One-minute heart-rate recovery, BPM, with its date.
    var hrRecovery: DatedValue?
    var vitals: OvernightVitals?
    var mobility: MobilitySummary?
    /// Steps since midnight (statistics sum).
    var todaySteps: Double?
    /// Active energy since midnight, kcal (statistics sum).
    var todayActiveKcal: Double?
    /// Latest body mass, kg, with its date.
    var weight: DatedValue?

    init(sleep: SleepSummary? = nil, restingHeartRateBPM: Double? = nil,
         hrvSDNNms: Double? = nil, hrEvents: [HREventSummary] = [],
         vo2Max: DatedValue? = nil, hrRecovery: DatedValue? = nil,
         vitals: OvernightVitals? = nil, mobility: MobilitySummary? = nil,
         todaySteps: Double? = nil, todayActiveKcal: Double? = nil,
         weight: DatedValue? = nil) {
        self.sleep = sleep
        self.restingHeartRateBPM = restingHeartRateBPM
        self.hrvSDNNms = hrvSDNNms
        self.hrEvents = hrEvents
        self.vo2Max = vo2Max
        self.hrRecovery = hrRecovery
        self.vitals = vitals
        self.mobility = mobility
        self.todaySteps = todaySteps
        self.todayActiveKcal = todayActiveKcal
        self.weight = weight
    }

    static let empty = DailySummary()

    /// True when no metric is present — used to skip the daily subsection entirely.
    var isEmpty: Bool {
        sleep == nil && restingHeartRateBPM == nil && hrvSDNNms == nil
            && hrEvents.isEmpty && vo2Max == nil && hrRecovery == nil
            && (vitals?.isEmpty ?? true) && (mobility?.isEmpty ?? true)
            && todaySteps == nil && todayActiveKcal == nil && weight == nil
    }
}

/// What the provider returns: the daily summary plus the recent workouts. A value
/// type so the whole gather is faked in tests without HealthKit.
nonisolated struct HealthSnapshot: Equatable, Sendable {
    var daily: DailySummary
    var workouts: [WorkoutSummary]
    static let empty = HealthSnapshot(daily: .empty, workouts: [])
}

// MARK: - Classifiers (pure, tested)

/// Decides whether a sleep session is a nap/artifact rather than the night: short
/// (under `napMaxMinutes`) AND centered in daytime (an implausible window for the
/// main night). A long session is always the night; a short session that spans the
/// usual overnight window is treated as a fragmented night, not a nap.
nonisolated enum SleepClassifier {
    static let napMaxMinutes: Double = 120

    /// `midpoint` is the center instant of the session; `timeZone` localizes the
    /// hour-of-day test. A nap is short and centered between 10:00 and 20:00 local.
    static func isNap(totalMinutes: Double, midpoint: Date, timeZone: TimeZone) -> Bool {
        guard totalMinutes < napMaxMinutes else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: midpoint)
        return hour >= 10 && hour < 20
    }
}

/// Maps an Apple Walking Steadiness percentage to its classification band. Apple's
/// Health app buckets steadiness as OK / Low / Very Low; the thresholds here mirror
/// the published bands (Low below 40%, Very Low below 20%).
nonisolated enum WalkingSteadiness {
    static func classify(percent: Double) -> String {
        if percent < 20 { return "Very Low" }
        if percent < 40 { return "Low" }
        return "OK"
    }
}

// MARK: - Daily-summary formatter

/// Renders `DailySummary` into the daily subsection: a header then one line per
/// present metric in a FIXED order. Any metric whose data is unavailable is
/// omitted. Locale-fixed (en_US_POSIX dates, metric units, kcal) so the bytes are
/// deterministic. Dated metrics re-check recency against `now` so a stale sample
/// the provider returned is still dropped.
nonisolated enum DailySummaryFormatter {
    static let header = "Daily health summary from Apple Health:"

    // Recency windows for the dated metrics (re-checked here, in seconds).
    static let vo2MaxWindow: TimeInterval = 180 * 86_400
    static let recoveryWindow: TimeInterval = 7 * 86_400
    static let weightWindow: TimeInterval = 7 * 86_400
    static let hrEventWindow: TimeInterval = 7 * 86_400

    /// The metric lines (no header), in fixed order, omitting unavailable metrics.
    static func lines(from d: DailySummary, now: Date, timeZone: TimeZone) -> [String] {
        var out: [String] = []
        if let s = d.sleep { out.append(sleepLine(s)) }
        if let hr = d.restingHeartRateBPM { out.append("Resting HR: \(int(hr)) bpm") }
        if let hrv = d.hrvSDNNms { out.append("HRV (SDNN): \(int(hrv)) ms") }
        if let ev = hrEventsLine(d.hrEvents, now: now, timeZone: timeZone) { out.append(ev) }
        if let v = d.vo2Max, within(v.date, now, vo2MaxWindow) {
            out.append("VO2 max: \(oneDecimal(v.value)) mL/kg·min (\(day(v.date, timeZone)))")
        }
        if let r = d.hrRecovery, within(r.date, now, recoveryWindow) {
            out.append("HR recovery (1 min): \(int(r.value)) bpm (\(day(r.date, timeZone)))")
        }
        if let vit = d.vitals, let line = vitalsLine(vit) { out.append(line) }
        if let mob = d.mobility, let line = mobilityLine(mob) { out.append(line) }
        if let steps = d.todaySteps, let kcal = d.todayActiveKcal {
            out.append("Today so far: \(int(steps)) steps, \(int(kcal)) kcal active")
        } else if let steps = d.todaySteps {
            out.append("Today so far: \(int(steps)) steps")
        } else if let kcal = d.todayActiveKcal {
            out.append("Today so far: \(int(kcal)) kcal active")
        }
        if let w = d.weight, within(w.date, now, weightWindow) {
            out.append("Weight: \(oneDecimal(w.value)) kg (\(day(w.date, timeZone)))")
        }
        return out
    }

    // MARK: line builders

    private static func sleepLine(_ s: SleepSummary) -> String {
        var parts = ["\(oneDecimal(s.totalMinutes / 60))h total"]
        if let d = s.deepMinutes { parts.append("\(int(d))m deep") }
        if let r = s.remMinutes { parts.append("\(int(r))m REM") }
        if let c = s.coreMinutes { parts.append("\(int(c))m core") }
        if let a = s.awakeMinutes { parts.append("\(int(a))m awake") }
        let label = s.isNap ? "nap" : "last night"
        return "Sleep (\(label)): " + parts.joined(separator: ", ")
    }

    private static func hrEventsLine(_ events: [HREventSummary],
                                     now: Date, timeZone: TimeZone) -> String? {
        // Fixed kind order; only events within the 7-day window with a positive count.
        let fresh = HREventKind.allCases.compactMap { kind -> String? in
            guard let e = events.first(where: { $0.kind == kind }),
                  e.count > 0, within(e.mostRecent, now, hrEventWindow) else { return nil }
            return "\(e.count) \(kind.label) (latest \(dayTime(e.mostRecent, timeZone)))"
        }
        return fresh.isEmpty ? nil : "HR events: " + fresh.joined(separator: ", ")
    }

    private static func vitalsLine(_ v: OvernightVitals) -> String? {
        var parts: [String] = []
        if let r = v.respiratoryRate { parts.append("\(int(r)) breaths/min") }
        if let o = v.oxygenSaturation { parts.append("SpO2 \(int(o * 100))%") }
        if let t = v.wristTemperatureDeviation {
            parts.append(String(format: "wrist temp %+.1f°C", t))
        }
        return parts.isEmpty ? nil : "Overnight: " + parts.joined(separator: ", ")
    }

    private static func mobilityLine(_ m: MobilitySummary) -> String? {
        var parts: [String] = []
        if let s = m.steadiness { parts.append("steadiness \(s)") }
        if let a = m.asymmetryPercent { parts.append("asymmetry \(oneDecimal(a))%") }
        return parts.isEmpty ? nil : "Mobility: " + parts.joined(separator: ", ")
    }

    // MARK: formatting helpers (C-locale numeric, en_US_POSIX dates)

    private static func within(_ date: Date, _ now: Date, _ window: TimeInterval) -> Bool {
        date >= now.addingTimeInterval(-window) && date <= now.addingTimeInterval(60)
    }
    private static func int(_ v: Double) -> String { String(format: "%.0f", v) }
    private static func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func day(_ date: Date, _ timeZone: TimeZone) -> String {
        fmt("yyyy-MM-dd", timeZone).string(from: date)
    }
    private static func dayTime(_ date: Date, _ timeZone: TimeZone) -> String {
        fmt("yyyy-MM-dd HH:mm", timeZone).string(from: date)
    }
    private static func fmt(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f
    }
}

// MARK: - Composer (both subsections under one byte cap)

/// Composes the two-subsection health-context block the phone attaches to a turn:
/// the daily summary followed by the recent workouts. One hard byte ceiling
/// (`maxBytes`) over the WHOLE block, with a truncation priority that keeps the
/// high-value daily summary intact and sheds workout detail: drop the oldest
/// workout lines first, then a boundary workout's running-dynamics suffix — never
/// truncating mid-line. Returns nil when neither subsection has anything.
nonisolated enum HealthContextFormatter {
    /// Hard byte ceiling on the whole rendered block (well under the bridge's 4 KiB).
    static let maxBytes = 3 * 1024

    static func block(daily: DailySummary,
                      workouts: [WorkoutSummary],
                      now: Date,
                      timeZone: TimeZone = .current) -> String? {
        // Daily subsection (mandatory when present — never shed by the byte cap).
        let dailyLines = DailySummaryFormatter.lines(from: daily, now: now, timeZone: timeZone)
        var sections: [[String]] = []
        var used = 0
        func cost(_ line: String) -> Int { line.utf8.count + 1 } // + newline joiner

        if !dailyLines.isEmpty {
            let block = [DailySummaryFormatter.header] + dailyLines
            sections.append(block)
            used += block.reduce(0) { $0 + cost($1) }
        }

        // Workouts subsection: newest-first, within 48h, at most maxWorkouts. Then
        // greedily fit under the remaining budget — a workout keeps its dynamics
        // suffix if it fits, else the suffix is dropped, else the (older) line is
        // dropped. Header cost is reserved so it always fits with its lines.
        let cutoff = now.addingTimeInterval(-WorkoutContextFormatter.windowHours * 3600)
        let candidates = workouts
            .filter { $0.end >= cutoff }
            .sorted { $0.start > $1.start }
            .prefix(WorkoutContextFormatter.maxWorkouts)

        let headerReserve = WorkoutContextFormatter.header(count: candidates.count).utf8.count + 1
        var workoutLines: [String] = []
        var workoutUsed = headerReserve
        for w in candidates {
            let base = WorkoutContextFormatter.baseLine(for: w, timeZone: timeZone)
            let full = base + WorkoutContextFormatter.dynamicsSuffix(for: w)
            if used + workoutUsed + cost(full) <= maxBytes {
                workoutLines.append(full)
                workoutUsed += cost(full)
            } else if used + workoutUsed + cost(base) <= maxBytes {
                workoutLines.append(base)
                workoutUsed += cost(base)
            } else {
                break // this and every older workout are dropped
            }
        }
        if !workoutLines.isEmpty {
            sections.append([WorkoutContextFormatter.header(count: workoutLines.count)] + workoutLines)
        }

        guard !sections.isEmpty else { return nil }
        // Subsections separated by a blank line; when only the workouts subsection is
        // present this is byte-identical to the pre-daily-summary block.
        return sections.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }
}

// MARK: - Policy

/// The pure decision of whether to attach the block to a turn: the feature must be
/// enabled AND the provider must have produced a non-empty block.
nonisolated enum HealthContextPolicy {
    static func shouldAttach(enabled: Bool, block: String?) -> Bool {
        guard enabled else { return false }
        guard let block, !block.isEmpty else { return false }
        return true
    }
}

// MARK: - Resolver (send-path wiring)

/// Resolves the `health_context` string a turn should carry, or nil to attach
/// nothing. Applied inside `JesseClient.send` so every turn path — typed, Siri, and
/// the watch relay — inherits it. When the feature is off it never touches the
/// provider; otherwise it gathers the snapshot (best-effort, empty on any failure),
/// renders, and applies the policy. Pure given the provider, so it is unit-tested
/// with a fake provider and a fixed clock.
nonisolated enum HealthContextResolver {
    static func resolve(enabled: Bool,
                        provider: any HealthContextProviding,
                        now: Date,
                        timeZone: TimeZone = .current) async -> String? {
        guard enabled else { return nil }
        let snap = await provider.snapshot()
        let block = HealthContextFormatter.block(daily: snap.daily, workouts: snap.workouts,
                                                 now: now, timeZone: timeZone)
        return HealthContextPolicy.shouldAttach(enabled: enabled, block: block) ? block : nil
    }
}

// MARK: - Provider seam

/// The one seam HealthKit hides behind. A conformer returns a best-effort
/// `HealthSnapshot`. It **never throws and never blocks a send**: every degrade
/// path — unauthorized, no data, a per-metric error, or a timeout — yields empty
/// values, so a turn always goes out (just without the block). HealthKit read
/// denial is invisible by design (empty results), so silence is the only correct
/// degrade. `HealthContextProvider` is the sole production conformer; tests
/// inject a fake.
protocol HealthContextProviding: Sendable {
    func snapshot() async -> HealthSnapshot
    /// A windowed daily series for one whitelisted metric, used to fulfill a
    /// `JESSE_NEEDS_HEALTH` metrics request. Best-effort: returns `[]` on any
    /// failure (unauthorized, no data, error), so a request degrades to "no data"
    /// rather than blocking. `windowDays` is pre-validated to 1...31.
    func series(for metric: RequestableMetric, windowDays: Int) async -> [MetricSeriesPoint]
}

extension HealthContextProviding {
    // Default so existing conformers (the test fakes for the workouts/daily block)
    // need not implement the series read; only the live provider — and the fakes
    // that exercise the metrics channel — override it.
    func series(for metric: RequestableMetric, windowDays: Int) async -> [MetricSeriesPoint] { [] }
}

// MARK: - Combined bounded gather

/// A bundle of best-effort HealthKit reads, each independently failable, injected
/// so the gather's per-metric isolation and the timeout are exercised WITHOUT
/// simulator Health data. The live `HealthContextProvider` fills these with real
/// queries; tests pass fakes (some throwing) to prove one failing read never drops
/// another metric's line.
nonisolated struct HealthMetricFetches: Sendable {
    var workouts: @Sendable () async throws -> [WorkoutSummary]
    var sleep: @Sendable () async throws -> SleepSummary?
    var restingHR: @Sendable () async throws -> Double?
    var hrv: @Sendable () async throws -> Double?
    var hrEvents: @Sendable () async throws -> [HREventSummary]
    var vo2Max: @Sendable () async throws -> DatedValue?
    var hrRecovery: @Sendable () async throws -> DatedValue?
    var vitals: @Sendable () async throws -> OvernightVitals?
    var mobility: @Sendable () async throws -> MobilitySummary?
    var todaySteps: @Sendable () async throws -> Double?
    var todayActiveKcal: @Sendable () async throws -> Double?
    var weight: @Sendable () async throws -> DatedValue?

    /// All-empty fetches — the default the live provider overrides per metric.
    static let empty = HealthMetricFetches(
        workouts: { [] }, sleep: { nil }, restingHR: { nil }, hrv: { nil },
        hrEvents: { [] }, vo2Max: { nil }, hrRecovery: { nil }, vitals: { nil },
        mobility: { nil }, todaySteps: { nil }, todayActiveKcal: { nil }, weight: { nil })
}

/// Runs every metric fetch concurrently and assembles a `HealthSnapshot`, isolating
/// each failure: a thrown read (a failed HRV query, say) degrades only that metric
/// to nil/empty and never drops another. Pure given the fetches, so it is unit-
/// tested with a mix of succeeding and throwing closures.
nonisolated enum HealthContextGather {
    static func snapshot(_ f: HealthMetricFetches) async -> HealthSnapshot {
        async let workouts = (try? f.workouts()) ?? []
        async let sleep = (try? f.sleep()) ?? nil
        async let restingHR = (try? f.restingHR()) ?? nil
        async let hrv = (try? f.hrv()) ?? nil
        async let hrEvents = (try? f.hrEvents()) ?? []
        async let vo2Max = (try? f.vo2Max()) ?? nil
        async let hrRecovery = (try? f.hrRecovery()) ?? nil
        async let vitals = (try? f.vitals()) ?? nil
        async let mobility = (try? f.mobility()) ?? nil
        async let todaySteps = (try? f.todaySteps()) ?? nil
        async let todayActiveKcal = (try? f.todayActiveKcal()) ?? nil
        async let weight = (try? f.weight()) ?? nil

        let daily = DailySummary(
            sleep: await sleep,
            restingHeartRateBPM: await restingHR,
            hrvSDNNms: await hrv,
            hrEvents: await hrEvents,
            vo2Max: await vo2Max,
            hrRecovery: await hrRecovery,
            vitals: await vitals,
            mobility: await mobility,
            todaySteps: await todaySteps,
            todayActiveKcal: await todayActiveKcal,
            weight: await weight)
        return HealthSnapshot(daily: daily, workouts: await workouts)
    }
}

/// Bounds the combined gather: runs `operation` racing a `timeout`; whichever
/// finishes first wins and the other is cancelled. An overrun yields the empty
/// snapshot — so the gather can never block a send past the bound. Pure (Foundation
/// only), tested with fake fast/slow operations.
nonisolated enum HealthContextTimeout {
    static func orEmpty(within timeout: Duration,
                        _ operation: @escaping @Sendable () async -> HealthSnapshot)
        async -> HealthSnapshot {
        await withTaskGroup(of: HealthSnapshot?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .empty
        }
    }
}

// MARK: - Settings

/// The persisted "attach health context" toggle. Backed by `UserDefaults` (a
/// non-secret preference, unlike the Keychain-stored bridge token). Defaults OFF
/// until the user connects Apple Health once, then the Settings row flips it on.
/// `JesseClient` reads `isEnabled` at send time; the Settings `@AppStorage` binds
/// the same key. The key is unchanged from the shipped workouts-only feature, so an
/// existing user's toggle state carries over.
nonisolated enum HealthContextSettings {
    static let enabledKey = "attachHealthContext"
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    static var isEnabled: Bool { defaults.bool(forKey: enabledKey) }
    static func setEnabled(_ on: Bool) { defaults.set(on, forKey: enabledKey) }
}
