import XCTest
@testable import JesseVault

// THE RETRIEVAL FLOOR.
//
// Everything else in this suite asserts a mechanism. This asserts the OUTCOME the whole
// feature stands on: for twelve ordinary questions, over a corpus of twenty notes that
// share vocabulary with each other, the note that actually answers the question is among
// the handful put in front of the model.
//
// It is a floor, not a benchmark. Twelve of twelve is the passing bar because the corpus
// is small and invented; what it catches is a regression — a tokenizer change, a fusion
// change, an exclusion that starts eating real notes — turning "answers with a citation"
// into "abstains" without anybody noticing until the phone is in the air.
//
// Run with NO EMBEDDING, deliberately. The sentence embedding is not present on every
// machine this suite runs on, and a floor whose result depends on whether an optional
// system asset happens to be installed is not a floor. The fusion is exercised with a
// scripted embedding in `VaultRetrieverTests`.
final class VaultRetrievalFloorTests: XCTestCase {

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

    func testEveryExpectedNoteIsAmongTheChunksRetrieved() async throws {
        VaultRetrievalFixture.write(in: root)
        let index = try VaultIndex(
            url: VaultIndex.databaseURL(forRoot: root, in: databaseDirectory))
        let file = VaultFile(root: root)
        try index.reindex(scan: VaultScanner().scan(root: root),
                          read: { try file.read(relativePath: $0) })

        let retriever = VaultRetriever(index: index)
        let budget = VaultRetrievalBudget.forMeasuredPrompt(nil)

        var missed: [String] = []
        for testCase in VaultRetrievalFixture.cases {
            let result = await retriever.retrieve(question: testCase.question,
                                                  budget: budget)
            let paths = result.chunks.map(\.path)
            XCTAssertFalse(paths.contains { $0.hasPrefix("Inbox/") },
                           "\(testCase.question) retrieved from Inbox/")
            if !paths.contains(testCase.expectedPath) {
                missed.append("\(testCase.question) -> expected \(testCase.expectedPath), got \(paths)")
            }
        }
        XCTAssertEqual(missed, [], "retrieval floor: \(missed.count) of "
                       + "\(VaultRetrievalFixture.cases.count) questions missed")
    }
}
