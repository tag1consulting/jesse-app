import Foundation
import JesseNetworking

// The SCOPE factories: one per thing on the Health tab that can be asked about.
//
// Each is a thin composition over `AskFacts` — a title, a range, a subject noun, some
// starters, and a facts tree assembled from the unit serializers. That is the whole
// point of the split: an item names one unit block, a section names its items' blocks,
// and a page names its sections'. Nothing here re-derives a number.
//
// WHY THE VIEW PASSES THE VALUES IN. Every factory takes the data the view already holds
// rather than a snapshot to re-read. A serializer that re-fetched would eventually
// disagree with the pixels the gesture was made on, and "the chat knows what you were
// looking at" is the entire feature.

/// The day a reading belongs to. Carried as one value rather than a `(String, Bool)`
/// pair threaded through forty signatures.
struct HealthAskDay: Equatable, Sendable {
    /// The `yyyy-MM-dd` day on screen.
    let iso: String
    /// Whether that is the LIVE day. A paged-back day says its own date everywhere, so a
    /// past reading can never be answered as if it were today's.
    let isToday: Bool

    var range: HealthAskTimeRange { .day(iso, isToday: isToday) }
    /// "Aug 22" — the title suffix.
    var short: String { DietSemantics.displayDate(iso) ?? iso }
    /// "today" / "Aug 22" — the possessive in a title ("today's macros").
    var possessive: String { isToday ? "today's" : "\(short)'s" }
}

// MARK: - Starters

/// The two-to-four opening questions each scope offers.
///
/// They are SUGGESTIONS, not a menu: the chat is the ordinary one and the user can ask
/// anything. They exist because an empty composer under a page of numbers is a worse
/// prompt than three concrete questions, and because they teach what the scope can
/// answer — the item-level ones deliberately name things only the item context knows
/// ("how confident is this estimate"), so a tap demonstrates that the chat really does
/// have the row in hand.
enum HealthAskStarters {
    static let dayPage = ["What's good and bad about today?",
                          "What should I change for dinner?",
                          "Am I on track for the week?"]
    static let macros = ["What's good and bad about today?",
                         "Which number is furthest off?",
                         "What should I eat next to round this out?"]
    static let calorieItem = ["Why is this so caloric?",
                              "What's a lighter swap?",
                              "How confident is this estimate?"]
    static let nutrientItem = ["Where is this coming from?",
                               "Is this a problem or is it fine?",
                               "What would move this most?"]
    static let meal = ["Break down this meal",
                       "Was this a good choice?",
                       "What's missing nutritionally?"]
    static let food = ["Why is this so caloric?",
                       "What's a lighter swap?",
                       "How confident is this estimate?"]
    static let foodJournal = ["What stands out about today's food?",
                              "Where did most of the calories come from?",
                              "What's missing nutritionally?"]
    static let sources = ["Why is this source weighted this way?",
                          "Which source is most reliable for calories?",
                          "What would I swap to shift this?"]
    static let patterns = ["Explain this pattern",
                           "Is this actually a problem?",
                           "What would break this pattern?"]
    static let exercise = ["Was this a good session?",
                           "How does this compare to my usual?",
                           "Did this offset what I ate?"]
    static let trends = ["What's driving this?",
                         "Is this change meaningful or noise?",
                         "What should I expect next week?"]
    static let weight = ["Is this trend real or noise?",
                         "Am I losing at a sensible rate?",
                         "What would you expect next week?"]
    static let progress = ["Am I on pace?", "What would have to change to hit this?",
                           "Is the fat/lean split healthy?"]
    static let coach = ["What's the most important thing here?",
                        "What should I do about it today?"]
    static let consistency = ["Which of these is worth holding?",
                              "What breaks these streaks?",
                              "Is this enough measurement to trust?"]
}

// MARK: - The factories

/// Every "ask about this" context the Health tab can produce.
///
/// Namespaced rather than scattered as initializers so the whole surface — every scope
/// the tab offers — reads as one list, and so a new Health section can see at a glance
/// what it has to add.
enum HealthAsk {

    // MARK: Day (the Health tab root)

    /// The WHOLE dashboard for the day (or window) on screen — the page-level ask behind
    /// the tab's own toolbar entry. "What's good and what's bad about today" must be
    /// answerable from this alone, with nothing selected.
    static func day(snapshot: DietSnapshot, gauges: DietGauges, hour: Int,
                    windowMode: NutrientWindowMode, day: HealthAskDay) -> HealthAskContext {
        let today = snapshot.today
        let isNeutral = HistoryUI.mode(fidelity: snapshot.fidelityKind) == .neutral
        var children: [HealthAskFacts] = []

        var head = HealthAskFacts(heading: "The day", lines: [
            "date \(today.date)\(day.isToday ? " (today, live)" : " (a past day)")",
        ])
        if let style = today.dayStyle { head.lines.append("day type: \(style)") }
        if gauges.isCarbLoad { head.lines.append("this is a carb-load day, so the targets differ") }
        if isNeutral {
            head.lines.append("this day was rebuilt from logs and recorded no targets, "
                + "so nothing on it is judged")
        }
        if snapshot.isHistorical {
            head.lines.append("a past day is judged on its own numbers alone, never on a "
                + "window that ends after it")
        }
        children.append(head)

        if !isNeutral {
            children.append(HealthAskFacts(
                heading: "Summary",
                lines: AskFacts.daySummary(DaySummary.make(gauges: gauges, hour: hour,
                                                           hasFood: !today.meals.isEmpty)).lines))
        }

        children.append(HealthAskFacts(
            heading: "Calories & macros",
            lines: [AskFacts.gaugeLine(gauges.calories)]
                + gauges.orderedMacros.map { AskFacts.gaugeLine($0.gauge) }
                + ["net: \(DietSemantics.fmt(gauges.net.intake)) eaten − "
                   + "\(DietSemantics.fmt(gauges.net.burned)) burned = "
                   + "\(DietSemantics.fmt(gauges.net.net))"]))

        // The rolling read, when the tab is showing one — the numbers on screen ARE the
        // window's medians in that mode, so the snapshot must be too.
        if let days = windowMode.days, let series = snapshot.nutrientSeries,
           NutrientTrends.isAvailable(series) {
            let rows = NutrientWindows.gauges(series: series, targets: today.targets,
                                              windowDays: days)
            if !rows.isEmpty {
                children.append(HealthAskFacts(
                    heading: "Rolling \(days)-day read (what the screen is showing)",
                    lines: rows.map { AskFacts.gaugeLine($0.gauge) },
                    note: NutrientWindows.coverageFootnote))
            }
        }

        let micros = DietSemantics.micronutrientGauges(
            for: today, hour: hour,
            series: snapshot.isHistorical ? nil : snapshot.nutrientSeries)
            .filter { ($0.knownItemCount ?? 0) > 0 }
        if !micros.isEmpty {
            children.append(HealthAskFacts(heading: "Micronutrients",
                                           lines: micros.map(AskFacts.gaugeLine)))
        }

        if let card = HealthDisplay.weightCard(today: today, series: snapshot.weightSeries) {
            children.append(HealthAskFacts(heading: "Weight", lines: AskFacts.weightCard(card).lines))
        }

        var foodLines = AskFacts.dayFoodTotals(today.meals)
        let meals = DietSemantics.sortedMeals(today.meals)
        foodLines.append("\(meals.count) \(meals.count == 1 ? "meal" : "meals") logged")
        var food = HealthAskFacts(heading: "Food journal", lines: foodLines)
        food.children = meals.map { AskFacts.meal($0, foodLimit: HealthAskBudget.maxNestedListItems) }
        children.append(food)

        let sessions = DietSemantics.sortedExercise(today.exercise)
        children.append(HealthAskFacts(
            heading: "Exercise",
            lines: sessions.isEmpty
                ? ["nothing logged"]
                : ["\(sessions.count) \(sessions.count == 1 ? "session" : "sessions") · "
                   + "\(DietSemantics.fmt(DietSemantics.burnedCalories(today.exercise))) cal burned"],
            children: sessions.map(AskFacts.workout)))

        if let coach = snapshot.coach {
            children.append(HealthAskFacts(heading: "Coach's notes", lines: AskFacts.coach(coach).lines))
        }
        if let progress = snapshot.progress {
            let targets = DietSemantics.displayTargets(
                progress,
                currentWeight: HealthDisplay.weightCard(today: today, series: snapshot.weightSeries)?.lbs,
                today: today.date)
            children.append(HealthAskFacts(heading: "Progress & pace",
                                           lines: AskFacts.progress(progress, targets: targets).lines))
        }
        if !snapshot.errors.isEmpty {
            children.append(HealthAskFacts(heading: "Sections that could not be read",
                                           lines: snapshot.errors))
        }

        return HealthAskContext(
            scope: .page, area: .day,
            timeRange: windowMode.days.map { .trailing(days: $0, through: today.date) } ?? day.range,
            title: "Health · \(day.short)", subject: "this whole day",
            subjectKey: "dashboard",
            facts: HealthAskFacts(children: children),
            related: [today.date],
            suggestedQuestions: HealthAskStarters.dayPage)
    }

    /// The plain-language day summary card.
    static func daySummary(_ summary: DaySummary, gauges: DietGauges,
                           day: HealthAskDay) -> HealthAskContext {
        HealthAskContext(
            scope: .section, area: .day, timeRange: day.range,
            title: "\(day.possessive.capitalizedAsk) summary", subject: "this summary",
            subjectKey: "summary",
            facts: HealthAskFacts(children: [
                AskFacts.daySummary(summary),
                HealthAskFacts(heading: "The gauges it is derived from",
                               lines: [AskFacts.gaugeLine(gauges.calories)]
                                + gauges.orderedMacros.map { AskFacts.gaugeLine($0.gauge) }),
            ]),
            suggestedQuestions: HealthAskStarters.dayPage)
    }

    /// The day-type chip ("carb-load day").
    static func dayStyle(_ style: String?, isCarbLoad: Bool, gauges: DietGauges,
                         day: HealthAskDay) -> HealthAskContext {
        HealthAskContext(
            scope: .item, area: .day, timeRange: day.range,
            title: "Day type · \(day.short)", subject: "this day type",
            subjectKey: "day-style",
            facts: HealthAskFacts(lines: [
                "day type: \(style ?? "not recorded")",
                isCarbLoad ? "this is a carb-load day" : "this is an ordinary day",
                "what it changes: \(AskFacts.gaugeLine(gauges.carbs))",
                AskFacts.gaugeLine(gauges.fiber),
            ]),
            suggestedQuestions: ["What does this day type change?",
                                 "How should I eat differently today?"])
    }

    // MARK: Macros & calories

    /// The Macros & calories PAGE — every nutrient row it draws, in the order it draws
    /// them, with the same judgements.
    static func macrosPage(today: DietToday, gauges: DietGauges, hour: Int,
                           judgeSeries: [NutrientDay]?, neutral: Bool,
                           day: HealthAskDay) -> HealthAskContext {
        var children: [HealthAskFacts] = [
            HealthAskFacts(heading: "Calories & macros",
                           lines: [AskFacts.gaugeLine(gauges.calories)]
                            + gauges.orderedMacros.map { AskFacts.gaugeLine($0.gauge) }),
        ]
        if let bonus = gauges.carbsBonus {
            children[0].lines.append("\(bonus.label): \(DietSemantics.fmt(bonus.consumed))"
                + " of \(DietSemantics.fmt(bonus.pool))g earned by exercise")
        }
        let micros = NutrientOrder.macroArea.compactMap { entry -> MetricGauge? in
            guard case .micronutrient(let n) = entry else { return nil }
            let g = DietSemantics.micronutrientGauge(n, meals: today.meals, targets: today.targets,
                                                     hour: hour, series: judgeSeries)
            return (g.knownItemCount ?? 0) > 0 ? g : nil
        }
        if !micros.isEmpty {
            children.append(HealthAskFacts(heading: "Sub-entries under the macros above",
                                           lines: micros.map(AskFacts.gaugeLine)))
        }
        let minerals = NutrientOrder.minerals
            .map { DietSemantics.micronutrientGauge($0, meals: today.meals, targets: today.targets,
                                                    hour: hour, series: judgeSeries) }
            .filter { ($0.knownItemCount ?? 0) > 0 }
        if !minerals.isEmpty {
            children.append(HealthAskFacts(heading: "Micronutrients",
                                           lines: minerals.map(AskFacts.gaugeLine)))
        }
        let windowRows = DietSemantics.rollingWindowGauges(for: today)
        if !windowRows.isEmpty {
            children.append(HealthAskFacts(
                heading: "Over the last week (window totals, not day totals)",
                lines: windowRows.map { AskFacts.gaugeLine($0.gauge) },
                note: DietSemantics.rollingWindowFootnote))
        }
        children.append(HealthAskFacts(
            heading: "Net calories",
            lines: ["\(DietSemantics.fmt(gauges.net.intake)) eaten − "
                    + "\(DietSemantics.fmt(gauges.net.burned)) burned = "
                    + "\(DietSemantics.fmt(gauges.net.net)) net"]))
        if neutral {
            children.append(HealthAskFacts(lines: [NeutralMode.noTargetsCaption]))
        }
        return HealthAskContext(
            scope: .page, area: .macros, timeRange: day.range,
            title: "Macros & calories · \(day.short)", subject: "\(day.possessive) macros",
            subjectKey: "macros",
            facts: HealthAskFacts(children: children),
            related: [today.date],
            suggestedQuestions: HealthAskStarters.macros)
    }

    /// The macros SECTION as reached from the dashboard's nav row — the same facts, at
    /// section scope, so long-pressing the row and opening the page agree.
    static func macrosSection(today: DietToday, gauges: DietGauges, hour: Int,
                              judgeSeries: [NutrientDay]?, neutral: Bool,
                              day: HealthAskDay) -> HealthAskContext {
        let page = macrosPage(today: today, gauges: gauges, hour: hour,
                              judgeSeries: judgeSeries, neutral: neutral, day: day)
        return HealthAskContext(
            scope: .section, area: .macros, timeRange: page.timeRange,
            title: page.title, subject: page.subject, subjectKey: "macros",
            facts: page.facts, related: page.related,
            suggestedQuestions: page.suggestedQuestions)
    }

    /// ONE metric row — the calorie hero, a macro ring, a nutrient bar, a mineral, a
    /// rolling-window row. The single item factory behind every gauge on the tab.
    ///
    /// `breakdown` is the drill-down's own ranked contributors when the caller has them,
    /// which is what makes "why is this so caloric" answerable without a second turn.
    static func metric(_ gauge: MetricGauge, area: HealthAskArea, day: HealthAskDay,
                       breakdown: FoodBreakdown? = nil,
                       starters: [String]? = nil) -> HealthAskContext {
        var children = [AskFacts.gauge(gauge)]
        if let breakdown {
            let foods = AskFacts.contributors(breakdown, decimals: gauge.decimals, unit: gauge.unit)
            if !foods.isEmpty { children.append(foods) }
        }
        // A rolling row's number spans days, so its range must say so rather than claim
        // the day it was tapped on.
        let range = gauge.rollingWindow.map {
            HealthAskTimeRange.trailing(days: $0.days, through: $0.to ?? day.iso)
        } ?? gauge.windowRead.map {
            HealthAskTimeRange.trailing(days: $0.windowDays, through: day.iso)
        } ?? day.range
        return HealthAskContext(
            scope: .item, area: area, timeRange: range,
            title: "\(gauge.label) · \(day.short)", subject: "this number",
            subjectKey: gauge.label,
            facts: HealthAskFacts(children: children),
            suggestedQuestions: starters
                ?? (gauge.label.lowercased().contains("calorie")
                    ? HealthAskStarters.calorieItem : HealthAskStarters.nutrientItem))
    }

    /// The rolling 7/30-day read the window switcher puts on screen — the SECTION, whose
    /// rows are medians rather than today's numbers.
    static func rollingRead(_ rows: [(nutrient: TrendNutrient, gauge: MetricGauge)],
                            windowDays: Int, day: HealthAskDay) -> HealthAskContext {
        HealthAskContext(
            scope: .section, area: .macros,
            timeRange: .trailing(days: windowDays, through: day.iso),
            title: "Rolling read · last \(windowDays) days",
            subject: "this \(windowDays)-day read", subjectKey: "rolling-\(windowDays)",
            facts: HealthAskFacts(
                lines: rows.map { AskFacts.gaugeLine($0.gauge) },
                note: NutrientWindows.coverageFootnote),
            suggestedQuestions: ["What stands out over these days?",
                                 "Which of these is worth acting on?",
                                 "Is this better or worse than usual?"])
    }

    /// The four macro rings, as one section.
    static func macroRings(_ gauges: DietGauges, day: HealthAskDay) -> HealthAskContext {
        HealthAskContext(
            scope: .section, area: .macros, timeRange: day.range,
            title: "Macros · \(day.short)", subject: "\(day.possessive) macros",
            subjectKey: "macro-rings",
            facts: HealthAskFacts(lines: gauges.orderedMacros.map { AskFacts.gaugeLine($0.gauge) }),
            suggestedQuestions: HealthAskStarters.macros)
    }

    /// A GROUP of metric rows as one section — the shape every "these rows together"
    /// ask takes, so the minerals block, the weekly-window block and any block a future
    /// section adds all compose from the same place.
    static func gaugeGroup(_ gauges: [MetricGauge], area: HealthAskArea, title: String,
                           subject: String, subjectKey: String, day: HealthAskDay,
                           range: HealthAskTimeRange? = nil, note: String? = nil,
                           starters: [String] = HealthAskStarters.nutrientItem) -> HealthAskContext {
        HealthAskContext(
            scope: .section, area: area, timeRange: range ?? day.range,
            title: title, subject: subject, subjectKey: subjectKey,
            facts: HealthAskFacts(lines: gauges.map(AskFacts.gaugeLine), note: note),
            suggestedQuestions: starters)
    }

    /// The standalone minerals block on Macros & calories.
    static func mineralsSection(_ gauges: [MetricGauge], day: HealthAskDay) -> HealthAskContext {
        gaugeGroup(gauges, area: .macros, title: "Micronutrients · \(day.short)",
                   subject: "\(day.possessive) micronutrients", subjectKey: "minerals", day: day)
    }

    /// The "over the last week" block, whose numbers are WINDOW TOTALS rather than a
    /// day's — so its range says a week even though it was pressed on a day screen.
    static func rollingWindowSection(_ gauges: [MetricGauge], day: HealthAskDay) -> HealthAskContext {
        let days = gauges.compactMap { $0.rollingWindow?.days }.first ?? 7
        return gaugeGroup(gauges, area: .macros, title: "Last \(days) days",
                          subject: "this weekly total", subjectKey: "rolling-window",
                          day: day, range: .trailing(days: days, through: day.iso),
                          note: DietSemantics.rollingWindowFootnote)
    }

    /// The net-calorie bar.
    static func netCalories(_ net: NetCalories, day: HealthAskDay) -> HealthAskContext {
        HealthAskContext(
            scope: .item, area: .calories, timeRange: day.range,
            title: "Net calories · \(day.short)", subject: "these net calories",
            subjectKey: "net-calories",
            facts: HealthAskFacts(lines: [
                "eaten \(DietSemantics.fmt(net.intake)) cal",
                "burned in logged exercise \(DietSemantics.fmt(net.burned)) cal",
                "net \(DietSemantics.fmt(net.net)) cal",
            ]),
            suggestedQuestions: ["Is this net sensible for today?",
                                 "Did training earn me more food?"])
    }

    // MARK: Food journal

    static func foodJournalPage(today: DietToday, proposed: DietProposed?,
                                day: HealthAskDay) -> HealthAskContext {
        let meals = DietSemantics.sortedMeals(today.meals)
        var children = [HealthAskFacts(heading: "The day's food",
                                       lines: AskFacts.dayFoodTotals(today.meals))]
        children += meals.map { AskFacts.meal($0) }
        if let proposed, !proposed.ideas.isEmpty {
            var planned = HealthAskFacts(
                heading: "Planned (proposals — NOT eaten, not in any total above)",
                children: proposed.ideas.map(AskFacts.idea))
            if let source = proposed.source { planned.lines.append("source: \(source)") }
            if let gap = proposed.gapNote { planned.lines.append(gap) }
            children.append(planned)
        }
        return HealthAskContext(
            scope: .page, area: .foodJournal, timeRange: day.range,
            title: "Food journal · \(day.short)", subject: "\(day.possessive) food",
            subjectKey: "food-journal",
            facts: HealthAskFacts(children: children),
            related: [today.date],
            suggestedQuestions: HealthAskStarters.foodJournal)
    }

    static func foodJournalSection(today: DietToday, day: HealthAskDay) -> HealthAskContext {
        let meals = DietSemantics.sortedMeals(today.meals)
        return HealthAskContext(
            scope: .section, area: .foodJournal, timeRange: day.range,
            title: "Food journal · \(day.short)", subject: "\(day.possessive) food",
            subjectKey: "food-journal",
            facts: HealthAskFacts(
                lines: AskFacts.dayFoodTotals(today.meals),
                children: meals.map { AskFacts.meal($0, foodLimit: HealthAskBudget.maxNestedListItems) }),
            suggestedQuestions: HealthAskStarters.foodJournal)
    }

    static func meal(_ meal: DietMeal, day: HealthAskDay) -> HealthAskContext {
        HealthAskContext(
            scope: .item, area: .foodJournal, timeRange: day.range,
            title: "\(meal.name) · \(day.short)", subject: "this meal",
            subjectKey: meal.name,
            facts: AskFacts.meal(meal),
            suggestedQuestions: HealthAskStarters.meal)
    }

    /// ONE logged food, with the meal it sits in for context and every micronutrient the
    /// log actually measured for it — which is what "how confident is this estimate"
    /// needs, and what the row itself does not show.
    static func food(_ item: DietItem, in meal: DietMeal, day: HealthAskDay) -> HealthAskContext {
        var lines = [AskFacts.foodLine(item)]
        let micros = AskFacts.foodMicros(item)
        if micros.isEmpty {
            lines.append("no micronutrients measured for this row — unknown, not zero")
        } else {
            lines.append("measured micronutrients: \(micros.joined(separator: " · "))")
        }
        if item.amount == nil {
            lines.append("no amount was logged, so the estimate rests on the name alone")
        }
        return HealthAskContext(
            scope: .item, area: .foodJournal, timeRange: day.range,
            title: "\(item.item) · \(meal.name)", subject: "this food",
            subjectKey: "\(meal.name)-\(item.item)",
            facts: HealthAskFacts(
                lines: lines,
                children: [HealthAskFacts(heading: "The meal it is part of",
                                          lines: AskFacts.meal(meal).lines)]),
            suggestedQuestions: HealthAskStarters.food)
    }

    static func idea(_ idea: DietIdea, day: HealthAskDay) -> HealthAskContext {
        HealthAskContext(
            scope: .item, area: .foodJournal, timeRange: day.range,
            title: "Planned: \(idea.name)", subject: "this planned meal",
            subjectKey: "planned-\(idea.name)",
            facts: AskFacts.idea(idea),
            suggestedQuestions: ["Is this a good idea for today?",
                                 "What would it do to my numbers?",
                                 "What would you change about it?"])
    }

    // MARK: Exercise

    static func exercisePage(_ exercise: [DietExercise], day: HealthAskDay) -> HealthAskContext {
        let sessions = DietSemantics.sortedExercise(exercise)
        return HealthAskContext(
            scope: .page, area: .exercise, timeRange: day.range,
            title: "Exercise · \(day.short)", subject: "\(day.possessive) training",
            subjectKey: "exercise",
            facts: HealthAskFacts(
                lines: sessions.isEmpty
                    ? ["nothing logged"]
                    : ["\(sessions.count) \(sessions.count == 1 ? "session" : "sessions") · "
                       + "\(DietSemantics.fmt(DietSemantics.burnedCalories(exercise))) cal burned"],
                children: sessions.map(AskFacts.workout)),
            suggestedQuestions: HealthAskStarters.exercise)
    }

    static func exerciseSection(_ exercise: [DietExercise], day: HealthAskDay) -> HealthAskContext {
        let page = exercisePage(exercise, day: day)
        return HealthAskContext(
            scope: .section, area: .exercise, timeRange: page.timeRange, title: page.title,
            subject: page.subject, subjectKey: "exercise", facts: page.facts,
            suggestedQuestions: page.suggestedQuestions)
    }

    static func workout(_ e: DietExercise, day: HealthAskDay,
                        alongside all: [DietExercise] = []) -> HealthAskContext {
        var facts = AskFacts.workout(e)
        if all.count > 1 {
            facts.lines.append("one of \(all.count) sessions logged that day · "
                + "\(DietSemantics.fmt(DietSemantics.burnedCalories(all))) cal burned in total")
        }
        return HealthAskContext(
            scope: .item, area: .exercise, timeRange: day.range,
            title: "\(e.type.capitalized) · \(day.short)", subject: "this workout",
            subjectKey: "\(e.type)-\(e.time ?? "")",
            facts: facts,
            suggestedQuestions: HealthAskStarters.exercise)
    }

    // MARK: Weight & progress

    static func weightCard(_ card: HealthDisplay.WeightCard, day: HealthAskDay) -> HealthAskContext {
        HealthAskContext(
            scope: .item, area: .weight, timeRange: day.range,
            title: "Weight · \(day.short)", subject: "this weigh-in",
            subjectKey: "weight-card",
            facts: AskFacts.weightCard(card),
            suggestedQuestions: HealthAskStarters.weight)
    }

    /// The weight chart as a WHOLE, including whatever point the user has scrubbed to —
    /// the chart's current selection is part of what they are looking at.
    static func weightTrend(series: [WeightPoint], progress: DietProgress?,
                            rangeLabel: String, rangeDays: Int?,
                            selection: WeightPoint? = nil,
                            scope: HealthAskScope = .page) -> HealthAskContext {
        var children = [AskFacts.weightSeries(series)]
        if let progress {
            let targets = DietSemantics.displayTargets(progress, currentWeight: series.last?.lbs,
                                                       today: series.last?.date)
            children.append(HealthAskFacts(heading: "Goals",
                                           lines: AskFacts.progress(progress, targets: targets).lines))
        }
        if let selection {
            children.append(HealthAskFacts(
                heading: "Currently selected on the chart",
                lines: ["\(selection.date) — \(DietSemantics.fmt1(selection.lbs)) lb"
                        + (selection.bf.map { " · \(DietSemantics.fmt($0))% body fat" } ?? "")]))
        }
        let anchor = series.last?.date ?? ""
        return HealthAskContext(
            scope: scope, area: .weight,
            timeRange: rangeDays.map { .trailing(days: $0, through: anchor) }
                ?? .all(through: anchor),
            title: "Weight & trend · \(rangeLabel)", subject: "this weight trend",
            subjectKey: "weight-trend",
            facts: HealthAskFacts(children: children),
            suggestedQuestions: HealthAskStarters.weight)
    }

    static func progress(_ p: DietProgress, today: DietToday, series: [WeightPoint]?,
                         scope: HealthAskScope, day: HealthAskDay) -> HealthAskContext {
        let current = HealthDisplay.weightCard(today: today, series: series)?.lbs
        let targets = DietSemantics.displayTargets(p, currentWeight: current, today: today.date)
        var facts = AskFacts.progress(p, targets: targets)
        if let current { facts.lines.insert("current weight \(DietSemantics.fmt(current)) lb", at: 0) }
        if let bf = today.weight?.bf, let lbs = today.weight?.lbs {
            facts.lines.append("body composition today: \(DietSemantics.fmt(lbs * bf / 100)) lb fat, "
                + "\(DietSemantics.fmt(lbs - lbs * bf / 100)) lb lean (\(DietSemantics.fmt(bf))% bf)")
        }
        return HealthAskContext(
            scope: scope, area: .progress, timeRange: day.range,
            title: "Progress & pace · \(day.short)", subject: "this progress",
            subjectKey: "progress",
            facts: facts,
            suggestedQuestions: HealthAskStarters.progress)
    }

    static func coach(_ c: DietCoach, scope: HealthAskScope, day: HealthAskDay) -> HealthAskContext {
        HealthAskContext(
            scope: scope, area: .coach, timeRange: day.range,
            title: "Coach's notes · \(day.short)", subject: "these notes",
            subjectKey: "coach",
            facts: AskFacts.coach(c),
            suggestedQuestions: HealthAskStarters.coach)
    }

    // MARK: Sources

    static func sourcesOverview(_ rankings: [NutrientSourceRanking], windowDays: Int,
                                anchor: String, scope: HealthAskScope) -> HealthAskContext {
        let (kept, note) = HealthAskBudget.cap(rankings, noun: "nutrients", totalsCoverAll: false)
        return HealthAskContext(
            scope: scope, area: .sources,
            timeRange: .trailing(days: windowDays, through: anchor),
            title: "Sources · last \(windowDays) days", subject: "these sources",
            subjectKey: "sources-overview",
            facts: HealthAskFacts(
                lines: ["\(rankings.count) \(rankings.count == 1 ? "nutrient" : "nutrients") "
                        + "can be answered for over this range"],
                children: kept.map(AskFacts.sourceRanking),
                note: note),
            suggestedQuestions: HealthAskStarters.sources)
    }

    static func sourceRanking(_ r: NutrientSourceRanking, anchor: String,
                              scope: HealthAskScope = .item) -> HealthAskContext {
        HealthAskContext(
            scope: scope, area: .sources,
            timeRange: .trailing(days: r.windowDays, through: anchor),
            title: "\(r.nutrient.fullName) sources · last \(r.windowDays) days",
            subject: "these \(r.nutrient.fullName.lowercased()) sources",
            subjectKey: "sources-\(r.nutrient.rawValue)",
            facts: AskFacts.sourceRanking(r),
            related: [r.nutrient.rawValue],
            suggestedQuestions: HealthAskStarters.sources)
    }

    /// ONE food inside a sources ranking.
    static func sourceEntry(_ e: NutrientSourceEntry, in r: NutrientSourceRanking,
                            anchor: String) -> HealthAskContext {
        HealthAskContext(
            scope: .item, area: .sources,
            timeRange: .trailing(days: r.windowDays, through: anchor),
            title: "\(e.name) · \(r.nutrient.fullName)", subject: "this source",
            subjectKey: "source-\(r.nutrient.rawValue)-\(e.name)",
            facts: HealthAskFacts(
                lines: ["\(e.name) supplied \(NutrientTrends.fmt(e.value, r.nutrient)) "
                        + "\(r.nutrient.unit) of \(r.nutrient.fullName.lowercased()) over the "
                        + "last \(r.windowDays) days",
                        "\(NutrientSources.pct(e.share)) of the measured total, "
                        + "on \(e.days) \(e.days == 1 ? "day" : "days")"],
                children: [AskFacts.sourceRanking(r)]),
            suggestedQuestions: HealthAskStarters.sources)
    }

    // MARK: Trends

    static func trend(_ t: NutrientTrend, rangeLabel: String, anchor: String,
                      selection: NutrientTrendPoint? = nil,
                      scope: HealthAskScope = .page) -> HealthAskContext {
        var facts = AskFacts.trend(t)
        if let selection {
            facts.lines.append("currently selected on the chart: \(selection.date) — "
                + "\(selection.isPartial ? "≥" : "")\(NutrientTrends.fmt(selection.value, t.nutrient)) "
                + "\(t.unit)"
                + (selection.dayTarget.map { " against that day's own \(NutrientTrends.fmt($0.value, t.nutrient)) \(t.unit)" } ?? " (that day recorded no target)"))
        }
        return HealthAskContext(
            scope: scope, area: .trends,
            timeRange: t.windowDays.map { .trailing(days: $0, through: anchor) }
                ?? .all(through: anchor),
            title: "\(t.nutrient.fullName), \(rangeLabel)", subject: "this trend",
            subjectKey: "trend-\(t.nutrient.rawValue)",
            facts: facts, related: [t.nutrient.rawValue],
            suggestedQuestions: HealthAskStarters.trends)
    }

    // MARK: Consistency

    static func consistency(_ streaks: [NutrientStreak], anchor: String,
                            scope: HealthAskScope) -> HealthAskContext {
        let (kept, note) = HealthAskBudget.cap(streaks, noun: "nutrients", totalsCoverAll: false)
        return HealthAskContext(
            scope: scope, area: .consistency, timeRange: .all(through: anchor),
            title: "Consistency", subject: "these streaks", subjectKey: "consistency",
            facts: HealthAskFacts(children: kept.map(AskFacts.streak),
                                  note: note ?? NutrientStreaks.gapRule),
            suggestedQuestions: HealthAskStarters.consistency)
    }

    static func streak(_ s: NutrientStreak, anchor: String) -> HealthAskContext {
        HealthAskContext(
            scope: .item, area: .consistency, timeRange: .all(through: anchor),
            title: "\(s.nutrient.fullName) streak", subject: "this streak",
            subjectKey: "streak-\(s.nutrient.rawValue)",
            facts: HealthAskFacts(children: [AskFacts.streak(s)], note: NutrientStreaks.gapRule),
            related: [s.nutrient.rawValue],
            suggestedQuestions: HealthAskStarters.consistency)
    }

    // MARK: Patterns

    static func patterns(_ report: DietCorrelationReport, anchor: String,
                         scope: HealthAskScope) -> HealthAskContext {
        var children = report.associations.map(AskFacts.association)
        if !report.misses.isEmpty {
            children.append(HealthAskFacts(
                heading: "Set aside, and why (never hidden)",
                children: report.misses.map(AskFacts.patternMiss)))
        }
        return HealthAskContext(
            scope: scope, area: .patterns, timeRange: .all(through: anchor),
            title: "Patterns", subject: "these patterns", subjectKey: "patterns",
            facts: HealthAskFacts(
                lines: ["\(report.associations.count) association"
                        + "\(report.associations.count == 1 ? "" : "s") cleared the guardrails"],
                children: children, note: DietCorrelations.caveat),
            suggestedQuestions: HealthAskStarters.patterns)
    }

    static func association(_ a: DietAssociation, anchor: String) -> HealthAskContext {
        HealthAskContext(
            scope: .item, area: .patterns, timeRange: .all(through: anchor),
            title: a.title, subject: "this pattern", subjectKey: a.id,
            facts: HealthAskFacts(children: [AskFacts.association(a)],
                                  note: DietCorrelations.caveat),
            suggestedQuestions: HealthAskStarters.patterns)
    }

    static func patternMiss(_ m: DietPairMiss, anchor: String) -> HealthAskContext {
        HealthAskContext(
            scope: .item, area: .patterns, timeRange: .all(through: anchor),
            title: m.title, subject: "this set-aside pair", subjectKey: m.id,
            facts: HealthAskFacts(children: [AskFacts.patternMiss(m)],
                                  note: DietCorrelations.caveat),
            suggestedQuestions: ["Why isn't there enough data for this?",
                                 "What would I have to log to answer it?"])
    }
}

extension String {
    /// Sentence-case the first character without touching the rest — "today's" →
    /// "Today's", and "Aug 22's" left alone. `capitalized` would lowercase the rest.
    var capitalizedAsk: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
