import XCTest
@testable import JesseNetworking

// `GET /jesse/today/items/{id}/detail`, decoded.
//
// The three `today-detail-*.json` fixtures are the BRIDGE'S OWN OUTPUT, captured from
// the real route over a synthetic vault: one item linking a note that exists, one
// linking nothing, and one whose link points OUT of the vault (which the bridge's
// sandbox refuses, and which therefore comes back as `unresolved-target` rather than as
// the file it aimed at). Invented content throughout.
//
// Everything interesting about this endpoint is the status contract, and all of it goes
// through `JesseBridgeClient.detailResult(status:data:etagHeader:)` — so these drive
// that directly rather than standing up a URL-protocol stub to reach it.

final class TodayDetailWireTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: "json"),
                                "fixture \(name).json is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private func result(_ name: String, status: Int = 200,
                        etagHeader: String? = nil) throws -> TodayDetailResult {
        try JesseBridgeClient.detailResult(status: status, data: try fixture(name),
                                           etagHeader: etagHeader)
    }

    // MARK: - The note

    func testAResolvedNoteDecodes() throws {
        guard case .detail(let note) = try result("today-detail-ok") else {
            return XCTFail("expected a note")
        }
        XCTAssertEqual(note.path, "Projects/Demo/Widget.md")
        XCTAssertEqual(note.target, "todo-list/Projects/Demo/Widget")
        XCTAssertEqual(note.fileName, "Widget.md")
        XCTAssertTrue(note.markdown.contains("Everything you need to know"))
        XCTAssertFalse(note.truncated)
        XCTAssertEqual(note.id.count, 12, "keyed by the item's id, not by a path")
        let etag = try XCTUnwrap(note.etag)
        XCTAssertTrue(etag.hasPrefix("\""), "a strong ETag is quoted: \(etag)")
    }

    /// The path on the wire is VAULT-RELATIVE. The bridge's own location is not the
    /// app's business, and a UI that showed an absolute path would be publishing it to
    /// anyone looking over a shoulder.
    func testThePathIsRelativeAndNeverAbsolute() throws {
        let note = try XCTUnwrap(try result("today-detail-ok").note)
        XCTAssertFalse(note.path.hasPrefix("/"), note.path)
        XCTAssertFalse(note.path.contains(".."), note.path)
    }

    // MARK: - No note

    /// An item with no wiki link is an ORDINARY item. The bridge types this rather than
    /// answering `500`, and the client must keep it typed — the moment it becomes an
    /// error, the app renders a failure for a perfectly healthy day file.
    func testAnItemWithNoLinkIsTypedNoDetail() throws {
        guard case .noDetail(let none) = try result("today-detail-no-target") else {
            return XCTFail("expected a typed no-detail")
        }
        XCTAssertEqual(none.reason, .noTarget)
        XCTAssertNotNil(none.etag, "a no-detail answer still tags, so polling it 304s")
    }

    /// A link the vault cannot resolve — a note not written yet, or (as in this fixture)
    /// a target that tried to escape the vault root and was refused.
    func testAnUnresolvableLinkIsTypedNoDetail() throws {
        guard case .noDetail(let none) = try result("today-detail-unresolved") else {
            return XCTFail("expected a typed no-detail")
        }
        XCTAssertEqual(none.reason, .unresolvedTarget)
    }

    /// The two reasons carry different wording because they are different facts about
    /// the vault — and they must not be the same string, or the distinction is decorative.
    func testTheTwoNoDetailReasonsAreDistinguishable() throws {
        let a = try XCTUnwrap({ if case .noDetail(let n) = try result("today-detail-no-target") { return n } else { return nil } }())
        let b = try XCTUnwrap({ if case .noDetail(let n) = try result("today-detail-unresolved") { return n } else { return nil } }())
        XCTAssertNotEqual(a.reason, b.reason)
        XCTAssertNotEqual(a.etag, b.etag, "and they tag differently, so one cannot 304 into the other")
    }

    /// A reason spelling this build has not heard of is still a no-detail answer, not a
    /// decode failure: the reason refines the wording, never the outcome.
    func testAnUnknownNoDetailReasonStillDecodes() throws {
        let body = Data(#"{"id":"abc123abc123","status":"no-detail","reason":"embargoed","etag":"\"x\""}"#.utf8)
        guard case .noDetail(let none) = try JesseBridgeClient.detailResult(
            status: 200, data: body, etagHeader: nil) else {
            return XCTFail("expected a typed no-detail")
        }
        XCTAssertEqual(none.reason, .unknown)
    }

    // MARK: - The status contract

    /// `304` is the common answer when a note is re-opened, and it carries no body at
    /// all — so the tag comes off the header.
    func testNotModifiedCarriesTheHeaderTag() throws {
        let result = try JesseBridgeClient.detailResult(status: 304, data: Data(),
                                                        etagHeader: "\"abc\"")
        XCTAssertEqual(result, .notModified(etag: "\"abc\""))
        XCTAssertEqual(result.etag, "\"abc\"")
        XCTAssertNil(result.note)
    }

    /// `410`, not `404`: the client had this id from a snapshot, so the honest answer is
    /// that the ITEM is gone, not that the URL is wrong. A client that retried the URL
    /// would be retrying forever.
    func testGoneIsItsOwnOutcome() throws {
        XCTAssertEqual(try JesseBridgeClient.detailResult(status: 410,
                                                          data: Data("no such item".utf8),
                                                          etagHeader: nil),
                       .itemGone)
    }

    /// Everything else throws — a `500` or a `401` is a real failure and must not be
    /// laundered into "this item has no note".
    func testRealFailuresThrow() {
        for status in [401, 429, 500, 503] {
            XCTAssertThrowsError(try JesseBridgeClient.detailResult(
                status: status, data: Data("nope".utf8), etagHeader: nil), "status \(status)")
        }
        XCTAssertThrowsError(try JesseBridgeClient.detailResult(
            status: 200, data: Data("this is not json".utf8), etagHeader: nil))
    }

    /// The body's own ETag wins; the header is the fallback for a proxy that rewrote the
    /// framing but not the content. Same rule the snapshot decode already follows.
    func testTheBodyTagWinsAndTheHeaderIsTheFallback() throws {
        let withTag = try XCTUnwrap(try result("today-detail-ok", etagHeader: "\"header\"").note)
        XCTAssertNotEqual(withTag.etag, "\"header\"")

        let untagged = Data(#"{"id":"abc123abc123","status":"ok","path":"A.md","markdown":"x"}"#.utf8)
        let fallback = try XCTUnwrap(try JesseBridgeClient.detailResult(
            status: 200, data: untagged, etagHeader: "\"header\"").note)
        XCTAssertEqual(fallback.etag, "\"header\"")
    }
}
