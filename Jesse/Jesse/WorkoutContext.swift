import Foundation

// Recent-workouts rendering — the workouts SUBSECTION of the two-section health
// context (see `HealthContext.swift` for the daily-summary subsection and the
// `HealthContextFormatter` that composes both under the single byte cap).
//
// Everything here is `nonisolated` and deterministic so it is fully unit-tested;
// the ONLY code that touches HealthKit lives behind `HealthContextProviding` in
// `HealthKitWorkoutProvider.swift`. `WorkoutSummary` is the value type the
// provider fills; `WorkoutContextFormatter` renders one line per workout (a base
// line plus, for runs, a droppable running-dynamics segment) and the subsection
// header. The window/cap/composition live in `HealthContextFormatter`.

// MARK: - Value type

/// One device-reported workout, reduced to just the fields the block renders.
/// A value type with no HealthKit dependency, so the formatter is pure and the
/// provider seam can be faked in tests. Running-dynamics fields are populated only
/// for running workouts (nil otherwise) and render as a droppable suffix.
nonisolated struct WorkoutSummary: Equatable, Sendable {
    /// Short human name for the activity, e.g. "Swim", "Run", "Walk", "Workout".
    var activityName: String
    /// When the workout started (absolute instant).
    var start: Date
    /// Elapsed duration in seconds.
    var duration: TimeInterval
    /// Total distance in METERS, or nil if the activity records none.
    var distanceMeters: Double?
    /// Total active energy in kcal, or nil if unavailable.
    var activeEnergyKcal: Double?
    /// Average heart rate in BPM over the workout, or nil if unavailable.
    var averageHeartRateBPM: Double?
    /// Max heart rate in BPM over the workout, or nil if unavailable.
    var maxHeartRateBPM: Double?
    /// Recording source, e.g. "Apple Watch", or nil if unknown.
    var source: String?

    // Running dynamics — average over the workout window, runs only, each nil when
    // the sample stream is absent. Rendered as a droppable suffix by the formatter.
    /// Average running power in watts.
    var averageRunningPowerW: Double?
    /// Average ground contact time in milliseconds.
    var groundContactTimeMs: Double?
    /// Average vertical oscillation in centimeters.
    var verticalOscillationCm: Double?
    /// Average stride length in meters.
    var strideLengthM: Double?

    init(activityName: String, start: Date, duration: TimeInterval,
         distanceMeters: Double? = nil, activeEnergyKcal: Double? = nil,
         averageHeartRateBPM: Double? = nil, maxHeartRateBPM: Double? = nil,
         source: String? = nil,
         averageRunningPowerW: Double? = nil, groundContactTimeMs: Double? = nil,
         verticalOscillationCm: Double? = nil, strideLengthM: Double? = nil) {
        self.activityName = activityName
        self.start = start
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.activeEnergyKcal = activeEnergyKcal
        self.averageHeartRateBPM = averageHeartRateBPM
        self.maxHeartRateBPM = maxHeartRateBPM
        self.source = source
        self.averageRunningPowerW = averageRunningPowerW
        self.groundContactTimeMs = groundContactTimeMs
        self.verticalOscillationCm = verticalOscillationCm
        self.strideLengthM = strideLengthM
    }

    /// When the workout ended (start + duration).
    var end: Date { start.addingTimeInterval(duration) }

    /// True when any running-dynamics field is present (populated only for runs).
    var hasRunningDynamics: Bool {
        averageRunningPowerW != nil || groundContactTimeMs != nil
            || verticalOscillationCm != nil || strideLengthM != nil
    }
}

// MARK: - Formatter (workouts subsection)

/// Renders workout summaries into the "recent workouts" subsection. Pure and
/// locale-fixed (en_US_POSIX dates, metric units, kcal) so the output is
/// byte-deterministic. The window (48h), the newest-first ordering, the 5-cap, and
/// the byte budget live in `HealthContextFormatter`; this type only formats an
/// individual line and the subsection header.
nonisolated enum WorkoutContextFormatter {
    static let maxWorkouts = 5
    static let windowHours: Double = 48

    /// The subsection header for `count` workout lines (singular/plural).
    static func header(count: Int) -> String {
        "\(count) recent workout\(count == 1 ? "" : "s") from Apple Health "
            + "(last 48h, newest first):"
    }

    /// One workout as a single line, including the running-dynamics suffix when the
    /// workout has dynamics. Back-compatible default; `HealthContextFormatter` calls
    /// `baseLine`/`dynamicsSuffix` separately so it can drop the suffix under budget.
    static func line(for s: WorkoutSummary, timeZone: TimeZone = .current) -> String {
        baseLine(for: s, timeZone: timeZone) + dynamicsSuffix(for: s)
    }

    /// The workout line WITHOUT the running-dynamics suffix. Fields that are nil are
    /// omitted; the source, when present, is parenthesized at the end.
    static func baseLine(for s: WorkoutSummary, timeZone: TimeZone = .current) -> String {
        var parts = ["\(s.activityName) — \(dateString(s.start, timeZone: timeZone))"]
        parts.append(durationString(s.duration))
        if let d = s.distanceMeters { parts.append(distanceString(d)) }
        if let k = s.activeEnergyKcal { parts.append(energyString(k)) }
        if let avg = s.averageHeartRateBPM { parts.append("avg HR \(bpmString(avg))") }
        if let mx = s.maxHeartRateBPM { parts.append("max HR \(bpmString(mx))") }
        var out = parts.joined(separator: ", ")
        if let src = s.source, !src.trimmingCharacters(in: .whitespaces).isEmpty {
            out += " (\(src))"
        }
        return out
    }

    /// The running-dynamics segment appended to a run's line (leading ", "), or ""
    /// when the workout has no dynamics. Kept separate so the byte-cap can drop it
    /// before dropping whole lines. Each field is omitted when nil.
    static func dynamicsSuffix(for s: WorkoutSummary) -> String {
        var d: [String] = []
        if let p = s.averageRunningPowerW { d.append(String(format: "power %.0f W", p)) }
        if let g = s.groundContactTimeMs { d.append(String(format: "GCT %.0f ms", g)) }
        if let v = s.verticalOscillationCm { d.append(String(format: "vert osc %.1f cm", v)) }
        if let l = s.strideLengthM { d.append(String(format: "stride %.2f m", l)) }
        return d.isEmpty ? "" : ", " + d.joined(separator: ", ")
    }

    // MARK: Field formatting (all locale-fixed / C-locale numeric)

    /// `yyyy-MM-dd HH:mm` in en_US_POSIX so the string never shifts by host locale.
    private static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Compact duration: `45m` under an hour, else `1h05m`. Rounded to the minute.
    private static func durationString(_ seconds: TimeInterval) -> String {
        let totalMin = max(0, Int((seconds / 60).rounded()))
        if totalMin < 60 { return "\(totalMin)m" }
        return "\(totalMin / 60)h\(String(format: "%02d", totalMin % 60))m"
    }

    /// Metric distance: `3.2 km` at/above 1 km, else `850 m`. `%.Nf` is C-locale
    /// (period decimal), so no locale drift.
    private static func distanceString(_ meters: Double) -> String {
        if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
        return String(format: "%.0f m", meters)
    }

    private static func energyString(_ kcal: Double) -> String {
        String(format: "%.0f kcal", kcal)
    }

    private static func bpmString(_ bpm: Double) -> String {
        String(format: "%.0f", bpm)
    }
}
