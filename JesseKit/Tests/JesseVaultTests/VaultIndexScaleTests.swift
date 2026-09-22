import XCTest
@testable import JesseVault

// THE TWO NUMBERS THE WHOLE DESIGN WAS CHOSEN FOR, as a test rather than as a claim in a
// commit message: a search answers in well under a tenth of a second, and a reindex of an
// unchanged vault costs the walk and nothing more.
//
// The corpus here is 500 generated notes rather than the 7,600 of the real vault — this
// runs on every local gate, and a full-size corpus would add ten seconds to it. The
// full-size measurement is in the pull request that added this file; what this pins is the
// SHAPE: per-query cost that does not grow with the corpus, and an incremental pass that
// reads only what changed.

final class VaultIndexScaleTests: XCTestCase {

    private var root: URL!
    private var databaseDirectory: URL!

    override func setUp() {
        super.setUp()
        root = VaultFixture.makeDirectory()
        databaseDirectory = VaultFixture.makeDirectory()
    }

    override func tearDown() {
        VaultFixture.cleanUp(root)
        VaultFixture.cleanUp(databaseDirectory)
        super.tearDown()
    }

    /// 500 invented notes, each with frontmatter, four `##` sections and a wiki link — the
    /// shape of the real corpus, at a hundredth of its size.
    private func generate(_ count: Int) {
        let words = ["kiln", "brick", "glaze", "burner", "arch", "slip", "wheel", "pallet",
                     "quote", "schedule", "firing", "cone", "clay", "shelf"]
        for i in 0..<count {
            var body = "---\ntitle: Note \(i)\ntags: generated\n---\n\n# Note \(i)\n"
            for section in 1...4 {
                body += "\n## Section \(section)\n\n"
                for line in 0..<5 {
                    let chosen = (0..<10).map { words[($0 * 7 + line * 3 + i) % words.count] }
                    body += "- " + chosen.joined(separator: " ") + "\n"
                }
                body += "\nSee [[Notes/Note-\((i + section) % count)]] for the rest.\n"
            }
            if i == 0 { body += "\nThe café in Perugia sells Terrasole bricks.\n" }
            VaultFixture.write(body, to: "Notes/Note-\(i).md", in: root)
        }
    }

    func testSearchStaysWellUnderATenthOfASecondAndAReindexOnlyReadsWhatChanged() throws {
        generate(500)
        let index = try VaultIndex(url: VaultIndex.databaseURL(forRoot: root,
                                                               in: databaseDirectory))
        let file = VaultFile(root: root)
        let first = try index.reindex(scan: VaultScanner().scan(root: root),
                                      read: { try file.read(relativePath: $0) })
        XCTAssertEqual(first.added, 500)

        // A search, warmed once the way a second keystroke is.
        let searcher = VaultSearcher(index: index)
        _ = searcher.base("terrasole")
        for query in ["terrasole", "cafe perugia", "kiln arch"] {
            let outcome = searcher.base(query)
            XCTAssertLessThan(outcome.baseDuration, 0.1,
                              "\"\(query)\" took \(outcome.baseDuration) s")
        }
        XCTAssertEqual(searcher.base("terrasole").hits.count, 1)
        XCTAssertEqual(searcher.base("cafe perugia").hits.count, 1,
                       "diacritics fold at scale too")

        // Ten files changed out of 500: the reindex reads ten files, not 500.
        var read: [String] = []
        for i in 0..<10 {
            VaultFixture.write("# Touched \(i)\n\nThe arch was measured again.\n",
                               to: "Notes/Note-\(i).md", in: root)
            VaultFixture.touch("Notes/Note-\(i).md", in: root,
                               date: Date().addingTimeInterval(3600))
        }
        let second = try index.reindex(scan: VaultScanner().scan(root: root),
                                        read: { path in
                                            read.append(path)
                                            return try file.read(relativePath: path)
                                        })

        XCTAssertEqual(second.updated, 10)
        XCTAssertEqual(second.unchanged, 490)
        XCTAssertEqual(read.count, 10,
                       "the whole point: 490 files were never opened")
    }
}
