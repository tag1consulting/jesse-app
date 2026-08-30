import XCTest
@testable import JesseOps

// The release-summaries block of `GET /sentinel/deploy/status`, and the one property of it
// that is not about content at all: THE CARD MUST STILL DECODE WITHOUT IT.
//
// A deploy replaces the bridge, not the sentinel. The sentinel is reinstalled by hand, so a
// phone on the newest build routinely talks to a sentinel that predates this block — that is
// the ordinary case, not an edge one, and a document with no `releases` key has to decode to
// exactly the card that shipped before it.
//
// The fixture below is the `json!` shape pinned by
// `the_release_block_is_shaped_as_the_app_decodes_it` in `bridge/src/sentinel/deploy.rs`, so
// the two sides cannot drift without one of them failing.

final class DeployReleasesTests: XCTestCase {

    /// The whole block, decoded: both groups, the per-release caps, and the positional ids.
    func testDecodesADocumentCarryingReleases() throws {
        let doc = try DeployStatusDocument.decode(Data(Self.withReleases.utf8))
        let releases = try XCTUnwrap(doc.releases)

        let deployed = try XCTUnwrap(releases.deployed)
        XCTAssertEqual(deployed.title,
                       "Stop the deploy card showing a cached answer as a current one")
        XCTAssertEqual(deployed.version, "bridge 0.106.0")
        XCTAssertEqual(deployed.lines.count, 2)
        XCTAssertEqual(deployed.lines.first,
                       "The deploy card no longer shows a cached answer as a current one.")
        XCTAssertEqual(deployed.more, 0)
        XCTAssertEqual(deployed.dateMs, 1_756_500_000_000)
        XCTAssertEqual(deployed.subtitle, "bridge 0.106.0 · 23f03ce")

        XCTAssertEqual(releases.undeployed.count, 2, "newest first, as the sentinel sends them")
        XCTAssertEqual(releases.undeployed.first?.title, "Take the interim fixes")
        XCTAssertEqual(releases.undeployed.first?.version, "bridge 0.107.0, App 1.0 (121)")
        XCTAssertEqual(releases.undeployed.first?.more, 3,
                       "what a release did not show is reported, not swallowed")
        XCTAssertEqual(releases.truncated, 2, "nor is what the LIST did not show")
        XCTAssertNil(releases.reason, "an ordinary range needs no explanation")

        // Positional identity: the two undeployed releases here share a title and a version,
        // which is exactly why nothing in the payload can serve as one.
        XCTAssertEqual(releases.undeployed.map(\.id), [0, 1])
        XCTAssertEqual(releases.undeployed[0].title, releases.undeployed[1].title)

        // The card's own decision is unaffected by any of this.
        XCTAssertEqual(DeployAvailability.decide(doc), .ready(sha: String(repeating: "b", count: 40)))
    }

    /// **A sentinel that sends no `releases` key still renders a whole card.** The rest of the
    /// document is untouched, and the block is simply nil — no throw, no empty placeholder.
    func testDecodesADocumentWithNoReleasesKey() throws {
        let doc = try DeployStatusDocument.decode(Data(Self.withoutReleases.utf8))

        XCTAssertNil(doc.releases, "an older sentinel is not a decode failure")
        XCTAssertEqual(doc.running.version, "0.106.0")
        XCTAssertEqual(doc.running.sha, String(repeating: "a", count: 40))
        XCTAssertEqual(doc.originMain.version, "0.107.0")
        XCTAssertEqual(doc.originMain.ci, "green")
        XCTAssertFalse(doc.originMain.isStale)
        XCTAssertEqual(DeployAvailability.decide(doc), .ready(sha: String(repeating: "b", count: 40)))
    }

    /// The cases the sentinel refuses to guess at arrive as an EMPTY list plus a reason. The
    /// one that matters most is a sentinel with no recorded deploy: "everything on main is
    /// undeployed" would be a wall of releases the Studio may already be running.
    func testAnUncomputableRangeArrivesAsAReasonRatherThanAGuess() throws {
        for reason in ["the sentinel has not recorded a deployed commit yet",
                       "the running commit is not on origin/main",
                       "the running commit is not in the deploy clone"] {
            let json = """
            {"running": {"version": null, "sha": null},
             "origin_main": {"sha": "\(String(repeating: "b", count: 40))", "ci": "green",
                             "checked_ms": 1756600000000},
             "releases": {"deployed": null, "undeployed": [], "truncated": 0,
                          "reason": "\(reason)"}}
            """
            let doc = try DeployStatusDocument.decode(Data(json.utf8))
            let releases = try XCTUnwrap(doc.releases, reason)
            XCTAssertTrue(releases.undeployed.isEmpty, reason)
            XCTAssertNil(releases.deployed, reason)
            XCTAssertEqual(releases.reason, reason)
        }
    }

    /// A release that added no changelog bullet is its title alone, and a missing `version` is
    /// nil rather than a guess — the subtitle then falls back to the short sha.
    func testAReleaseWithNoLinesAndNoVersionDecodes() throws {
        let json = """
        {"running": {"version": null, "sha": null},
         "origin_main": {"sha": null, "ci": "none", "checked_ms": 0},
         "releases": {"deployed": {"sha": "\(String(repeating: "c", count: 40))",
                                   "version": null, "title": "A commit with no changelog entry",
                                   "date_ms": 0, "lines": [], "more": 0},
                      "undeployed": [], "truncated": 0, "reason": null}}
        """
        let doc = try DeployStatusDocument.decode(Data(json.utf8))
        let deployed = try XCTUnwrap(doc.releases?.deployed)
        XCTAssertTrue(deployed.lines.isEmpty)
        XCTAssertNil(deployed.version)
        XCTAssertEqual(deployed.subtitle, "ccccccc", "no version, so just the commit")
    }

    // MARK: - Fixtures

    /// Pinned by `the_release_block_is_shaped_as_the_app_decodes_it` in `deploy.rs`.
    static let withReleases = """
    {
      "deploy": null,
      "running": {"version": "0.106.0", "sha": "\(String(repeating: "a", count: 40))"},
      "origin_main": {"sha": "\(String(repeating: "b", count: 40))", "version": "0.107.0",
                      "ci": "green", "ci_detail": "run 42 (CI) passed the \\"bridge\\" job",
                      "checked_ms": 1756600000000},
      "releases": {
        "deployed": {"sha": "23f03ce0000000000000000000000000000000aa",
                     "version": "bridge 0.106.0",
                     "title": "Stop the deploy card showing a cached answer as a current one",
                     "date_ms": 1756500000000,
                     "lines": ["The deploy card no longer shows a cached answer as a current one.",
                               "A `pending` CI verdict is never served from the cache."],
                     "more": 0},
        "undeployed": [
          {"sha": "3407550000000000000000000000000000000bb",
           "version": "bridge 0.107.0, App 1.0 (121)", "title": "Take the interim fixes",
           "date_ms": 1756600000000,
           "lines": ["The location channel takes the interim fixes."], "more": 3},
          {"sha": "3407550000000000000000000000000000000cc",
           "version": "bridge 0.107.0, App 1.0 (121)", "title": "Take the interim fixes",
           "date_ms": 1756590000000, "lines": [], "more": 0}
        ],
        "truncated": 2,
        "reason": null
      }
    }
    """

    /// The same card from a sentinel that predates the block — the key is simply absent.
    static let withoutReleases = """
    {
      "deploy": null,
      "running": {"version": "0.106.0", "sha": "\(String(repeating: "a", count: 40))"},
      "origin_main": {"sha": "\(String(repeating: "b", count: 40))", "version": "0.107.0",
                      "ci": "green", "ci_detail": "run 42 (CI) passed the \\"bridge\\" job",
                      "checked_ms": 1756600000000}
    }
    """
}
