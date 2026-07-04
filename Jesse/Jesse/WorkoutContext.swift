import Foundation

// Recent-workouts context — the pure, Foundation-only core of the "attach my
// recent workouts to every turn" feature. Everything here is `nonisolated` and
// deterministic so it is fully unit-tested; the ONLY code that touches HealthKit
// lives behind `WorkoutContextProviding` in `HealthKitWorkoutProvider.swift`.
//
// Shape: the provider returns value-type `WorkoutSummary` records (best-effort,
// empty on any failure); `WorkoutContextFormatter` renders them into the compact
// block the bridge frames as untrusted device data; `WorkoutContextPolicy` is the
// pure decision of whether to attach; `WorkoutContextResolver` wires the three
// together for the send path; `WorkoutContextTimeout` bounds the async query.

// MARK: - Value type

/// One device-reported workout, reduced to just the fields the block renders.
/// A value type with no HealthKit dependency, so the formatter is pure and the
/// provider seam can be faked in tests.
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

    /// When the workout ended (start + duration).
    var end: Date { start.addingTimeInterval(duration) }
}

// MARK: - Provider seam

/// The one seam HealthKit hides behind. A conformer returns recent workout
/// summaries newest-first, best-effort. It **never throws and never blocks a
/// send**: every degrade path — unauthorized, no data, a query error, or a
/// timeout — yields an empty array, so a turn always goes out (just without the
/// block). HealthKit read denial is invisible by design (empty results), so
/// silence is the only correct degrade. `HealthKitWorkoutProvider` is the sole
/// production conformer; tests inject a fake.
protocol WorkoutContextProviding: Sendable {
    func recentWorkouts() async -> [WorkoutSummary]
}

// MARK: - Formatter

/// Renders workout summaries into the compact block the phone attaches to a turn.
/// Pure and locale-fixed (en_US_POSIX dates, metric units, kcal) so the output is
/// byte-deterministic. Caps: at most `maxWorkouts` lines, only workouts ended
/// within `windowHours`, and a hard `maxBytes` ceiling that truncates whole lines
/// (never mid-line). Returns nil when nothing qualifies.
nonisolated enum WorkoutContextFormatter {
    static let maxWorkouts = 5
    static let windowHours: Double = 48
    /// Hard byte ceiling on the whole rendered block (header + lines).
    static let maxBytes = 2 * 1024
    /// Bytes reserved for the header line so the line budget leaves room for it.
    private static let headerReserveBytes = 96

    /// Render the block, or nil if no workout qualifies (empty input, or every
    /// workout older than the 48h window). `now` and `timeZone` are injected so
    /// the output is deterministic under test.
    static func block(from summaries: [WorkoutSummary],
                      now: Date,
                      timeZone: TimeZone = .current) -> String? {
        let cutoff = now.addingTimeInterval(-windowHours * 3600)
        // Newest-first, only those ended within the window, at most maxWorkouts.
        let candidates = summaries
            .filter { $0.end >= cutoff }
            .sorted { $0.start > $1.start }
            .prefix(maxWorkouts)

        // Greedily accumulate whole lines under the byte budget (reserving room
        // for the header). Never truncate a line mid-way.
        let lineBudget = maxBytes - headerReserveBytes
        var lines: [String] = []
        var used = 0
        for s in candidates {
            let ln = line(for: s, timeZone: timeZone)
            let cost = ln.utf8.count + 1 // + newline joiner
            if used + cost > lineBudget { break }
            lines.append(ln)
            used += cost
        }
        guard !lines.isEmpty else { return nil }

        let n = lines.count
        let header = "\(n) recent workout\(n == 1 ? "" : "s") from Apple Health "
            + "(last 48h, newest first):"
        return ([header] + lines).joined(separator: "\n")
    }

    /// One workout as a single line. Fields that are nil are omitted; the source,
    /// when present, is parenthesized at the end.
    static func line(for s: WorkoutSummary, timeZone: TimeZone = .current) -> String {
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

// MARK: - Policy

/// The pure decision of whether to attach the block to a turn: the feature must be
/// enabled AND the provider must have produced a non-empty block. Kept separate
/// from the formatter/provider so the "when" is testable in isolation.
nonisolated enum WorkoutContextPolicy {
    static func shouldAttach(enabled: Bool, block: String?) -> Bool {
        guard enabled else { return false }
        guard let block, !block.isEmpty else { return false }
        return true
    }
}

// MARK: - Resolver (send-path wiring)

/// Resolves the `health_context` string a turn should carry, or nil to attach
/// nothing. Applied inside `JesseClient.send` so every turn path — typed, Siri,
/// and the watch relay — inherits it. When the feature is off it never touches the
/// provider; otherwise it queries (best-effort, empty on any failure), renders,
/// and applies the policy. Pure given the provider, so it is unit-tested with a
/// fake provider and a fixed clock.
nonisolated enum WorkoutContextResolver {
    static func resolve(enabled: Bool,
                        provider: any WorkoutContextProviding,
                        now: Date,
                        timeZone: TimeZone = .current) async -> String? {
        guard enabled else { return nil }
        let summaries = await provider.recentWorkouts()
        let block = WorkoutContextFormatter.block(from: summaries, now: now, timeZone: timeZone)
        return WorkoutContextPolicy.shouldAttach(enabled: enabled, block: block) ? block : nil
    }
}

// MARK: - Timeout helper

/// Bounds an async workout fetch: runs `operation` racing a `timeout`; whichever
/// finishes first wins and the other is cancelled. A thrown error OR an overrun
/// both yield an empty array — so `recentWorkouts()` can never block a send past
/// the bound, and never surfaces an error. Pure (Foundation only), tested with
/// fake fast/slow/throwing operations.
nonisolated enum WorkoutContextTimeout {
    static func orEmpty(within timeout: Duration,
                        _ operation: @escaping @Sendable () async throws -> [WorkoutSummary])
        async -> [WorkoutSummary] {
        await withTaskGroup(of: [WorkoutSummary].self) { group in
            group.addTask {
                do { return try await operation() } catch { return [] }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Settings

/// The persisted "attach recent workouts" toggle. Backed by `UserDefaults` (a
/// non-secret preference, unlike the Keychain-stored bridge token). Defaults OFF
/// until the user has connected Apple Health once, then the Settings row flips it
/// on. `JesseClient` reads `isEnabled` at send time; the Settings `@AppStorage`
/// binds the same key.
nonisolated enum WorkoutContextSettings {
    static let enabledKey = "attachHealthContext"
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    static var isEnabled: Bool { defaults.bool(forKey: enabledKey) }
    static func setEnabled(_ on: Bool) { defaults.set(on, forKey: enabledKey) }
}
