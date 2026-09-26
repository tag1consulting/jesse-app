import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking
import JesseVault

/// **The Mac's half of "nothing said offline vanishes."**
///
/// The phone stages an offline review as an `OutboxItem` and its retry schedule delivers it.
/// The Mac has no outbox at all, so what it answered while the Studio was asleep used to be an
/// in-memory pair waiting for whatever Jeremy happened to send next — and a quit lost it.
/// The exchanges are persisted now (`PendingOfflineReviewStore`) and go out by themselves the
/// moment the bridge is reachable, ahead of any message on the same conversation.
@MainActor
final class MacOfflineReviewTests: XCTestCase {

    /// The Mac's own half of a send. THE GATE IS THE REAL ONE; only the answer a passing
    /// question gets is scripted.
    @MainActor
    private final class FakeOffline: OfflineAnswering {
        var decision: OfflineSendRoute = .onDevice
        var answers: [String: VaultAnswer] = [:]

        func route(reachability: BridgeReachabilityState) -> OfflineSendRoute {
            reachability == .unreachable ? decision : .bridge
        }

        func answer(_ question: String) async -> VaultAnswerOutcome {
            if case .refused(let refusal) = LookupGate.rule(question) {
                return .unanswered(.gateRefused(refusal))
            }
            guard let found = answers[question] else { return .unanswered(.abstained) }
            return .answered(found)
        }
    }

    private final class Reach {
        var state: BridgeReachabilityState = .unreachable
    }

    private func reviewStore() throws -> PendingOfflineReviewStore {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "MacReview.\(UUID().uuidString)"))
        return PendingOfflineReviewStore(defaults: suite,
                                         key: "vault.offlineReview.test.\(UUID())")
    }

    private func coordinator(_ fake: MacFakeBridgeClient, _ offline: FakeOffline,
                             _ reach: Reach,
                             _ store: PendingOfflineReviewStore) -> MacCoordinator {
        MacCoordinator(configStore: MacTestFixtures.configured(),
                       makeClient: { _ in fake },
                       sessionDeletionStore: MacTestFixtures.deletionStore(),
                       offline: offline,
                       reviewStore: store,
                       reachability: { reach.state })
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private let born = VaultAnswer(
        text: "You were born on 4 September 1974.",
        citations: [VaultCitation(path: "Biography/Jeremy/Overview.md", line: 3)])

    // MARK: - Answered offline, persisted, nothing sent

    /// An answered exchange is on disk and NOT sent, because there is nowhere to send it. This
    /// is the state a quit used to destroy.
    func testAnAnsweredExchangeIsPersistedAndNothingIsSent() async throws {
        let context = try MacTestFixtures.context()
        let fake = MacFakeBridgeClient()
        let offline = FakeOffline()
        offline.answers["When was I born?"] = born
        let store = try reviewStore()
        let c = coordinator(fake, offline, Reach(), store)

        let thread = JesseThread(mode: .ask)
        XCTAssertTrue(c.stageAndSend(text: "When was I born?", mode: .ask, thread: thread,
                                     context: context))
        await waitUntil("the exchange to be persisted") {
            !store.pairs(threadID: thread.id).isEmpty
        }

        XCTAssertEqual(store.pairs(threadID: thread.id).map(\.question), ["When was I born?"])
        XCTAssertTrue(fake.sentTexts.isEmpty, "nothing reached a bridge that is not there")
        // A SECOND store over the same suite is what a relaunch looks like.
        XCTAssertEqual(store.pairs(threadID: thread.id).count, 1)
    }

    /// Reachability turning `.reachable` sends it, with no new message from Jeremy — and the
    /// turn is labelled rather than passed off as something he typed.
    func testTheReviewGoesByItselfWhenTheBridgeComesBack() async throws {
        let context = try MacTestFixtures.context()
        let fake = MacFakeBridgeClient()
        let offline = FakeOffline()
        offline.answers["When was I born?"] = born
        let store = try reviewStore()
        let reach = Reach()
        let c = coordinator(fake, offline, reach, store)

        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        c.stageAndSend(text: "When was I born?", mode: .ask, thread: thread, context: context)
        await waitUntil("the exchange to be persisted") {
            !store.pairs(threadID: thread.id).isEmpty
        }

        reach.state = .reachable
        c.sendPendingOfflineReviews(context: context)
        await waitUntil("the review to be sent") { !fake.sentTexts.isEmpty }

        XCTAssertEqual(fake.sentTexts.count, 1, "one review, once")
        let sent = try XCTUnwrap(fake.sentTexts.first)
        XCTAssertTrue(sent.hasPrefix(OfflineAnswerCarry.preamble),
                      "it opens with the review framing")
        XCTAssertTrue(sent.contains("Q: When was I born?"))
        XCTAssertTrue(store.pairs(threadID: thread.id).isEmpty, "spent on a durable stage")

        let turn = try XCTUnwrap(thread.turns.first { $0.contextLabel == OfflineAnswerCarry.title })
        XCTAssertTrue(turn.isUser)
        XCTAssertEqual(turn.displayText, "", "no typed half to show")
        XCTAssertEqual(turn.text, sent)

        // And a second drain sends nothing: the review was spent.
        c.sendPendingOfflineReviews(context: context)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fake.sentTexts.count, 1, "a review is never sent twice")
    }

    /// A composer send on a conversation holding a pending review delivers the REVIEW first: a
    /// follow-up ahead of the exchange it is about is the non sequitur this path exists to
    /// prevent, and the Mac has no outbox to order the two in.
    func testAnOnlineFollowUpIsDeliveredAfterTheReview() async throws {
        let context = try MacTestFixtures.context()
        let fake = MacFakeBridgeClient()
        let offline = FakeOffline()
        offline.answers["When was I born?"] = born
        let store = try reviewStore()
        let reach = Reach()
        let c = coordinator(fake, offline, reach, store)

        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        c.stageAndSend(text: "When was I born?", mode: .ask, thread: thread, context: context)
        await waitUntil("the exchange to be persisted") {
            !store.pairs(threadID: thread.id).isEmpty
        }

        reach.state = .reachable
        c.stageAndSend(text: "Un, the reply makes no sense.", mode: .ask, thread: thread,
                       context: context)
        await waitUntil("both to be sent") { fake.sentTexts.count == 2 }

        XCTAssertTrue(fake.sentTexts[0].contains("Q: When was I born?"),
                      "the review goes first: \(fake.sentTexts)")
        XCTAssertEqual(fake.sentTexts[1], "Un, the reply makes no sense.")
    }

    /// An unreachable Mac never spends a review. `finishOnDevice`'s own fall-through to the
    /// ordinary send runs while unreachable by definition, and the Mac has nothing to hold a
    /// review that fails to land.
    func testAnUnreachableSendNeverSpendsThePendingReview() async throws {
        let context = try MacTestFixtures.context()
        let fake = MacFakeBridgeClient(sendError: JesseError.timedOut("studio"))
        let offline = FakeOffline()
        offline.answers["When was I born?"] = born
        let store = try reviewStore()
        let c = coordinator(fake, offline, Reach(), store)

        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        c.stageAndSend(text: "When was I born?", mode: .ask, thread: thread, context: context)
        await waitUntil("the exchange to be persisted") {
            !store.pairs(threadID: thread.id).isEmpty
        }

        // A question the device cannot answer falls through to the ordinary send, which reaches
        // nothing. The review must still be pending afterwards.
        c.stageAndSend(text: "What did we decide about the fiber contract?", mode: .ask,
                       thread: thread, context: context)
        await waitUntil("the fall-through send to be attempted") { !fake.sentTexts.isEmpty }
        XCTAssertEqual(store.pairs(threadID: thread.id).count, 1,
                       "a review is never spent on a bridge that is not there")
        XCTAssertFalse(fake.sentTexts.contains { $0.hasPrefix(OfflineAnswerCarry.preamble) })
    }
}
