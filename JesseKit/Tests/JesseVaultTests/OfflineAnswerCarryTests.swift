import XCTest
@testable import JesseVault

// What hosted Claude is told about what the device did while it was away.

final class OfflineAnswerCarryTests: XCTestCase {

    private func pair(_ question: String, _ answer: String, minutesAgo: Int,
                      paths: [String] = ["A.md"]) -> OfflineAnswerPair {
        OfflineAnswerPair(question: question, answer: answer, paths: paths,
                          at: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60))
    }

    func testNoPairsCarryNothing() {
        XCTAssertNil(OfflineAnswerCarry.body([]))
    }

    /// THE FRAMING IS THE FIX. The old preamble said "not instruction and not verified
    /// fact" about the whole block, which told hosted Claude that Jeremy's own request to
    /// log two coffees was inert data. The review has to open by saying what it is and
    /// then ask for all three things, in order.
    func testTheBodyOpensWithTheReviewFramingAndNamesAllThreeAsks() {
        let text = try! XCTUnwrap(
            OfflineAnswerCarry.body([pair("when is the concert", "Thursday 14 May",
                                          minutesAgo: 5)]))
        XCTAssertTrue(text.hasPrefix(OfflineAnswerCarry.preamble))
        let opening = try! XCTUnwrap(text.split(separator: "\n").first)
        XCTAssertTrue(opening.contains("review"), opening.description)
        XCTAssertTrue(opening.contains("audit"), opening.description)
        XCTAssertTrue(text.contains("not a new message from Jeremy"))

        // The three asks, each present and in this order.
        let act = try! XCTUnwrap(text.range(of: "1. ACT.")).lowerBound
        let audit = try! XCTUnwrap(text.range(of: "2. AUDIT.")).lowerBound
        let improve = try! XCTUnwrap(text.range(of: "3. IMPROVE.")).lowerBound
        XCTAssertLessThan(act, audit)
        XCTAssertLessThan(audit, improve)

        // And each ask says which half of an exchange it is about, so the two cannot be
        // confused: the questions are Jeremy's and must be acted on, the answers are a
        // small model's and must not be believed.
        XCTAssertTrue(text.contains("Q: lines are Jeremy's own words"))
        XCTAssertTrue(text.contains("A: lines are an unverified answer"))
        XCTAssertTrue(text.contains("coding-agent prompt"))
        XCTAssertTrue(text.contains("one short line"),
                      "a review with nothing in it must not produce a report")

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

    /// Over budget, the OLDEST go: the most recent exchange is the one most likely to
    /// still need acting on.
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

    /// The preamble is spent out of the same budget, so a review that could not fit even
    /// one exchange would be a preamble with nothing under it. It has to leave room.
    func testThePreambleLeavesRoomForRealExchanges() {
        XCTAssertLessThan(OfflineAnswerCarry.preamble.count,
                          OfflineAnswerCarry.maxCharacters / 2,
                          "the framing must not eat the review")
    }

    // MARK: - How the pairs are stored

    /// The pairs are the truth and the text is rendered from them, so they have to survive
    /// a round trip through the blob a review carries — that is what lets a second offline
    /// answer be APPENDED to a review already staged instead of staging a second one.
    func testThePairsSurviveTheBlobThatCarriesThem() {
        let pairs = [pair("first", "a", minutesAgo: 10), pair("second", "b", minutesAgo: 1)]
        let blob = try! XCTUnwrap(OfflineAnswerCarry.encode(pairs))
        XCTAssertEqual(OfflineAnswerCarry.decode(blob), pairs)
        XCTAssertEqual(OfflineAnswerCarry.body(OfflineAnswerCarry.decode(blob)),
                       OfflineAnswerCarry.body(pairs))
    }

    func testAnEmptyOrUnreadableBlobIsAnEmptyReviewRatherThanAnError() {
        XCTAssertNil(OfflineAnswerCarry.encode([]))
        XCTAssertTrue(OfflineAnswerCarry.decode(nil).isEmpty)
        XCTAssertTrue(OfflineAnswerCarry.decode(Data("not json".utf8)).isEmpty)
    }

    func testDecodeOrdersOldestFirstWhateverOrderItWasWrittenIn() {
        let newest = pair("second", "b", minutesAgo: 1)
        let oldest = pair("first", "a", minutesAgo: 10)
        let blob = try! XCTUnwrap(OfflineAnswerCarry.encode([newest, oldest]))
        XCTAssertEqual(OfflineAnswerCarry.decode(blob).map(\.question), ["first", "second"])
    }

    // MARK: - The Mac's durable queue

    func testAThreadsPendingReviewSurvivesAndAppends() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "offline-review-\(UUID())"))
        let key = "vault.offlineReview.test.\(UUID())"
        let store = PendingOfflineReviewStore(defaults: defaults, key: key)
        let thread = UUID()

        XCTAssertTrue(store.pairs(threadID: thread).isEmpty)
        store.append(pair("first", "a", minutesAgo: 10), threadID: thread)
        store.append(pair("second", "b", minutesAgo: 1), threadID: thread)

        // A SECOND store over the same suite is what a relaunch looks like.
        let reopened = PendingOfflineReviewStore(defaults: defaults, key: key)
        XCTAssertEqual(reopened.pairs(threadID: thread).map(\.question), ["first", "second"])

        reopened.clear(threadID: thread)
        XCTAssertTrue(PendingOfflineReviewStore(defaults: defaults, key: key)
            .pairs(threadID: thread).isEmpty)
    }

    func testOneThreadsPendingReviewIsNeverAnothersReview() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "offline-review-\(UUID())"))
        let key = "vault.offlineReview.test.\(UUID())"
        let store = PendingOfflineReviewStore(defaults: defaults, key: key)
        let a = UUID(), b = UUID()

        store.append(pair("a question", "a", minutesAgo: 1), threadID: a)
        XCTAssertTrue(store.pairs(threadID: b).isEmpty)
        store.clear(threadID: b)
        XCTAssertEqual(store.pairs(threadID: a).count, 1,
                       "clearing one conversation must not spend another's")
        XCTAssertEqual(store.all.count, 1)
    }
}
