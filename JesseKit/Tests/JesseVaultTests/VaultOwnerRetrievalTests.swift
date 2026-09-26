import XCTest
@testable import JesseVault

// WHOSE BIRTHDAY, AND FROM WHICH NOTES — the 2026-09-26 incident, asserted.
//
// With the bridge unreachable, "What's my birthday?" was answered "June 26", citing an
// archived research note and an archived draft that both mention a trip taken for somebody
// else's birthday. The owner's birthday is September 4 and it sits in a live note under a
// heading that names him.
//
// THREE THINGS WERE WRONG AND EACH ONE HAS ITS OWN ASSERTION HERE, because a test that
// only checked the end result would pass again the moment two of them were reintroduced
// together:
//
//   1. `my` was dropped as a stop word and nothing took its place, so the index was asked
//      for `birthday` and had no idea whose.
//   2. `what's` was not on the stop list at all — the list holds words, the tokenizer hands
//      over contractions whole — so it was a REQUIRED keyword, no note contains it, and the
//      precise pass found nothing. The answer came out of the single-keyword fallback.
//   3. `Projects/drafts/archive/` and `Projects/Research/archive/` ranked exactly like a
//      note in use.
//
// The model and the embedding are fakes; the index and the filesystem are real, for the
// reason `VaultRetrieverTests` gives.

/// A generator that answers out of the first chunk it is handed and cites it. Enough to
/// show WHICH note the full path ends up answering from, with no model anywhere.
private struct FirstChunkGeneration: VaultAnswerGenerating {
    var isAvailable: Bool { true }
    func generate(question: String, chunks: [RetrievedChunk]) async throws -> VaultAnswerDraft {
        guard let first = chunks.first else {
            throw VaultAnswerGenerationError.failed("no chunks")
        }
        // The date out of the chunk's own text, so the answer is grounded the way a real
        // one is: the first parenthesised date in the extract.
        let date = first.text.split(separator: "(").dropFirst().first?
            .split(separator: ")").first ?? "unknown"
        return VaultAnswerDraft(answer: "It is \(date).", citations: [first.reference],
                                abstain: false)
    }
}

final class VaultOwnerRetrievalTests: XCTestCase {

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
        VaultOwnerRetrievalFixture.write(in: root)
        let index = try VaultIndex(
            url: VaultIndex.databaseURL(forRoot: root, in: databaseDirectory))
        let file = VaultFile(root: root)
        try index.reindex(scan: VaultScanner().scan(root: root),
                          read: { try file.read(relativePath: $0) })
        return index
    }

    // MARK: - The incident

    /// THE REGRESSION TEST. Both wordings of the question the phone was asked, over a
    /// corpus where one live note is denser in "birthday" than the answer and two archived
    /// notes are about a birthday trip: the note that answers it comes FIRST.
    func testAFirstPersonQuestionRetrievesTheOwnersOwnLiveNoteFirst() async throws {
        let index = try indexedCorpus()
        let retriever = VaultRetriever(index: index,
                                       ownerName: VaultOwnerRetrievalFixture.ownerName)

        for question in [VaultOwnerRetrievalFixture.question,
                         VaultOwnerRetrievalFixture.plainQuestion] {
            let result = await retriever.retrieve(question: question,
                                                  budget: .forMeasuredPrompt(nil))
            let paths = result.chunks.map(\.path)
            XCTAssertEqual(paths.first, VaultOwnerRetrievalFixture.answer,
                           "\(question) retrieved \(paths)")
            // And every archived note is behind every live one, which is the other half
            // of the fix and the half a reordering would quietly undo.
            let firstArchived = paths.firstIndex(where: { VaultRetriever.isArchived($0) })
            let lastLive = paths.lastIndex(where: { !VaultRetriever.isArchived($0) })
            if let firstArchived, let lastLive {
                XCTAssertLessThan(lastLive, firstArchived,
                                  "\(question) interleaved archived notes: \(paths)")
            }
        }
    }

    /// The whole path, with a stub generator: the answer cites the live note, and neither
    /// archived note is what it was read from.
    func testTheAnsweredReplyCitesTheLiveNote() async throws {
        let index = try indexedCorpus()
        let retrieved = await VaultRetriever(index: index,
                                            ownerName: VaultOwnerRetrievalFixture.ownerName)
            .retrieve(question: VaultOwnerRetrievalFixture.question,
                      budget: .forMeasuredPrompt(nil))
        let outcome = await VaultAnswerer(generator: FirstChunkGeneration())
            .answer(question: VaultOwnerRetrievalFixture.question, chunks: retrieved.chunks)

        let answer = try XCTUnwrap(outcome.answer, "outcome was \(outcome.label)")
        XCTAssertEqual(answer.citations.map(\.path), [VaultOwnerRetrievalFixture.answer])
        XCTAssertTrue(answer.text.contains("Sep 4"), answer.text)
    }

    // MARK: - The owner's name, on its own

    func testAFirstPersonQuestionCarriesTheOwnersNameToTheIndex() {
        XCTAssertEqual(LookupQuery.keywords("What is my birthday?", ownerName: "Jeremy"),
                       ["birthday", "Jeremy"])
        XCTAssertEqual(LookupQuery.keywords("When was I born?", ownerName: "Jeremy"),
                       ["born", "Jeremy"])
        XCTAssertEqual(LookupQuery.keywords("What's my birthday?", ownerName: "Jeremy"),
                       ["birthday", "Jeremy"])
        XCTAssertEqual(LookupQuery.keywords("Which doctor did I see?", ownerName: "Jeremy"),
                       ["doctor", "see", "Jeremy"])
    }

    /// A question about somebody else is untouched, and so is the name when the question
    /// already says it.
    func testAQuestionAboutSomebodyElseIsNotAboutTheOwner() {
        XCTAssertEqual(LookupQuery.keywords("When is Marta's birthday?", ownerName: "Jeremy"),
                       ["Marta's", "birthday"])
        XCTAssertEqual(LookupQuery.keywords("When is Jeremy's birthday?", ownerName: "Jeremy"),
                       ["Jeremy's", "birthday"])
        XCTAssertEqual(LookupQuery.keywords("What is my birthday?", ownerName: "jeremy"),
                       ["birthday", "jeremy"])
    }

    /// NO NAME, NO CHANGE. The one property that keeps this safe to ship to a device whose
    /// owner never filled the field in.
    func testWithoutAnOwnerNameNothingChanges() {
        for name in [nil, "", "   "] as [String?] {
            XCTAssertEqual(LookupQuery.keywords("What is my birthday?", ownerName: name),
                           ["birthday"], "owner name \(String(describing: name))")
        }
        XCTAssertEqual(LookupQuery.keywords("What is my birthday?"), ["birthday"])
    }

    /// A phone types a curly apostrophe, and `I’m` has to read as first person.
    func testACurlyApostropheIsStillFirstPerson() {
        XCTAssertTrue(LookupQuery.isFirstPerson("What’s my birthday?"))
        XCTAssertTrue(LookupQuery.isFirstPerson("I’ve been to which clinics?"))
        XCTAssertTrue(LookupQuery.isFirstPerson("When was I born?"))
        XCTAssertFalse(LookupQuery.isFirstPerson("When is Marta's birthday?"))
        XCTAssertFalse(LookupQuery.isFirstPerson("Which myth did we read?"),
                       "a word that BEGINS with a pronoun is not one")
        XCTAssertFalse(LookupQuery.isFirstPerson("What is the mineral in it?"))
    }

    /// A contraction of a stop word is a stop word; a possessive of a real word is not.
    func testAContractedQuestionWordCarriesNoMoreSignalThanTheWordItself() {
        XCTAssertEqual(LookupQuery.keywords("What's the studio rent?"), ["studio", "rent"])
        XCTAssertEqual(LookupQuery.keywords("When's the boiler service?"),
                       ["boiler", "service"])
        XCTAssertEqual(LookupQuery.keywords("Who's the landlord?"), ["landlord"])
        XCTAssertEqual(LookupQuery.keywords("What is Marta's number?"),
                       ["Marta's", "number"])
    }

    /// The name matches the possessive the vault actually writes, through FTS5's own
    /// tokenizer rather than through a special case here.
    func testTheOwnersNameFindsThePossessiveFormInANote() throws {
        let index = try indexedCorpus()
        let expression = try XCTUnwrap(VaultSearchQuery.matchExpression("birthday Jeremy"))
        let paths = index.search(expression: expression, limit: 10).map(\.path)
        XCTAssertTrue(paths.contains(VaultOwnerRetrievalFixture.answer),
                       "`Jeremy` must match `Jeremy's Birthday`, got \(paths)")
        XCTAssertFalse(paths.contains(VaultOwnerRetrievalFixture.liveDistractor),
                       "a note that names nobody must not match the name")
    }

    // MARK: - Archived notes

    func testAnArchiveDirectoryAnywhereInThePathIsArchived() {
        XCTAssertTrue(VaultRetriever.isArchived("Projects/drafts/archive/2026-06-26-List.md"))
        XCTAssertTrue(VaultRetriever.isArchived("Projects/Research/archive/2026-05-26-Notes.md"))
        XCTAssertTrue(VaultRetriever.isArchived("Projects/drafts/archive/old/2025-01-01-Old.md"))
        XCTAssertTrue(VaultRetriever.isArchived("Archive/2026-01-01-Note.md"))
        XCTAssertFalse(VaultRetriever.isArchived("Projects/Archive-Policy.md"),
                       "a FILE named after the archive is not in it")
        XCTAssertFalse(VaultRetriever.isArchived("Workshop/archive.md"))
        XCTAssertFalse(VaultRetriever.isArchived("Family/Key-Dates.md"))
    }

    /// Demoted, never excluded: an archived note still comes back when it is all there is.
    func testAnArchivedNoteIsStillRetrievedWhenNothingLiveMatches() async throws {
        let index = try indexedCorpus()
        let retriever = VaultRetriever(index: index,
                                       ownerName: VaultOwnerRetrievalFixture.ownerName)
        let result = await retriever.retrieve(question: "What is the packing list?",
                                              budget: .forMeasuredPrompt(nil))
        XCTAssertEqual(result.chunks.first?.path, VaultOwnerRetrievalFixture.archivedDraft,
                       "got \(result.chunks.map(\.path))")
    }

    /// The ordering itself, stated over hits rather than inferred from a corpus: archived
    /// behind live, and the order WITHIN each group untouched.
    func testArchivedHitsAreDemotedAndEachGroupKeepsItsOrder() async throws {
        let index = try indexedCorpus()
        let retriever = VaultRetriever(index: index,
                                       ownerName: VaultOwnerRetrievalFixture.ownerName)
        let result = await retriever.retrieve(question: "What is the birthday lunch?",
                                              budget: VaultRetrievalBudget(chunkCount: 4,
                                                                           totalCharacters: 12_000))
        let paths = result.chunks.map(\.path)
        let archived = paths.filter { VaultRetriever.isArchived($0) }
        let live = paths.filter { !VaultRetriever.isArchived($0) }
        XCTAssertFalse(archived.isEmpty, "the corpus has archived matches: \(paths)")
        XCTAssertFalse(live.isEmpty, "the corpus has live matches: \(paths)")
        XCTAssertEqual(paths, live + archived, "archived notes must all come last")
    }
}
