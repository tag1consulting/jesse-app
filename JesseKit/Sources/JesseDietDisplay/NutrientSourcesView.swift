import SwiftUI
import JesseNetworking

// The Sources screens: which foods actually delivered a nutrient over the last week or
// month. Reached from a nav row on the Health tab, and from the per-nutrient trend chart —
// which is the path that matters, because the trend is where the question is raised
// ("saturated fat runs high on the 7-day median") and this is where it is answered ("it is
// mostly cheese and cured meat").
//
// Two levels, matching every other drill-down on this tab: an overview listing each
// nutrient with its leading foods, and a per-nutrient list with the full ranking. Every
// number comes from `NutrientSources`, which is pure and unit-tested; these views only draw.
//
// The unknown rule is printed on the screen rather than left implied. A ranking over
// measured foods is a different claim from a ranking over all foods, and a screen that
// shows shares has to say which total they are shares OF.

// MARK: - Level 1: every nutrient's leading sources

struct NutrientSourcesOverview: View {
    let series: [SourceDay]
    let targets: DietTargets
    /// The nutrient history, carried through so a tapped nutrient can open its trend chart
    /// from inside the Sources detail — the loop runs both ways.
    var nutrientSeries: [NutrientDay]?
    var meals: [DietMeal] = []

    @State private var windowDays: Int

    /// `initialRange` is the range the screen OPENS on, so arriving from a 7d window lands
    /// on 7d rather than snapping to the screen's own default.
    init(series: [SourceDay], targets: DietTargets, nutrientSeries: [NutrientDay]? = nil,
         meals: [DietMeal] = [], initialRange: Int = 30) {
        self.series = series
        self.targets = targets
        self.nutrientSeries = nutrientSeries
        self.meals = meals
        _windowDays = State(initialValue: NutrientSources.ranges.contains(initialRange) ? initialRange : 30)
    }

    private var rankings: [NutrientSourceRanking] {
        NutrientSources.overview(series, windowDays: windowDays)
    }

    /// The range's last logged day — the anchor every Sources ask is dated from, so two
    /// asks about "the last 30 days" a week apart are two different readings.
    private var anchor: String { series.last?.date ?? "" }

    var body: some View {
        List {
            Section {
                rangePicker($windowDays)
            }

            if rankings.isEmpty {
                Section {
                    Text("No logged food in the last \(windowDays) days carries a measured "
                         + "nutrient value yet, so there is nothing to rank.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section {
                    ForEach(rankings, id: \.nutrient) { r in
                        NavigationLink {
                            NutrientSourcesDetail(nutrient: r.nutrient, series: series,
                                                  targets: targets, nutrientSeries: nutrientSeries,
                                                  meals: meals, initialRange: windowDays)
                        } label: {
                            NutrientSourceSummaryRow(ranking: r)
                        }
                        .askable(HealthAsk.sourceRanking(r, anchor: anchor))
                    }
                } header: {
                    Text("Last \(windowDays) days")
                }
                Section { CaveatRow(text: NutrientSources.unknownRule) }
            }
        }
        .navigationTitle("Sources")
        .dietNavTitle(.inline)
        .askPageToolbar(HealthAsk.sourcesOverview(rankings, windowDays: windowDays,
                                                  anchor: anchor, scope: .page))
    }
}

/// A caveat that states what the numbers above do and do not cover, as a ROW rather than a
/// `Section` footer.
///
/// The row is not a style preference, it is the only shape that survives both platforms.
/// macOS lays a `Section` footer out on ONE line and ellipsises the rest; forcing the wrap
/// with `lineLimit(nil)` makes it wrap and then CLIPS it against the following section. Both
/// outcomes cut a sentence whose second half is the part that matters ("…is unknown, not
/// zero, so it is left out of both the list and the total", "…is left out rather than counted
/// as zero"). A truncated caveat is worse than no caveat at all, because the numbers above
/// still read as complete while the qualification silently disappears. A plain row wraps
/// correctly everywhere, so both screens use this and the wording is never at the mercy of a
/// platform's footer metrics.
///
/// Note this is a general quirk of long footers on macOS, not something these screens
/// introduced: the shipped Consistency screen's gap rule truncates the same way and is left
/// alone here as out of scope.
struct CaveatRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }
}

/// The shared 7d / 30d picker. One spelling, so the overview and the per-nutrient list can
/// never offer different ranges — and it is capped at 30 because the bridge sends 45 days of
/// per-item detail, so a longer option would print a label the data cannot back.
@ViewBuilder
func rangePicker(_ selection: Binding<Int>) -> some View {
    Picker("Range", selection: selection) {
        ForEach(NutrientSources.ranges, id: \.self) { Text("\($0)d").tag($0) }
    }
    .pickerStyle(.segmented)
    .accessibilityLabel("Source range")
}

/// One nutrient's row on the overview: the goal glyph and name, then the plain-language
/// "mostly X and Y" line. No colour judgment — this screen says where a nutrient came from,
/// not whether the amount was good, which is the trend chart's question.
struct NutrientSourceSummaryRow: View {
    let ranking: NutrientSourceRanking

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                GoalChip(goal: ranking.nutrient.displayGoal)
                Text(ranking.nutrient.fullName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(ranking.contributorCount) \(ranking.contributorCount == 1 ? "food" : "foods")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let line = NutrientSources.summaryLine(ranking) {
                Text(line)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ranking.nutrient.fullName): "
                            + (NutrientSources.summaryLine(ranking) ?? "no measured sources"))
    }
}

// MARK: - Level 2: one nutrient's ranked foods

struct NutrientSourcesDetail: View {
    let nutrient: TrendNutrient
    let series: [SourceDay]
    let targets: DietTargets
    var nutrientSeries: [NutrientDay]?
    var meals: [DietMeal] = []

    @State private var windowDays: Int

    init(nutrient: TrendNutrient, series: [SourceDay], targets: DietTargets,
         nutrientSeries: [NutrientDay]? = nil, meals: [DietMeal] = [], initialRange: Int = 30) {
        self.nutrient = nutrient
        self.series = series
        self.targets = targets
        self.nutrientSeries = nutrientSeries
        self.meals = meals
        _windowDays = State(initialValue: NutrientSources.ranges.contains(initialRange) ? initialRange : 30)
    }

    private var ranking: NutrientSourceRanking {
        NutrientSources.rank(series, nutrient: nutrient, windowDays: windowDays)
    }

    private var anchor: String { series.last?.date ?? "" }

    var body: some View {
        let r = ranking
        return List {
            Section {
                rangePicker($windowDays)

                if r.isEmpty {
                    // Nothing known contributed. Say exactly that — a guess dressed as a
                    // ranking would be worse than an empty screen.
                    Text("Nothing logged in the last \(windowDays) days carries a measured "
                         + "\(nutrient.fullName.lowercased()) value, so there is nothing to rank.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    totalLine(r)
                }
                // The coverage facts sit WITH the total they qualify — how many days
                // measured it, and whether unmeasured foods make the total a floor.
                CaveatRow(text: NutrientSources.coverageLine(r))
            }

            if !r.isEmpty {
                Section {
                    ForEach(r.entries) { entry in
                        NutrientSourceRow(entry: entry, nutrient: nutrient)
                            .askable(HealthAsk.sourceEntry(entry, in: r, anchor: anchor))
                    }
                } header: {
                    Text("Top sources")
                        .askable(HealthAsk.sourceRanking(r, anchor: anchor, scope: .section))
                }
                Section { CaveatRow(text: NutrientSources.unknownRule) }
            }

            // Back to the reading this screen explains. The trend answers "how much, and is
            // that a pattern"; this one answers "from what" — each is the other's next
            // question, so both directions are one tap.
            if let nutrientSeries, NutrientTrends.isAvailable(nutrientSeries) {
                Section {
                    NavigationLink {
                        NutrientTrendDetail(
                            context: NutrientTrendContext(nutrient: nutrient, series: nutrientSeries,
                                                          targets: targets, meals: meals,
                                                          sourceSeries: series),
                            initialRange: windowDays == 7 ? .d7 : .d30)
                    } label: {
                        NavRow(title: "\(nutrient.fullName) trend", icon: "chart.xyaxis.line",
                               subtitle: "how much, day by day")
                    }
                }
            }
        }
        .navigationTitle("\(nutrient.fullName) sources")
        .dietNavTitle(.inline)
        .askPageToolbar(HealthAsk.sourceRanking(ranking, anchor: anchor, scope: .page))
    }

    /// The measured total the shares are taken against, marked "≥" whenever an unmeasured
    /// food in the range means it is a floor — the same convention the day drill-down uses.
    private func totalLine(_ r: NutrientSourceRanking) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Measured total")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text("\(r.isPartial ? "≥" : "")\(NutrientTrends.fmt(r.knownTotal, nutrient)) \(nutrient.unit)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}

/// One food in the ranking: name, summed contribution, a proportional bar in the nutrient's
/// identity colour, its share of the measured total, and how many days it appeared on. The
/// day count is the row's real insight — it separates a staple from a one-off.
struct NutrientSourceRow: View {
    let entry: NutrientSourceEntry
    let nutrient: TrendNutrient

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.name).font(.subheadline)
                Spacer()
                Text("\(NutrientTrends.fmt(entry.value, nutrient)) \(nutrient.unit)")
                    .font(.subheadline.monospacedDigit())
            }
            HStack(spacing: 8) {
                ProportionBar(fraction: entry.share, color: metricTint(nutrient.contributionMetric))
                Text(NutrientSources.pct(entry.share))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            }
            Text("on \(entry.days) \(entry.days == 1 ? "day" : "days")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name): \(NutrientTrends.fmt(entry.value, nutrient)) \(nutrient.unit), "
                            + "\(NutrientSources.pct(entry.share)) of the measured total, "
                            + "on \(entry.days) \(entry.days == 1 ? "day" : "days")")
    }
}
