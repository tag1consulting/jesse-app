import XCTest
@testable import JesseNetworking

/// The `brief` object on `GET /jesse/today/items/{id}/detail`, decoded from the bridge's
/// own serializer output over synthetic fixtures.
///
/// Synthetic throughout — invented people, invented companies. The vault these types
/// carry is personal, and none of it belongs in this repository.
final class TodayBriefWireTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: "json"),
                                "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    /// The seven answers arrive in order, with their provenance.
    func testTheSevenAnswersDecodeInTheOrderThePageShowsThem() throws {
        let detail = try JSONDecoder().decode(TodayItemDetail.self,
                                              from: fixture("today-detail-brief"))
        let envelope = try XCTUnwrap(detail.brief)
        XCTAssertEqual(envelope.status, .ok)
        let brief = try XCTUnwrap(envelope.brief)

        XCTAssertEqual(brief.sections.map(\.heading),
                       ["What it is", "Where it came from", "Due", "Priority",
                        "Done so far", "Done means", "Who knows more"])
        XCTAssertTrue(brief.about.text.hasPrefix("Sign the 2024 and 2025"))
        XCTAssertEqual(brief.priorityLevel, .thisWeek)
        XCTAssertEqual(brief.harness, "claude-code")
        XCTAssertEqual(brief.model, "opus")
        XCTAssertEqual(brief.sources, ["Projects/Acme/Filing.md", "Dashboard/Acme.md"])
    }

    /// An answer the notes could not support keeps its sentence AND its `known: false`,
    /// which is what lets the page render it differently instead of hiding it.
    func testAnUnknownAnswerKeepsItsSentenceAndItsFlag() throws {
        let detail = try JSONDecoder().decode(TodayItemDetail.self,
                                              from: fixture("today-detail-brief"))
        let brief = try XCTUnwrap(detail.brief?.brief)
        XCTAssertFalse(brief.due.known)
        XCTAssertEqual(brief.due.text, "No due date is recorded.")
        XCTAssertTrue(brief.about.known)
    }

    /// The note is still there, under the answers.
    func testTheSourceNoteStillDecodesAlongsideTheBrief() throws {
        let detail = try JSONDecoder().decode(TodayItemDetail.self,
                                              from: fixture("today-detail-brief"))
        XCTAssertEqual(detail.path, "Projects/Acme/Filing.md")
        XCTAssertTrue(detail.markdown.contains("The Acme filing note"))
        XCTAssertFalse(detail.truncated)
    }

    /// A bridge that predates the feature sends no `brief` key, and that is not an error
    /// — the page falls back to showing the note exactly as it always did.
    func testABridgeThatSendsNoBriefStillDecodes() throws {
        let json = #"{"id":"abc","status":"ok","path":"N.md","target":"t","markdown":"x"}"#
        let detail = try JSONDecoder().decode(TodayItemDetail.self,
                                              from: Data(json.utf8))
        XCTAssertNil(detail.brief)
        XCTAssertEqual(detail.path, "N.md")
    }

    /// `pending` and `failed` are answers, not absences.
    func testPendingAndFailedDecodeAsStates() throws {
        let pending = #"{"id":"a","status":"ok","brief":{"status":"pending"}}"#
        let p = try JSONDecoder().decode(TodayItemDetail.self, from: Data(pending.utf8))
        XCTAssertEqual(p.brief?.status, .pending)
        XCTAssertNil(p.brief?.brief)

        let failed = #"{"id":"a","status":"ok","brief":{"status":"failed","failure":"the model timed out"}}"#
        let f = try JSONDecoder().decode(TodayItemDetail.self, from: Data(failed.utf8))
        XCTAssertEqual(f.brief?.status, .failed)
        XCTAssertEqual(f.brief?.failure, "the model timed out")
    }

    /// An item with NO note still carries a brief — those are exactly the items a reader
    /// could previously learn nothing about.
    func testAnItemWithNoNoteStillCarriesABrief() throws {
        let json = """
        {"id":"a","status":"no-detail","reason":"no-target",
         "brief":{"status":"ok","brief":{
           "about":{"text":"Book the flights.","known":true},
           "origin":{"text":"A note to self on 2026-09-09.","known":true},
           "due":{"text":"No due date is recorded.","known":false},
           "priority":{"text":"Fares rise closer to the date.","known":true},
           "priorityLevel":"when-time-allows",
           "progress":{"text":"Nothing recorded yet.","known":true},
           "done":{"text":"Flights and hotel are booked.","known":true},
           "contacts":{"text":"Nobody else is recorded.","known":false},
           "relevance":{"verdict":"open","reason":"Nothing shows a booking.","confidence":"low"}}}}
        """
        let none = try JSONDecoder().decode(TodayNoDetail.self, from: Data(json.utf8))
        XCTAssertEqual(none.reason, .noTarget)
        XCTAssertEqual(none.brief?.status, .ok)
        XCTAssertEqual(none.brief?.brief?.about.text, "Book the flights.")
        XCTAssertFalse(try XCTUnwrap(none.brief?.brief?.contacts.known))
    }

    /// A verdict this build has not heard of reads as `open` — the safe direction, since
    /// `open` is the one verdict that draws no marker and offers no button.
    func testAnUnknownVerdictReadsAsTheSafeDefault() throws {
        let json = #"{"verdict":"invented","reason":"r","confidence":"medium"}"#
        let relevance = try JSONDecoder().decode(TodayBriefRelevance.self,
                                                 from: Data(json.utf8))
        XCTAssertEqual(relevance.verdict, .unknown)
        XCTAssertEqual(relevance.confidence, .unknown)
    }
}
