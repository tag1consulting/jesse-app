import XCTest
@testable import JesseVault

// WHERE A REVIEW REQUEST GOES, AND WHAT IT SAYS WHEN IT GETS THERE.
//
// Two destinations, one sentence, and the sentence is the part worth pinning: the agent's
// routine keys off it, so a reword here is a behaviour change on the Studio rather than a
// tidy-up. Both paths are asserted against the same fixed string.

/// A capture that records rather than writes.
@MainActor
private final class FakeCapture: VaultInboxCapturing {
    var offered: InboxCaptureOffer = .hidden
    var asked: [BridgeReachabilityState] = []
    var captures: [(text: String, about: String?)] = []
    var failure: InboxCaptureFailure?

    func offer(reachability: BridgeReachabilityState) -> InboxCaptureOffer {
        asked.append(reachability)
        return offered
    }

    func capture(_ text: String,
                 about: String?) async -> Result<InboxCaptureWrite, InboxCaptureFailure> {
        captures.append((text, about))
        if let failure { return .failure(failure) }
        return .success(InboxCaptureWrite(relativePath: "Inbox/2026-09-25-Phone.md",
                                         entry: text, createdFile: false,
                                         bytesAppended: text.utf8.count,
                                         checksum: "abc", fileBytes: 400))
    }
}

@MainActor
final class VaultAnnotationReviewTests: XCTestCase {

    private let path = "Projects/Tag1/Kiln.md"

    private func action(_ state: BridgeReachabilityState,
                        started: @escaping @MainActor (String) -> Void) -> VaultReviewAction {
        VaultReviewAction(reachability: { state }, start: started)
    }

    // MARK: - The sentence

    func testTheSentenceNamesTheNoteAndNothingElse() {
        XCTAssertEqual(VaultAnnotationReview.sentence(path: path),
                       "Review my annotations in Projects/Tag1/Kiln.md")
    }

    // MARK: - The rule

    func testTheVaultTakesItOnlyWhenACaptureIsOffered() {
        XCTAssertEqual(VaultAnnotationReview.destination(offer: .offered,
                                                         canStartConversation: true),
                       .capture)
        XCTAssertEqual(VaultAnnotationReview.destination(offer: .hidden,
                                                         canStartConversation: true),
                       .conversation)
    }

    /// No shell wired a conversation opener: the request goes to the vault rather than
    /// nowhere, because a button that silently did nothing is the worse failure.
    func testWithNoOpenerTheRequestStillLands() {
        XCTAssertEqual(VaultAnnotationReview.destination(offer: .hidden,
                                                         canStartConversation: false),
                       .capture)
    }

    // MARK: - Doing it

    func testAReachableBridgeStartsAConversationWithTheFixedSentence() async {
        let capture = FakeCapture()
        capture.offered = .hidden
        var started: [String] = []
        let model = VaultNoteReviewModel(capture: capture)

        await model.send(path: path, review: action(.reachable) { started.append($0) })

        XCTAssertEqual(started, ["Review my annotations in Projects/Tag1/Kiln.md"])
        XCTAssertEqual(capture.captures.count, 0, "nothing is written to the vault")
        XCTAssertEqual(capture.asked, [.reachable])
        XCTAssertEqual(model.destination, .conversation)
        XCTAssertEqual(model.status, VaultAnnotationReview.sentStatus)
        XCTAssertNil(model.badge)
    }

    func testAnUnreachableBridgeCapturesTheSentenceAgainstTheNote() async {
        let capture = FakeCapture()
        capture.offered = .offered
        var started: [String] = []
        let model = VaultNoteReviewModel(capture: capture)

        await model.send(path: path, review: action(.unreachable) { started.append($0) })

        XCTAssertTrue(started.isEmpty, "an unreachable bridge is not asked for a conversation")
        XCTAssertEqual(capture.captures.count, 1)
        XCTAssertEqual(capture.captures.first?.text,
                       "Review my annotations in Projects/Tag1/Kiln.md")
        XCTAssertEqual(capture.captures.first?.about, path)
        XCTAssertEqual(model.destination, .capture)
        XCTAssertEqual(model.status, VaultAnnotationReview.queuedStatus)
        XCTAssertEqual(model.badge, InboxCaptureReply.badge(path: "Inbox/2026-09-25-Phone.md"))
    }

    /// A cold launch has not probed yet. It goes to the bridge, for the reason the capture
    /// offer is not made there either: the Studio is probably fine.
    func testAnUnknownReachabilityStartsAConversation() async {
        let capture = FakeCapture()
        var started: [String] = []
        let model = VaultNoteReviewModel(capture: capture)

        await model.send(path: path, review: action(.unknown) { started.append($0) })

        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(model.destination, .conversation)
    }

    func testWithNoActionAtAllTheSentenceIsCaptured() async {
        let capture = FakeCapture()
        let model = VaultNoteReviewModel(capture: capture)

        await model.send(path: path, review: nil)

        XCTAssertEqual(capture.captures.first?.text,
                       "Review my annotations in Projects/Tag1/Kiln.md")
        XCTAssertEqual(model.status, VaultAnnotationReview.queuedStatus)
    }

    /// A capture that could not be written says why, in the failure's own words, rather
    /// than claiming it was queued.
    func testAFailedCaptureReportsItsOwnReason() async {
        let capture = FakeCapture()
        capture.offered = .offered
        capture.failure = .noFolder
        let model = VaultNoteReviewModel(capture: capture)

        await model.send(path: path, review: action(.unreachable) { _ in })

        XCTAssertEqual(model.status, InboxCaptureFailure.noFolder.description)
        XCTAssertNil(model.badge)
    }
}
