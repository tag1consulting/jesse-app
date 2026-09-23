import XCTest
@testable import JesseVault

// What hosted Claude is told about what the device said while it was away.

final class OfflineAnswerCarryTests: XCTestCase {

    private func pair(_ question: String, _ answer: String, minutesAgo: Int,
                      paths: [String] = ["A.md"]) -> OfflineAnswerPair {
        OfflineAnswerPair(question: question, answer: answer, paths: paths,
                          at: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60))
    }

    func testNoPairsCarryNothing() {
        XCTAssertNil(OfflineAnswerCarry.body([]))
    }

    func testTheCarryIsFramedAsARecordRatherThanAnInstruction() {
        let body = OfflineAnswerCarry.body([pair("when is the concert", "Thursday 14 May",
                                                 minutesAgo: 5)])
        let text = try! XCTUnwrap(body)
        XCTAssertTrue(text.hasPrefix(OfflineAnswerCarry.preamble))
        XCTAssertTrue(text.contains("not instruction"))
        XCTAssertTrue(text.contains("Q: when is the concert"))
        XCTAssertTrue(text.contains("A: Thursday 14 May"))
        XCTAssertTrue(text.contains("from: A.md"))
    }

    func testPairsAreRenderedOldestFirst() {
        let body = try! XCTUnwrap(OfflineAnswerCarry.body([
            pair("second", "b", minutesAgo: 1),
            pair("first", "a", minutesAgo: 10),
        ]))
        let firstIndex = try! XCTUnwrap(body.range(of: "Q: first")).lowerBound
        let secondIndex = try! XCTUnwrap(body.range(of: "Q: second")).lowerBound
        XCTAssertLessThan(firstIndex, secondIndex)
    }

    /// Over budget, the OLDEST go: the follow-up about to be sent is about the newest
    /// exchange, and that is the one that must survive.
    func testTheCapDropsTheOldestPairsAndKeepsTheNewest() {
        let pairs = (0..<40).map { index in
            pair("question number \(index)", String(repeating: "answer ", count: 20),
                 minutesAgo: 100 - index)
        }
        let body = try! XCTUnwrap(OfflineAnswerCarry.body(pairs))
        XCTAssertLessThanOrEqual(body.count, OfflineAnswerCarry.maxCharacters)
        XCTAssertTrue(body.contains("question number 39"), "the newest must survive")
        XCTAssertFalse(body.contains("question number 0"), "the oldest must be dropped")
    }

    func testTheShippedCapIsThreeThousandCharacters() {
        XCTAssertEqual(OfflineAnswerCarry.maxCharacters, 3_000)
    }

    // MARK: - The ledger

    @MainActor
    func testAThreadCarriesItsPairsOnceAndNeverAgain() {
        let ledger = OfflineAnswerLedger()
        let thread = UUID()
        ledger.record(threadID: thread,
                      pair: pair("when is the concert", "Thursday", minutesAgo: 1))
        XCTAssertEqual(ledger.uncarried(threadID: thread).count, 1)
        XCTAssertNotNil(ledger.carryBody(threadID: thread))

        ledger.markCarried(threadID: thread)
        XCTAssertTrue(ledger.uncarried(threadID: thread).isEmpty)
        XCTAssertNil(ledger.carryBody(threadID: thread))
    }

    @MainActor
    func testOneThreadsPairsNeverRideAnothersTurn() {
        let ledger = OfflineAnswerLedger()
        let a = UUID(), b = UUID()
        ledger.record(threadID: a, pair: pair("a question", "a", minutesAgo: 1))
        XCTAssertNil(ledger.carryBody(threadID: b))
        ledger.markCarried(threadID: b)
        XCTAssertEqual(ledger.uncarried(threadID: a).count, 1,
                       "marking one thread carried must not spend another's")
    }
}
