import XCTest
@testable import Jesse

// Labeled weight goals: the legacy-fallback synthesis, the achieved/past-date
// states, the countdown selection and phrasing, `short`→`title` fallback, date
// formatting, and the coach-quote entity decode. The synthesis and countdown are
// pure `DietSemantics`, so every rule is tested directly without a view.

@MainActor
final class DietTargetTests: XCTestCase {
    typealias S = DietSemantics

    // A legacy-only progress payload (no `targets` array), like a pre-rollout file.
    private func legacyProgress() -> DietProgress {
        var p = DietProgress()
        p.startWeight = 204
        p.raceTarget = 165
        p.raceDate = "2026-08-15"
        p.maintTarget = 180
        p.raceBarFilled = 12
        p.maintBarFilled = 7
        p.raceBarLabel = "24 of 39 lb"
        p.maintBarLabel = "21 of 24 lb"
        return p
    }

    // MARK: - Legacy fallback synthesis

    func testLegacyFallbackSynthesizesTwoTargets() {
        // targets absent → race + maint synthesized, in that order, bar fields
        // carried from the legacy fields and daysLeft computed from the date.
        let t = S.displayTargets(legacyProgress(), currentWeight: 190, today: "2026-07-08")
        XCTAssertEqual(t.count, 2)

        let race = t[0]
        XCTAssertEqual(race.id, "race")
        XCTAssertEqual(race.title, "Target 165")
        XCTAssertEqual(race.short, "165")
        XCTAssertEqual(race.weight, 165)
        XCTAssertEqual(race.date, "2026-08-15")
        XCTAssertEqual(race.daysLeft, 38, "days from 2026-07-08 to 2026-08-15")
        XCTAssertNil(race.requiredPace, "legacy data has no required pace")
        XCTAssertEqual(race.achieved, false, "190 is above 165")
        XCTAssertEqual(race.barFilled, 12)
        XCTAssertEqual(race.barLabel, "24 of 39 lb")

        let maint = t[1]
        XCTAssertEqual(maint.id, "maint")
        XCTAssertEqual(maint.title, "Maintenance")
        XCTAssertEqual(maint.short, "Maint")
        XCTAssertEqual(maint.weight, 180)
        XCTAssertNil(maint.date, "maintenance is undated")
        XCTAssertNil(maint.daysLeft)
        XCTAssertEqual(maint.barLabel, "21 of 24 lb")
    }

    func testEmittedTargetsUsedVerbatim() {
        // When the generator emits `targets`, synthesis is bypassed entirely —
        // the array (and its authoritative derived fields) passes through unchanged.
        var p = DietProgress()
        p.raceTarget = 165  // legacy field present but ignored in favor of targets
        p.targets = [DietTarget(id: "bday", title: "Birthday", short: "Bday", weight: 180,
                                date: "2026-08-15", daysLeft: 38, requiredPace: 2.2,
                                achieved: false, barFilled: 11, barLabel: "56%")]
        let t = S.displayTargets(p, currentWeight: 190, today: "2026-07-08")
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].id, "bday")
        XCTAssertEqual(t[0].requiredPace, 2.2)
    }

    func testEmptyTargetsStayEmpty() {
        // targets: [] means "no weight goals right now" — synthesis must NOT kick in
        // and refill from the legacy fields; the empty array is authoritative so the
        // UI sections hide.
        var p = legacyProgress()
        p.targets = []
        XCTAssertTrue(S.displayTargets(p, currentWeight: 190, today: "2026-07-08").isEmpty)
    }

    // MARK: - Achieved state

    func testAchievedWhenCurrentWeightAtOrUnderTarget() {
        // A current weight at or under the goal weight is achieved; a nil current
        // weight leaves achieved unknown (nil), never a false "not yet".
        let atOrUnder = S.displayTargets(legacyProgress(), currentWeight: 165, today: "2026-07-08")
        XCTAssertEqual(atOrUnder[0].achieved, true, "165 == 165 counts as achieved")
        let unknown = S.displayTargets(legacyProgress(), currentWeight: nil, today: "2026-07-08")
        XCTAssertNil(unknown[0].achieved)
    }

    // MARK: - Countdown selection

    private func target(_ id: String, daysLeft: Int?, dated: Bool = true) -> DietTarget {
        DietTarget(id: id, title: id.capitalized, short: id, weight: 180,
                   date: dated ? "2026-08-15" : nil, daysLeft: daysLeft)
    }

    func testCountdownPicksNearestUpcoming() {
        let picked = S.countdownTarget([
            target("far", daysLeft: 90),
            target("undated", daysLeft: nil, dated: false),
            target("soon", daysLeft: 12),
            target("past", daysLeft: -5),
        ])
        XCTAssertEqual(picked?.id, "soon", "smallest non-negative daysLeft wins")
    }

    func testCountdownFallsBackToLeastPastWhenAllPast() {
        let picked = S.countdownTarget([
            target("longAgo", daysLeft: -40),
            target("recent", daysLeft: -3),
        ])
        XCTAssertEqual(picked?.id, "recent", "least-past when nothing is upcoming")
    }

    func testCountdownHiddenWithoutDatedGoal() {
        XCTAssertNil(S.countdownTarget([target("u", daysLeft: nil, dated: false)]))
        XCTAssertNil(S.countdownTarget([]))
    }

    // MARK: - Countdown phrasing

    func testCountdownTextFuturePastAndSingular() {
        XCTAssertEqual(S.countdownText(target("Birthday", daysLeft: 38)), "38 days to Birthday")
        XCTAssertEqual(S.countdownText(target("Birthday", daysLeft: 1)), "1 day to Birthday")
        XCTAssertEqual(S.countdownText(target("Cut", daysLeft: -68)), "68 days past Cut")
        XCTAssertEqual(S.countdownText(target("Cut", daysLeft: -1)), "1 day past Cut")
        XCTAssertEqual(S.countdownText(target("Cut", daysLeft: 0)), "0 days to Cut", "today is not 'past'")
        XCTAssertNil(S.countdownText(target("x", daysLeft: nil, dated: false)))
    }

    // MARK: - short → title fallback

    func testShortLabelFallsBackToTitle() {
        let withShort = DietTarget(id: "a", title: "Maintenance", short: "Maint", weight: 165)
        XCTAssertEqual(withShort.shortLabel, "Maint")
        let noShort = DietTarget(id: "b", title: "Maintenance", weight: 165)
        XCTAssertEqual(noShort.shortLabel, "Maintenance", "absent short → title")
    }

    func testTargetDecodesWithOmittedShort() throws {
        // A generator that skips `short` (contract says decode it as optional) still
        // decodes, and shortLabel falls back to title.
        let json = """
        { "id": "bday", "title": "Birthday", "weight": 180, "date": null, "extra": 1 }
        """
        let t = try JSONDecoder().decode(DietTarget.self, from: Data(json.utf8))
        XCTAssertNil(t.short)
        XCTAssertEqual(t.shortLabel, "Birthday")
        XCTAssertNil(t.date, "explicit null date decodes to nil")
    }

    func testProgressDecodesTargetsArray() throws {
        let json = """
        { "startWeight": 204, "raceTarget": 165,
          "targets": [
            { "id": "bday", "title": "Birthday", "short": "Bday", "weight": 180,
              "date": "2026-08-15", "daysLeft": 38, "requiredPace": 2.2,
              "achieved": false, "barFilled": 11, "barLabel": "56%" },
            { "id": "maint", "title": "Maintenance", "weight": 165, "date": null }
          ] }
        """
        let p = try JSONDecoder().decode(DietProgress.self, from: Data(json.utf8))
        XCTAssertEqual(p.targets?.count, 2)
        XCTAssertEqual(p.targets?[0].requiredPace, 2.2)
        XCTAssertEqual(p.targets?[0].shortLabel, "Bday")
        XCTAssertEqual(p.targets?[1].shortLabel, "Maintenance")
    }

    // MARK: - Date helpers

    func testDaysBetween() {
        XCTAssertEqual(S.daysBetween(from: "2026-07-08", to: "2026-08-15"), 38)
        XCTAssertEqual(S.daysBetween(from: "2026-07-08", to: "2026-07-08"), 0)
        XCTAssertEqual(S.daysBetween(from: "2026-07-08", to: "2026-05-01"), -68, "past date is negative")
        XCTAssertNil(S.daysBetween(from: "nope", to: "2026-08-15"))
    }

    func testDisplayDate() {
        XCTAssertEqual(S.displayDate("2026-08-15"), "Aug 15")
        XCTAssertNil(S.displayDate(nil))
        XCTAssertEqual(S.displayDate("not-a-date"), "not-a-date", "unparseable → raw fallback")
    }

    func testFmt1KeepsTenths() {
        XCTAssertEqual(S.fmt1(2.2), "2.2")
        XCTAssertEqual(S.fmt1(2.0), "2.0")
    }

    // MARK: - Coach quote entity decoding

    func testQuoteEntitiesDecodeLikeNotes() {
        // The quote text/author carry the same limited entity set as the notes; the
        // app decodes them through CoachHTML before display.
        XCTAssertEqual(CoachHTML.plainText("what you want now &mdash; and what you want most"),
                       "what you want now \u{2014} and what you want most")
        XCTAssertEqual(CoachHTML.plainText("don&rsquo;t quit"), "don\u{2019}t quit")
        XCTAssertEqual(CoachHTML.plainText("&lsquo;go&rsquo;"), "\u{2018}go\u{2019}")
    }
}
