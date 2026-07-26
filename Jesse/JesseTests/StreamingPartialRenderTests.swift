import XCTest
@testable import Jesse

/// The invariant that lets the streaming partial reply hold NO clock.
///
/// The defect: `StreamingPartialText` rendered inside
/// `TimelineView(.animation(minimumInterval: 0.1, paused: !running))`, so it kept a
/// display-link subscription alive for the whole turn — measured at roughly 20 interrupt
/// wakeups/second on top of the send button's, while a turn sat in tool use emitting no
/// text at all.
///
/// That clock only ever existed to service a parse the renderer's cadence cap had
/// suppressed. Whether a parse WAS suppressed is answerable directly, via `hasRendered`,
/// so the view can arm one catch-up re-render instead of ticking forever on the chance.
/// These tests pin the two halves of that:
///  * `hasRendered` is exactly "the cached blocks came from this text", and
///  * a publish suppressed by the cap is reported as not-rendered and does land on the
///    next evaluation past the cooldown — so a stranded tail is impossible without a clock.
@MainActor
final class StreamingPartialRenderTests: XCTestCase {

    func testHasRenderedTracksWhatTheCacheWasParsedFrom() {
        let r = MarkdownStreamRenderer(interval: 0.1)
        let base = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertFalse(r.hasRendered("hello"), "nothing parsed yet")
        _ = r.blocks(for: "hello", now: base)
        XCTAssertTrue(r.hasRendered("hello"), "that text is on screen")
        XCTAssertFalse(r.hasRendered("hello there"), "a newer text is not")
    }

    /// The tail case that used to need the clock: `flushPartial` publishes the last chunk
    /// immediately, which can land inside the renderer's cooldown. The renderer serves the
    /// previous text — and `hasRendered` says so, which is the signal the view acts on.
    func testAPublishInsideTheCooldownIsReportedAsNotRendered() {
        let r = MarkdownStreamRenderer(interval: 0.1)
        let base = Date(timeIntervalSinceReferenceDate: 0)

        _ = r.blocks(for: "partial", now: base)
        // The tail arrives 10ms later — well inside the 100ms cap.
        let served = r.blocks(for: "partial tail", now: base.addingTimeInterval(0.01))

        XCTAssertEqual(served, parseMarkdownBlocks("partial"),
                       "the cap served the older text")
        XCTAssertFalse(r.hasRendered("partial tail"),
                       "so the view knows a catch-up is owed — without a running clock")
    }

    /// …and the catch-up lands. One re-evaluation past the cooldown is all it takes, which
    /// is exactly what the view's single `.task` provides.
    func testTheCatchUpEvaluationRendersTheSuppressedTail() {
        let r = MarkdownStreamRenderer(interval: 0.1)
        let base = Date(timeIntervalSinceReferenceDate: 0)

        _ = r.blocks(for: "partial", now: base)
        _ = r.blocks(for: "partial tail", now: base.addingTimeInterval(0.01))
        let after = r.blocks(for: "partial tail", now: base.addingTimeInterval(0.11))

        XCTAssertEqual(after, parseMarkdownBlocks("partial tail"),
                       "the tail is on screen after one catch-up evaluation")
        XCTAssertTrue(r.hasRendered("partial tail"),
                      "and nothing further is owed, so no second catch-up is armed")
    }

    /// The common case must cost nothing: `RunCoordinator` already publishes `partialText`
    /// no more often than `MarkdownStreamRenderer.interval`, so a publish parses on the
    /// evaluation it triggers and no catch-up is armed at all.
    func testPublishesAtTheCoalescedCadenceNeverOweACatchUp() {
        let r = MarkdownStreamRenderer(interval: MarkdownStreamRenderer.interval)
        let base = Date(timeIntervalSinceReferenceDate: 0)
        var text = ""

        for i in 0..<20 {
            text += "chunk\(i) "
            let at = base.addingTimeInterval(Double(i) * MarkdownStreamRenderer.interval)
            _ = r.blocks(for: text, now: at)
            XCTAssertTrue(r.hasRendered(text),
                          "publish \(i) rendered immediately — no timer needed")
        }
    }

    /// Unchanged text (a body re-evaluation for some other reason: a new turn, the activity
    /// line, a scroll) never re-parses and never owes a catch-up either.
    func testUnchangedTextNeitherReParsesNorArmsACatchUp() {
        var parses = 0
        let r = MarkdownStreamRenderer(interval: 0.1) { text in
            parses += 1
            return parseMarkdownBlocks(text)
        }
        let base = Date(timeIntervalSinceReferenceDate: 0)
        _ = r.blocks(for: "steady", now: base)
        for i in 1...50 {
            _ = r.blocks(for: "steady", now: base.addingTimeInterval(Double(i)))
            XCTAssertTrue(r.hasRendered("steady"))
        }
        XCTAssertEqual(parses, 1, "50 re-evaluations of the same text cost one parse")
    }
}
