import SwiftUI

// The Level-2 detail screens (except the weight chart, which is its own file). Each
// renders purely from `DietSnapshot` + `DietSemantics`/`Explainers`; no business
// logic lives in a view body.

/// Map a progress zone string to a color chip.
func zoneColor(_ zone: String?) -> Color {
    switch zone?.lowercased() {
    case "good", "on", "ok", "green": return .green
    case "watch", "yellow", "warn": return .orange
    case "concern", "high", "over", "red", "bad": return .red
    default: return .secondary
    }
}

/// A small colored zone chip.
struct ZoneChip: View {
    let text: String
    let zone: String?
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(zoneColor(zone).opacity(0.18)))
            .foregroundStyle(zoneColor(zone))
    }
}

// MARK: - 1. Macros & calories

struct MacrosCaloriesDetail: View {
    let today: DietToday
    let hour: Int
    /// A reconstructed day has no recorded targets → plain totals, no bars/colors.
    var neutral: Bool = false
    @State private var explainer: Explainer?

    private var g: DietGauges { DietSemantics.gauges(for: today, hour: hour) }
    private var totals: MacroTotals { DietSemantics.dayTotals(today.meals) }
    private var net: NetCalories { NetCalories(intake: totals.cal, burned: DietSemantics.burnedCalories(today.exercise)) }

    var body: some View {
        Group {
            if neutral { neutralBody } else { judgedBody }
        }
        .navigationTitle("Macros & calories")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $explainer) { ExplainerSheet(explainer: $0) }
    }

    private var judgedBody: some View {
        List {
            Section {
                bar(g.calories, Explainers.calories(g.calories, isCarbLoad: g.isCarbLoad),
                    metric: .calories)
                // Macro bars in canonical order (Protein, Carbs, Fiber, Fat); the
                // carbs bonus row follows carbs, so fiber sits right after them.
                ForEach(g.orderedMacros, id: \.macro) { entry in
                    bar(entry.gauge, Explainers.macro(entry.macro, gauges: g),
                        metric: .macro(entry.macro), isSubEntry: entry.macro.isSubEntry)
                    if entry.macro == .carbs, let bonus = g.carbsBonus { bonusRow(bonus) }
                }
            }
            Section("Net calories") {
                NetCalorieBar(net: g.net)
                    .onTapGesture { explainer = Explainers.netCalories(g.net) }
            }
            Section {
                legend
            }
        }
    }

    // Neutral: plain per-macro totals, no bars, no colors, no goal glyphs — a
    // reconstructed day had no targets to judge against.
    private var neutralBody: some View {
        List {
            Section {
                totalRow("Calories", "\(DietSemantics.fmt(totals.cal))")
                // Canonical order (Protein, Carbs, Fiber, Fat); fiber renders as a
                // sub-entry of carbs (smaller + secondary label).
                ForEach(Macro.allCases, id: \.self) { macro in
                    totalRow(macro.displayName, "\(DietSemantics.fmt(totals.grams(for: macro)))g",
                             isSubEntry: macro.isSubEntry)
                }
            } footer: {
                Text(NeutralMode.noTargetsCaption)
            }
            if net.burned > 0 {
                Section("Net calories") {
                    totalRow("Eaten", "\(DietSemantics.fmt(net.intake))")
                    totalRow("Burned", "\(DietSemantics.fmt(net.burned))")
                    totalRow("Net", "\(DietSemantics.fmt(net.net))")
                }
            }
        }
    }

    private func totalRow(_ title: String, _ value: String, isSubEntry: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(isSubEntry ? .footnote : .body)
                .foregroundStyle(isSubEntry ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            Spacer()
            Text(value).font(.body.monospacedDigit())
        }
    }

    private func bar(_ gauge: MetricGauge, _ ex: Explainer, metric: ContributionMetric,
                     isSubEntry: Bool = false) -> some View {
        // Attach the "what fed this" drill-down to the row's explainer, so the same
        // tap that opens the explanation also carries the contributing foods and the
        // grounding for the on-device insight.
        var withFoods = ex
        withFoods.drilldown = drilldown(for: metric, gauge: gauge)
        return MetricBarRow(gauge: gauge, isSubEntry: isSubEntry) { explainer = withFoods }
    }

    /// Build the drill-down for a tapped metric: the ranked contributing foods (from
    /// the same meals the totals came from) plus the grounded insight input. The
    /// headline is the gauge's own value, so the foods reconcile against the number the
    /// row is showing.
    private func drilldown(for metric: ContributionMetric, gauge: MetricGauge) -> FoodDrilldown {
        let breakdown = FoodContributions.breakdown(today.meals, metric: metric, total: gauge.value)
        let input = HealthInsight.input(
            metric: metric, total: gauge.value,
            goalPhrase: goalPhrase(gauge.goal), statusLine: gauge.remaining,
            dayStyle: g.isCarbLoad ? "carb-load day" : "ordinary day",
            contributions: breakdown.contributions)
        return FoodDrilldown(breakdown: breakdown, insightInput: input)
    }

    /// How a metric is judged, in plain words for the insight grounding.
    private func goalPhrase(_ goal: DietSemantics.Goal) -> String {
        switch goal {
        case .floor: return "a floor to hit or beat"
        case .ceiling: return "a ceiling to stay under"
        case .window: return "a target window"
        }
    }

    private func bonusRow(_ bonus: CarbsBonus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bonus.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(DietSemantics.fmt(bonus.consumed)) / \(DietSemantics.fmt(bonus.pool))g")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            StatusMeter(fraction: bonus.fraction, status: .green, height: 5)
        }
        .padding(.leading, 24)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("≥", "floor")
            legendItem("≤", "ceiling")
            legendItem("↕", "window")
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
    private func legendItem(_ glyph: String, _ label: String) -> some View {
        HStack(spacing: 4) { Text(glyph).fontWeight(.bold); Text(label) }
    }
}

/// The two-part net-calorie bar: intake with the exercise-burn portion marked.
struct NetCalorieBar: View {
    let net: NetCalories
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(DietSemantics.fmt(net.net)) net")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Spacer()
                Text("\(DietSemantics.fmt(net.intake)) in · \(DietSemantics.fmt(net.burned)) burned")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                let intake = max(net.intake, 1)
                let burnedFrac = min(max(net.burned / intake, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.accentColor.opacity(0.85))
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: geo.size.width * burnedFrac)
                        .overlay(Capsule().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .frame(width: geo.size.width * burnedFrac, alignment: .leading)
                }
            }
            .frame(height: 10)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 2. Food journal

struct FoodJournalDetail: View {
    let today: DietToday
    let proposed: DietProposed?

    private var meals: [DietMeal] { DietSemantics.sortedMeals(today.meals) }
    private var grand: MacroTotals { DietSemantics.dayTotals(today.meals) }

    var body: some View {
        List {
            summarySection
            ForEach(Array(meals.enumerated()), id: \.offset) { _, meal in
                mealCard(meal)
            }
            if let proposed, !proposed.ideas.isEmpty {
                plannedSection(proposed)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Food journal")
        .navigationBarTitleDisplayMode(.inline)
    }

    // A day-summary card: total calories large, one stacked bar of where they came
    // from, and the grand macro line. This replaces the old grand-total footer.
    private var summarySection: some View {
        Section {
            HealthCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(DietSemantics.fmt(grand.cal))")
                            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        Text("cal today").font(.subheadline).foregroundStyle(.secondary)
                    }
                    CalorieSourceBar(split: HealthDisplay.calorieSplit(grand))
                    // Grand macro line: fiber reads as a sub-entry of carbs — one
                    // ramp step smaller (caption → caption2) and dimmer (tertiary).
                    macroCaptionText(grand, fiberFont: .caption2, fiberColor: Color(uiColor: .tertiaryLabel))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .cardRow()
        }
    }

    private func mealCard(_ meal: DietMeal) -> some View {
        Section {
            HealthCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(meal.name).font(.headline)
                        if let t = meal.time { TimeCapsule(time: t) }
                        Spacer()
                        Text("\(DietSemantics.fmt(DietSemantics.subtotal(of: meal).cal)) cal")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    ForEach(Array(meal.items.enumerated()), id: \.offset) { _, it in
                        itemRow(it)
                    }
                    Divider()
                    subtotalRow(DietSemantics.subtotal(of: meal))
                }
            }
            .cardRow()
        }
    }

    private func itemRow(_ it: DietItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(it.item).font(.subheadline)
                if let a = it.amount { Text(a).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let cal = it.cal {
                    Text("\(DietSemantics.fmt(cal)) cal").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(MacroLine.format(MacroTotals(cal: 0, p: it.p ?? 0, f: it.f ?? 0, c: it.c ?? 0, fiber: it.fiber ?? 0)))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    // The full macro names don't fit beside "Subtotal" and the calories on one line
    // at default Dynamic Type, so the macro line drops to its own full-width line
    // below (matching the item-row layout directly above). Units are kept there for
    // parity with the item rows.
    private func subtotalRow(_ t: MacroTotals) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Subtotal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(DietSemantics.fmt(t.cal)) cal")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            // Subtotal macro line: fiber as a sub-entry of carbs (smaller + dimmer).
            macroCaptionText(t, fiberFont: .caption2, fiberColor: Color(uiColor: .tertiaryLabel))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Proposed meal ideas, styled distinctly from logged meals (secondary tint,
    // "Planned" header) so logged vs proposed is unmistakable.
    private func plannedSection(_ proposed: DietProposed) -> some View {
        Section {
            ForEach(Array(proposed.ideas.enumerated()), id: \.offset) { _, idea in
                HealthCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").font(.caption).foregroundStyle(.secondary)
                            Text(idea.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            if let t = idea.time { TimeCapsule(time: t) }
                            Spacer()
                            let tot = DietSemantics.total(of: idea.items)
                            Text("~\(DietSemantics.fmt(tot.cal)) cal")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(MacroLine.format(DietSemantics.total(of: idea.items)))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        if let notes = idea.notes {
                            Text(notes).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .cardRow()
            }
            if let source = proposed.source {
                Text("Source: \(source)").font(.caption2).foregroundStyle(.tertiary)
                    .cardRow()
            }
            if let gap = proposed.gapNote {
                Text(gap).font(.caption).foregroundStyle(.secondary)
                    .cardRow()
            }
        } header: {
            Label("Planned", systemImage: "calendar.badge.clock")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private extension View {
    /// The card list-row treatment shared by the food-journal and exercise cards:
    /// no separators, a clear background, and a snug inset so the cards float.
    func cardRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - 3. Exercise

struct ExerciseDetail: View {
    let exercise: [DietExercise]
    private var sessions: [DietExercise] { DietSemantics.sortedExercise(exercise) }

    private let columns = [GridItem(.flexible(), alignment: .topLeading),
                           GridItem(.flexible(), alignment: .topLeading),
                           GridItem(.flexible(), alignment: .topLeading)]

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView("No exercise logged", systemImage: "figure.run")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(sessions.enumerated()), id: \.offset) { _, ex in
                card(ex).cardRow()
            }
        }
        .listStyle(.plain)
        .navigationTitle("Exercise")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func card(_ ex: DietExercise) -> some View {
        HealthCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: ExerciseSymbol.name(for: ex.type))
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 30)
                    Text(ex.type.capitalized).font(.headline)
                    Spacer()
                    if let t = ex.time { TimeCapsule(time: t) }
                }
                let tiles = metrics(ex)
                if !tiles.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(tiles, id: \.0) { tile in
                            MetricTile(label: tile.0, value: tile.1)
                        }
                    }
                }
                if let d = ex.desc {
                    Text(d).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The (label, value) metric tiles present for a session, in a fixed order:
    /// Duration, Distance, Pace, Avg HR, Calories. Absent fields are omitted.
    private func metrics(_ ex: DietExercise) -> [(String, String)] {
        var out: [(String, String)] = []
        if let d = ex.duration { out.append(("Duration", d)) }
        if let dist = ex.distance {
            out.append(("Distance", "\(DietSemantics.fmt(dist))\(ex.unit.map { " \($0)" } ?? "")"))
        }
        if let p = ex.pace { out.append(("Pace", p)) }
        if let hr = ex.avgHR { out.append(("Avg HR", DietSemantics.fmt(hr))) }
        if let cal = ex.calories { out.append(("Calories", DietSemantics.fmt(cal))) }
        return out
    }
}

// MARK: - 5. Progress & pace

struct ProgressPaceDetail: View {
    let progress: DietProgress
    let today: DietToday
    let series: [WeightPoint]?

    @State private var explainer: Explainer?

    private var currentWeight: Double? {
        HealthDisplay.weightCard(today: today, series: series)?.lbs
    }

    /// The user's weight goals — the emitted `targets`, or the legacy synthesis.
    private var targets: [DietTarget] {
        DietSemantics.displayTargets(progress, currentWeight: currentWeight, today: today.date)
    }

    var body: some View {
        List {
            goalsSection
            if let t = DietSemantics.countdownTarget(targets), let text = DietSemantics.countdownText(t) {
                Section { countdownRow(t, text: text) }
            }
            if !targets.isEmpty {
                Section("Toward targets") {
                    ForEach(targets) { t in
                        progressBar(to: t.weight, label: t.barLabel, title: t.title)
                    }
                }
            }
            Section("Fat vs lean") {
                HStack(alignment: .top, spacing: 12) {
                    StatTile(title: "Fat", value: paceValue(progress.fatPace),
                             zone: progress.fatZone, caption: progress.fatSubMain) {
                        explainer = Explainers.fatLeanPace(progress)
                    }
                    StatTile(title: "Lean", value: paceValue(progress.leanPace),
                             zone: progress.leanZone, caption: progress.leanSubMain) {
                        explainer = Explainers.fatLeanPace(progress)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            if let traj = progress.trajectory {
                Section {
                    Label(traj, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.subheadline)
                        .padding(.vertical, 4)
                }
            }
            if let bf = today.weight?.bf, let lbs = today.weight?.lbs {
                Section("Body composition (today)") {
                    BodyCompBar(totalLbs: lbs, bfPct: bf)
                }
            }
        }
        .navigationTitle("Progress & pace")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $explainer) { ExplainerSheet(explainer: $0) }
    }

    // The start weight plus one compact milestone per weight goal, in one row.
    // Goals are user targets (not fixed program phases), so there may be zero to
    // N; an achieved goal shows a checkmark.
    @ViewBuilder
    private var goalsSection: some View {
        if progress.startWeight != nil || !targets.isEmpty {
            Section("Goals") {
                HStack(alignment: .top, spacing: 12) {
                    milestone("Start", progress.startWeight.map { "\(DietSemantics.fmt($0)) lb" }, sub: nil)
                    ForEach(targets) { t in
                        milestone(t.shortLabel, "\(DietSemantics.fmt(t.weight)) lb",
                                  sub: DietSemantics.displayDate(t.date), achieved: t.achieved ?? false)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }

    // The countdown to a dated goal (phrasing from `DietSemantics.countdownText`),
    // plus the required pace when the payload carries one. `requiredPace` is null
    // for a past or achieved goal, so the pace line only ever rides a future date.
    @ViewBuilder
    private func countdownRow(_ t: DietTarget, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(text).font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "flag.checkered")
            }
            if let pace = t.requiredPace {
                Text("needs \(DietSemantics.fmt1(pace)) lb/wk")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func milestone(_ title: String, _ value: String?, sub: String?, achieved: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(spacing: 3) {
                Text(value ?? "—").font(.headline.monospacedDigit())
                if achieved {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
            }
            if let sub { Text(sub).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paceValue(_ pace: Double?) -> String {
        pace.map { "\(DietSemantics.fmt($0)) lb/wk" } ?? "—"
    }

    /// A progress bar computed natively from current weight over start→target. The
    /// prerendered label rides along as a caption; we never parse numbers from it.
    @ViewBuilder
    private func progressBar(to target: Double?, label: String?, title: String) -> some View {
        if let target, let start = progress.startWeight, let cur = currentWeight, start != target {
            let frac = min(max((start - cur) / (start - target), 0), 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int((frac * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                StatusMeter(fraction: frac, status: .green, height: 8)
                if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
            }
        } else if let label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A horizontal stacked lean-vs-fat bar with lbs and percents.
struct BodyCompBar: View {
    let totalLbs: Double
    let bfPct: Double
    private var fatLbs: Double { totalLbs * bfPct / 100 }
    private var leanLbs: Double { totalLbs - fatLbs }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geo.size.width * (leanLbs / max(totalLbs, 1)))
                    Rectangle().fill(Color.orange)
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            HStack {
                Label("\(DietSemantics.fmt(leanLbs)) lb lean (\(DietSemantics.fmt(100 - bfPct))%)",
                      systemImage: "circle.fill")
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Label("\(DietSemantics.fmt(fatLbs)) lb fat (\(DietSemantics.fmt(bfPct))%)",
                      systemImage: "circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - 6. Coach

struct CoachDetail: View {
    let coach: DietCoach

    var body: some View {
        List {
            if let title = coach.title {
                Section { Text(title).font(.headline) }
            }
            if !coach.notes.isEmpty {
                Section("Notes") {
                    ForEach(Array(coach.notes.enumerated()), id: \.offset) { _, note in
                        Text(CoachHTML.attributed(note)).font(.body)
                    }
                }
            }
            if !coach.ahead.isEmpty {
                Section("What's ahead") {
                    ForEach(Array(coach.ahead.enumerated()), id: \.offset) { _, item in
                        Label { Text(CoachHTML.attributed(item)) } icon: { Image(systemName: "arrow.right.circle") }
                    }
                }
            }
            if let quote = coach.quote {
                Section {
                    VStack(spacing: 6) {
                        // Quote strings carry the same limited HTML/entity subset as
                        // the notes (e.g. `&mdash;`, `&lsquo;`), so decode them the
                        // same way — centered and italic, author on a second line.
                        Text("“\(CoachHTML.plainText(quote.text))”").font(.body.italic())
                        if let author = quote.author {
                            Text("— \(CoachHTML.plainText(author))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle("Coach's notes")
        .navigationBarTitleDisplayMode(.inline)
    }
}
