import XCTest
@testable import JesseNetworking

// What the client puts ON THE WIRE for the three mutations. These are pure
// encode/format assertions with no server: the bridge REJECTS a malformed `at`
// with a `400` rather than substituting its own clock (the stamp records when the
// USER tapped, and a silently-substituted server time would be a quiet lie in the
// vault), so getting these spellings right is a correctness requirement, not a
// formatting preference.

final class TodayRequestShapeTests: XCTestCase {

    private let instant = Date(timeIntervalSince1970: 1_772_530_200)  // 2026-03-03T09:30:00Z

    /// `stamp_from_iso` wants `YYYY-MM-DDTHH:MM…` and parses the first 16 characters.
    /// Fractional seconds and a local offset are what a naive formatter emits; neither
    /// is what this sends.
    func testCheckAndMoveSendAnISO8601InstantInUTC() {
        let iso = JesseBridgeClient.isoInstant(instant)
        XCTAssertEqual(iso, "2026-03-03T09:30:00Z")
        XCTAssertEqual(iso.prefix(16), "2026-03-03T09:30")
        XCTAssertFalse(iso.contains("."), "no fractional seconds")
    }

    /// Glance takes unix MILLISECONDS, not the ISO instant — the glance store
    /// resolves concurrent marks last-writer-wins on that number.
    func testGlanceSendsUnixMilliseconds() {
        XCTAssertEqual(JesseBridgeClient.unixMillis(instant), 1_772_530_200_000)
        XCTAssertEqual(JesseBridgeClient.unixMillis(Date(timeIntervalSince1970: 0)), 0)
    }

    func testCheckBodyOmitsEvidenceWhenThereIsNone() throws {
        let bare = try body(TodayCheckBody(checked: true, evidence: nil,
                                           at: JesseBridgeClient.isoInstant(instant)))
        XCTAssertEqual(bare, #"{"at":"2026-03-03T09:30:00Z","checked":true}"#,
                       "an absent evidence field is what makes a bare check write no sub-line")

        let noted = try body(TodayCheckBody(checked: true, evidence: "sent the date to Ada",
                                            at: JesseBridgeClient.isoInstant(instant)))
        XCTAssertTrue(noted.contains(#""evidence":"sent the date to Ada""#))
    }

    func testMoveBodyCarriesTheWireSpelling() throws {
        let op = TodayMoveOp.toDoNow
        let encoded = try body(TodayMoveBody(op: op.wireOp, section: op.destinationSection,
                                             at: JesseBridgeClient.isoInstant(instant)))
        XCTAssertEqual(encoded, #"{"at":"2026-03-03T09:30:00Z","op":"to_do_now"}"#,
                       "the section field is OMITTED for every op that names no destination")
    }

    /// The one op that carries a destination, and the exact name it carries: the
    /// bridge matches the heading verbatim, so a client that trimmed or prettified it
    /// would get a `404` for a section that is plainly there.
    func testToSectionCarriesTheHeadingVerbatim() throws {
        let op = TodayMoveOp.toSection("Do Now (carried, owed replies and decisions)")
        let encoded = try body(TodayMoveBody(op: op.wireOp, section: op.destinationSection,
                                             at: JesseBridgeClient.isoInstant(instant)))
        XCTAssertEqual(
            encoded,
            #"{"at":"2026-03-03T09:30:00Z","op":"to_section","section":"Do Now (carried, owed replies and decisions)"}"#)
    }

    /// Milliseconds, like a glance and unlike the two file mutations: nothing about a
    /// postponement reaches the vault, so the number is a clock the defer store
    /// resolves races with, not a stamp anyone reads in the day file.
    func testDeferBodyCarriesTheFlagAndMillis() throws {
        let encoded = try body(TodayDeferBody(deferred: true,
                                              atMs: JesseBridgeClient.unixMillis(instant)))
        XCTAssertEqual(encoded, #"{"atMs":1772530200000,"deferred":true}"#)
    }

    func testGlanceBodyCarriesIdAndMillis() throws {
        let encoded = try body(TodayGlanceBody(id: "8dd0678d544b",
                                               glancedAt: JesseBridgeClient.unixMillis(instant)))
        XCTAssertEqual(encoded, #"{"glancedAt":1772530200000,"id":"8dd0678d544b"}"#)
    }

    /// Ids are hex plus an optional ordinal suffix, so escaping never changes one.
    /// It is here so a malformed id out of a stale cache produces a `404` rather than
    /// a path that addresses a different route.
    func testIdPathEscapingLeavesRealIdsAlone() {
        XCTAssertEqual(JesseBridgeClient.pathEscaped("8dd0678d544b"), "8dd0678d544b")
        XCTAssertEqual(JesseBridgeClient.pathEscaped("8dd0678d544b-2"), "8dd0678d544b%2D2")
        XCTAssertEqual(JesseBridgeClient.pathEscaped("../../etc"), "%2E%2E%2F%2E%2E%2Fetc")
    }

    private func body(_ value: some Encodable) throws -> String {
        String(data: try JesseBridgeClient.encodeBody(value), encoding: .utf8) ?? ""
    }
}
