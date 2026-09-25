import XCTest
import JesseNetworking
@testable import JesseTodayDisplay

/// THE TREE LENS: every strand under its parent, in recency order at every level, with
/// collapse, a count of what a collapsed parent holds, and no tree at all from a bridge
/// that cannot say who the parents are.
@MainActor
final class StrandsTreeTests: XCTestCase {

    private func strand(_ slug: String, parent: String? = nil,
                        state: StrandState = .active,
                        updated: String = "2026-09-25",
                        servesParent: Bool = true) -> Strand {
        Strand(slug: slug, title: slug, state: state, updated: updated,
               parent: parent, servesParent: servesParent)
    }

    /// Three levels, in the server's recency order: a child can arrive before its
    /// parent, and a parent sits where its OWN recency puts it.
    private var threeLevels: [Strand] {
        [strand("Strands-System", parent: "Jesse"),
         strand("Health"),
         strand("Jesse", parent: "Tag1"),
         strand("Scolta", parent: "Tag1"),
         strand("Tag1"),
         strand("Jesse-Pro", parent: "Jesse")]
    }

    private func shape(_ rows: [StrandsTreeRow]) -> [String] {
        rows.map { String(repeating: "  ", count: $0.depth) + $0.strand.slug }
    }

    func testTreeOrderAndDepthOnThreeLevels() {
        let rows = StrandsSemantics.tree(threeLevels)
        XCTAssertEqual(shape(rows), [
            "Health",
            "Tag1",
            "  Jesse",
            "    Strands-System",
            "    Jesse-Pro",
            "  Scolta",
        ])
        XCTAssertEqual(rows.map(\.descendants), [0, 4, 2, 0, 0, 0])
    }

    /// Through the lens: one group of the same rows, the dormant group below it and
    /// never nested, even when a live strand names the dormant one as its parent.
    func testTheTreeLensKeepsDormantStrandsOutOfTheTree() {
        let board = threeLevels + [strand("Asleep", state: .dormant),
                                   strand("Under-Asleep", parent: "Asleep")]
        let groups = StrandsSemantics.grouped(board, by: .tree)
        XCTAssertEqual(groups.count, 2)
        let tree = try? XCTUnwrap(groups.first?.treeRows)
        XCTAssertEqual(tree?.first(where: { $0.strand.slug == "Under-Asleep" })?.depth, 0,
                       "a dormant parent is not in the tree, so its child is top level")
        XCTAssertEqual(groups.first?.strands.map(\.slug), tree?.map(\.strand.slug))
        XCTAssertEqual(groups.last?.title, "Dormant")
        XCTAssertEqual(groups.last?.strands.map(\.slug), ["Asleep"])
        XCTAssertNil(groups.last?.treeRows)
    }

    func testCollapseHidesTheWholeSubtreeAndCountsIt() {
        let rows = StrandsSemantics.tree(threeLevels)
        let tag1 = StrandsSemantics.visibleTreeRows(rows, collapsed: ["Tag1"])
        XCTAssertEqual(shape(tag1), ["Health", "Tag1"])
        XCTAssertEqual(StrandsSemantics.insideCaption(tag1[1].descendants), "4 inside")

        let jesse = StrandsSemantics.visibleTreeRows(rows, collapsed: ["Jesse"])
        XCTAssertEqual(shape(jesse), ["Health", "Tag1", "  Jesse", "  Scolta"])
        XCTAssertEqual(StrandsSemantics.insideCaption(jesse[2].descendants), "2 inside")

        XCTAssertEqual(StrandsSemantics.visibleTreeRows(rows, collapsed: []), rows,
                       "every parent starts expanded")
        XCTAssertEqual(StrandsSemantics.visibleTreeRows(rows, collapsed: ["Health"]), rows,
                       "a leaf has nothing to fold")
    }

    func testCollapsedSlugsSurviveTheirStoredForm() {
        let slugs: Set<String> = ["Tag1", "Jesse"]
        XCTAssertEqual(StrandsSemantics.decodeCollapsed(
            StrandsSemantics.encodeCollapsed(slugs)), slugs)
        XCTAssertEqual(StrandsSemantics.decodeCollapsed(""), [])
    }

    /// A parent the bridge could not resolve arrives as nil, so the strand is simply top
    /// level; the row's warning glyph comes from its `PARENT-MISSING` finding.
    func testAnUnresolvedParentIsTopLevel() {
        var orphan = strand("Orphan")
        orphan.findings = [StrandFinding(code: "PARENT-MISSING", message: "parent Gone")]
        let rows = StrandsSemantics.tree([strand("Tag1"), orphan])
        XCTAssertEqual(shape(rows), ["Tag1", "Orphan"])
    }

    /// A loop the bridge should never send is broken where the walk would repeat, and
    /// every strand still appears exactly once.
    func testACycleIsBrokenAtTheFirstRepeat() {
        let board = [strand("Top"),
                     strand("A", parent: "B"),
                     strand("B", parent: "C"),
                     strand("C", parent: "A"),
                     strand("Under-C", parent: "C"),
                     strand("Self", parent: "Self")]
        let rows = StrandsSemantics.tree(board)
        XCTAssertEqual(Set(rows.map(\.strand.slug)), Set(board.map(\.slug)))
        XCTAssertEqual(rows.count, board.count, "no strand twice")
        XCTAssertEqual(shape(rows), [
            "Top",
            "Self",
            "A",
            "  C",
            "    B",
            "    Under-C",
        ])
    }

    /// An older bridge sends no `parent`, so `Tree` is not offered and a stored choice
    /// of it falls back to `Most recent` rather than drawing a flat list as a tree.
    func testTreeIsHiddenOnAParentlessSnapshot() async {
        XCTAssertEqual(StrandsSortKey.available(servesParents: false), [.mostRecent, .group])
        XCTAssertEqual(StrandsSortKey.available(servesParents: true),
                       [.mostRecent, .group, .tree])

        let olderBoard = StrandsSnapshot(strands: [strand("A", servesParent: false)])
        let older = StrandsModel(makeClient: { FixedStrands(snapshot: olderBoard) })
        await older.load()
        older.sortKey = .tree
        XCTAssertFalse(older.availableSortKeys.contains(.tree))
        XCTAssertEqual(older.effectiveSortKey, .mostRecent)
        XCTAssertNil(older.groups.first?.treeRows)

        let newerBoard = StrandsSnapshot(strands: [strand("A")])
        let newer = StrandsModel(makeClient: { FixedStrands(snapshot: newerBoard) })
        await newer.load()
        newer.sortKey = .tree
        XCTAssertEqual(newer.effectiveSortKey, .tree)
        XCTAssertNotNil(newer.groups.first?.treeRows)
    }

    func testTreeLabel() {
        XCTAssertEqual(StrandsSortKey.tree.label, "Tree")
    }
}

private struct FixedStrands: StrandsProviding {
    let snapshot: StrandsSnapshot
    func getStrands(ifNoneMatch: String?) async throws -> StrandsFetchResult {
        .snapshot(snapshot)
    }
    func getStrand(slug: String) async throws -> StrandDetail {
        StrandDetail(markdown: "# \(slug)")
    }
}
