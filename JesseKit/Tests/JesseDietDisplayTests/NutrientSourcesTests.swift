import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// The Sources engine. The rule the whole file exists to protect: UNKNOWN IS NOT ZERO. A
// food the log never measured for a nutrient is not a food that supplied none of it — it
// is excluded from the ranking AND from the total the shares are taken against, because a
// denominator quietly padded with unmeasured foods would understate every listed food's
// real share. Deterministic — dates are fixtures, never `Date()`.

final class NutrientSourcesTests: XCTestCase {

    // MARK: - Fixture builders

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// `count` consecutive ISO dates starting at `start`.
    private func dates(from start: String, count: Int) -> [String] {
        let s = Self.fmt.date(from: start)!
        return (0..<count).map { Self.fmt.string(from: Self.cal.date(byAdding: .day, value: $0, to: s)!) }
    }

    private func item(_ name: String, _ n: [String: Double]) -> SourceItem {
        SourceItem(name: name, n: n)
    }

    // MARK: - Ranking

    /// The headline behavior: foods summed across days, ranked by known contribution, with
    /// each one's share of the KNOWN total and the number of days it appeared on. This is
    /// the "saturated fat is mostly cheese and cured meat" answer.
    func testRanksTopFoodsByKnownContribution() {
        let d = dates(from: "2026-07-01", count: 3)
        let series = [
            SourceDay(date: d[0], items: [item("Pecorino", ["satf": 10]), item("Salami", ["satf": 9])]),
            SourceDay(date: d[1], items: [item("Pecorino", ["satf": 12]), item("Bread", ["satf": 5])]),
            SourceDay(date: d[2], items: [item("Pecorino", ["satf": 8]), item("Salami", ["satf": 6])]),
        ]

        let r = NutrientSources.rank(series, nutrient: .satf, windowDays: 7)

        XCTAssertEqual(r.entries.map(\.name), ["Pecorino", "Salami", "Bread"])
        XCTAssertEqual(r.entries[0].value, 30, accuracy: 0.001)   // 10 + 12 + 8, summed across days
        XCTAssertEqual(r.entries[1].value, 15, accuracy: 0.001)   // 9 + 6
        XCTAssertEqual(r.entries[2].value, 5, accuracy: 0.001)
        XCTAssertEqual(r.knownTotal, 50, accuracy: 0.001)
        XCTAssertEqual(r.entries[0].share, 0.60, accuracy: 0.001)
        XCTAssertEqual(r.entries[1].share, 0.30, accuracy: 0.001)
        XCTAssertEqual(r.entries[2].share, 0.10, accuracy: 0.001)
        // Day counts separate a staple from a one-off.
        XCTAssertEqual(r.entries.map(\.days), [3, 2, 1])
        XCTAssertEqual(r.contributorCount, 3)
        XCTAssertEqual(r.daysKnown, 3)
        XCTAssertEqual(r.daysInRange, 3)
    }

    /// A food appearing several times on the SAME day sums within the day too, and still
    /// counts as one day.
    func testSameFoodTwiceInOneDaySumsAndCountsOneDay() {
        let d = dates(from: "2026-07-01", count: 2)
        let series = [
            SourceDay(date: d[0], items: [item("Almonds", ["mg": 80]), item("Almonds", ["mg": 40])]),
            SourceDay(date: d[1], items: [item("Almonds", ["mg": 30])]),
        ]

        let r = NutrientSources.rank(series, nutrient: .mg, windowDays: 7)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].value, 150, accuracy: 0.001)
        XCTAssertEqual(r.entries[0].days, 2)
    }

    // MARK: - Unknown is not zero

    /// THE test this engine exists for. An unmeasured food is neither ranked nor summed:
    /// it never appears as a source, and it never enters the share denominator — so the
    /// measured foods' shares are identical whether or not the unmeasured ones were logged.
    func testUnknownContributionIsNeitherRankedNorInTheDenominator() {
        let d = dates(from: "2026-07-01", count: 2)
        let withUnknowns = [
            SourceDay(date: d[0], items: [
                item("Pecorino", ["satf": 30]),
                item("Restaurant risotto", ["cal": 700]),   // no satf key at all → UNKNOWN
            ]),
            SourceDay(date: d[1], items: [
                item("Salami", ["satf": 10]),
                item("Nonna's soup", ["cal": 300, "p": 12]), // likewise unknown for satf
            ]),
        ]
        let withoutUnknowns = [
            SourceDay(date: d[0], items: [item("Pecorino", ["satf": 30])]),
            SourceDay(date: d[1], items: [item("Salami", ["satf": 10])]),
        ]

        let r = NutrientSources.rank(withUnknowns, nutrient: .satf, windowDays: 7)
        let clean = NutrientSources.rank(withoutUnknowns, nutrient: .satf, windowDays: 7)

        // Never a source.
        XCTAssertEqual(r.entries.map(\.name), ["Pecorino", "Salami"])
        XCTAssertFalse(r.entries.contains { $0.name == "Restaurant risotto" })
        XCTAssertFalse(r.entries.contains { $0.name == "Nonna's soup" })
        // Never in the denominator: 40, not 40-plus-two-zeros, and the shares are exactly
        // what they would be if the unmeasured foods had never been logged.
        XCTAssertEqual(r.knownTotal, 40, accuracy: 0.001)
        XCTAssertEqual(r.entries[0].share, 0.75, accuracy: 0.001)
        XCTAssertEqual(r.entries.map(\.share), clean.entries.map(\.share))
        // But they ARE counted, so the screen can say the total is a floor.
        XCTAssertEqual(r.unmeasuredItems, 2)
        XCTAssertTrue(r.isPartial)
    }

    /// A MEASURED zero is a different animal from an unmeasured food: it contributed
    /// nothing (so it is not a source), but it leaves the total exact rather than a floor.
    func testMeasuredZeroIsNotASourceAndDoesNotMakeTheTotalAFloor() {
        let d = dates(from: "2026-07-01", count: 1)
        let series = [SourceDay(date: d[0], items: [
            item("Pecorino", ["satf": 20]),
            item("White rice", ["satf": 0]),
        ])]

        let r = NutrientSources.rank(series, nutrient: .satf, windowDays: 7)
        XCTAssertEqual(r.entries.map(\.name), ["Pecorino"])
        XCTAssertEqual(r.knownTotal, 20, accuracy: 0.001)
        XCTAssertEqual(r.unmeasuredItems, 0)
        XCTAssertFalse(r.isPartial)
    }

    /// A range where nothing measured the nutrient yields NO sources — the caller shows
    /// nothing rather than a guess, and there is no denominator to divide by.
    func testRangeWithNoKnownContributorYieldsNoSources() {
        let d = dates(from: "2026-07-01", count: 3)
        let series = d.map { SourceDay(date: $0, items: [item("Pasta", ["cal": 600, "c": 90])]) }

        let r = NutrientSources.rank(series, nutrient: .o3, windowDays: 7)
        XCTAssertTrue(r.isEmpty)
        XCTAssertTrue(r.entries.isEmpty)
        XCTAssertEqual(r.knownTotal, 0)
        XCTAssertEqual(r.daysKnown, 0)
        XCTAssertNil(r.leader)
        XCTAssertNil(NutrientSources.summaryLine(r))
        // The nutrient is absent from the overview entirely rather than listed as empty.
        XCTAssertFalse(NutrientSources.overview(series, windowDays: 7).contains { $0.nutrient == .o3 })
    }

    /// An empty series is answered, not crashed on.
    func testEmptySeriesRanksToNothing() {
        let r = NutrientSources.rank([], nutrient: .satf, windowDays: 7)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.daysInRange, 0)
        XCTAssertEqual(NutrientSources.overview([], windowDays: 30).count, 0)
    }

    // MARK: - Windowing

    /// The window is the most recent N calendar days anchored on the LAST logged day, so a
    /// food that fell out of the range stops counting — and the 30-day view still sees it.
    func testWindowExcludesFoodOlderThanTheRange() {
        let d = dates(from: "2026-07-01", count: 20)
        let series = [
            SourceDay(date: d[0], items: [item("Old cheese", ["satf": 100])]),
            SourceDay(date: d[19], items: [item("Recent cheese", ["satf": 10])]),
        ]

        let week = NutrientSources.rank(series, nutrient: .satf, windowDays: 7)
        XCTAssertEqual(week.entries.map(\.name), ["Recent cheese"])
        XCTAssertEqual(week.knownTotal, 10, accuracy: 0.001)

        let month = NutrientSources.rank(series, nutrient: .satf, windowDays: 30)
        XCTAssertEqual(month.entries.map(\.name), ["Old cheese", "Recent cheese"])
    }

    /// Rows whose date doesn't parse are dropped rather than allowed to anchor the window.
    func testUnparseableDatesAreDropped() {
        let series = [
            SourceDay(date: "not-a-date", items: [item("Ghost", ["satf": 99])]),
            SourceDay(date: "2026-07-10", items: [item("Pecorino", ["satf": 10])]),
        ]
        let r = NutrientSources.rank(series, nutrient: .satf, windowDays: 7)
        XCTAssertEqual(r.entries.map(\.name), ["Pecorino"])
    }

    // MARK: - Ordering, capping and naming

    /// Ties keep first-appearance order, so the list is stable and explainable rather than
    /// dictionary-ordered.
    func testEqualContributionsKeepFirstAppearanceOrder() {
        let d = dates(from: "2026-07-01", count: 1)
        let series = [SourceDay(date: d[0], items: [
            item("Anchovy", ["o3": 500]), item("Sardine", ["o3": 500]), item("Mackerel", ["o3": 500]),
        ])]
        let r = NutrientSources.rank(series, nutrient: .o3, windowDays: 7)
        XCTAssertEqual(r.entries.map(\.name), ["Anchovy", "Sardine", "Mackerel"])
    }

    /// The cap truncates the LIST but not the totals, and what it left out is counted so
    /// the screen can say so — a truncated list never reads as exhaustive.
    func testCapCountsWhatItLeavesOut() {
        let d = dates(from: "2026-07-01", count: 1)
        let items = (1...8).map { item("Food \($0)", ["na": Double(100 * (9 - $0))]) }
        let r = NutrientSources.rank([SourceDay(date: d[0], items: items)],
                                     nutrient: .na, windowDays: 7, limit: 3)

        XCTAssertEqual(r.entries.count, 3)
        XCTAssertEqual(r.entries.map(\.name), ["Food 1", "Food 2", "Food 3"])
        XCTAssertEqual(r.contributorCount, 8)
        XCTAssertEqual(r.hiddenContributors, 5)
        // The shares are still taken against the FULL known total, not the shown three.
        XCTAssertEqual(r.knownTotal, 3600, accuracy: 0.001)   // 800+700+…+100
        XCTAssertLessThan(r.listedShare, 1.0)
        XCTAssertTrue(NutrientSources.coverageLine(r).contains("5 smaller"))
    }

    /// A log row with no name is still a real measured contribution, so it is named rather
    /// than dropped — dropping it would understate the denominator.
    func testUnnamedRowIsLabelledNotDropped() {
        let d = dates(from: "2026-07-01", count: 1)
        let r = NutrientSources.rank([SourceDay(date: d[0], items: [item("   ", ["k": 400])])],
                                     nutrient: .k, windowDays: 7)
        XCTAssertEqual(r.entries.map(\.name), [NutrientSources.unnamedLabel])
        XCTAssertEqual(r.knownTotal, 400, accuracy: 0.001)
    }

    /// Unsaturated fat is derived by the bridge and arrives as a plain `unsat` key, so it
    /// ranks like any other nutrient with no special case here.
    func testDerivedUnsaturatedFatRanksLikeAnyOtherKey() {
        let d = dates(from: "2026-07-01", count: 1)
        let r = NutrientSources.rank([SourceDay(date: d[0], items: [
            item("Olive oil", ["f": 14, "satf": 2, "unsat": 12]),
            item("Butter", ["f": 11, "satf": 7, "unsat": 4]),
        ])], nutrient: .unsat, windowDays: 7)
        XCTAssertEqual(r.entries.map(\.name), ["Olive oil", "Butter"])
        XCTAssertEqual(r.knownTotal, 16, accuracy: 0.001)
    }

    // MARK: - Availability (graceful degrade)

    /// The affordance gate: absent (older bridge) or empty hides the Sources screens; one
    /// day of data is enough to offer them.
    func testAvailabilityHidesOnAbsentOrEmptySeries() {
        XCTAssertFalse(NutrientSources.isAvailable(nil))
        XCTAssertFalse(NutrientSources.isAvailable([]))
        XCTAssertTrue(NutrientSources.isAvailable([SourceDay(date: "2026-07-01",
                                                             items: [item("Eggs", ["p": 18])])]))
    }

    // MARK: - Wording

    /// The summary line names the leaders and says the share is of the MEASURED total —
    /// never of "the total", which would be a claim the ranking cannot make.
    func testSummaryLineNamesLeadersAndQualifiesTheShare() throws {
        let d = dates(from: "2026-07-01", count: 2)
        let r = NutrientSources.rank([
            SourceDay(date: d[0], items: [item("Pecorino", ["satf": 30]), item("Salami", ["satf": 10])]),
            SourceDay(date: d[1], items: [item("Pecorino", ["satf": 10])]),
        ], nutrient: .satf, windowDays: 7)

        let line = try XCTUnwrap(NutrientSources.summaryLine(r))
        XCTAssertTrue(line.contains("Pecorino"))
        XCTAssertTrue(line.contains("Salami"))
        XCTAssertTrue(line.contains("measured total"))
    }

    /// The coverage line states the known/logged days and, when anything was unmeasured,
    /// that the total is a floor. It never presents a gap as a zero day.
    func testCoverageLineStatesKnownDaysAndFloor() {
        let d = dates(from: "2026-07-01", count: 3)
        let r = NutrientSources.rank([
            SourceDay(date: d[0], items: [item("Pecorino", ["satf": 20])]),
            SourceDay(date: d[1], items: [item("Mystery lunch", ["cal": 800])]),
            SourceDay(date: d[2], items: [item("Salami", ["satf": 8])]),
        ], nutrient: .satf, windowDays: 7)

        let line = NutrientSources.coverageLine(r)
        XCTAssertEqual(r.daysKnown, 2)
        XCTAssertEqual(r.daysInRange, 3)
        XCTAssertTrue(line.contains("Known on 2 of 3 logged days"))
        XCTAssertTrue(line.contains("at least this much"))
    }

    /// The ranges offered stay inside the 45 days of per-item detail the bridge sends, so a
    /// label can never promise more history than the data holds.
    func testOfferedRangesStayInsideTheBridgesFortyFiveDays() {
        XCTAssertEqual(NutrientSources.ranges, [7, 30])
        XCTAssertTrue(NutrientSources.ranges.allSatisfy { $0 <= 45 })
    }
}
