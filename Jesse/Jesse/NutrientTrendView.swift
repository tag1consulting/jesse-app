import SwiftUI
import Charts

// The per-nutrient trend detail — ONE nutrient, one tap deeper than its drill-down
// sheet, drawn in the same Swift Charts language as `WeightTrendDetail`: a range
// picker (30d / 90d / All), drag-to-scrub, and a target rule mark. What makes it an
// insight and not just a line: a plain-language verdict from the engine (coverage
// first, judgment only where the kind allows), the static consequence copy, where the
// nutrient is coming from (top sources), and — for a short floor — how to raise it.
//
// The engine (`NutrientTrends`) does every gap-aware computation; this view only draws.
// GAPS are honored: known days plot as points, and the line is broken across any
// missing day, so a gap reads as "no data", never a dip to zero. Partial days (a lower
// bound) plot as hollow points.

struct NutrientTrendDetail: View {
    let context: NutrientTrendContext

    enum Range: String, CaseIterable, Identifiable {
        case d30 = "30d", d90 = "90d", all = "All"
        var id: String { rawValue }
        var days: Int? { self == .d30 ? 30 : self == .d90 ? 90 : nil }
    }

    // 30 days is the meaningful default here (the coverage examples speak to "the last
    // 30 logged days"); the weight trend's 90-day default is for a slower signal.
    @State private var range: Range = .d30
    @State private var scrubDate: Date?

    private var nutrient: TrendNutrient { context.nutrient }

    private var trend: NutrientTrend {
        NutrientTrends.analyze(context.series, nutrient: nutrient,
                               targets: context.targets, windowDays: range.days)
    }

    /// One plotted day with a parsed date.
    private struct Pt: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let isPartial: Bool
    }

    /// A run of calendar-consecutive known days — the unit the line is drawn over, so it
    /// never bridges a gap.
    private struct Segment: Identifiable {
        let id: Int
        let points: [Pt]
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var points: [Pt] {
        trend.points.compactMap { p in
            NutrientTrends.dayParser.date(from: p.date)
                .map { Pt(id: p.date, date: $0, value: p.value, isPartial: p.isPartial) }
        }
    }

    /// Break the known days into segments at every calendar gap, so a LineMark run only
    /// ever connects days that are actually adjacent — a missing day leaves a visible gap.
    private var segments: [Segment] {
        var segs: [Segment] = []
        var current: [Pt] = []
        var nextId = 0
        for p in points {
            if let last = current.last {
                let gap = Self.utcCalendar.dateComponents([.day], from: last.date, to: p.date).day ?? 99
                if gap > 1 {
                    segs.append(Segment(id: nextId, points: current)); nextId += 1; current = []
                }
            }
            current.append(p)
        }
        if !current.isEmpty { segs.append(Segment(id: nextId, points: current)) }
        return segs
    }

    /// The target rule's color reads the nutrient's kind: green for a floor to reach,
    /// orange for a ceiling to stay under, and a neutral secondary for a target line.
    private var ruleColor: Color {
        switch nutrient.kind {
        case .floor: return .green
        case .ceiling: return .orange
        case .target, .informational: return .secondary
        }
    }

    /// A 0-based y-domain that always includes the target, so a value near the floor
    /// reads as genuinely low and the target rule is never clipped off the top.
    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        let hi = max(values.max() ?? 0, trend.target ?? 0)
        return 0...(hi > 0 ? hi * 1.15 : 1)
    }

    private var scrubbed: Pt? {
        guard let scrubDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate))
        }
    }

    private var topSources: [NutrientSource] {
        NutrientTrends.topSources(nutrient, meals: context.meals, limit: 3)
    }

    /// A short "raise it with" hint — only for a floor that is genuinely short (median
    /// under target on most known days), drawn from the static good-source list.
    private var raiseHint: String? {
        guard nutrient.kind == .floor,
              let pct = trend.pctUnderTarget, pct >= 0.5 else { return nil }
        return "Raise it with: \(nutrient.goodSourcesText)."
    }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if points.isEmpty {
                    emptyChart
                } else {
                    chart.frame(height: 240).listRowSeparator(.hidden)
                }
            }
            summarySection
        }
        .navigationTitle(nutrient.fullName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Summary band

    private var summarySection: some View {
        Section {
            // The plain-language verdict from the engine — coverage first, a judgment only
            // where the kind allows, and a hedge when coverage is thin.
            Text(NutrientTrends.verdict(trend))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // The static consequence copy, so no health claim is invented.
            Label {
                Text(nutrient.whyItMatters)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
            }

            // Where it is coming from — the real top-contributing foods the app has for
            // this range. Shown only when a known contributor exists (never a guess).
            if !topSources.isEmpty {
                sourcesRow
            }
            if let raiseHint {
                Text(raiseHint)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Trend")
        } footer: {
            Text(partialFooter)
        }
    }

    private var sourcesRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Top sources in this range")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(topSources.map(\.name).joined(separator: ", "))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var partialFooter: String {
        let base = "Gaps are days this nutrient wasn't measured — never counted as zero."
        return trend.partialCount > 0
            ? base + " Hollow points are partial days (a lower bound: at least this much)."
            : base
    }

    // MARK: - Chart

    private var emptyChart: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.tertiary)
            Text("No known \(nutrient.fullName) days in this range yet.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }

    private var chart: some View {
        Chart {
            // Broken line: one connected run per segment, never bridging a gap. Linear
            // interpolation (no catmullRom) so it can't dip toward zero between points.
            ForEach(segments) { seg in
                ForEach(seg.points) { p in
                    LineMark(x: .value("Date", p.date), y: .value(nutrient.fullName, p.value),
                             series: .value("Segment", seg.id))
                        .foregroundStyle(Color.accentColor.opacity(0.55))
                }
            }
            // Complete known days: filled points.
            ForEach(points.filter { !$0.isPartial }) { p in
                PointMark(x: .value("Date", p.date), y: .value(nutrient.fullName, p.value))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(36)
            }
            // Partial days: a hollow ring (outer accent disc + inner background hole) to
            // read as "at least this", distinct from a complete day.
            ForEach(points.filter { $0.isPartial }) { p in
                PointMark(x: .value("Date", p.date), y: .value(nutrient.fullName, p.value))
                    .foregroundStyle(Color.accentColor).symbolSize(70)
                PointMark(x: .value("Date", p.date), y: .value(nutrient.fullName, p.value))
                    .foregroundStyle(Color(.systemBackground)).symbolSize(26)
            }
            // The target rule, when the snapshot carries one — labeled by kind.
            if let target = trend.target {
                RuleMark(y: .value("Target", target))
                    .foregroundStyle(ruleColor.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("\(NutrientTrends.fmt(target)) \(nutrient.unit) \(kindWord)")
                            .font(.caption2).foregroundStyle(ruleColor)
                    }
            }
            if let s = scrubbed {
                RuleMark(x: .value("Date", s.date))
                    .foregroundStyle(.primary.opacity(0.3))
                    .annotation(position: .top, alignment: .center, spacing: 4) { scrubLabel(s) }
            }
        }
        .chartYScale(domain: yDomain)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = value.location.x - geo[plotFrame].origin.x
                            if let d: Date = proxy.value(atX: x) { scrubDate = d }
                        }
                        .onEnded { _ in scrubDate = nil })
            }
        }
    }

    private var kindWord: String {
        switch nutrient.kind {
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .target: return "target"
        case .informational: return "ref"
        }
    }

    private func scrubLabel(_ p: Pt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.id).font(.caption2).foregroundStyle(.secondary)
            Text("\(p.isPartial ? "≥" : "")\(NutrientTrends.fmt(p.value)) \(nutrient.unit)")
                .font(.caption.weight(.semibold).monospacedDigit())
            if p.isPartial {
                Text("partial day").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    }
}
