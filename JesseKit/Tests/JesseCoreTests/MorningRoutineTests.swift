import XCTest
@testable import JesseCore

// The Chats tab's "Good morning" prompt. The wording is frozen, and these tests pin
// the four properties that make it do the right thing rather than merely read well:
// the positive scope, the negative clause that keeps the health refresh out of the
// default, the ORDER of the two halves when the health refresh is opted into, and the
// date coming from the device rather than from the agent's own clock.

final class MorningRoutineTests: XCTestCase {

    /// 2026-08-10 at 06:30 UTC — a Monday. Late enough in UTC that a westward zone is
    /// still on the previous day, which is what the time-zone test turns on.
    private let instant = Date(timeIntervalSince1970: 1_786_343_400)

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    // MARK: - The date

    func testTheDateIsSpelledOutWithItsWeekdayAndYear() {
        let prompt = MorningRoutine.prompt(now: instant, calendar: calendar("Europe/Rome"))
        XCTAssertTrue(prompt.contains("It is Monday, August 10, 2026."),
                      "weekday, month name, day and year — the form Jeremy types by hand")
    }

    /// The whole reason the date is interpolated at all: the agent's idea of "today"
    /// comes from a different machine in a different zone. One instant is two different
    /// local dates, and each device must send its own.
    func testTheSameInstantIsADifferentDateInADifferentTimeZone() {
        let rome = MorningRoutine.prompt(now: instant, calendar: calendar("Europe/Rome"))
        let honolulu = MorningRoutine.prompt(now: instant, calendar: calendar("Pacific/Honolulu"))

        XCTAssertTrue(rome.contains("Monday, August 10, 2026"))
        XCTAssertTrue(honolulu.contains("Sunday, August 9, 2026"),
                      "06:30 UTC Monday is still Sunday evening in Hawaii")
        XCTAssertNotEqual(rome, honolulu)
    }

    /// The agent reads English. A phone set to Italian must not start sending
    /// "lunedì, agosto 10, 2026" — that would be a behavior change made by a device
    /// language setting that has nothing to do with what the vault speaks.
    func testANonEnglishDeviceLocaleStillProducesEnglishMonthAndWeekdayNames() {
        var italian = Calendar(identifier: .gregorian)
        italian.timeZone = TimeZone(identifier: "Europe/Rome")!
        italian.locale = Locale(identifier: "it_IT")

        let prompt = MorningRoutine.prompt(now: instant, calendar: italian)
        XCTAssertTrue(prompt.contains("Monday, August 10, 2026"))
        XCTAssertFalse(prompt.contains("lunedì"))
        XCTAssertFalse(prompt.contains("agosto"))
    }

    // MARK: - The default body

    func testTheDefaultBodyAsksForStartOfDayAndTheBriefing() {
        let prompt = MorningRoutine.prompt(now: instant, calendar: calendar("Europe/Rome"))
        XCTAssertTrue(prompt.hasPrefix("Good morning."))
        XCTAssertTrue(prompt.contains("Run the full start of day routine now"))
        for named in ["the scanners", "the inbox", "the calendar", "the currency check"] {
            XCTAssertTrue(prompt.contains(named), "the routine's parts are named: \(named)")
        }
        XCTAssertTrue(prompt.contains("rebuild Today.md and give me the briefing at the end"))
        XCTAssertTrue(prompt.contains("give me the delta rather than a full rerun"),
                      "a second tap in one morning must not redo the whole thing")
    }

    /// THE NEGATIVE CLAUSE. The health and diet new-day refresh is the Health tab
    /// button's job and also runs as a scheduled task. Without this sentence one tap of
    /// Good morning can roll the diet dashboard over a second time in the same morning.
    func testTheDefaultBodyForbidsTheHealthAndDietRefreshByName() {
        let prompt = MorningRoutine.prompt(now: instant, calendar: calendar("Europe/Rome"))
        XCTAssertTrue(prompt.contains(
            "Do not run the health and diet new day refresh: the Health tab button owns that one"))
    }

    /// The default is `false`, asserted by OMITTING the argument. A silent flip of that
    /// default would fold a second diet rollover into every morning tap, and every other
    /// assertion in this file would still pass.
    func testTheDefaultIsToLeaveTheHealthRefreshOut() {
        let implicit = MorningRoutine.prompt(now: instant, calendar: calendar("Europe/Rome"))
        let explicit = MorningRoutine.prompt(now: instant,
                                             calendar: calendar("Europe/Rome"),
                                             includeHealthNewDay: false)
        XCTAssertEqual(implicit, explicit)
        XCTAssertTrue(implicit.contains("Do not run the health and diet new day refresh"))
        XCTAssertFalse(implicit.contains("Two things, in this order"))
    }

    func testTheDefaultBodyDoesNotAskForTheInterimReport() {
        let prompt = MorningRoutine.prompt(now: instant, calendar: calendar("Europe/Rome"))
        XCTAssertFalse(prompt.contains("STILL RUNNING:"),
                       "nothing lands mid-turn when the health refresh is not in the turn")
    }

    // MARK: - The opt-in body

    private func optIn() -> String {
        MorningRoutine.prompt(now: instant,
                              calendar: calendar("Europe/Rome"),
                              includeHealthNewDay: true)
    }

    /// ORDERING IS THE FEATURE. Asserting both halves are present would pass on a body
    /// that ran start of day first and left Jeremy unable to log breakfast for the
    /// twenty minutes the scanners take — which is the entire problem this option
    /// exists to solve. So the assertion is on the INDEX of each half.
    func testTheOptInBodyPutsTheHealthAndDietWorkFirst() {
        let prompt = optIn()
        guard let rollover = prompt.range(of: "roll the diet dashboard over to today"),
              let scanners = prompt.range(of: "the scanners") else {
            return XCTFail("both halves must be present before their order can mean anything")
        }
        XCTAssertTrue(rollover.lowerBound < scanners.lowerBound,
                      "the diet rollover finishes before start of day begins")

        guard let first = prompt.range(of: "FIRST,"), let second = prompt.range(of: "SECOND,") else {
            return XCTFail("the two halves are labelled")
        }
        XCTAssertTrue(first.lowerBound < second.lowerBound)
        XCTAssertTrue(prompt.contains("finished completely before anything else starts"))
    }

    /// The interim line is the other half of the ordering promise: the order only helps
    /// if Jeremy is TOLD the moment the rollover lands, rather than finding out when the
    /// whole turn returns.
    func testTheOptInBodyAsksForTheInterimReportAndSaysWhy() {
        let prompt = optIn()
        XCTAssertTrue(prompt.contains("send one short line beginning STILL RUNNING:"))
        XCTAssertTrue(prompt.contains("I cannot log today's food or exercise until it has landed"))
    }

    func testTheOptInBodyStillAsksForTheWholeStartOfDayRoutine() {
        let prompt = optIn()
        XCTAssertTrue(prompt.contains("SECOND, the full start of day routine"))
        for named in ["the scanners", "the inbox", "the calendar", "the currency check"] {
            XCTAssertTrue(prompt.contains(named))
        }
        XCTAssertTrue(prompt.contains("rebuild Today.md and give me the briefing at the end"))
        XCTAssertTrue(prompt.contains("give me the delta rather than a full rerun"))
    }

    /// The contradiction a copy-and-paste reword would introduce: the default body's
    /// clause forbids exactly the work the opt-in body's first half asks for. It must
    /// not survive into this body, and neither must the equivalent clause in
    /// `HealthNewDay.prompt` — which is why that constant is not concatenated here.
    /// `@MainActor` only because `HealthNewDay.prompt` inherits this target's
    /// `defaultIsolation(MainActor.self)` — the assertion itself is pure string work.
    @MainActor
    func testTheOptInBodyDoesNotAlsoForbidTheHealthRefresh() {
        let prompt = optIn()
        XCTAssertFalse(prompt.contains("Do not run the health and diet new day refresh"))
        XCTAssertFalse(prompt.contains("Do not run start of day"),
                       "HealthNewDay's own scope clause would contradict the second half")
        XCTAssertFalse(prompt.contains(HealthNewDay.prompt),
                       "the opt-in body is its own string, not that constant plus a suffix")
    }

    // MARK: - The confirmation copy

    /// The stamp only ever changes the message. The routine may have run from the other
    /// device or from a scheduled task, so "already ran" is a note and never a lock.
    func testTheMessageChangesOnlyWhenThisDeviceAlreadyFiredToday() {
        let rome = calendar("Europe/Rome")
        let today = MorningRoutine.dayStamp(instant, calendar: rome)
        XCTAssertEqual(today, "2026-08-10")

        XCTAssertEqual(
            MorningRoutine.confirmationMessage(lastFiredDay: nil, now: instant, calendar: rome),
            MorningRoutine.message)
        XCTAssertEqual(
            MorningRoutine.confirmationMessage(lastFiredDay: "2026-08-09", now: instant, calendar: rome),
            MorningRoutine.message,
            "yesterday's stamp is a new day")
        XCTAssertEqual(
            MorningRoutine.confirmationMessage(lastFiredDay: today, now: instant, calendar: rome),
            MorningRoutine.alreadyFiredMessage)
    }

    /// The stamp is local too, for the same reason the prompt's date is: a device west
    /// of the line that fired the routine on its own Sunday evening has not fired it on
    /// the Monday the other device is looking at.
    func testTheDayStampIsLocalToTheCalendarsTimeZone() {
        XCTAssertEqual(MorningRoutine.dayStamp(instant, calendar: calendar("Europe/Rome")),
                       "2026-08-10")
        XCTAssertEqual(MorningRoutine.dayStamp(instant, calendar: calendar("Pacific/Honolulu")),
                       "2026-08-09")
    }
}
