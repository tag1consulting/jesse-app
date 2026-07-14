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
                       total: Double = 250, statusLine: String = "need 40g more") -> HealthInsightInput {
        HealthInsightInput(metricLabel: metricLabel, unit: unit, total: total,
                           goalPhrase: "a floor to hit or beat", statusLine: statusLine,
                           dayStyle: "ordinary day", foods: foods)
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
        XCTAssertTrue(prompt.contains("250 g"))       // the day total
        XCTAssertTrue(prompt.contains("need 40g more")) // the live status line
        XCTAssertTrue(prompt.contains("Carbs"))
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
            metric: .macro(.carbs), total: 100, goalPhrase: "a floor to hit or beat",
            statusLine: "need 40g more", dayStyle: "ordinary day", contributions: contributions)
        XCTAssertEqual(built.foods.count, HealthInsight.groundingFoodCount)
        XCTAssertEqual(built.foods.first?.name, "F0")
        XCTAssertEqual(built.foods.first?.sharePct, 10)   // 10/100 → 10%
        XCTAssertEqual(built.metricLabel, "Carbs")
        XCTAssertEqual(built.unit, "g")
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
