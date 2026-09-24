import XCTest
@testable import JesseVault

// What a typed query becomes, how the answers are ordered, and when — and only when —
// the on-device model is asked for alternates.

final class VaultSearchTests: XCTestCase {

    // MARK: - The query, as FTS5 sees it

    /// Every token is a quoted PREFIX term and all of them are required. Quoting is not
    /// decoration: unquoted, FTS5 reads an apostrophe or a hyphen as its own operator and
    /// answers a syntax error for a perfectly reasonable search.
    func testEveryTokenBecomesARequiredPrefixTerm() {
        XCTAssertEqual(VaultSearchQuery.matchExpression("soft bricks"),
                       "\"soft\"* AND \"bricks\"*")
        XCTAssertEqual(VaultSearchQuery.matchExpression("  Marta   Ruggeri  "),
                       "\"Marta\"* AND \"Ruggeri\"*")
    }

    /// Punctuation is trimmed off a token, and a token with no letters or digits left is
    /// dropped. A query of `--` must come back as "nothing to search for", never as a
    /// syntax error from the database.
    func testPunctuationOnlyTokensAreDroppedRatherThanSentToTheDatabase() {
        XCTAssertNil(VaultSearchQuery.matchExpression("--"))
        XCTAssertNil(VaultSearchQuery.matchExpression("   "))
        XCTAssertNil(VaultSearchQuery.matchExpression(""))
        XCTAssertEqual(VaultSearchQuery.matchExpression("kiln."), "\"kiln\"*")
        XCTAssertEqual(VaultSearchQuery.matchExpression("(kiln)"), "\"kiln\"*")
    }

    /// A double quote inside a term is escaped by doubling, the one escape FTS5 defines.
    func testAQuoteInsideATermIsDoubled() {
        XCTAssertEqual(VaultSearchQuery.escaped("say \"this\""), "say \"\"this\"\"")
    }

    /// The tokenizer is the CONVERSATION LIST's: one rule, so a query does not mean two
    /// different things in two parts of the same app.
    func testTheTokenizerIsTheOneTheConversationSearchUses() {
        XCTAssertEqual(SearchQueryRules.significantTokens("a kiln bricks").map(String.init),
                       ["kiln", "bricks"],
                       "tokens shorter than two characters are not tokens")
        // …and a query of nothing but short tokens still searches, rather than being
        // silently dropped.
        XCTAssertEqual(VaultSearchQuery.tokens("hi"), ["hi"])
    }

    // MARK: - The order

    private func hit(_ path: String, title: String, score: Double,
                     heading: String = "") -> VaultSearchHit {
        VaultSearchHit(path: path, title: title, heading: heading, line: 1,
                       snippet: "…", score: score)
    }

    /// A file NAMED after the query comes first even when bm25 prefers another row.
    /// Searching a surname in this vault means "their file".
    func testANameMatchOutranksABetterScoringBodyMatch() {
        let body = hit("Workshop/Meeting.md", title: "Meeting notes", score: -9)
        let name = hit("People/Marta Ruggeri.md", title: "Marta Ruggeri", score: -1)

        let ranked = VaultSearchQuery.ranked([body, name], tokens: ["ruggeri"])

        XCTAssertEqual(ranked.first?.path, "People/Marta Ruggeri.md")
        XCTAssertTrue(ranked.first?.isNameMatch == true)
        XCTAssertFalse(ranked.last?.isNameMatch == true)
    }

    /// EVERY token has to be in the name for it to count as a name match. One word out of
    /// two is a body hit like any other.
    func testANameMatchNeedsEveryToken() {
        XCTAssertTrue(VaultSearchQuery.isNameMatch(title: "Marta Ruggeri",
                                                   path: "People/Marta Ruggeri.md",
                                                   tokens: ["marta", "ruggeri"]))
        XCTAssertFalse(VaultSearchQuery.isNameMatch(title: "Marta Ruggeri",
                                                    path: "People/Marta Ruggeri.md",
                                                    tokens: ["marta", "kiln"]))
        XCTAssertFalse(VaultSearchQuery.isNameMatch(title: "x", path: "y", tokens: []))
    }

    /// The path counts as the name too: `Suppliers/Terrasole.md` answers "suppliers".
    func testThePathCountsAsTheName() {
        XCTAssertTrue(VaultSearchQuery.isNameMatch(title: "Terrasole",
                                                   path: "Suppliers/Terrasole.md",
                                                   tokens: ["suppliers"]))
    }

    /// Diacritics and case fold in the name rule as well, so it agrees with the index's own
    /// tokenizer rather than contradicting it.
    func testTheNameRuleFoldsCaseAndDiacritics() {
        XCTAssertTrue(VaultSearchQuery.isNameMatch(title: "Café notes", path: "A/B.md",
                                                   tokens: ["cafe"]))
    }

    /// Within a group the order is bm25, and ties break on path then line so two runs of
    /// the same query cannot answer in two different orders.
    func testTheOrderIsStableWithinAGroup() {
        let a = hit("A.md", title: "A", score: -3)
        let b = hit("B.md", title: "B", score: -3)
        let c = hit("C.md", title: "C", score: -5)

        XCTAssertEqual(VaultSearchQuery.ranked([b, a, c], tokens: ["kiln"]).map(\.path),
                       ["C.md", "A.md", "B.md"])
    }

    func testCollapsingKeepsTheFirstRowPerFile() {
        let first = hit("A.md", title: "A", score: -9, heading: "One")
        let second = hit("A.md", title: "A", score: -8, heading: "Two")
        let other = hit("B.md", title: "B", score: -7)

        let collapsed = VaultSearchQuery.collapsedByFile([first, second, other])

        XCTAssertEqual(collapsed.map(\.heading), ["One", ""])
    }

    // MARK: - The expansion tier

    /// A fake expander, so the gate is asserted without a model on the machine.
    private final class FakeExpander: VaultQueryExpanding, @unchecked Sendable {
        let terms: [String]
        private(set) var calls: [String] = []
        init(terms: [String]) { self.terms = terms }
        func expand(_ query: String) async -> [String] {
            calls.append(query)
            return terms
        }
    }

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

    private func indexed(_ notes: [(String, String)]) throws -> VaultIndex {
        for (path, text) in notes { VaultFixture.write(text, to: path, in: root) }
        let index = try VaultIndex(url: VaultIndex.databaseURL(forRoot: root,
                                                               in: databaseDirectory))
        let file = VaultFile(root: root)
        try index.reindex(scan: VaultScanner().scan(root: root),
                          read: { try file.read(relativePath: $0) })
        return index
    }

    /// FEWER THAN FIVE HITS: the tier is worth the model, and its terms WIDEN the result
    /// set rather than replacing it.
    func testAThinResultSetAsksTheExpanderAndTheTermsOnlyAddRows() async throws {
        let index = try indexed([
            ("Workshop/Kiln.md", "# Kiln\n\nThe arch is rebuilt.\n"),
            ("Workshop/Oven.md", "# Oven\n\nThe bread oven is separate.\n"),
        ])
        let expander = FakeExpander(terms: ["oven"])
        let searcher = VaultSearcher(index: index)

        let outcome = await searcher.search("kiln", expander: expander)

        XCTAssertEqual(expander.calls, ["kiln"])
        XCTAssertEqual(outcome.hits.map(\.path), ["Workshop/Kiln.md", "Workshop/Oven.md"],
                       "the typed query's hit keeps its place; the expansion's follows it")
        XCTAssertEqual(outcome.expansionTerms, ["oven"])
        XCTAssertEqual(outcome.expansionCaption, "Also searched: oven")
    }

    /// **THE FOLDER BINDS THE WIDENING TOO.** The typed query is thin, so the tier runs
    /// and the expander offers a term that matches a note OUTSIDE the chosen folder. The
    /// screen says it is showing one folder, so that note must not appear — and the term
    /// must not be named either, because a caption claiming a term "also searched" for a
    /// row nobody can see is worse than no caption.
    func testTheExpansionTierNeverReachesOutsideTheChosenFolder() async throws {
        let index = try indexed([
            ("Strands/Kiln.md", "# Kiln\n\nThe arch is rebuilt.\n"),
            ("Bicycle/Oven.md", "# Oven\n\nThe bread oven is separate.\n"),
        ])
        let expander = FakeExpander(terms: ["oven"])
        let searcher = VaultSearcher(index: index, folder: "Strands")

        let outcome = await searcher.search("kiln", expander: expander)

        XCTAssertEqual(expander.calls, ["kiln"], "the tier still ran; it just found nothing")
        XCTAssertEqual(outcome.hits.map(\.path), ["Strands/Kiln.md"])
        XCTAssertEqual(outcome.expansionTerms, [], "no term contributed, so none is named")
        XCTAssertNil(outcome.expansionCaption)
    }

    /// The same expander, the same corpus, with no folder held: the alternate term DOES
    /// contribute, which is what makes the test above a claim about the folder rather
    /// than about a dry expander.
    func testTheSameAlternateTermContributesWithNoFolderHeld() async throws {
        let index = try indexed([
            ("Strands/Kiln.md", "# Kiln\n\nThe arch is rebuilt.\n"),
            ("Bicycle/Oven.md", "# Oven\n\nThe bread oven is separate.\n"),
        ])
        let searcher = VaultSearcher(index: index)

        let outcome = await searcher.search("kiln", expander: FakeExpander(terms: ["oven"]))

        XCTAssertEqual(outcome.hits.map(\.path), ["Strands/Kiln.md", "Bicycle/Oven.md"])
        XCTAssertEqual(outcome.expansionTerms, ["oven"])
    }

    /// A folder is given WITHOUT its trailing slash by the screen; the searcher adds it,
    /// so `Work` cannot answer with `Workshop/`.
    func testAFolderIsMatchedOnAPathBoundary() throws {
        let index = try indexed([
            ("Work/Bench.md", "# Bench\n\nThe bisque schedule.\n"),
            ("Workshop/Kiln.md", "# Kiln\n\nThe bisque schedule.\n"),
        ])

        XCTAssertEqual(VaultSearcher(index: index, folder: "Work").base("bisque")
                        .hits.map(\.path), ["Work/Bench.md"])
        XCTAssertEqual(VaultSearcher(index: index, folder: "Workshop").base("bisque")
                        .hits.map(\.path), ["Workshop/Kiln.md"])
    }

    /// AT FIVE HITS the model is never spent: a plentiful result set is never widened. The
    /// same threshold the conversation list uses, and the same `shouldExpand` deciding it.
    func testAPlentifulResultSetNeverSpendsTheModel() async throws {
        var notes: [(String, String)] = []
        for i in 1...5 { notes.append(("N/Note-\(i).md", "# Note \(i)\n\nThe kiln again.\n")) }
        let index = try indexed(notes)
        let expander = FakeExpander(terms: ["oven"])

        let outcome = await VaultSearcher(index: index).search("kiln", expander: expander)

        XCTAssertEqual(outcome.hits.count, 5)
        XCTAssertTrue(expander.calls.isEmpty, "five hits is plenty; the model is not asked")
        XCTAssertNil(outcome.expansionCaption)
    }

    /// A one or two character query never spends the model either, however few hits it has.
    func testATrivialQueryNeverSpendsTheModel() async throws {
        let index = try indexed([("A.md", "# A\n\nnothing much\n")])
        let expander = FakeExpander(terms: ["oven"])

        _ = await VaultSearcher(index: index).search("ki", expander: expander)

        XCTAssertTrue(expander.calls.isEmpty)
        XCTAssertTrue(SearchQueryRules.shouldExpand(query: "kil", baseMatchCount: 0,
                                                    threshold: 5))
        XCTAssertFalse(SearchQueryRules.shouldExpand(query: "ki", baseMatchCount: 0,
                                                     threshold: 5))
    }

    /// An expander that returns nothing leaves the result set exactly as the typed query
    /// found it — and says nothing in the caption, which is what makes the caption
    /// trustworthy when it does appear.
    func testADryExpanderChangesNothingAndClaimsNothing() async throws {
        let index = try indexed([("Workshop/Kiln.md", "# Kiln\n\nThe arch.\n")])

        let outcome = await VaultSearcher(index: index).search("kiln",
                                                              expander: NoVaultExpansion())

        XCTAssertEqual(outcome.hits.count, 1)
        XCTAssertNil(outcome.expansionCaption)
    }

    /// A term that finds only what the typed query already found is NOT claimed in the
    /// caption: the caption names the terms that actually contributed a row.
    func testATermThatAddsNothingIsNotNamed() async throws {
        let index = try indexed([("Workshop/Kiln.md", "# Kiln\n\nThe kiln arch.\n")])
        let expander = FakeExpander(terms: ["arch"])

        let outcome = await VaultSearcher(index: index).search("kiln", expander: expander)

        XCTAssertEqual(outcome.hits.count, 1)
        XCTAssertEqual(outcome.expansionTerms, [])
        XCTAssertNil(outcome.expansionCaption)
    }

    /// The base query reports its own latency, which is the number the under-100-ms target
    /// is stated against.
    func testTheBaseQueryTimesItself() throws {
        let index = try indexed([("A.md", "# A\n\nThe kiln.\n")])
        let outcome = VaultSearcher(index: index).base("kiln")
        XCTAssertGreaterThan(outcome.baseDuration, 0)
        XCTAssertLessThan(outcome.baseDuration, 1, "a five-file index answers in milliseconds")
    }
}
