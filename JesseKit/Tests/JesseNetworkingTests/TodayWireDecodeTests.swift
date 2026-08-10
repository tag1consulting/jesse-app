import XCTest
@testable import JesseNetworking

// Decoding `GET /jesse/today` and its mutation responses.
//
// The fixtures are the BRIDGE'S OWN OUTPUT: `bridge/src/today.rs`'s serializer run
// over `bridge/tests/fixtures/today/full.md`, captured verbatim. That is what makes
// these tests worth having — hand-written JSON would only assert that this file
// agrees with itself, whereas these fail the moment the bridge's key names, its
// camelCase mapping, its null-vs-absent choices, or its id contract move.
//
// The fixture content is synthetic by construction (an invented kiln rebuild), which
// matters because this repo is public: no line of the real personal Today.md is in
// it, and regenerating it means re-running the bridge parser over the same synthetic
// markdown rather than over a live vault.

final class TodayWireDecodeTests: XCTestCase {

    // MARK: - Fixtures

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: "json"),
                                "fixture \(name).json is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private func snapshot(_ name: String) throws -> TodaySnapshot {
        try TodaySnapshot.decode(from: fixture(name))
    }

    private func section(_ snap: TodaySnapshot, _ name: String) throws -> TodaySection {
        try XCTUnwrap(snap.sections.first { $0.name == name }, "section \(name) missing")
    }

    private func item(_ sec: TodaySection, _ leadPrefix: String) throws -> TodayItem {
        try XCTUnwrap(sec.items.first { $0.lead.hasPrefix(leadPrefix) },
                      "item \(leadPrefix) missing from \(sec.name)")
    }

    // MARK: - The document

    func testHeaderFieldsDecode() throws {
        let snap = try snapshot("today-full")
        XCTAssertEqual(snap.title, "Today: Tuesday, March 3, 2026")
        XCTAssertEqual(snap.date, "2026-03-03")
        XCTAssertFalse(snap.missing)
        XCTAssertEqual(snap.generatedAt, "2026-03-03T09:00:00Z")
        XCTAssertNotNil(snap.etag)
        // `pending` is added only by a MUTATION response, so a plain GET has none.
        XCTAssertNil(snap.pending)
        XCTAssertTrue(try XCTUnwrap(snap.narrative).contains("it is a short day"))
    }

    func testSectionsDecodeInFileOrderWithTheirRenderingKind() throws {
        let snap = try snapshot("today-full")
        XCTAssertEqual(snap.sections.map(\.name),
                       ["Schedule", "Do Now", "Errands", "Health", "Currency",
                        "Still open (aging)", "Reminders (Mar 3 to Mar 10)", "Done Today"])
        XCTAssertEqual(snap.sections.map(\.kind),
                       ["schedule", "tasks", "tasks", "briefing", "briefing",
                        "briefing", "briefing", "tasks"])
    }

    /// A briefing section still yields its task lines — `kind` is a rendering hint,
    /// never a parse mode. A client that skipped items in briefing sections would
    /// silently drop real work.
    func testTaskLinesDecodeEvenInsideBriefingSections() throws {
        let snap = try snapshot("today-full")
        XCTAssertEqual(try section(snap, "Do Now").items.count, 4)
        XCTAssertEqual(try section(snap, "Errands").items.count, 2)
        XCTAssertEqual(try section(snap, "Health").items.count, 1)
        XCTAssertEqual(try section(snap, "Health").kind, "briefing")
    }

    func testLeadItemDecodesWithAnEmptySectionName() throws {
        let snap = try snapshot("today-full")
        XCTAssertEqual(snap.leadItems.count, 1)
        let standing = try XCTUnwrap(snap.leadItems.first)
        XCTAssertTrue(standing.lead.hasPrefix("TOP PRIORITY"))
        XCTAssertEqual(standing.sectionName, "")
        XCTAssertTrue(standing.isLeadItem, "an empty sectionName IS the lead block")
        XCTAssertEqual(standing.addedDate, "2026-01-04")
        XCTAssertTrue(standing.text.contains("Standing lead item"),
                      "the raw text carries the continuation block")
    }

    func testItemFieldsDecode() throws {
        let snap = try snapshot("today-full")
        let it = try item(section(snap, "Do Now"), "Order the replacement thermocouple")
        XCTAssertFalse(it.checked)
        XCTAssertEqual(it.lead, "Order the replacement thermocouple.")
        XCTAssertEqual(it.addedDate, "2026-03-01")
        XCTAssertEqual(it.updatedDate, "2026-03-03")
        XCTAssertEqual(it.sectionName, "Do Now")
        XCTAssertNil(it.appCompleted, "an explicit JSON null decodes to nil, not a crash")
        XCTAssertTrue(it.text.hasPrefix("* [ ] **Order the replacement"))
    }

    func testAppCompletedSubLineDecodes() throws {
        let snap = try snapshot("today-full")
        let done = try item(section(snap, "Errands"), "Collect the glaze order")
        XCTAssertTrue(done.checked)
        let app = try XCTUnwrap(done.appCompleted)
        XCTAssertEqual(app.at, "2026-03-03T08:12:00Z")
        XCTAssertEqual(app.evidence, "checked off on the phone")
    }

    func testLinksDecodeWithTheirKindAndChipLabel() throws {
        let snap = try snapshot("today-full")
        let it = try item(section(snap, "Do Now"), "Reply to Ada")
        XCTAssertEqual(it.links, [
            TodayLink(target: "https://example.invalid/kiln/schedule", kind: "url"),
            TodayLink(target: "notes/Dashboard/Workshop", kind: "wiki"),
        ])
        XCTAssertEqual(it.links[0].chipLabel, "example.invalid", "a URL chip shows its host")
        XCTAssertEqual(it.links[1].chipLabel, "Workshop", "a wiki chip shows its leaf")
        XCTAssertFalse(it.links[0].isWiki)
        XCTAssertTrue(it.links[1].isWiki)
    }

    func testReportRowsDecodeWithKindAndSeenState() throws {
        let snap = try snapshot("today-full")
        let health = try section(snap, "Health")
        let run = try XCTUnwrap(health.reports.first { $0.title.contains("run day") })
        XCTAssertEqual(run.kind, "health")
        XCTAssertFalse(run.seen, "with no glance store every row is unseen")
        XCTAssertEqual(run.seenMs, 0)
        XCTAssertEqual(try section(snap, "Currency").reports.first?.kind, "currency")
        // Reports are a briefing-section idea: a tasks section never has any.
        XCTAssertTrue(try section(snap, "Do Now").reports.isEmpty)
    }

    func testProseIsCarriedPerSection() throws {
        let snap = try snapshot("today-full")
        XCTAssertTrue(try section(snap, "Health").prose
            .contains { $0.text.hasPrefix("Plain prose with no bold") })
        XCTAssertEqual(try section(snap, "Schedule").prose.count, 2,
                       "a schedule's bullets are prose, not report rows")
    }

    func testCountsDecode() throws {
        let snap = try snapshot("today-full")
        XCTAssertEqual(snap.counts.done, 3)
        XCTAssertEqual(snap.counts.open + snap.counts.done, snap.allItems.count)
        XCTAssertEqual(snap.counts.reportsUnseen, snap.allReports.count)
    }

    func testSourceRangesDecode() throws {
        let snap = try snapshot("today-full")
        let it = try item(section(snap, "Do Now"), "Reply to Ada")
        XCTAssertGreaterThan(it.range.end, it.range.start)
    }

    // MARK: - The id contract

    /// Every id is 12 hex characters (plus an optional `-N` ordinal for a duplicated
    /// lead), and unique within one parse. Both halves matter: the width is what the
    /// bridge documents, and the uniqueness is what lets the client key state by id
    /// at all.
    func testIdsAreTwelveHexAndUniqueWithinAParse() throws {
        let snap = try snapshot("today-full")
        let ids = snap.allItems.map(\.id) + snap.allReports.map(\.id)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique within one parse")
        for id in ids {
            let base = id.split(separator: "-").first.map(String.init) ?? id
            XCTAssertEqual(base.count, 12, "\(id) is not 12 hex characters")
            XCTAssertTrue(base.allSatisfy(\.isHexDigit), "\(id) is not hex")
        }
    }

    /// **The re-key hazard, straight from the bridge.** `today-moved.json` is the same
    /// document after a `to_do_now` move of one item, produced by the bridge's own
    /// splice. The item's lead and Added date are byte-identical across the two
    /// snapshots; its ID IS NOT, because the id hashes the section name and the
    /// section changed. Any client that assumed an id survives a move would strand
    /// every piece of state it held.
    func testACrossSectionMoveChangesTheItemsId() throws {
        let before = try snapshot("today-full")
        let after = try snapshot("today-moved")

        let from = try item(section(before, "Errands"), "Collect the glaze order")
        let to = try item(section(after, "Do Now"), "Collect the glaze order")

        XCTAssertEqual(from.lead, to.lead, "the words did not change")
        XCTAssertEqual(from.addedDate, to.addedDate, "nor the Added date")
        XCTAssertNotEqual(from.id, to.id, "but the id did — it hashes the section name")
        XCTAssertEqual(from.sectionName, "Errands")
        XCTAssertEqual(to.sectionName, "Do Now")
        // And it is gone from where it was, so there is exactly one of it.
        XCTAssertEqual(after.allItems.filter { $0.lead == from.lead }.count, 1)
        XCTAssertNil(after.item(id: from.id))
    }

    /// A mutation response carries `pending`, and a fresh etag the next mutation must
    /// send back.
    func testAMutationResponseCarriesPendingAndAFreshEtag() throws {
        let before = try snapshot("today-full")
        let after = try snapshot("today-moved")
        XCTAssertEqual(after.pending, false)
        XCTAssertNotNil(after.etag)
        XCTAssertNotEqual(after.etag, before.etag,
                          "the document changed, so the strong etag must have too")
    }

    // MARK: - Degradation

    /// An empty day file: `200` with `missing: true`, which the client renders as an
    /// empty day rather than an error. Before the morning routine has run there is
    /// legitimately no file.
    func testAMissingDayFileDecodesAsAnEmptySnapshot() throws {
        let snap = try TodaySnapshot.decode(from: Data("""
        {"title":null,"date":null,"narrative":null,"leadItems":[],"sections":[],
         "counts":{"open":0,"done":0,"reportsUnseen":0},"missing":true,
         "generatedAt":"2026-03-03T09:00:00Z","etag":"\\"abc\\""}
        """.utf8))
        XCTAssertTrue(snap.missing)
        XCTAssertTrue(snap.allItems.isEmpty)
        XCTAssertNil(snap.title)
    }

    /// A bridge that stops sending a collection, or one that grows a field we do not
    /// model, must BOTH decode. The screen degrades; it never fails to draw.
    func testDecodeToleratesAbsentCollectionsAndUnknownFields() throws {
        let snap = try TodaySnapshot.decode(from: Data("""
        {"title":"Today","missing":false,"somethingNewFromALaterBridge":{"a":1}}
        """.utf8))
        XCTAssertEqual(snap.title, "Today")
        XCTAssertTrue(snap.leadItems.isEmpty)
        XCTAssertTrue(snap.sections.isEmpty)
        XCTAssertEqual(snap.counts, TodayCounts())
    }

    // MARK: - The op spellings

    /// The four wire spellings, exactly as `MoveOp::parse` reads them. A typo here is
    /// a `400` from the bridge naming the four valid ops.
    func testMoveOpWireSpellings() {
        XCTAssertEqual(TodayMoveOp.topOfSection.rawValue, "top_of_section")
        XCTAssertEqual(TodayMoveOp.toDoNow.rawValue, "to_do_now")
        XCTAssertEqual(TodayMoveOp.up.rawValue, "up")
        XCTAssertEqual(TodayMoveOp.down.rawValue, "down")
        XCTAssertEqual(TodayMoveOp.allCases.filter(\.crossesSections), [.toDoNow],
                       "to_do_now is the ONLY op that can change an item's id")
    }
}
