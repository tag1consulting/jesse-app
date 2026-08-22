import Foundation
import JesseNetworking

// The UNIT serializers: one function per thing the Health tab draws, each turning it
// into the lines a chat needs to answer questions about it.
//
// This is the layer that makes "don't hand-write three serializers per area" true. There
// is exactly one serializer per UNIT (a meal, a food, a workout, a gauge, a trend, a
// source ranking, a streak, an association), and the scope factories in
// `HealthAskContext+Areas.swift` compose them: a section is its units' blocks, a page is
// its sections'. Adding a unit is one function here; widening a scope is one line there.
//
// Everything is a pure function of values the view already holds. Nothing here fetches,
// and nothing here decides a judgement — the bands, the tones, the verdict sentences and
// the coverage lines all come from `DietSemantics`, `NutrientTrends`, `NutrientSources`,
// `NutrientStreaks` and `DietCorrelations`, which are the same engines the pixels came
// from. That is what guarantees the chat and the screen cannot disagree.
//
// UNKNOWN IS NOT ZERO survives into the snapshot. A partial total is written "≥", an
// unmeasured item is named as unmeasured, and a gap day is absent rather than zero —
// exactly as the screen renders them. A snapshot that quietly flattened those would let
// the agent state as fact something the app is careful never to claim.

enum AskFacts {

    // MARK: - Numbers, shared

    /// A gauge's value with its floor marker and unit — "≥1,240 mg", "1840 kcal".
    static func value(_ g: MetricGauge) -> String {
        let prefix = g.partial ? "≥" : ""
        return "\(prefix)\(DietSemantics.fmt(g.value, decimals: g.decimals))\(unitSuffix(g.unit))"
    }

    /// Units join without a space for `g`/`mg`, with one for `kcal`, matching the rows.
    private static func unitSuffix(_ unit: String) -> String {
        unit.isEmpty ? "" : (unit == "kcal" ? " \(unit)" : unit)
    }

    /// The one-word reading a tone stands for, so the snapshot carries the same judgement
    /// the row's colour does without asking the agent to infer it from a colour name.
    static func toneWord(_ tone: DietSemantics.Tone) -> String {
        switch tone {
        case .onTrack: return "on track"
        case .inProgress: return "still coming along"
        case .nudge: return "worth a nudge"
        case .takeNote: return "worth a note"
        }
    }

    /// The goal in words, from the gauge's own glyph vocabulary.
    static func goalWord(_ goal: DietSemantics.Goal) -> String {
        switch goal {
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .window: return "window"
        case .band: return "range"
        }
    }

    // MARK: - A gauge (calories, a macro, a micronutrient, a rolling row)

    /// ONE dense line for a metric row — the form used inside sections and pages.
    ///
    /// "Protein: 118g of a 150g floor · 32g to go · still coming along"
    static func gaugeLine(_ g: MetricGauge) -> String {
        var out = "\(g.label): \(value(g))"
        if let target = g.target {
            out += " of a \(DietSemantics.fmt(target, decimals: g.decimals))"
                + "\(unitSuffix(g.unit)) \(goalWord(g.goal))"
        }
        if !g.remaining.isEmpty { out += " · \(g.remaining)" }
        out += " · \(toneWord(g.tone))"
        return out
    }

    /// The full block for a metric row asked about on its own: the line above, plus every
    /// qualification the row itself carries (partiality, the window a colour came from,
    /// a flag, a note, a blow-out).
    static func gauge(_ g: MetricGauge) -> HealthAskFacts {
        var lines = [gaugeLine(g)]
        if g.partial {
            lines.append("\(g.unknownItemCount) logged "
                + "\(g.unknownItemCount == 1 ? "item carries" : "items carry") no measured value "
                + "for this, so the number above is a floor, not a total")
        }
        if let known = g.knownItemCount, known == 0 {
            lines.append("nothing logged today carries a measured value for this yet")
        }
        if let flag = g.flag { lines.append("flag: \(flag)") }
        if let note = g.note { lines.append("note: \(note)") }
        if g.blowout {
            lines.append("today is well past this ceiling — a rolling colour would hide that, "
                + "so it is called out separately")
        }
        if case .rolling = g.judgment {
            lines.append("the colour on this row is the rolling window's, not today's; "
                + "the number is today's")
        }
        if let w = g.windowRead {
            lines.append("rolling read over \(w.windowDays) days: "
                + (w.median.map { "median \(NutrientTrends.fmt($0, w.nutrient)) \(w.nutrient.unit)" }
                   ?? "no known days")
                + " · \(w.coverage)")
        }
        if let r = g.rollingWindow {
            var line = "this is a \(r.days)-day TOTAL, not a day's"
            if let range = r.range { line += " (\(range))" }
            if r.partial {
                line += " · \(r.unknownItemCount) items in the window carry no value, so it is a floor"
            }
            lines.append(line)
        }
        return HealthAskFacts(lines: lines)
    }

    /// The foods behind a metric, already ranked by the same builder the drill-down sheet
    /// uses — so "why is this so caloric" is answerable from the snapshot alone.
    static func contributors(_ breakdown: FoodBreakdown, decimals: Int, unit: String,
                             limit: Int = HealthAskBudget.maxListItems) -> HealthAskFacts {
        guard !breakdown.contributions.isEmpty || !breakdown.unknownFoods.isEmpty else {
            return HealthAskFacts()
        }
        let (kept, note) = HealthAskBudget.cap(breakdown.contributions, limit: limit,
                                               noun: "contributing foods")
        var lines = kept.map { c -> String in
            let amount = c.amount.map { " (\($0))" } ?? ""
            return "\(c.name)\(amount) — \(DietSemantics.fmt(c.value, decimals: decimals))"
                + "\(unitSuffix(unit)) · \(NutrientSources.pct(c.share)) of the total"
        }
        if !breakdown.unknownFoods.isEmpty {
            let (unknown, unknownNote) = HealthAskBudget.cap(
                breakdown.unknownFoods, limit: HealthAskBudget.maxNestedListItems,
                noun: "unmeasured foods", totalsCoverAll: false)
            lines.append("not estimated (unknown, never counted as zero): "
                + unknown.map(\.name).joined(separator: ", ")
                + (unknownNote.map { " — \($0)" } ?? ""))
        }
        var block = HealthAskFacts(heading: "Where it came from", lines: lines, note: note)
        if let recon = breakdown.reconciliationNote {
            block.lines.append("reconciliation: \(recon)")
        }
        return block
    }

    // MARK: - Food journal

    /// One food row, as logged. The amount is the half that makes a calorie number
    /// answerable, so it is never dropped.
    static func foodLine(_ it: DietItem) -> String {
        let amount = it.amount.map { " (\($0))" } ?? ""
        let cal = it.cal.map { "\(DietSemantics.fmt($0)) cal" } ?? "cal not estimated"
        let macros = MacroLine.format(MacroTotals(cal: 0, p: it.p ?? 0, f: it.f ?? 0,
                                                  c: it.c ?? 0, fiber: it.fiber ?? 0))
        return "\(it.item)\(amount) — \(cal) · \(macros)"
    }

    /// The micronutrients ONE logged food carries a measured value for. Only the known
    /// ones; an absent key is unknown and is simply not mentioned.
    static func foodMicros(_ it: DietItem) -> [String] {
        let pairs: [(String, Double?, String, Int)] = [
            ("Sodium", it.na, "mg", 0), ("Saturated Fat", it.satf, "g", 0),
            ("Total Sugars", it.sug, "g", 0), ("Added Sugar", it.asug, "g", 0),
            ("Potassium", it.k, "mg", 0), ("Calcium", it.ca, "mg", 0),
            ("Omega-3 (EPA+DHA)", it.o3, "mg", 0), ("Magnesium", it.mg, "mg", 0),
            ("Cholesterol", it.chol, "mg", 0), ("Trans Fat", it.tfat, "g", 2),
            ("Purines", it.pur, "mg", 0), ("Mercury", it.hg, "µg", 0),
            ("Selenium", it.se, "µg", 0), ("Vitamin D", it.vd, "µg", 0),
        ]
        return pairs.compactMap { name, v, unit, decimals in
            v.map { "\(name) \(DietSemantics.fmt($0, decimals: decimals))\(unit)" }
        }
    }

    /// One meal: its name, time, subtotal, and its foods.
    ///
    /// `foodLimit` is how the page-level union stays inside budget — a meal asked about on
    /// its own lists everything, the same meal inside a whole-day snapshot lists its
    /// biggest few and says how many it left out.
    static func meal(_ m: DietMeal, foodLimit: Int = HealthAskBudget.maxListItems) -> HealthAskFacts {
        let subtotal = DietSemantics.subtotal(of: m)
        let time = m.time.map { " · \($0)" } ?? ""
        // Ordered by calories so a cap keeps the rows that explain the subtotal.
        let ordered = m.items.sorted { ($0.cal ?? 0) > ($1.cal ?? 0) }
        let (kept, note) = HealthAskBudget.cap(ordered, limit: foodLimit, noun: "foods")
        return HealthAskFacts(
            heading: "\(m.name)\(time)",
            lines: ["\(DietSemantics.fmt(subtotal.cal)) cal · \(MacroLine.format(subtotal))"]
                + kept.map(foodLine),
            note: note)
    }

    /// A day's food totals and where its calories came from — the food journal's own
    /// summary card, which is also the sensible lead for any wider scope.
    static func dayFoodTotals(_ meals: [DietMeal]) -> [String] {
        let t = DietSemantics.dayTotals(meals)
        let split = HealthDisplay.calorieSplit(t)
        return [
            "\(DietSemantics.fmt(t.cal)) cal logged · \(MacroLine.format(t))",
            "calorie sources: protein \(NutrientSources.pct(split.proteinFraction))"
                + " · net carbs \(NutrientSources.pct(split.netCarbsFraction))"
                + " · fiber \(NutrientSources.pct(split.fiberFraction))"
                + " · fat \(NutrientSources.pct(split.fatFraction))",
        ]
    }

    /// A planned (not logged) meal idea. Kept visibly distinct, because the screen keeps
    /// it visibly distinct and a proposal counted as eaten is the worst kind of error.
    static func idea(_ idea: DietIdea) -> HealthAskFacts {
        let total = DietSemantics.total(of: idea.items)
        let time = idea.time.map { " · \($0)" } ?? ""
        var lines = ["PLANNED, not logged — ~\(DietSemantics.fmt(total.cal)) cal · \(MacroLine.format(total))"]
        lines += idea.items.map(foodLine)
        if let notes = idea.notes { lines.append("note: \(notes)") }
        return HealthAskFacts(heading: "\(idea.name)\(time)", lines: lines)
    }

    // MARK: - Exercise

    /// One logged session, with every field the card shows and none it doesn't.
    static func workout(_ e: DietExercise) -> HealthAskFacts {
        var parts: [String] = []
        if let d = e.duration { parts.append("duration \(d)") }
        if let dist = e.distance {
            parts.append("distance \(DietSemantics.fmt(dist))\(e.unit.map { " \($0)" } ?? "")")
        }
        if let p = e.pace { parts.append("pace \(p)") }
        if let hr = e.avgHR { parts.append("avg HR \(DietSemantics.fmt(hr))") }
        if let cal = e.calories { parts.append("\(DietSemantics.fmt(cal)) cal") }
        var lines = [parts.isEmpty ? "no metrics recorded" : parts.joined(separator: " · ")]
        if let d = e.desc { lines.append(d) }
        let time = e.time.map { " · \($0)" } ?? ""
        return HealthAskFacts(heading: "\(e.type.capitalized)\(time)", lines: lines)
    }

    // MARK: - Weight, progress, coach

    static func weightCard(_ c: HealthDisplay.WeightCard) -> HealthAskFacts {
        var lines = ["\(DietSemantics.fmt(c.lbs)) lb"
            + (c.kg.map { " (\(DietSemantics.fmt($0)) kg)" } ?? "")]
        if let d = c.deltaLbs {
            lines.append("\(d >= 0 ? "+" : "")\(DietSemantics.fmt1(d)) lb since the previous weigh-in")
        }
        if c.isTodayWeighIn {
            if let bf = c.bf { lines.append("body fat \(DietSemantics.fmt(bf))%") }
            if let lean = c.leanLbs { lines.append("lean mass \(DietSemantics.fmt(lean)) lb") }
        } else if let last = c.lastWeighInDate {
            lines.append("no weigh-in today — this is the last one, from \(last). "
                + "Body fat and lean mass are deliberately not carried forward")
        }
        return HealthAskFacts(lines: lines)
    }

    /// The weight series, summarized rather than dumped: the ends, the extremes, the
    /// 7-day average, and the recent tail. Ninety raw points would be most of the budget
    /// and answer nothing the summary doesn't.
    static func weightSeries(_ series: [WeightPoint], tail: Int = 14) -> HealthAskFacts {
        guard let first = series.first, let last = series.last else {
            return HealthAskFacts(lines: ["no weigh-ins in this range"])
        }
        var lines = [
            "\(series.count) weigh-ins from \(first.date) to \(last.date)",
            "first \(DietSemantics.fmt(first.lbs)) lb · latest \(DietSemantics.fmt(last.lbs)) lb"
                + " · change \(DietSemantics.fmt1(last.lbs - first.lbs)) lb",
        ]
        if let lo = series.map(\.lbs).min(), let hi = series.map(\.lbs).max() {
            lines.append("range \(DietSemantics.fmt1(lo))–\(DietSemantics.fmt1(hi)) lb")
        }
        if let avg = HealthDisplay.movingAverage(series, window: 7).last {
            lines.append("7-day moving average now \(DietSemantics.fmt1(avg.value)) lb")
        }
        if HealthDisplay.hasBodyFat(series),
           let lastBF = series.last(where: { $0.bf != nil })?.bf {
            lines.append("most recent body fat \(DietSemantics.fmt(lastBF))%")
        }
        let recent = series.suffix(tail)
        lines.append("most recent \(recent.count): "
            + recent.map { "\($0.date) \(DietSemantics.fmt1($0.lbs))" }.joined(separator: ", "))
        let hidden = series.count - recent.count
        return HealthAskFacts(
            heading: "Weigh-ins", lines: lines,
            note: hidden > 0 ? "\(hidden) earlier weigh-ins summarized above rather than listed" : nil)
    }

    static func progress(_ p: DietProgress, targets: [DietTarget]) -> HealthAskFacts {
        var lines: [String] = []
        if let start = p.startWeight { lines.append("start weight \(DietSemantics.fmt(start)) lb") }
        for t in targets {
            var line = "goal \(t.title): \(DietSemantics.fmt(t.weight)) lb"
            if let date = DietSemantics.displayDate(t.date) { line += " by \(date)" }
            if let days = t.daysLeft { line += " · \(days) days left" }
            if let pace = t.requiredPace { line += " · needs \(DietSemantics.fmt1(pace)) lb/wk" }
            if t.achieved == true { line += " · ACHIEVED" }
            lines.append(line)
        }
        if let pace = p.troughPace { lines.append("trough pace \(DietSemantics.fmt1(pace)) lb/wk") }
        if let raw = p.rawPace { lines.append("raw pace \(DietSemantics.fmt1(raw)) lb/wk") }
        if let fat = p.fatPace {
            lines.append("fat pace \(DietSemantics.fmt1(fat)) lb/wk"
                + (p.fatZone.map { " (\($0))" } ?? "")
                + (p.fatSubMain.map { " — \($0)" } ?? ""))
        }
        if let lean = p.leanPace {
            lines.append("lean pace \(DietSemantics.fmt1(lean)) lb/wk"
                + (p.leanZone.map { " (\($0))" } ?? "")
                + (p.leanSubMain.map { " — \($0)" } ?? ""))
        }
        if let zone = p.paceZone { lines.append("pace zone \(zone)") }
        if let traj = p.trajectory { lines.append("trajectory: \(traj)") }
        return HealthAskFacts(lines: lines)
    }

    static func coach(_ c: DietCoach) -> HealthAskFacts {
        var lines: [String] = []
        if let title = c.title { lines.append(CoachHTML.plainText(title)) }
        lines += c.notes.map { "note: \(CoachHTML.plainText($0))" }
        lines += c.ahead.map { "ahead: \(CoachHTML.plainText($0))" }
        if let q = c.quote {
            lines.append("quote: “\(CoachHTML.plainText(q.text))”"
                + (q.author.map { " — \(CoachHTML.plainText($0))" } ?? ""))
        }
        return HealthAskFacts(lines: lines)
    }

    static func daySummary(_ s: DaySummary) -> HealthAskFacts {
        HealthAskFacts(lines: [s.headline, "what would help next: \(s.nextAction)",
                               "overall reading: \(toneWord(s.tone))"])
    }

    // MARK: - Trends, sources, streaks, patterns

    /// One nutrient's trend over the visible range. The verdict sentence is the ENGINE's
    /// (`NutrientTrends.verdict`), so the snapshot repeats the screen's own words rather
    /// than paraphrasing a chart, and the day-by-day tail rides underneath it.
    static func trend(_ t: NutrientTrend, tail: Int = 14) -> HealthAskFacts {
        var lines = [NutrientTrends.verdict(t)]
        lines.append("direction over the range: \(t.direction.label)")
        if t.daysTargetUnknown > 0 {
            lines.append("\(t.daysTargetUnknown) known "
                + "\(t.daysTargetUnknown == 1 ? "day" : "days") recorded no target of their own "
                + "and are in the distribution but in no verdict")
        }
        if t.partialCount > 0 {
            lines.append("\(t.partialCount) of the known days are partial (a lower bound)")
        }
        let recent = t.points.suffix(tail)
        if !recent.isEmpty {
            lines.append("day by day (most recent \(recent.count), gap days absent — never zero): "
                + recent.map { p in
                    "\(p.date) \(p.isPartial ? "≥" : "")\(NutrientTrends.fmt(p.value, t.nutrient))"
                }.joined(separator: ", "))
        }
        let hidden = t.points.count - recent.count
        return HealthAskFacts(
            heading: "\(t.nutrient.fullName) trend (\(t.unit))", lines: lines,
            note: hidden > 0
                ? "\(hidden) earlier known days are in every statistic above but not listed"
                : nil)
    }

    /// One nutrient's ranked food sources over a range, with the coverage sentence the
    /// screen prints beneath it.
    static func sourceRanking(_ r: NutrientSourceRanking) -> HealthAskFacts {
        guard !r.isEmpty else {
            return HealthAskFacts(
                heading: r.nutrient.fullName,
                lines: ["nothing logged in this range carries a measured value, "
                        + "so there is nothing to rank"])
        }
        var lines = ["measured total \(r.isPartial ? "≥" : "")"
            + "\(NutrientTrends.fmt(r.knownTotal, r.nutrient)) \(r.nutrient.unit)"]
        lines += r.entries.map { e in
            "\(e.name) — \(NutrientTrends.fmt(e.value, r.nutrient)) \(r.nutrient.unit)"
                + " · \(NutrientSources.pct(e.share)) of the measured total"
                + " · on \(e.days) \(e.days == 1 ? "day" : "days")"
        }
        lines.append(NutrientSources.coverageLine(r))
        return HealthAskFacts(heading: "\(r.nutrient.fullName) sources", lines: lines,
                              note: NutrientSources.unknownRule)
    }

    /// One nutrient's consistency row, in the screen's own wording.
    static func streak(_ s: NutrientStreak) -> HealthAskFacts {
        HealthAskFacts(
            heading: s.nutrient.fullName,
            lines: ["current run \(s.current) \(s.current == 1 ? "day" : "days")"
                        + " · best run \(s.longest)",
                    s.lastMissLine,
                    s.coverageNote])
    }

    /// One association, in the engine's fixed, non-causal wording.
    static func association(_ a: DietAssociation) -> HealthAskFacts {
        HealthAskFacts(
            heading: a.title,
            lines: ["Spearman \(a.coefficientText) over \(a.pairs) day-pairs (\(a.strengthWord))",
                    a.sentence])
    }

    /// One pair the guardrails set aside, named rather than hidden.
    static func patternMiss(_ m: DietPairMiss) -> HealthAskFacts {
        HealthAskFacts(heading: m.title, lines: [m.reasonText])
    }
}
