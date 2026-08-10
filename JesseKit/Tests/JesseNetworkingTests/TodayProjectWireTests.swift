import XCTest
@testable import JesseNetworking

// The project slug, decoded.
//
// `today-projects.json` is the BRIDGE'S OWN OUTPUT over `bridge/tests/fixtures/today/
// projects.md` — the fixture the bridge's own derivation tests run against — served
// through the real route with two synthetic `Dashboard/<Topic>.md` pages on disk so the
// rollup half of the derivation actually resolves. All six slugs appear in it, which is
// the point: hand-written JSON would only assert that this file agrees with itself.
//
// The content is invented (a demo project, an orphan note). The five topic NAMES are
// real, because they are the frozen wire taxonomy.

final class TodayProjectWireTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: "json"),
                                "fixture \(name).json is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private func projects() throws -> TodaySnapshot {
        try TodaySnapshot.decode(from: fixture("today-projects"))
    }

    private func project(_ snap: TodaySnapshot, _ leadPrefix: String) throws -> TodayProject {
        try XCTUnwrap(snap.allItems.first { $0.lead.hasPrefix(leadPrefix) },
                      "item \(leadPrefix) missing").project
    }

    // MARK: - The five topics and the absence

    /// Every slug the bridge can emit decodes to its case, including the one whose wire
    /// spelling is not its case name.
    func testEverySlugDecodes() throws {
        let snap = try projects()
        XCTAssertEqual(try project(snap, "A Tag1 home link"), .tag1)
        XCTAssertEqual(try project(snap, "A Personal home link"), .personal)
        XCTAssertEqual(try project(snap, "A Network home link"), .network)
        XCTAssertEqual(try project(snap, "A Via-Con-Me home link"), .viaConMe)
        XCTAssertEqual(try project(snap, "A Perseido home link"), .perseido)
        XCTAssertEqual(try project(snap, "No link at all"), .unfiled)
    }

    /// The one hyphenated spelling. A case name of `viaConMe` with a raw value of
    /// `viaConMe` would decode every Via Con Me item as `.unfiled` and nothing would
    /// visibly break — which is exactly why this is asserted rather than assumed.
    func testViaConMeKeepsItsHyphenatedWireSpelling() {
        XCTAssertEqual(TodayProject.viaConMe.rawValue, "via-con-me")
        XCTAssertEqual(TodayProject(rawValue: "via-con-me"), .viaConMe)
        XCTAssertEqual(Set(TodayProject.allCases.map(\.rawValue)),
                       ["tag1", "personal", "network", "via-con-me", "perseido", "unfiled"],
                       "the frozen wire set, exactly as bridge/src/today.rs freezes it")
    }

    /// `unfiled` is common and expected: an item that links nothing, an item whose link
    /// no topic page claims, a URL (which is not a lineage), and an ambiguity the
    /// heading cannot break all land there rather than being guessed at.
    func testUnfiledIsTheHonestAnswerAndNotAnError() throws {
        let snap = try projects()
        for lead in ["No link at all", "A wiki link no topic page claims",
                     "A URL is not a lineage", "A note two topic pages claim",
                     "Two home links with nothing to separate them"] {
            XCTAssertEqual(try project(snap, lead), .unfiled, lead)
        }
        XCTAssertTrue(TodayProject.unfiled.isUnfiled)
        XCTAssertFalse(TodayProject.filed.contains(.unfiled),
                       "a filter bar must not offer the absence of a project as one")
    }

    /// The rollup half of the derivation, end to end: an item that links a project note
    /// rather than a topic home inherits the topic whose Dashboard page claims that
    /// note, and the section heading breaks a two-topic tie only among candidates the
    /// item's own links already declared.
    func testRollupAndHeadingTiebreakArriveOnTheWire() throws {
        let snap = try projects()
        XCTAssertEqual(try project(snap, "A note one topic page claims"), .tag1)
        XCTAssertEqual(try project(snap, "A home link outranks a rollup link"), .network)
        XCTAssertEqual(try project(snap, "A heading tie-break over a two-topic rollup"), .tag1)
        XCTAssertEqual(try project(snap, "A heading never files an item that declared nothing"),
                       .unfiled)
    }

    /// Dashboard order, which is what a project-grouped view sorts by.
    func testDisplayOrderIsDashboardOrderWithUnfiledLast() {
        XCTAssertEqual(TodayProject.allCases.sorted { $0.displayOrder < $1.displayOrder },
                       [.tag1, .personal, .network, .viaConMe, .perseido, .unfiled])
    }

    // MARK: - Degradation

    /// **A slug this build has never heard of is `.unfiled`, never a thrown decode.** A
    /// bridge that grows a sixth topic must not blank the day screen on a phone that has
    /// not been updated yet.
    func testAnUnknownSlugDecodesToUnfiled() throws {
        let snap = try TodaySnapshot.decode(from: Data("""
        {"missing":false,"sections":[{"name":"Do Now","kind":"tasks","items":[
          {"id":"aaaaaaaaaaaa","lead":"From a later bridge","project":"quantum-kiln"},
          {"id":"bbbbbbbbbbbb","lead":"Empty slug","project":""},
          {"id":"cccccccccccc","lead":"Wrong case","project":"Tag1"}
        ],"prose":[],"reports":[],"range":{"start":0,"end":1}}]}
        """.utf8))
        XCTAssertEqual(snap.allItems.map(\.project), [.unfiled, .unfiled, .unfiled])
        XCTAssertEqual(snap.allItems.count, 3, "and the surrounding items still decode")
    }

    /// **An ABSENT `project` key is `.unfiled` too** — which is what every bridge before
    /// 0.72.0 sends, and what a partial payload from a proxy would send.
    func testAnAbsentProjectKeyDecodesToUnfiled() throws {
        let snap = try TodaySnapshot.decode(from: Data("""
        {"missing":false,"sections":[{"name":"Do Now","kind":"tasks","items":[
          {"id":"aaaaaaaaaaaa","lead":"From an older bridge","checked":false}
        ],"prose":[],"reports":[],"range":{"start":0,"end":1}}]}
        """.utf8))
        XCTAssertEqual(snap.allItems.first?.project, .unfiled)
        XCTAssertEqual(snap.allItems.first?.links, [], "and the absent collections too")
        XCTAssertEqual(snap.allItems.first?.sectionName, "")
    }

    /// The whole day carries a slug on every item — there is no "no value" state to
    /// handle in a view.
    func testEveryItemInTheFixtureCarriesASlug() throws {
        let snap = try projects()
        XCTAssertGreaterThan(snap.allItems.count, 15)
        for item in snap.allItems {
            XCTAssertTrue(TodayProject.allCases.contains(item.project), item.lead)
        }
        // …and the same is true of the general day fixture, which is a different
        // document produced by the same serializer.
        let full = try TodaySnapshot.decode(from: fixture("today-full"))
        XCTAssertFalse(full.allItems.isEmpty)
        for item in full.allItems {
            XCTAssertTrue(TodayProject.allCases.contains(item.project), item.lead)
        }
    }
}
