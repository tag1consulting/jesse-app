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
//
// TARGETS MOVE, so the reference does too. Calories (recomputed from each day's logged
// exercise) and carbs (a base plus an optional fuel band) get a STEPPED target line that
// walks with the data — one flat rule across a month of training days would draw a line
// the user never actually had. The nutrients whose targets really are constants keep the
// flat rule. A day that archived no target of its own is drawn dimmed: it is real data
// with no reference, and the summary band says how many such days are in view.

struct NutrientTrendDetail: View {
    let context: NutrientTrendContext

    enum Range: String, CaseIterable, Identifiable {
        case d7 = "7d", d30 = "30d", d90 = "90d", all = "All"
        var id: String { rawValue }
        var days: Int? {
            switch self { case .d7: return 7; case .d30: return 30; case .d90: return 90; case .all: return nil }
        }

        /// The range that matches the Health tab's window mode, so a nutrient tapped from a
        /// 7d list opens on 7d rather than snapping to the screen's own default. The Day
        /// mode has no matching range and keeps the 30-day default.
        static func matching(_ mode: NutrientWindowMode) -> Range {
            switch mode {
            case .day: return .d30
            case .week: return .d7
            case .month: return .d30
            }
        }
    }

    // 30 days is the meaningful default here (the coverage examples speak to "the last
    // 30 logged days"); the weight trend's 90-day default is for a slower signal. The 7-day
    // option reads the recent tail at a glance — handy while traveling. A caller arriving
    // from the Health tab's window switcher overrides it with the matching range.
    @State private var range: Range
    @State private var scrubDate: Date?

    /// `initialRange` is the range the chart OPENS on; the picker is free from then on.
    /// Defaulted so every existing call site (the drill-down sheet's "View trend" link)
    /// keeps the 30-day default it has always had.
    init(context: NutrientTrendContext, initialRange: Range = .d30) {
        self.context = context
        _range = State(initialValue: initialRange)
    }

    private var nutrient: TrendNutrient { context.nutrient }

    private var trend: NutrientTrend {
        NutrientTrends.analyze(context.series, nutrient: nutrient,
                               targets: context.targets, windowDays: range.days)
    }

    /// One plotted day with a parsed date and THAT day's own target basis (nil when the
    /// day archived none — drawn dimmed, judged by nothing).
    private struct Pt: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let isPartial: Bool
        let dayTarget: DayTarget?
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
                .map { Pt(id: p.date, date: $0, value: p.value, isPartial: p.isPartial,
                          dayTarget: p.dayTarget) }
        }
    }

    /// Break a run of days into segments at every calendar gap, so a LineMark run only
    /// ever connects days that are actually adjacent — a missing day leaves a visible gap.
    private func runs(_ pts: [Pt]) -> [Segment] {
        var segs: [Segment] = []
        var current: [Pt] = []
        var nextId = 0
        for p in pts {
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

    private var segments: [Segment] { runs(points) }

    /// The runs the STEPPED target line is drawn over: consecutive days that each recorded
    /// a target of their own. A target-unknown day breaks the line exactly as a data gap
    /// breaks the value line — the reference is missing, so it is not drawn across.
    private var targetSegments: [Segment] { runs(points.filter { $0.dayTarget != nil }) }

    /// True for the nutrients whose target genuinely moves day to day (calories, fat,
    /// carbs): they get the stepped line. The rest keep the flat rule mark.
    private var usesSteppedTarget: Bool { nutrient.kind == .target }

    /// The target rule's color reads the nutrient's day-goal, matching the dot coloring:
    /// green for a floor to reach, orange for a ceiling/window cap to stay under, and a
    /// neutral secondary for an informational reference line.
    private var ruleColor: Color {
        switch nutrient.dayGoal {
        case .floor: return .green
        case .ceiling, .window: return .orange
        case nil: return .secondary
        }
    }

    /// The `DietSemantics` status color for one plotted day, reusing the daily gauge's
    /// palette so the trend dot matches the color the Today bar gives that value — judged
    /// against THAT DAY's own target, never today's. A day that recorded no target of its
    /// own is dimmed rather than coloured: there is nothing to have been good or bad
    /// against, and a colour there would be a verdict the data cannot support.
    private func markColor(_ p: Pt) -> Color {
        guard let basis = p.dayTarget else { return .secondary.opacity(0.35) }
        return statusColor(NutrientTrends.dayStatus(nutrient, value: p.value,
                                                    isPartial: p.isPartial, target: basis.value))
    }

    /// A 0-based y-domain that always includes every reference drawn — today's flat rule,
    /// each day's own target, and the top of the carb fuel band — so a value near the
    /// floor reads as genuinely low and no reference is clipped off the top.
    private var yDomain: ClosedRange<Double> {
        let references = points.flatMap { [$0.dayTarget?.value, $0.dayTarget?.band] }.compactMap { $0 }
        let hi = max(points.map(\.value).max() ?? 0,
                     usesSteppedTarget ? 0 : (trend.target ?? 0),
                     references.max() ?? 0)
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
        .dietNavTitle(.inline)
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
            // The line above covers only the LOADED day's meals; when the bridge sends the
            // per-item history, the range-wide ranking is one tap away. This is the whole
            // point of the pairing: the chart raises "saturated fat runs high", and that
            // screen answers "from what".
            if let sourceSeries = context.sourceSeries, NutrientSources.isAvailable(sourceSeries) {
                NavigationLink {
                    NutrientSourcesDetail(nutrient: nutrient, series: sourceSeries,
                                          targets: context.targets,
                                          nutrientSeries: context.series, meals: context.meals,
                                          initialRange: range == .d7 ? 7 : 30)
                } label: {
                    NavRow(title: "Where it comes from", icon: "list.bullet.rectangle",
                           subtitle: "top foods over the last 7 or 30 days")
                }
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
        var out = "Gaps are days this nutrient wasn't measured — never counted as zero."
        if trend.partialCount > 0 {
            out += " Hollow points are partial days (a lower bound: at least this much)."
        }
        if usesSteppedTarget {
            out += nutrient == .c
                ? " The dashed line is each day's own carb base; the shaded band above it is"
                    + " optional exercise fuel, never an obligation."
                : " The dashed line is each day's own target, which moves with that day's"
                    + " logged training — not one number across the range."
        }
        if trend.daysTargetUnknown > 0 {
            out += " Dimmed points are days that recorded no target of their own:"
                + " plotted, never judged."
        }
        return out
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
            // interpolation (no catmullRom) so it can't dip toward zero between points. The
            // line is a neutral connector — the per-day GOAL color lives on the dots, which
            // would read as noise smeared along a multi-colored line.
            ForEach(segments) { seg in
                ForEach(seg.points) { p in
                    LineMark(x: .value("Date", p.date), y: .value(nutrient.fullName, p.value),
                             series: .value("Segment", seg.id))
                        .foregroundStyle(.secondary.opacity(0.4))
                }
            }
            // Complete known days: filled points, colored by that day's goal status (the
            // same greens/ambers/reds the daily bars use) so under/on/over reads at a glance.
            // Position relative to the target rule carries the same signal for accessibility.
            ForEach(points.filter { !$0.isPartial }) { p in
                PointMark(x: .value("Date", p.date), y: .value(nutrient.fullName, p.value))
                    .foregroundStyle(markColor(p))
                    .symbolSize(36)
            }
            // Partial days: a hollow ring (outer status disc + inner background hole) to
            // read as "at least this", distinct from a complete day. A partial ring only
            // takes a red/green once its lower bound already proves the breach; otherwise it
            // stays neutral rather than overclaim (see `NutrientTrends.dayStatus`).
            ForEach(points.filter { $0.isPartial }) { p in
                PointMark(x: .value("Date", p.date), y: .value(nutrient.fullName, p.value))
                    .foregroundStyle(markColor(p)).symbolSize(70)
                PointMark(x: .value("Date", p.date), y: .value(nutrient.fullName, p.value))
                    .foregroundStyle(Color.dietBackground).symbolSize(26)
            }
            // The reference. For calories, fat and carbs it STEPS with the data — one flat
            // rule would draw a line the day never had — and for carbs the shaded band
            // above the base is the optional exercise add-back, drawn because it explains
            // the shape of the days and never because it is a goal.
            if usesSteppedTarget {
                ForEach(targetSegments) { seg in
                    ForEach(seg.points) { p in
                        if let band = p.dayTarget?.band, let base = p.dayTarget?.value {
                            AreaMark(x: .value("Date", p.date),
                                     yStart: .value("Base", base), yEnd: .value("Fuel", band),
                                     series: .value("Series", "fuel-\(seg.id)"))
                                .foregroundStyle(ruleColor.opacity(0.12))
                                .interpolationMethod(.stepCenter)
                        }
                    }
                    ForEach(seg.points) { p in
                        if let basis = p.dayTarget {
                            // A STRING series key, deliberately: Swift Charts groups by the
                            // series VALUE, so an Int key here collides with the value
                            // line's `seg.id` and the run inherits its pale styling —
                            // which is exactly how the first run went missing once.
                            LineMark(x: .value("Date", p.date),
                                     y: .value("Target", basis.value),
                                     series: .value("Series", "target-\(seg.id)"))
                                .foregroundStyle(ruleColor.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .interpolationMethod(.stepCenter)
                        }
                    }
                }
            } else if let target = trend.target {
                // A constant floor/ceiling keeps the flat rule it has always drawn.
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
        switch nutrient.dayGoal {
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .window: return "cap"
        case nil: return "ref"
        }
    }

    private func scrubLabel(_ p: Pt) -> some View {
        // The under/on/over word behind the color, so the readout carries the same signal
        // (accessibility) — measured against THAT DAY's own target. Nil for an informational
        // day, a day with no recorded target, or a partial day the unknowns leave undecided:
        // never an overclaim. A judged day tints its value to match its dot; a neutral
        // (`.suspended`) day stays primary so the number never reads as muted.
        let basis = p.dayTarget?.value
        let status = NutrientTrends.dayStatus(nutrient, value: p.value,
                                              isPartial: p.isPartial, target: basis)
        let phrase = p.dayTarget == nil ? nil
            : NutrientTrends.dayStatusPhrase(nutrient, value: p.value,
                                             isPartial: p.isPartial, target: basis)
        return VStack(alignment: .leading, spacing: 2) {
            Text(p.id).font(.caption2).foregroundStyle(.secondary)
            Text("\(p.isPartial ? "≥" : "")\(NutrientTrends.fmt(p.value)) \(nutrient.unit)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(p.dayTarget == nil || status == .suspended
                                 ? Color.primary : statusColor(status))
            // The day's OWN reference, named as that day's, plus the signed distance from
            // it — the one number a reader of this chart actually wants.
            if let d = p.dayTarget {
                Text("\(NutrientTrends.deltaWords(d.delta(p.value), nutrient.unit))"
                     + " \(NutrientTrends.basisNoun(nutrient)) (\(NutrientTrends.fmt(d.value)))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("no target recorded that day").font(.caption2).foregroundStyle(.secondary)
            }
            if let phrase {
                Text(phrase).font(.caption2).foregroundStyle(.secondary)
            }
            if p.isPartial {
                Text("partial day").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    }
}
