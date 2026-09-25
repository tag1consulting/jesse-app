import XCTest
@testable import JesseNetworking

/// THE STRAND CONTRACT, decoded from the bridge's own spelling.
///
/// The fixture below is `bridge/src/strands.rs`'s serialization verbatim, and the two
/// things worth asserting about it are the two that would break silently: the wire is
/// SNAKE CASE (`global_findings`, `waits_on`, `generated_at`) while the day file's is
/// camel, and every may-be-absent field has to survive both a `null` and an outright
/// missing key, because a bridge that predates a field and one that grows a field must
/// both decode rather than blank the board.
final class StrandsWireDecodeTests: XCTestCase {

    /// A full board: two strands, one of everything.
    private let fullBoard = """
    {
      "generated_at": "2026-09-24T09:40:00+02:00",
      "strands": [
        {
          "slug": "Argus",
          "title": "Argus",
          "group": "personal",
          "state": "active",
          "updated": "2026-09-23",
          "repos": ["jeremyandrews/argus"],
          "now": "One or two sentences.",
          "waiting": { "text": "you: create the empty repository", "jeremy": true },
          "next": {
            "id": "A1d",
            "text": "Guest budget probe on the fixed kernel.",
            "link": "todo-list/Projects/drafts/2026-09-23-1248-Trovato-Argus-Guest-Budget-A1d",
            "waits_on": "provider key"
          },
          "counts": { "queue": 2, "later": 1, "running": 1, "done": 2 },
          "findings": [
            { "code": "RUNNING-SILENT", "message": "B8 launched 2026-09-19, no outcome after 4 days", "line": 17 }
          ]
        },
        {
          "slug": "Strands-System",
          "title": "Strands System",
          "group": "tag1",
          "state": "dormant",
          "updated": "2026-09-22",
          "repos": [],
          "now": null,
          "waiting": null,
          "next": null,
          "counts": { "queue": 0, "later": 0, "running": 0, "done": 0 },
          "findings": []
        }
      ],
      "global_findings": [ { "code": "UNOWNED-PROMPT", "message": "a draft nothing links" } ],
      "counts": { "active": 14, "waiting": 1, "dormant": 2 }
    }
    """

    func testDecodesTheWholeContract() throws {
        let snap = try StrandsSnapshot.decode(from: Data(fullBoard.utf8))

        XCTAssertEqual(snap.generatedAt, "2026-09-24T09:40:00+02:00")
        XCTAssertEqual(snap.counts, StrandsCounts(active: 14, waiting: 1, dormant: 2))
        XCTAssertEqual(snap.strands.count, 2)

        let argus = try XCTUnwrap(snap.strand(slug: "Argus"))
        XCTAssertEqual(argus.title, "Argus")
        XCTAssertEqual(argus.group, .personal)
        XCTAssertEqual(argus.state, .active)
        XCTAssertEqual(argus.updated, "2026-09-23")
        XCTAssertEqual(argus.repos, ["jeremyandrews/argus"])
        XCTAssertEqual(argus.now, "One or two sentences.")
        XCTAssertEqual(argus.waiting?.text, "you: create the empty repository")
        XCTAssertTrue(argus.isWaitingOnYou)
        XCTAssertEqual(argus.counts, StrandCounts(queue: 2, later: 1, running: 1, done: 2))

        // `waits_on`, not `waitsOn`: the strand structs carry no `rename_all`, so the
        // wire is Rust's own field name. Getting this wrong loses the gate silently.
        XCTAssertEqual(argus.next?.id, "A1d")
        XCTAssertEqual(argus.next?.waitsOn, "provider key")
        XCTAssertEqual(argus.next?.link,
                       "todo-list/Projects/drafts/2026-09-23-1248-Trovato-Argus-Guest-Budget-A1d")

        XCTAssertEqual(argus.findings.count, 1)
        XCTAssertEqual(argus.findings.first?.code, "RUNNING-SILENT")
        XCTAssertEqual(argus.findings.first?.line, 17)

        // `global_findings`, likewise.
        XCTAssertEqual(snap.globalFindings.count, 1)
        XCTAssertEqual(snap.globalFindings.first?.code, "UNOWNED-PROMPT")
        XCTAssertNil(snap.globalFindings.first?.line,
                     "a global finding is about a file that is not a note, so it has no line")
    }

    /// Every optional as an explicit `null` — which is what the bridge sends, since none
    /// of the three carries `skip_serializing_if`.
    /// `parent`: a slug, a `null` (top level on a bridge that serves the key), or no key
    /// at all (a bridge that predates it). The last two both decode to nil, and only the
    /// last hides the `Tree` lens, so the decode keeps them apart.
    func testParentDecodesAsASlugANullOrAnAbsence() throws {
        let board = """
        { "strands": [
            { "slug": "Strands-System", "parent": "Jesse" },
            { "slug": "Tag1", "parent": null }
        ] }
        """
        let snap = try StrandsSnapshot.decode(from: Data(board.utf8))
        let child = try XCTUnwrap(snap.strand(slug: "Strands-System"))
        XCTAssertEqual(child.parent, "Jesse")
        XCTAssertTrue(child.servesParent)
        let top = try XCTUnwrap(snap.strand(slug: "Tag1"))
        XCTAssertNil(top.parent)
        XCTAssertTrue(top.servesParent, "an explicit null is a top level strand")
        XCTAssertTrue(snap.servesParents)

        let older = try StrandsSnapshot.decode(from: Data(fullBoard.utf8))
        XCTAssertTrue(older.strands.allSatisfy { $0.parent == nil && !$0.servesParent },
                      "a bridge with no parent key decodes, every parent nil")
        XCTAssertFalse(older.servesParents)
        XCTAssertFalse(StrandsSnapshot().servesParents, "an empty board has no tree")
    }

    func testExplicitNullsAreAbsences() throws {
        let snap = try StrandsSnapshot.decode(from: Data(fullBoard.utf8))
        let system = try XCTUnwrap(snap.strand(slug: "Strands-System"))
        XCTAssertNil(system.now)
        XCTAssertNil(system.waiting)
        XCTAssertNil(system.next)
        XCTAssertFalse(system.isWaitingOnYou)
        XCTAssertEqual(system.state, .dormant)
        XCTAssertTrue(system.repos.isEmpty)
    }

    /// A bridge that has not been taught a field, and one that has grown one. Both
    /// decode: the first because every field but `slug` has a fallback, the second
    /// because Swift's synthesized container ignores keys it does not know.
    func testTolerantOfMissingAndUnknownKeys() throws {
        let json = """
        { "strands": [ { "slug": "Bare", "sixth_field": 12 } ] }
        """
        let snap = try StrandsSnapshot.decode(from: Data(json.utf8))
        let bare = try XCTUnwrap(snap.strands.first)
        XCTAssertEqual(bare.slug, "Bare")
        XCTAssertEqual(bare.title, "Bare", "a note with no title is named by its file")
        XCTAssertEqual(bare.group, .unfiled)
        XCTAssertEqual(bare.state, .active)
        XCTAssertEqual(bare.counts, StrandCounts())
        XCTAssertTrue(bare.findings.isEmpty)
        XCTAssertEqual(snap.counts, StrandsCounts())
        XCTAssertNil(snap.generatedAt)
    }

    /// A SIXTH GROUP, and a fourth state. Neither is a decode failure: a bridge that
    /// grows a Dashboard topic must not blank a board on a phone that has not been
    /// updated, and a state this build has never heard of must leave the row visible
    /// rather than file it under a collapsed heading.
    func testUnknownGroupAndStateDegradeRatherThanThrow() throws {
        let json = """
        { "strands": [
            { "slug": "Sixth", "group": "atlantis", "state": "hibernating", "updated": "2026-09-24" }
        ] }
        """
        let snap = try StrandsSnapshot.decode(from: Data(json.utf8))
        let sixth = try XCTUnwrap(snap.strands.first)
        XCTAssertEqual(sixth.group, .unfiled)
        XCTAssertEqual(sixth.state, .active)
        XCTAssertFalse(sixth.state.isDormant)
    }

    /// A strand with no `slug` is not a strand: it cannot be addressed, opened or keyed.
    func testASluglessStrandIsADecodeFailure() {
        let json = #"{ "strands": [ { "title": "No slug" } ] }"#
        XCTAssertThrowsError(try StrandsSnapshot.decode(from: Data(json.utf8)))
    }

    /// The note path the reader opens, composed once.
    func testNotePathIsTheStrandsFolder() {
        XCTAssertEqual(Strand(slug: "Strands-System").notePath, "Strands/Strands-System.md")
    }

    /// The detail route: markdown beside the same parsed object.
    func testDetailDecodes() throws {
        let json = """
        { "markdown": "# Strands System\\n\\n**Now:** up", "strand": { "slug": "Strands-System" } }
        """
        let detail = try StrandDetail.decode(from: Data(json.utf8))
        XCTAssertTrue(detail.markdown.hasPrefix("# Strands System"))
        XCTAssertEqual(detail.strand?.slug, "Strands-System")
    }

    /// The board has a cache key of its own, and it is a legal file name.
    func testCacheKeyIsValid() {
        XCTAssertTrue(SnapshotCache.isValidKey(SnapshotCacheKey.strands))
        XCTAssertNotEqual(SnapshotCacheKey.strands, SnapshotCacheKey.today)
    }
}
