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
    @State private var explainer: Explainer?

    private var g: DietGauges { DietSemantics.gauges(for: today, hour: hour) }

    var body: some View {
        List {
            Section {
                bar(g.calories, Explainers.calories(g.calories, isCarbLoad: g.isCarbLoad))
                bar(g.protein, Explainers.protein(g.protein))
                bar(g.carbs, Explainers.carbs(g.carbs, hasBonus: g.carbsBonus != nil))
                if let bonus = g.carbsBonus { bonusRow(bonus) }
                bar(g.fat, Explainers.fat(g.fat, isCarbLoad: g.isCarbLoad))
                bar(g.fiber, Explainers.fiber(g.fiber, isCarbLoad: g.isCarbLoad))
            }
            Section("Net calories") {
                NetCalorieBar(net: g.net)
                    .onTapGesture { explainer = Explainers.netCalories(g.net) }
            }
            Section {
                legend
            }
        }
        .navigationTitle("Macros & calories")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $explainer) { ExplainerSheet(explainer: $0) }
    }

    private func bar(_ gauge: MetricGauge, _ ex: Explainer) -> some View {
        MetricBarRow(gauge: gauge) { explainer = ex }
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
            ForEach(Array(meals.enumerated()), id: \.offset) { _, meal in
                Section {
                    ForEach(Array(meal.items.enumerated()), id: \.offset) { _, it in
                        itemRow(it)
                    }
                    subtotalRow(DietSemantics.subtotal(of: meal))
                } header: {
                    HStack {
                        Text(meal.name)
                        if let t = meal.time { Spacer(); Text(t).foregroundStyle(.secondary) }
                    }
                }
            }
            Section {
                HStack {
                    Text("Day total").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(DietSemantics.fmt(grand.cal)) cal").font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Text(macroLine(grand)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let proposed, !proposed.ideas.isEmpty {
                mealIdeas(proposed)
            }
        }
        .navigationTitle("Food journal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func itemRow(_ it: DietItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(it.item).font(.subheadline)
                if let a = it.amount { Text(a).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let cal = it.cal { Text("\(DietSemantics.fmt(cal)) cal").font(.caption.monospacedDigit()) }
            }
            Text(macroLine(MacroTotals(cal: 0, p: it.p ?? 0, f: it.f ?? 0, c: it.c ?? 0, fiber: it.fiber ?? 0)))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func subtotalRow(_ t: MacroTotals) -> some View {
        HStack {
            Text("Subtotal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("\(DietSemantics.fmt(t.cal)) cal · \(macroLine(t))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func mealIdeas(_ proposed: DietProposed) -> some View {
        Section {
            ForEach(Array(proposed.ideas.enumerated()), id: \.offset) { _, idea in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(idea.name).font(.subheadline.weight(.semibold))
                        if let t = idea.time { Spacer(); Text(t).font(.caption).foregroundStyle(.secondary) }
                    }
                    let t = DietSemantics.total(of: idea.items)
                    Text("~\(DietSemantics.fmt(t.cal)) cal · \(macroLine(t))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let notes = idea.notes { Text(notes).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let source = proposed.source {
                Text("Source: \(source)").font(.caption2).foregroundStyle(.tertiary)
            }
            if let gap = proposed.gapNote {
                Text(gap).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Meal ideas")
        }
    }
}

// MARK: - 3. Exercise

struct ExerciseDetail: View {
    let exercise: [DietExercise]
    private var sessions: [DietExercise] { DietSemantics.sortedExercise(exercise) }

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView("No exercise logged", systemImage: "figure.run")
            }
            ForEach(Array(sessions.enumerated()), id: \.offset) { _, ex in
                HealthCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(ex.type.capitalized).font(.headline)
                            Spacer()
                            if let t = ex.time { Text(t).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        if let d = ex.desc { Text(d).font(.subheadline) }
                        let line = detailLine(ex)
                        if !line.isEmpty {
                            Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Exercise")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Join whichever of duration / distance+unit / pace / avgHR / calories exist,
    /// separated by " · ".
    private func detailLine(_ ex: DietExercise) -> String {
        var parts: [String] = []
        if let d = ex.duration { parts.append(d) }
        if let dist = ex.distance {
            parts.append("\(DietSemantics.fmt(dist))\(ex.unit.map { " \($0)" } ?? "")")
        }
        if let p = ex.pace { parts.append("\(p) pace") }
        if let hr = ex.avgHR { parts.append("HR \(DietSemantics.fmt(hr))") }
        if let cal = ex.calories { parts.append("\(DietSemantics.fmt(cal)) cal") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 5. Progress & pace

struct ProgressPaceDetail: View {
    let progress: DietProgress
    let today: DietToday
    let series: [WeightPoint]?

    private var currentWeight: Double? {
        HealthDisplay.weightCard(today: today, series: series)?.lbs
    }

    var body: some View {
        List {
            Section("Phase") {
                if let s = progress.startWeight { row("Start", "\(DietSemantics.fmt(s)) lb") }
                if let r = progress.raceTarget {
                    row("Race target", "\(DietSemantics.fmt(r)) lb\(progress.raceDate.map { " by \($0)" } ?? "")")
                }
                if let m = progress.maintTarget { row("Maintenance", "\(DietSemantics.fmt(m)) lb") }
            }
            Section("Toward targets") {
                progressBar(to: progress.raceTarget, label: progress.raceBarLabel, title: "Race")
                progressBar(to: progress.maintTarget, label: progress.maintBarLabel, title: "Maintenance")
            }
            Section("Composition pace") {
                paceRow("Fat", progress.fatBarLabel ?? progress.fatPace.map { "\(DietSemantics.fmt($0)) lb/wk" },
                        zone: progress.fatZone, sub: progress.fatSubMain)
                paceRow("Lean", progress.leanBarLabel ?? progress.leanPace.map { "\(DietSemantics.fmt($0)) lb/wk" },
                        zone: progress.leanZone, sub: progress.leanSubMain)
            }
            if let bf = today.weight?.bf, let lbs = today.weight?.lbs {
                Section("Body composition (today)") {
                    BodyCompBar(totalLbs: lbs, bfPct: bf)
                }
            }
            if let traj = progress.trajectory {
                Section { Text(traj).font(.subheadline) }
            }
        }
        .navigationTitle("Progress & pace")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a); Spacer(); Text(b).font(.body.monospacedDigit()).foregroundStyle(.secondary) }
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
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func paceRow(_ title: String, _ value: String?, zone: String?, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let value { Text(value).font(.subheadline.monospacedDigit()) }
                if let zone { ZoneChip(text: zone, zone: zone) }
            }
            if let sub { Text(sub).font(.caption).foregroundStyle(.secondary) }
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
                        Text("“\(quote.text)”").font(.body.italic())
                        if let author = quote.author {
                            Text("— \(author)").font(.caption).foregroundStyle(.secondary)
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
