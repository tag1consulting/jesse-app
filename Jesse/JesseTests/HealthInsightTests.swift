import XCTest
@testable import Jesse

// The on-device insight seam has two testable halves: the pure prompt builder (which
// grounds the model in the on-screen foods and numbers and forbids invention) and the
// seam contract itself (a total, never-throwing stream that collapses to EMPTY when
// the model is unavailable or errors — the path that lets the facts stand alone). The
// real FoundationModels model is unavailable in CI / the Simulator, so this file
// exercises the pure builder and stub conformers, never the model. It does NOT import
// FoundationModels — proving the seam and its grounding are usable without it.

@MainActor
final class HealthInsightTests: XCTestCase {

    private func input(foods: [FoodFact],
                       metricLabel: String = "Carbs", unit: String = "g",
                       total: Double = 250, goal: Double? = 290,
                       goalStatus: DietSemantics.GoalStatus = .short(40),
                       partial: Bool = false, knownItemCount: Int = 0,
                       unknownItemCount: Int = 0, informational: Bool = false) -> HealthInsightInput {
        HealthInsightInput(metricLabel: metricLabel, unit: unit, total: total,
                           goal: goal, goalStatus: goalStatus,
                           goalPhrase: "a floor to hit or beat",
                           dayStyle: "ordinary day", foods: foods,
                           partial: partial, knownItemCount: knownItemCount,
                           unknownItemCount: unknownItemCount, informational: informational)
    }

    // MARK: - Prompt grounding

    func testPromptNamesEveryFoodAndNumber() {
        let prompt = HealthInsightPrompt.make(input(foods: [
            FoodFact(name: "Pasta", value: 80, sharePct: 32),
            FoodFact(name: "Banana", value: 27, sharePct: 11),
        ]))
        XCTAssertTrue(prompt.contains("Pasta"))
        XCTAssertTrue(prompt.contains("Banana"))
        XCTAssertTrue(prompt.contains("80 g"))
        XCTAssertTrue(prompt.contains("32%"))
        XCTAssertTrue(prompt.contains("250 g"))       // consumed so far
        XCTAssertTrue(prompt.contains("290 g"))       // the target
        XCTAssertTrue(prompt.contains("Carbs"))
    }

    // MARK: - Authoritative goal-status grounding (the defect)

    func testPromptStatesGoalNotMetWhenShort() {
        // 93 of 140 g protein — the real defect case: the model was asserting "you've
        // hit your goal". The prompt must hand it the computed NOT-met status as ground
        // truth, with the correct shortfall.
        let prompt = HealthInsightPrompt.make(input(
            foods: [FoodFact(name: "Star protein", value: 40, sharePct: 26)],
            metricLabel: "Protein", total: 93, goal: 140, goalStatus: .short(47)))
        XCTAssertTrue(prompt.contains("GOAL STATUS"))
        XCTAssertTrue(prompt.uppercased().contains("NOT MET"))
        XCTAssertTrue(prompt.contains("47g short"))
        // And it must forbid the very claim that was appearing.
        XCTAssertTrue(prompt.lowercased().contains("never say"))
    }

    func testPromptStatesGoalMetWhenMet() {
        let prompt = HealthInsightPrompt.make(input(
            foods: [], metricLabel: "Carbs", total: 300, goal: 290, goalStatus: .met))
        XCTAssertTrue(prompt.uppercased().contains("MET"))
    }

    func testPromptMakesNoGoalClaimWhenNoTarget() {
        let prompt = HealthInsightPrompt.make(input(
            foods: [], metricLabel: "Fiber", total: 12, goal: nil, goalStatus: .noGoal))
        XCTAssertTrue(prompt.contains("Target: none set."))
        XCTAssertTrue(prompt.lowercased().contains("do not state any goal status"))
    }

    func testPromptForbidsInvention() {
        let prompt = HealthInsightPrompt.make(input(foods: [FoodFact(name: "Rice", value: 40, sharePct: 100)]))
        XCTAssertTrue(prompt.lowercased().contains("do not invent"))
        XCTAssertTrue(prompt.lowercased().contains("only"))
    }

    func testPromptHandlesNoFoods() {
        let prompt = HealthInsightPrompt.make(input(foods: []))
        XCTAssertTrue(prompt.contains("(none logged)"))
    }

    // MARK: - Grounding-input builder

    func testInputCapsFoodsAndComputesShare() {
        let contributions = (0..<8).map { i in
            FoodContribution(id: i, name: "F\(i)", amount: nil, value: Double(10 - i), share: Double(10 - i) / 100)
        }
        let built = HealthInsight.input(
            metric: .macro(.carbs), total: 100, goal: 140, goalStatus: .short(40),
            goalPhrase: "a floor to hit or beat", dayStyle: "ordinary day",
            contributions: contributions)
        XCTAssertEqual(built.foods.count, HealthInsight.groundingFoodCount)
        XCTAssertEqual(built.foods.first?.name, "F0")
        XCTAssertEqual(built.foods.first?.sharePct, 10)   // 10/100 → 10%
        XCTAssertEqual(built.metricLabel, "Carbs")
        XCTAssertEqual(built.unit, "g")
        XCTAssertEqual(built.goal, 140)
        XCTAssertEqual(built.goalStatus, .short(40))
    }

    // MARK: - Micronutrient grounding (partial floor + informational)

    func testPromptStatesPartialTotalIsAFloor() {
        let prompt = HealthInsightPrompt.make(input(
            foods: [FoodFact(name: "Bread", value: 450, sharePct: 60)],
            metricLabel: "Sodium", unit: "mg", total: 750, goal: 2300,
            goalStatus: .met, partial: true, knownItemCount: 2, unknownItemCount: 1))
        XCTAssertTrue(prompt.contains("PARTIALITY"))
        XCTAssertTrue(prompt.uppercased().contains("PARTIAL"))
        XCTAssertTrue(prompt.lowercased().contains("floor"))
        XCTAssertTrue(prompt.contains("1 of 3"), "names how many of how many items are unknown")
        // It must forbid claiming completeness.
        XCTAssertTrue(prompt.lowercased().contains("at least"))
    }

    func testPromptOmitsPartialityLineWhenComplete() {
        let prompt = HealthInsightPrompt.make(input(foods: [], metricLabel: "Sodium",
                                                    unit: "mg", total: 800, partial: false))
        XCTAssertFalse(prompt.contains("PARTIALITY"))
    }

    func testPromptForbidsJudgmentForInformationalMetric() {
        let prompt = HealthInsightPrompt.make(input(
            foods: [FoodFact(name: "Yogurt", value: 20, sharePct: 50)],
            metricLabel: "Total Sugars", unit: "g", total: 40, goal: nil,
            goalStatus: .noGoal, informational: true))
        XCTAssertTrue(prompt.uppercased().contains("INFORMATIONAL ONLY"))
        XCTAssertTrue(prompt.lowercased().contains("never judge"))
        XCTAssertTrue(prompt.contains("Target: none set."))
    }

    func testInputBuilderCarriesMicronutrientFacts() {
        let contributions = [FoodContribution(id: 0, name: "Bread", amount: nil, value: 450, share: 0.6)]
        let built = HealthInsight.input(
            metric: .micronutrient(.sodium), total: 750, goal: 2300, goalStatus: .met,
            goalPhrase: "a ceiling to stay under", dayStyle: "ordinary day",
            contributions: contributions, partial: true, knownItemCount: 2,
            unknownItemCount: 1, informational: false)
        XCTAssertEqual(built.unit, "mg")
        XCTAssertTrue(built.partial)
        XCTAssertEqual(built.knownItemCount, 2)
        XCTAssertEqual(built.unknownItemCount, 1)
    }

    // MARK: - The discard guard (deterministic backstop for a wrong generation)

    func testGuardDiscardsGoalClaimWhenShort() {
        // The exact wrong sentence from the field, against a short status → discard.
        let bad = "You've hit your protein goal for the day, with 26% from the Star protein."
        XCTAssertTrue(HealthInsightGuard.contradicts(bad, status: .short(47)))
    }

    func testGuardKeepsGoalClaimWhenActuallyMet() {
        let ok = "You've hit your protein goal for the day."
        XCTAssertFalse(HealthInsightGuard.contradicts(ok, status: .met))
    }

    func testGuardKeepsColorOnlyInsight() {
        // No goal claim at all — just contributor color — survives any status.
        let color = "Most of your carbs came from the pasta (32%) and a banana (11%)."
        XCTAssertFalse(HealthInsightGuard.contradicts(color, status: .short(40)))
        XCTAssertFalse(HealthInsightGuard.contradicts(color, status: .over(20)))
    }

    func testGuardDiscardsGoalClaimWhenNoTarget() {
        // A metric with no target must draw no goal claim; one gets discarded.
        let bad = "You reached your fiber target easily today."
        XCTAssertTrue(HealthInsightGuard.contradicts(bad, status: .noGoal))
    }

    func testGuardCatchesVariedCompletionPhrasings() {
        for claim in ["You met your carb goal.",
                      "Your protein target is met.",
                      "You're on track to hit your goal.",
                      "Nice — you reached your goal today."] {
            XCTAssertTrue(HealthInsightGuard.contradicts(claim, status: .short(10)),
                          "should catch: \(claim)")
        }
    }

    func testGuardKeepsNegatedNotMetPhrasings() {
        // The real on-device output for the 93/140 case — a CORRECT not-met sentence
        // that contains "met your protein goal" only under a negation. It must survive.
        for ok in ["You have not met your protein goal for the day",
                   "You haven't hit your protein goal yet.",
                   "You're still short of your protein goal.",
                   "You're under your protein target — 47 g to go."] {
            XCTAssertFalse(HealthInsightGuard.contradicts(ok, status: .short(47)),
                           "should keep: \(ok)")
        }
    }

    // MARK: - The discard guard, micronutrient facts (completeness + judgment)

    func testGuardDiscardsCompletenessClaimOnPartialDay() {
        // A partial sodium day: a generation that presents the floor as a complete total
        // is discarded (the number is only "at least").
        let partial = input(foods: [], metricLabel: "Sodium", unit: "mg", total: 750,
                            goal: 2300, goalStatus: .met, partial: true,
                            knownItemCount: 2, unknownItemCount: 1)
        for bad in ["You had 750 mg of sodium in total today.",
                    "Altogether that's a modest sodium day.",
                    "Your total sodium came mostly from the bread."] {
            XCTAssertTrue(HealthInsightGuard.contradicts(bad, input: partial),
                          "should discard completeness claim: \(bad)")
        }
    }

    func testGuardKeepsFloorPhrasingOnPartialDay() {
        let partial = input(foods: [], metricLabel: "Sodium", unit: "mg", total: 750,
                            goal: 2300, goalStatus: .met, partial: true,
                            knownItemCount: 2, unknownItemCount: 1)
        for ok in ["At least 750 mg of sodium so far, mostly from the bread.",
                   "The bread and cheese are your biggest sodium sources logged."] {
            XCTAssertFalse(HealthInsightGuard.contradicts(ok, input: partial),
                           "should keep floor-honest insight: \(ok)")
        }
    }

    func testGuardKeepsCompletenessClaimWhenComplete() {
        // The same "in total" phrasing is fine when the total is NOT partial.
        let complete = input(foods: [], metricLabel: "Sodium", unit: "mg", total: 800,
                             goal: 2300, goalStatus: .met, partial: false)
        XCTAssertFalse(HealthInsightGuard.contradicts("You had 800 mg of sodium in total.",
                                                      input: complete))
    }

    func testGuardDiscardsJudgmentForInformationalSugars() {
        let sugars = input(foods: [], metricLabel: "Total Sugars", unit: "g", total: 90,
                           goal: nil, goalStatus: .noGoal, informational: true)
        for bad in ["That's a lot of sugar — try to cut back tomorrow.",
                    "Your sugars are too high today.",
                    "You went over on sugar."] {
            XCTAssertTrue(HealthInsightGuard.contradicts(bad, input: sugars),
                          "should discard judgment: \(bad)")
        }
    }

    func testGuardKeepsCompositionForInformationalSugars() {
        let sugars = input(foods: [], metricLabel: "Total Sugars", unit: "g", total: 90,
                           goal: nil, goalStatus: .noGoal, informational: true)
        let ok = "Most of your sugars came from the yogurt and berries — natural dairy and fruit sugars."
        XCTAssertFalse(HealthInsightGuard.contradicts(ok, input: sugars))
    }

    // MARK: - Seam contract: empty / error → empty stream

    private func collect(_ stream: AsyncStream<String>) async -> [String] {
        var out: [String] = []
        for await s in stream { out.append(s) }
        return out
    }

    func testUnavailableSeamYieldsNothing() async {
        let out = await collect(NoHealthInsight().insight(for: input(foods: [])))
        XCTAssertEqual(out, [], "an unavailable/errored model must leave the facts alone")
    }

    func testStreamingSeamYieldsCumulativeSnapshots() async {
        let stub = StreamingInsightStub(snapshots: ["Carbs", "Carbs came", "Carbs came in high."])
        let out = await collect(stub.insight(for: input(foods: [])))
        XCTAssertEqual(out, ["Carbs", "Carbs came", "Carbs came in high."])
    }

    func testErroringSeamYieldsNothing() async {
        let out = await collect(ErroringInsightStub().insight(for: input(foods: [])))
        XCTAssertEqual(out, [], "a mid-stream failure degrades to nothing, no error surfaced")
    }
}

// MARK: - Stub conformers (stand in for the FoundationModels-backed seam)

/// Streams a fixed list of cumulative snapshots, like a working on-device model.
private struct StreamingInsightStub: HealthInsightGenerating {
    let snapshots: [String]
    func insight(for input: HealthInsightInput) -> AsyncStream<String> {
        AsyncStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
}

/// Finishes immediately with no snapshots, like a model that fails mid-call.
private struct ErroringInsightStub: HealthInsightGenerating {
    func insight(for input: HealthInsightInput) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}
