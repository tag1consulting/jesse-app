import XCTest
@testable import JesseVault

// What the model is shown: which notes, in which order, and how much of them.
//
// The index and the filesystem are REAL here, for the reason `VaultIndexTests` says: the
// claims are about what FTS5 answers and what the fusion does to it, and a fake index
// would prove nothing about either. The model and the embedding are fakes, always.

/// An embedding with a table of answers. Deterministic, so a fusion assertion is a
/// statement about the fusion and not about a sentence encoder's mood.
private struct ScriptedEmbedding: ChunkEmbedding {
    let scores: [String: Double]
    var available = true
    var isAvailable: Bool { available }
    func similarity(_ lhs: String, _ rhs: String) -> Double? {
        for (needle, score) in scores where rhs.contains(needle) { return score }
        return nil
    }
}

final class VaultRetrieverTests: XCTestCase {

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

    private func indexedCorpus() throws -> VaultIndex {
        VaultRetrievalFixture.write(in: root)
        let index = try VaultIndex(
            url: VaultIndex.databaseURL(forRoot: root, in: databaseDirectory))
        let file = VaultFile(root: root)
        try index.reindex(scan: VaultScanner().scan(root: root),
                          read: { try file.read(relativePath: $0) })
        return index
    }

    // MARK: - The budget

    func testAnUnmeasuredDeviceGetsFourChunksAndTwelveThousandCharacters() {
        let budget = VaultRetrievalBudget.forMeasuredPrompt(nil)
        XCTAssertEqual(budget.chunkCount, 4)
        XCTAssertEqual(budget.totalCharacters, 12_000)
    }

    /// The phone's measured number, and the Mac's.
    func testAMeasuredWindowSpendsSixtyPercentOfItselfOnSnippets() {
        let phone = VaultRetrievalBudget.forMeasuredPrompt(33_500)
        XCTAssertEqual(phone.chunkCount, 4)
        XCTAssertEqual(phone.totalCharacters, 20_100)
        XCTAssertEqual(phone.perChunkCharacters, 5_025)

        let mac = VaultRetrievalBudget.forMeasuredPrompt(21_000)
        XCTAssertEqual(mac.chunkCount, 4)
        XCTAssertEqual(mac.totalCharacters, 12_600)
    }

    /// Under six thousand characters, four chunks cannot each be worth sending.
    func testASmallWindowHalvesTheChunkCount() {
        let small = VaultRetrievalBudget.forMeasuredPrompt(5_000)
        XCTAssertEqual(small.chunkCount, 2)
        XCTAssertEqual(small.totalCharacters, 3_000)
        XCTAssertEqual(small.perChunkCharacters, 1_500)

        // Exactly at the boundary is NOT small.
        XCTAssertEqual(VaultRetrievalBudget.forMeasuredPrompt(6_000).chunkCount, 4)
    }

    // MARK: - Clipping

    func testAChunkIsClippedToItsOwnShareOnAWordBoundary() {
        let text = String(repeating: "brick ", count: 100)
        let clipped = VaultRetriever.clip(text, to: 50)
        XCTAssertLessThanOrEqual(clipped.count, 50)
        XCTAssertFalse(clipped.hasSuffix("bri"), "clipped mid-word")
        XCTAssertTrue(clipped.hasSuffix("brick"))
    }

    func testAShortChunkIsReturnedWhole() {
        XCTAssertEqual(VaultRetriever.clip("  forty soft bricks  ", to: 500),
                       "forty soft bricks")
    }

    /// A single word longer than the whole allowance still has to be cut somewhere.
    func testAWordLongerThanTheAllowanceIsCutAnyway() {
        let clipped = VaultRetriever.clip(String(repeating: "x", count: 100), to: 10)
        XCTAssertEqual(clipped.count, 10)
    }

    // MARK: - Inbox

    func testEverythingUnderInboxIsExcluded() {
        let hits = [
            VaultSearchHit(path: "Inbox/mail.md", title: "m", heading: "", line: 1,
                           snippet: "", score: -9),
            VaultSearchHit(path: "Inbox/archive/scan.md", title: "s", heading: "", line: 1,
                           snippet: "", score: -8),
            VaultSearchHit(path: "Family/School-Year.md", title: "s", heading: "", line: 1,
                           snippet: "", score: -1),
            VaultSearchHit(path: "Projects/Inbox-Redesign.md", title: "i", heading: "",
                           line: 1, snippet: "", score: -1),
        ]
        XCTAssertEqual(VaultRetriever.allowed(hits).map(\.path),
                       ["Family/School-Year.md", "Projects/Inbox-Redesign.md"],
                       "the prefix is a DIRECTORY, not a substring of a filename")
    }

    /// End to end, over the real index: the trap note under `Inbox/` is a better keyword
    /// match than the note that answers the question, and must never come back.
    func testTheInboxTrapIsNeverRetrieved() async throws {
        let index = try indexedCorpus()
        let retriever = VaultRetriever(index: index)
        let result = await retriever.retrieve(question: "when is the school concert",
                                              budget: .forMeasuredPrompt(nil))
        XCTAssertFalse(result.chunks.isEmpty)
        XCTAssertFalse(result.chunks.contains { $0.path.hasPrefix("Inbox/") })
        XCTAssertTrue(result.chunks.contains { $0.path == "Family/School-Year.md" })
    }

    // MARK: - Fusion

    func testWithNoEmbeddingBm25sOrderStands() {
        let bodies = [("a.md", "alpha"), ("b.md", "beta"), ("c.md", "gamma")]
            .map { (hit: VaultSearchHit(path: $0.0, title: "", heading: "", line: 1,
                                        snippet: "", score: -1), text: $0.1) }
        let fused = VaultRetriever.fused(bodies, question: "q", embedding: NoChunkEmbedding())
        XCTAssertEqual(fused.map(\.hit.path), ["a.md", "b.md", "c.md"])
    }

    /// The embedding's opinion actually moves a chunk: third by bm25, first by
    /// similarity, top after fusion.
    ///
    /// Note what this test CANNOT be. With k = 60, a chunk that is third by bm25 and
    /// first by embedding ties exactly with one that is first by bm25 and third by
    /// embedding — the two contributions are mirror images. That is reciprocal rank
    /// fusion working as published, not a bug: at k = 60 a single strong opinion nudges,
    /// and two agreeing opinions decide. What lifts a chunk is the OTHER candidate
    /// having no embedding opinion at all, which is the ordinary case over a real vault.
    func testTheEmbeddingCanLiftALowBm25Chunk() {
        let bodies = [("a.md", "alpha"), ("b.md", "beta"), ("c.md", "gamma"),
                      ("d.md", "delta")]
            .map { (hit: VaultSearchHit(path: $0.0, title: "", heading: "", line: 1,
                                        snippet: "", score: -1), text: $0.1) }
        let embedding = ScriptedEmbedding(scores: ["gamma": 0.9, "delta": 0.1])
        let fused = VaultRetriever.fused(bodies, question: "q", embedding: embedding)
        XCTAssertEqual(fused.map(\.hit.path), ["c.md", "d.md", "a.md", "b.md"])
    }

    /// The mirror case, stated so the property above is a decision and not an accident.
    func testTwoMirroredOpinionsTieAndBm25BreaksTheTie() {
        let bodies = [("a.md", "alpha"), ("b.md", "beta"), ("c.md", "gamma")]
            .map { (hit: VaultSearchHit(path: $0.0, title: "", heading: "", line: 1,
                                        snippet: "", score: -1), text: $0.1) }
        let embedding = ScriptedEmbedding(scores: ["gamma": 0.9, "beta": 0.5, "alpha": 0.2])
        let fused = VaultRetriever.fused(bodies, question: "q", embedding: embedding)
        XCTAssertEqual(fused.first?.hit.path, "a.md")
    }

    /// A chunk the embedding declines to place keeps its bm25 standing rather than being
    /// scored zero and sunk.
    func testAChunkTheEmbeddingCannotPlaceIsNotPunished() {
        let bodies = [("a.md", "alpha"), ("b.md", "unknown")]
            .map { (hit: VaultSearchHit(path: $0.0, title: "", heading: "", line: 1,
                                        snippet: "", score: -1), text: $0.1) }
        let embedding = ScriptedEmbedding(scores: ["alpha": 0.9])
        let fused = VaultRetriever.fused(bodies, question: "q", embedding: embedding)
        XCTAssertEqual(fused.map(\.hit.path), ["a.md", "b.md"])
    }

    func testReciprocalRankFusionScoresRanksNotValues() {
        let scores = RankFusion.fuse([["a", "b"], ["b", "a"]])
        XCTAssertEqual(scores["a"] ?? 0, scores["b"] ?? 0, accuracy: 1e-12,
                       "the same two ranks in both orders is a tie")
        let single = RankFusion.fuse([["a", "b"]])
        XCTAssertGreaterThan(single["a"] ?? 0, single["b"] ?? 0)
    }

    // MARK: - Keywords

    func testAQuestionIsReducedToItsKeywords() {
        XCTAssertEqual(LookupQuery.keywords("when is the school concert"),
                       ["school", "concert"])
        XCTAssertEqual(LookupQuery.keywords("what did we decide about the fiber contract"),
                       ["decide", "fiber", "contract"])
    }

    func testAQuestionOfNothingButStopWordsStillSearches() {
        XCTAssertEqual(LookupQuery.keywords("what is it"), ["what", "is", "it"])
    }

    // MARK: - The budget, applied

    func testTheBudgetDecidesHowManyChunksAndHowLong() async throws {
        let index = try indexedCorpus()
        let retriever = VaultRetriever(index: index)

        let four = await retriever.retrieve(question: "kiln bricks glaze concert",
                                            budget: .forMeasuredPrompt(nil))
        XCTAssertLessThanOrEqual(four.chunks.count, 4)

        let two = await retriever.retrieve(question: "kiln bricks glaze concert",
                                           budget: .forMeasuredPrompt(5_000))
        XCTAssertLessThanOrEqual(two.chunks.count, 2)
        XCTAssertLessThanOrEqual(two.characters, 3_000)
        for chunk in two.chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, 1_500)
        }
    }

    /// `chunkText` is the read this whole file depends on: a hit's snippet is fifteen
    /// words with match markers in it, and the body is what the model needs.
    func testChunkTextReadsTheWholeBodyNotTheSnippet() throws {
        let index = try indexedCorpus()
        let hits = index.search(expression: "\"tenmoku\"*", limit: 5)
        let hit = try XCTUnwrap(hits.first)
        let body = try XCTUnwrap(index.chunkText(path: hit.path, line: hit.line))
        XCTAssertTrue(body.contains("cone ten"))
        XCTAssertFalse(body.contains(VaultSearchHit.markStart))
        XCTAssertGreaterThan(body.count, hit.snippet.count)
        XCTAssertNil(index.chunkText(path: hit.path, line: 99_999))
        XCTAssertNil(index.chunkText(path: "Nowhere.md", line: 1))
    }
}
