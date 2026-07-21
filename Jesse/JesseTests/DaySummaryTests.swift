import XCTest
@testable import Jesse

// The plain-language day summary that leads the Health tab. It's derived entirely from
// the same gauges the rings draw, so these assert the three shapes the proposal showed:
// a calm morning, a solid evening with a gentle nudge, and a carb-load day that says
// "eat more" in words — never a wall of red.

@MainActor
final class DaySummaryTests: XCTestCase {
    typealias S = DietSemantics

    private func item(_ cal: Double, _ p: Double, _ f: Double, _ c: Double, _ fiber: Double) -> DietItem {
        DietItem(item: "x", amount: nil, cal: cal, p: p, f: f, c: c, fiber: fiber)
    }
    private func today(_ meals: [DietMeal], _ targets: DietTargets, dayStyle: String = "normal") -> DietToday {
        DietToday(date: "2026-07-21", dayStyle: dayStyle, dayType: nil, weight: nil,
                  exercise: [], meals: meals, targets: targets)
    }
    private let normalTargets = DietTargets(calories: 2600, protein: 140, fat: 65,
                                            carbs: 300, carbsBase: 300, fiber: 38)

    func testEmptyDayIsAGentleInvitation() {
        let g = S.gauges(for: today([], normalTargets), hour: 9)
        let s = DaySummary.make(gauges: g, hour: 9, hasFood: false)
        XCTAssertEqual(s.tone, .inProgress)
        XCTAssertTrue(s.nextAction.contains("Log a meal"))
        // Never a scolding — no punitive vocabulary.
        for banned in ["fail", "miss", "over limit", "breach", "penalty"] {
            XCTAssertFalse((s.headline + s.nextAction).lowercased().contains(banned))
        }
    }

    func testMorningReadsAsANormalStartNotFailure() {
        // ~9am, breakfast only: floors far short but it's early.
        let meals = [DietMeal(name: "breakfast", time: "08:00", items: [item(520, 30, 18, 68, 6)])]
        let s = DaySummary.make(gauges: S.gauges(for: today(meals, normalTargets), hour: 9),
                                hour: 9, hasFood: true)
        XCTAssertEqual(s.tone, .inProgress)
        XCTAssertEqual(s.headline, "Good start — the day's just getting going.")
        // The "what next" is reassurance, not a task list.
        XCTAssertTrue(s.nextAction.contains("Nothing needed yet"))
    }

    func testEveningNudgeNamesTheHelpfulActionFirst() {
        // Full day, 20:00: protein and fiber still low → a gentle, action-first nudge.
        let meals = [DietMeal(name: "day", time: "12:00", items: [item(2180, 100, 58, 295, 20)])]
        let s = DaySummary.make(gauges: S.gauges(for: today(meals, normalTargets), hour: 20),
                                hour: 20, hasFood: true)
        XCTAssertEqual(s.tone, .nudge)
        XCTAssertEqual(s.headline, "Solid day.")
        XCTAssertTrue(s.nextAction.contains("this evening"))
        // Names the genuinely-short floors, not the basically-there carbs.
        XCTAssertTrue(s.nextAction.contains("fiber"))
        XCTAssertTrue(s.nextAction.contains("protein"))
        XCTAssertFalse(s.nextAction.contains("carbs"))
    }

    func testCarbLoadUnderFuelSaysEatMoreInWords() {
        // Carb-load evening, under the fuel window: the helpful direction is MORE food,
        // and the words say so — the opposite instruction the same low calories would carry
        // on a normal day, without ever reusing a color to mean it.
        let targets = DietTargets(calories: 3200, protein: 140, fat: 45, carbs: 500, carbsBase: 500, fiber: 38)
        let meals = [DietMeal(name: "day", time: "12:00", items: [item(2600, 120, 35, 430, 8)])]
        let s = DaySummary.make(gauges: S.gauges(for: today(meals, targets, dayStyle: "carb-load-training"), hour: 19),
                                hour: 19, hasFood: true)
        XCTAssertEqual(s.headline, "Carb-load day — keep the fuel coming.")
        XCTAssertTrue(s.nextAction.contains("under the fuel window"))
        XCTAssertTrue(s.nextAction.lowercased().contains("carbs"))
    }

    func testWellOverCeilingLateIsAKindHeadsUpNotAnAlarm() {
        // Well over the calorie ceiling, late: the honest signal is kept, delivered gently.
        let meals = [DietMeal(name: "day", time: "12:00", items: [item(3100, 150, 60, 320, 40)])]
        let s = DaySummary.make(gauges: S.gauges(for: today(meals, normalTargets), hour: 21),
                                hour: 21, hasFood: true)
        XCTAssertEqual(s.tone, .takeNote)
        XCTAssertTrue(s.nextAction.contains("easing back"))
        XCTAssertFalse(s.nextAction.lowercased().contains("fail"))
    }
}
