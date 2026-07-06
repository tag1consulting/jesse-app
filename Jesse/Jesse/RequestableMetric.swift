import Foundation

// The app half of the JESSE_NEEDS_HEALTH channel: the fixed whitelist of metrics
// the agent may request a windowed series for, the VALIDATED decode of a request,
// and the pure formatter that renders a metric's series into lines. HealthKit
// itself lives in `HealthContextProvider`; everything here is Foundation-only and
// unit-tested.
//
// Correctness: a request is either fully valid or unfulfillable — an unknown
// metric, an out-of-range window, or more than four metrics rejects the WHOLE
// request (the coordinator then answers from vault data). We never partially
// fulfill an invalid request.

/// The fixed whitelist a `JESSE_NEEDS_HEALTH` directive may name. **MUST stay in
/// exact sync with the bridge's `NEEDS_HEALTH_METRICS`** — the bridge validates a
/// directive against its copy, the app against this one, so a prompt-injected
/// agent can only ever ask for these device-health aggregates the user opted into.
enum RequestableMetric: String, CaseIterable, Sendable, Equatable {
    case restingHeartRate
    case heartRate
    case heartRateVariabilitySDNN
    case stepCount
    case activeEnergyBurned
    case bodyMass
    case sleepAnalysis
    case vo2Max
    case workouts
}

/// A section the agent can request (mirrors the two-section health block).
enum HealthSection: String, Sendable, Equatable {
    case daily
    case workouts
}

/// One validated metric request: a whitelisted metric and an in-range window.
struct ValidatedMetricRequest: Equatable, Sendable {
    let metric: RequestableMetric
    let windowDays: Int   // guaranteed 1...31
}

/// The app-side, fully **validated** needs-health request, built from the wire
/// `directives.needs_health`. `validated` returns nil for anything the contract
/// rejects (so the caller treats it as unfulfillable), never a partial request.
struct NeedsHealthRequest: Equatable, Sendable {
    let sections: [HealthSection]
    let metrics: [ValidatedMetricRequest]

    static let maxMetrics = 4
    static let windowRange = 1...31

    /// Validate a decoded directive against the contract. Returns nil if any
    /// section is unknown, any metric is off the whitelist, any window is out of
    /// range, there are more than `maxMetrics` metrics, or nothing was requested at
    /// all — never a partially-valid request.
    static func validated(sections: [String],
                          metrics: [(metric: String, windowDays: Int)]) -> NeedsHealthRequest? {
        var validSections: [HealthSection] = []
        for raw in sections {
            guard let section = HealthSection(rawValue: raw) else { return nil }
            validSections.append(section)
        }
        guard metrics.count <= maxMetrics else { return nil }
        var validMetrics: [ValidatedMetricRequest] = []
        for m in metrics {
            guard let metric = RequestableMetric(rawValue: m.metric) else { return nil }
            guard windowRange.contains(m.windowDays) else { return nil }
            validMetrics.append(ValidatedMetricRequest(metric: metric, windowDays: m.windowDays))
        }
        guard !(validSections.isEmpty && validMetrics.isEmpty) else { return nil }
        return NeedsHealthRequest(sections: validSections, metrics: validMetrics)
    }
}

// MARK: - Series formatter (pure)

/// One dated aggregate point of a metric's windowed series (a daily value, or a
/// single sample for sparse types).
struct MetricSeriesPoint: Equatable, Sendable {
    let date: Date
    let value: Double
}

/// Renders a requested metric's windowed series into compact lines — one per day
/// (or per sample for sparse types), newest first, with a labeled header. Pure and
/// Foundation-only, so it is unit-tested with fixed series and a fixed clock.
enum MetricSeriesFormatter {
    /// The header + one value line per point. Empty series → a single "no data" line
    /// so a granted-but-empty request still tells the agent it looked and found none.
    static func lines(for metric: RequestableMetric,
                      series: [MetricSeriesPoint],
                      timeZone: TimeZone = .current) -> [String] {
        let header = "\(label(metric)) (last \(series.count) day\(series.count == 1 ? "" : "s")):"
        guard !series.isEmpty else { return ["\(label(metric)): no data in the requested window"] }
        let sorted = series.sorted { $0.date > $1.date }   // newest first
        let body = sorted.map { "  \(day($0.date, timeZone)): \(format(metric, $0.value))" }
        return [header] + body
    }

    /// A short human label for a metric.
    static func label(_ metric: RequestableMetric) -> String {
        switch metric {
        case .restingHeartRate: return "Resting heart rate"
        case .heartRate: return "Heart rate (daily avg)"
        case .heartRateVariabilitySDNN: return "HRV (SDNN)"
        case .stepCount: return "Steps"
        case .activeEnergyBurned: return "Active energy"
        case .bodyMass: return "Body mass"
        case .sleepAnalysis: return "Sleep (asleep)"
        case .vo2Max: return "VO2 max"
        case .workouts: return "Workouts"
        }
    }

    /// Format one value with the metric's unit, integer or one-decimal as fits.
    static func format(_ metric: RequestableMetric, _ value: Double) -> String {
        switch metric {
        case .restingHeartRate, .heartRate: return "\(int(value)) bpm"
        case .heartRateVariabilitySDNN: return "\(int(value)) ms"
        case .stepCount: return "\(int(value)) steps"
        case .activeEnergyBurned: return "\(int(value)) kcal"
        case .bodyMass: return "\(oneDecimal(value)) kg"
        case .sleepAnalysis: return "\(int(value)) min"
        case .vo2Max: return "\(oneDecimal(value)) ml/kg·min"
        case .workouts: return "\(int(value))"
        }
    }

    private static func int(_ v: Double) -> String { String(format: "%.0f", v) }
    private static func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func day(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Fulfillment assembler (pure)

/// Assembles the `health_context` block that answers a validated needs-health
/// request, from the section snapshot and each metric's series. Pure given its
/// inputs (the provider supplies the live data), so the composition + the 6 KiB
/// app-side cap are unit-tested. Returns nil when nothing could be gathered (empty
/// → the coordinator treats it as unfulfillable and answers from vault data).
enum HealthRequestFulfiller {
    /// App-side cap on a fulfilled block — under the bridge's 8 KiB
    /// `MAX_HEALTH_CONTEXT_BYTES`, so a granted request always fits with headroom.
    static let maxBytes = 6 * 1024

    static func block(request: NeedsHealthRequest,
                      snapshot: HealthSnapshot,
                      series: [RequestableMetric: [MetricSeriesPoint]],
                      now: Date,
                      timeZone: TimeZone = .current) -> String? {
        var parts: [String] = []

        if request.sections.contains(.daily) {
            let lines = DailySummaryFormatter.lines(from: snapshot.daily, now: now, timeZone: timeZone)
            if !lines.isEmpty { parts.append(lines.joined(separator: "\n")) }
        }
        if request.sections.contains(.workouts), !snapshot.workouts.isEmpty {
            let ws = Array(snapshot.workouts.prefix(WorkoutContextFormatter.maxWorkouts))
            let header = WorkoutContextFormatter.header(count: ws.count)
            let lines = ws.map { WorkoutContextFormatter.line(for: $0, timeZone: timeZone) }
            parts.append(([header] + lines).joined(separator: "\n"))
        }
        for m in request.metrics {
            let lines = MetricSeriesFormatter.lines(for: m.metric,
                                                    series: series[m.metric] ?? [],
                                                    timeZone: timeZone)
            parts.append(lines.joined(separator: "\n"))
        }

        guard !parts.isEmpty else { return nil }
        let capped = capWholeLines(parts.joined(separator: "\n\n"), maxBytes: maxBytes)
        return capped.isEmpty ? nil : capped
    }

    /// Truncate to at most `maxBytes` UTF-8 bytes on WHOLE-line boundaries (never
    /// mid-line), so a capped block is never a garbled partial line.
    static func capWholeLines(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        var kept: [String] = []
        var used = 0
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let cost = line.utf8.count + (kept.isEmpty ? 0 : 1) // + newline joiner
            if used + cost > maxBytes { break }
            used += cost
            kept.append(String(line))
        }
        return kept.joined(separator: "\n")
    }
}
