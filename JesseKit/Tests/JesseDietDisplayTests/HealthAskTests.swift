import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// "Ask about this" — the context model, the serializers, and the budget.
//
// What these pin is the set of claims the feature rests on:
//
//  * COMPOSITION. A section's snapshot contains its items' blocks and a page's contains
//    its sections'. That is what makes three scopes one implementation, and what stops
//    the three of them telling three different stories about the same meal.
//  * THE SNAPSHOT IS THE SCREEN. Judgements come from the same engines the pixels came
//    from, so the wording in the snapshot is the wording on the row.
//  * UNKNOWN IS NOT ZERO survives serialization. A partial total is a floor in the
//    snapshot too, and an unmeasured food is named as unmeasured.
//  * THE BUDGET IS STATED. A capped list says how many rows it left out; a clamped
//    snapshot says it was clamped. Silent truncation reads as completeness.
//  * SCOPE IDENTITY. Two asks resume the same conversation only when they really are
//    about the same reading, on the same day.

final class HealthAskTests: XCTestCase {

    // MARK: - Fixtures

    private func snapshot(date: String = "2026-08-22", meals: String = "[]",
                          exercise: String = "[]", targets: String = "{}",
                          extra: String = "") -> DietSnapshot {
        let json = """
        { "asOf": "2026-08-22T14:00:00Z", "todayMtime": "2026-08-22T13:00:00Z",
          "today": { "date": "\(date)", "exercise": \(exercise), "meals": \(meals),
                     "targets": \(targets) },
          "errors": []\(extra) }
        """
        return try! DietSnapshot.decode(from: Data(json.utf8))
    }

    private let lunchJSON = """
    [{ "name": "Lunch", "time": "12:30", "items": [
        { "item": "Chicken thigh", "amount": "200 g", "cal": 330, "p": 38, "f": 19, "c": 0, "fiber": 0, "na": 410 },
        { "item": "Rice", "amount": "1 cup", "cal": 205, "p": 4, "f": 0, "c": 45, "fiber": 1 }
    ]}]
    """

    private let day = HealthAskDay(iso: "2026-08-22", isToday: true)

    private func lunch() -> DietMeal {
        snapshot(meals: lunchJSON).today.meals[0]
    }

    // MARK: - Composition

    /// A MEAL's block is exactly what shows up inside the food-journal SECTION, which is
    /// exactly what shows up inside the DAY page. One serializer, three scopes.
    func testSectionContainsItsItemsAndPageContainsItsSections() {
        let snap = snapshot(meals: lunchJSON)
        let meal = HealthAsk.meal(lunch(), day: day)
        let section = HealthAsk.foodJournalSection(today: snap.today, day: day)
        let gauges = DietSemantics.gauges(for: snap.today, hour: 14)
        let page = HealthAsk.day(snapshot: snap, gauges: gauges, hour: 14,
                                 windowMode: .day, day: day)

        XCTAssertTrue(meal.snapshotText.contains("Lunch · 12:30"))
        XCTAssertTrue(meal.snapshotText.contains("Chicken thigh (200 g)"))
        XCTAssertTrue(section.snapshotText.contains("Lunch · 12:30"))
        XCTAssertTrue(section.snapshotText.contains("Chicken thigh (200 g)"))
        XCTAssertTrue(page.snapshotText.contains("Lunch · 12:30"))
        XCTAssertTrue(page.snapshotText.contains("Chicken thigh (200 g)"))
    }

    /// Every scope of the same day agrees on the day's totals, because all three take
    /// them from `DietSemantics`, never from a second sum of their own.
    func testEveryScopeReportsTheSameDayTotal() {
        let snap = snapshot(meals: lunchJSON)
        let total = DietSemantics.fmt(DietSemantics.dayTotals(snap.today.meals).cal)
        let section = HealthAsk.foodJournalSection(today: snap.today, day: day)
        let pageCtx = HealthAsk.foodJournalPage(today: snap.today, proposed: nil, day: day)
        XCTAssertTrue(section.snapshotText.contains("\(total) cal logged"))
        XCTAssertTrue(pageCtx.snapshotText.contains("\(total) cal logged"))
    }

    /// The whole-day page has to answer "what's good and what's bad about today" with
    /// nothing selected — so it must carry the summary, the gauges, the food and the
    /// training, not just a headline.
    func testTheDayPageCarriesEverySectionOnScreen() {
        let snap = snapshot(meals: lunchJSON,
                            exercise: """
                            [{ "type": "run", "time": "07:00", "duration": "45:00", "calories": 520 }]
                            """,
                            targets: """
                            { "calories": 2200, "protein": 150, "fat": 65, "carbs": 220, "fiber": 30 }
                            """)
        let gauges = DietSemantics.gauges(for: snap.today, hour: 14)
        let text = HealthAsk.day(snapshot: snap, gauges: gauges, hour: 14,
                                 windowMode: .day, day: day).snapshotText
        for heading in ["The day", "Summary", "Calories & macros", "Food journal", "Exercise"] {
            XCTAssertTrue(text.contains(heading), "the page snapshot is missing '\(heading)'")
        }
        XCTAssertTrue(text.contains("Run · 07:00"))
        XCTAssertTrue(text.contains("520 cal"))
    }

    // MARK: - The snapshot is the screen

    /// A gauge's line carries the same value, target, goal kind and remaining string the
    /// row draws — not a paraphrase.
    func testAGaugeLineRepeatsTheRowsOwnWords() {
        let snap = snapshot(meals: lunchJSON,
                            targets: """
                            { "calories": 2200, "protein": 150, "fat": 65, "carbs": 220, "fiber": 30 }
                            """)
        let gauges = DietSemantics.gauges(for: snap.today, hour: 14)
        let line = AskFacts.gaugeLine(gauges.protein)
        XCTAssertTrue(line.hasPrefix("\(gauges.protein.label): "))
        XCTAssertTrue(line.contains(gauges.protein.remaining))
        XCTAssertTrue(line.contains("floor"), "protein is a floor, and the line says so")
    }

    /// A partial micronutrient total is a FLOOR on the screen and a floor in the
    /// snapshot, with the count of unmeasured items stated rather than dropped.
    func testAPartialTotalStaysAFloor() {
        // Sodium is known on the chicken and unknown on the rice.
        let snap = snapshot(meals: lunchJSON, targets: "{ \"sodium\": 2300 }")
        let gauge = DietSemantics.micronutrientGauge(.sodium, meals: snap.today.meals,
                                                     targets: snap.today.targets, hour: 14)
        XCTAssertTrue(gauge.partial, "fixture precondition: one item carries no sodium")
        let facts = AskFacts.gauge(gauge).render()
        XCTAssertTrue(facts.contains("≥"), "a floor is marked, never rendered as a total")
        XCTAssertTrue(facts.contains("carries no measured value"))
        XCTAssertTrue(facts.contains("is a floor, not a total"))
    }

    /// A food with no measured micronutrients says so in those words. "Unknown, not zero"
    /// is the app's standing rule, and the snapshot is where it is easiest to lose.
    func testAnUnmeasuredFoodIsNamedUnknownNotZero() {
        let meal = lunch()
        let rice = meal.items[1]
        let text = HealthAsk.food(rice, in: meal, day: day).snapshotText
        XCTAssertTrue(text.contains("unknown, not zero"))
        XCTAssertFalse(text.contains("Sodium 0mg"))
    }

    /// A planned meal is never counted as eaten — the page marks it, in capitals.
    func testPlannedMealsAreMarkedAsNotEaten() {
        let snap = snapshot(meals: lunchJSON, extra: """
        , "proposed": { "ideas": [{ "name": "Dinner idea", "items": [
            { "item": "Salmon", "cal": 400, "p": 40, "f": 25, "c": 0, "fiber": 0 }] }] }
        """)
        let text = HealthAsk.foodJournalPage(today: snap.today, proposed: snap.proposed,
                                             day: day).snapshotText
        XCTAssertTrue(text.contains("NOT eaten, not in any total above"))
        XCTAssertTrue(text.contains("PLANNED, not logged"))
    }

    // MARK: - The budget

    /// A capped list keeps the biggest rows, states how many it dropped, and says the
    /// totals still cover all of them.
    func testACappedListSaysWhatItLeftOut() {
        let items = (1...20).map { i in
            "{ \"item\": \"Food \(i)\", \"cal\": \(i * 10), \"p\": 1, \"f\": 1, \"c\": 1, \"fiber\": 0 }"
        }.joined(separator: ",")
        let big = snapshot(meals: "[{ \"name\": \"Buffet\", \"items\": [\(items)] }]")
        let facts = AskFacts.meal(big.today.meals[0])
        let text = facts.render()
        XCTAssertTrue(text.contains("Food 20"), "the biggest contributor survives the cap")
        XCTAssertFalse(text.contains("Food 1 ("), "the smallest is dropped")
        XCTAssertTrue(text.contains("8 more foods not listed"))
        XCTAssertTrue(text.contains("the totals above still count all of them"))
        // The subtotal is over EVERY item, capped list or not.
        let all = DietSemantics.subtotal(of: big.today.meals[0])
        XCTAssertTrue(text.contains("\(DietSemantics.fmt(all.cal)) cal"))
    }

    /// A snapshot past the ceiling is cut at a line boundary and admits it.
    func testAnOversizedSnapshotIsClampedAndSaysSo() {
        let long = Array(repeating: "x", count: HealthAskBudget.maxCharacters / 4)
            .map { $0 + String(repeating: "y", count: 20) }
            .joined(separator: "\n")
        let clamped = HealthAskBudget.clamp(long)
        XCTAssertLessThan(clamped.count, long.count)
        XCTAssertTrue(clamped.hasSuffix("(snapshot truncated here to fit — ask for any part of it in full)"))
        XCTAssertFalse(clamped.dropLast(70).contains("\n\n"), "cut at a line, never mid-line")
    }

    func testAShortSnapshotIsUntouched() {
        XCTAssertEqual(HealthAskBudget.clamp("one line"), "one line")
    }

    // MARK: - Scope identity (what resume is decided on)

    func testTheSameReadingProducesTheSameScopeKey() {
        let a = HealthAsk.meal(lunch(), day: day)
        let b = HealthAsk.meal(lunch(), day: day)
        XCTAssertEqual(a.scopeKey, b.scopeKey)
    }

    func testADifferentDayIsADifferentReading() {
        let today = HealthAsk.meal(lunch(), day: day)
        let yesterday = HealthAsk.meal(lunch(),
                                       day: HealthAskDay(iso: "2026-08-21", isToday: false))
        XCTAssertNotEqual(today.scopeKey, yesterday.scopeKey)
    }

    func testADifferentScopeOfTheSameAreaIsADifferentReading() {
        let snap = snapshot(meals: lunchJSON)
        let item = HealthAsk.meal(lunch(), day: day)
        let section = HealthAsk.foodJournalSection(today: snap.today, day: day)
        let page = HealthAsk.foodJournalPage(today: snap.today, proposed: nil, day: day)
        XCTAssertNotEqual(item.scopeKey, section.scopeKey)
        XCTAssertNotEqual(section.scopeKey, page.scopeKey)
    }

    /// A rolling window's key carries its anchor, so "the last 7 days" asked on two
    /// different days are two different readings and never share a conversation.
    func testARollingWindowIsAnchoredToItsDay() {
        let a = HealthAskTimeRange.trailing(days: 7, through: "2026-08-22")
        let b = HealthAskTimeRange.trailing(days: 7, through: "2026-08-23")
        XCTAssertNotEqual(a.key, b.key)
    }

    func testScopeKeysAreSlugsWithNoSpaces() {
        let key = HealthAsk.meal(lunch(), day: day).scopeKey
        XCTAssertFalse(key.contains(" "))
        XCTAssertTrue(key.hasPrefix("health/foodJournal/item/d:2026-08-22/"))
    }

    // MARK: - Wording

    func testTheMenuItemNamesWhatWasPressed() {
        XCTAssertEqual(HealthAsk.meal(lunch(), day: day).menuLabel, "Ask about this meal")
        let workout = snapshot(exercise: """
        [{ "type": "run", "time": "07:00" }]
        """).today.exercise[0]
        XCTAssertEqual(HealthAsk.workout(workout, day: day).menuLabel, "Ask about this workout")
        let snap = snapshot(meals: lunchJSON)
        XCTAssertEqual(HealthAsk.foodJournalSection(today: snap.today, day: day).menuLabel,
                       "Ask about today's food")
    }

    /// A paged-back reading says its own date everywhere, so nothing can be answered as
    /// though it were today's.
    func testAPastDayNamesItsOwnDate() {
        let past = HealthAskDay(iso: "2026-08-01", isToday: false)
        let ctx = HealthAsk.meal(lunch(), day: past)
        XCTAssertEqual(ctx.title, "Lunch · Aug 1")
        XCTAssertFalse(ctx.timeRange.label.contains("today"))
        XCTAssertTrue(ctx.promptText.contains("Aug 1"))
    }

    // MARK: - Starters

    /// Two to four, everywhere. One is not a choice and five is a menu.
    func testEveryScopeOffersTwoToFourStarters() {
        let snap = snapshot(meals: lunchJSON)
        let gauges = DietSemantics.gauges(for: snap.today, hour: 14)
        let contexts: [HealthAskContext] = [
            HealthAsk.day(snapshot: snap, gauges: gauges, hour: 14, windowMode: .day, day: day),
            HealthAsk.meal(lunch(), day: day),
            HealthAsk.food(lunch().items[0], in: lunch(), day: day),
            HealthAsk.foodJournalPage(today: snap.today, proposed: nil, day: day),
            HealthAsk.macrosPage(today: snap.today, gauges: gauges, hour: 14,
                                 judgeSeries: nil, neutral: false, day: day),
            HealthAsk.exercisePage(snap.today.exercise, day: day),
            HealthAsk.metric(gauges.calories, area: .calories, day: day),
        ]
        for ctx in contexts {
            XCTAssertTrue((2...4).contains(ctx.suggestedQuestions.count),
                          "\(ctx.title) offers \(ctx.suggestedQuestions.count) starters")
        }
    }

    /// The brief's own example: the calorie item's starters have to be answerable from
    /// the item context alone, which is why the contributors ride along with it.
    func testACalorieItemCarriesItsContributingFoods() {
        let snap = snapshot(meals: lunchJSON, targets: "{ \"calories\": 2200 }")
        let gauges = DietSemantics.gauges(for: snap.today, hour: 14)
        let breakdown = FoodContributions.breakdown(snap.today.meals, metric: .calories,
                                                    total: gauges.calories.value)
        let ctx = HealthAsk.metric(gauges.calories, area: .calories, day: day,
                                   breakdown: breakdown)
        XCTAssertTrue(ctx.snapshotText.contains("Where it came from"))
        XCTAssertTrue(ctx.snapshotText.contains("Chicken thigh"))
        XCTAssertTrue(ctx.suggestedQuestions.contains("Why is this so caloric?"))
    }

    // MARK: - The prompt it becomes

    func testThePromptFencesTheSnapshotItBuilt() {
        let ctx = HealthAsk.meal(lunch(), day: day)
        let p = ctx.promptText
        XCTAssertTrue(p.contains("---BEGIN SCREEN---"))
        XCTAssertTrue(p.contains(ctx.snapshotText))
        XCTAssertTrue(p.contains("Scope: this reading only."))
    }

    func testTheAttachmentCarriesTitleAndStarters() {
        let ctx = HealthAsk.meal(lunch(), day: day)
        let attachment = ctx.attachment
        XCTAssertEqual(attachment.body, ctx.promptText)
        XCTAssertEqual(attachment.title, ctx.title)
        XCTAssertEqual(attachment.starters, ctx.suggestedQuestions)
    }

    // MARK: - The model's page context

    @MainActor
    func testPageAskContextIsNilUntilSomethingHasLoaded() {
        let model = HealthDashboardModel(makeClient: { NeverClient() })
        XCTAssertNil(model.pageAskContext)
    }

    private struct NeverClient: DietSnapshotProviding {
        func fetchDietSnapshot(date: String?) async throws -> DietSnapshot {
            throw DietFetchError.unreachable("no")
        }
    }
}
