import XCTest
@testable import JesseOps

// Grouping a flat job list into chains.
//
// The bridge sends jobs in config order with each link naming its predecessor; the screen
// shows chains. The interesting cases are all config mistakes a person can make, and the
// requirement they share is that NO JOB IS EVER LOST: an entry that cannot be placed under a
// head is still shown, because "where did that job go" is a worse question than "why is that
// job on its own".

final class ScheduleChainTests: XCTestCase {

    /// Build a row with only what grouping reads. Everything else is noise here.
    private func row(_ id: String, after: String? = nil) throws -> ScheduleRow {
        let json = after.map {
            #"{"id":"\#(id)","enabled":true,"kind":"link","after":"\#($0)"}"#
        } ?? #"{"id":"\#(id)","enabled":true,"kind":"head","after":null}"#
        return try JSONDecoder().decode(ScheduleRow.self, from: Data(json.utf8))
    }

    func testAHeadAndItsLinksComeBackInFireOrderWithIncreasingDepth() throws {
        let jobs = [try row("overnight"),
                    try row("diet", after: "overnight"),
                    try row("titles", after: "diet")]
        let chains = ScheduleChain.group(jobs)

        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains[0].id, "overnight")
        XCTAssertEqual(chains[0].members.map(\.id), ["overnight", "diet", "titles"])
        XCTAssertEqual(chains[0].members.map(\.depth), [0, 1, 2],
                       "depth is the indent, and it is the position in the chain")
    }

    /// Heads keep CONFIG ORDER, which is the order the day happens in. Sorting by clock would
    /// look right until somebody moved a job across midnight.
    func testHeadsKeepConfigOrder() throws {
        let jobs = [try row("evening"), try row("morning"), try row("noon")]
        XCTAssertEqual(ScheduleChain.group(jobs).map(\.id), ["evening", "morning", "noon"])
    }

    /// A link whose `after` names nothing in the list — a typo, or an entry that failed
    /// validation and is in `invalid` instead. It is shown on its own, at the bottom.
    func testAnOrphanedLinkIsShownRatherThanDropped() throws {
        let jobs = [try row("overnight"), try row("stray", after: "does-not-exist")]
        let chains = ScheduleChain.group(jobs)

        XCTAssertEqual(chains.map(\.id), ["overnight", "stray"])
        XCTAssertEqual(chains[1].members.map(\.depth), [0],
                       "an orphan has no head to be indented under, so it is not indented")
    }

    /// Two links hanging off the same predecessor. Both are placed, in list order — the bridge
    /// permits the shape and the screen must not silently show one of them.
    func testTwoLinksOffOnePredecessorAreBothPlaced() throws {
        let jobs = [try row("head"),
                    try row("first", after: "head"),
                    try row("second", after: "head")]
        let chains = ScheduleChain.group(jobs)

        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains[0].members.map(\.id), ["head", "first", "second"])
        XCTAssertEqual(chains[0].members.map(\.depth), [0, 1, 1])
    }

    /// A cycle. The walk must terminate, and every member must still appear exactly once.
    func testACycleTerminatesAndStillShowsEveryJob() throws {
        let jobs = [try row("a", after: "b"), try row("b", after: "a")]
        let chains = ScheduleChain.group(jobs)

        let shown = chains.flatMap { $0.members.map(\.id) }
        XCTAssertEqual(shown.sorted(), ["a", "b"])
        XCTAssertEqual(shown.count, 2, "each job appears exactly once, cycle or not")
    }

    /// A link that names itself is the degenerate cycle, and it must not recurse.
    func testASelfReferencingLinkIsPlacedOnce() throws {
        let chains = ScheduleChain.group([try row("loop", after: "loop")])
        XCTAssertEqual(chains.flatMap { $0.members.map(\.id) }, ["loop"])
    }

    /// A row whose `kind` is missing falls back to "has no `after`" — which is what `kind`
    /// means, and a row is not worth losing to an absent string.
    func testKindFallsBackToTheAbsenceOfAfter() throws {
        let head = try JSONDecoder().decode(
            ScheduleRow.self, from: Data(#"{"id":"h","enabled":true,"kind":""}"#.utf8))
        let link = try JSONDecoder().decode(
            ScheduleRow.self, from: Data(#"{"id":"l","enabled":true,"kind":"","after":"h"}"#.utf8))

        XCTAssertTrue(head.isHead)
        XCTAssertFalse(link.isHead)
        XCTAssertEqual(ScheduleChain.group([head, link]).first?.members.map(\.id), ["h", "l"])
    }

    /// The whole document's convenience path, over the same fixture the decode tests use: four
    /// jobs, three chains (two heads and one orphan).
    func testTheDocumentExposesItsChains() throws {
        let doc = try ScheduleDocument.decode(Data(OpsDocumentDecodeTests.schedule.utf8))
        XCTAssertEqual(doc.chains.map(\.id), ["overnight", "weekly", "orphan"])
        XCTAssertEqual(doc.chains[0].members.map(\.id), ["overnight", "diet-extract"])
    }
}
