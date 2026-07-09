import SwiftUI
import Charts

// The weight-and-trend detail: a Swift Charts line of daily weigh-ins plus a 7-day
// moving average, target rule marks, a range picker, drag-to-scrub, and a BF%
// toggle. This is where "digging" pays off — scrubbing the chart IS the drill-down.
// The moving-average math and range come from `HealthDisplay`; the view only draws.

struct WeightTrendDetail: View {
    let series: [WeightPoint]
    let progress: DietProgress?

    enum Range: String, CaseIterable, Identifiable {
        case d30 = "30d", d90 = "90d", all = "All"
        var id: String { rawValue }
        var days: Int? { self == .d30 ? 30 : self == .d90 ? 90 : nil }
    }

    @State private var range: Range = .d90
    @State private var showBF = false
    @State private var scrubDate: Date?

    /// One chart point with a parsed date; rows whose date doesn't parse are dropped.
    private struct Point: Identifiable {
        let id = UUID()
        var date: Date
        var lbs: Double
        var bf: Double?
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var points: [Point] {
        let parsed = series.compactMap { wp -> Point? in
            guard let d = Self.dayParser.date(from: wp.date) else { return nil }
            return Point(date: d, lbs: wp.lbs, bf: wp.bf)
        }
        guard let days = range.days, let last = parsed.last?.date else { return parsed }
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: last) ?? last
        return parsed.filter { $0.date >= cutoff }
    }

    private var average: [(date: Date, value: Double)] {
        // Reuse the pure builder over the filtered range, re-parsing the dates.
        let filtered = filteredWeightPoints()
        return HealthDisplay.movingAverage(filtered, window: 7).compactMap { ap in
            Self.dayParser.date(from: ap.date).map { ($0, ap.value) }
        }
    }

    private func filteredWeightPoints() -> [WeightPoint] {
        guard let days = range.days,
              let lastDate = series.last.flatMap({ Self.dayParser.date(from: $0.date) }) else { return series }
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: lastDate) ?? lastDate
        return series.filter { (Self.dayParser.date(from: $0.date) ?? .distantPast) >= cutoff }
    }

    private var scrubbed: Point? {
        guard let scrubDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate)) }
    }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                weightChart
                    .frame(height: 240)
                    .listRowSeparator(.hidden)

                if hasBF {
                    Toggle("Body fat %", isOn: $showBF)
                    if showBF { bfChart.frame(height: 140).listRowSeparator(.hidden) }
                }
            }
            if let progress { paceSection(progress) }
        }
        .navigationTitle("Weight & trend")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hasBF: Bool { points.contains { $0.bf != nil } }

    // MARK: charts

    private var weightChart: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Date", p.date), y: .value("Weight", p.lbs))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Date", p.date), y: .value("Weight", p.lbs))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .symbolSize(12)
            }
            ForEach(average, id: \.date) { a in
                LineMark(x: .value("Date", a.date), y: .value("7-day avg", a.value),
                         series: .value("Series", "avg"))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let race = progress?.raceTarget {
                RuleMark(y: .value("Race", race))
                    .foregroundStyle(.green.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("race \(DietSemantics.fmt(race))").font(.caption2).foregroundStyle(.green)
                    }
            }
            if let maint = progress?.maintTarget {
                RuleMark(y: .value("Maint", maint))
                    .foregroundStyle(.blue.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .bottom, alignment: .leading) {
                        Text("maint \(DietSemantics.fmt(maint))").font(.caption2).foregroundStyle(.blue)
                    }
            }
            if let s = scrubbed {
                RuleMark(x: .value("Date", s.date))
                    .foregroundStyle(.primary.opacity(0.3))
                    .annotation(position: .top, alignment: .center, spacing: 4) { scrubLabel(s) }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
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

    private func scrubLabel(_ p: Point) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.dayParser.string(from: p.date)).font(.caption2).foregroundStyle(.secondary)
            Text("\(DietSemantics.fmt(p.lbs)) lb").font(.caption.weight(.semibold).monospacedDigit())
            if let bf = p.bf { Text("\(DietSemantics.fmt(bf))% bf").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    }

    private var bfChart: some View {
        Chart {
            ForEach(points.filter { $0.bf != nil }) { p in
                LineMark(x: .value("Date", p.date), y: .value("BF%", p.bf ?? 0))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Date", p.date), y: .value("BF%", p.bf ?? 0))
                    .foregroundStyle(.orange)
                    .symbolSize(14)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
    }

    // MARK: pace block

    private func paceSection(_ p: DietProgress) -> some View {
        Section("Pace") {
            paceRow("Trough", p.paceBarLabel ?? p.troughPace.map { "\(DietSemantics.fmt($0)) lb/wk" },
                    zone: p.paceZone)
            paceRow("Raw", p.rawPace.map { "\(DietSemantics.fmt($0)) lb/wk" }, zone: nil)
            if let sub = p.paceSubMain { Text(sub).font(.caption).foregroundStyle(.secondary) }
            if let sub = p.paceSubZone { Text(sub).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func paceRow(_ title: String, _ value: String?, zone: String?) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            if let value { Text(value).font(.subheadline.monospacedDigit()) }
            if let zone { ZoneChip(text: zone, zone: zone) }
        }
    }
}
