import XCTest
@testable import JesseNetworking

/// The transcript's whole-answer progress row: when it shows, and how the model shape it keys
/// off is remembered. There is no non-streaming harness to run against — the bridge guard
/// `every_registered_harness_streams_until_a_client_can_render_one_that_does_not` keeps it that
/// way until the mid-turn event contract is designed — so the rendering is exercised against a
/// `streamsText: false` fixture, which is exactly what the client would see from one.
final class WholeAnswerProgressTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NonStreamingModelStore.reset()
    }

    override func tearDown() {
        NonStreamingModelStore.reset()
        super.tearDown()
    }

    private func model(_ id: String, streamsText: Bool) -> ModelInfo {
        ModelInfo(id: id, label: id, kind: "hosted", available: true, writesAllowed: false,
                  streamsText: streamsText)
    }

    // MARK: - The policy

    func testShowsForAWholeAnswerTurnWithNothingElseOnScreen() {
        XCTAssertTrue(WholeAnswerProgress.shouldShow(
            isRunning: true, streamsText: false, partialText: nil, activity: nil))
        XCTAssertTrue(WholeAnswerProgress.shouldShow(
            isRunning: true, streamsText: false, partialText: "", activity: nil))
    }

    func testNeverShowsForAStreamingModel() {
        // A streaming model's brief gap before the first delta is left exactly as it was.
        XCTAssertFalse(WholeAnswerProgress.shouldShow(
            isRunning: true, streamsText: true, partialText: nil, activity: nil))
    }

    func testNeverShowsWhenNotRunning() {
        XCTAssertFalse(WholeAnswerProgress.shouldShow(
            isRunning: false, streamsText: false, partialText: nil, activity: nil))
    }

    func testYieldsToTheActivityLineSoThereIsNeverASecondSpinner() {
        XCTAssertFalse(WholeAnswerProgress.shouldShow(
            isRunning: true, streamsText: false, partialText: nil,
            activity: "Reading the vault…"))
    }

    func testYieldsAsSoonAsAnyTextArrives() {
        // Belt and braces: a whole-answer harness pushes no deltas, but if one ever did, the
        // row must get out of the way rather than sit under the text.
        XCTAssertFalse(WholeAnswerProgress.shouldShow(
            isRunning: true, streamsText: false, partialText: "Here is", activity: nil))
    }

    func testCaptionDoesNotClaimProgressItCannotKnow() {
        // There is no mid-turn signal from a whole-answer harness, so the caption describes the
        // model's shape rather than inventing a step. Guards against it drifting into a lie
        // like "Reading…" that nothing actually reports.
        XCTAssertEqual(WholeAnswerProgress.caption, "Working… this model replies all at once")
    }

    // MARK: - The store

    func testUnknownModelsStreamMatchingTheWireDefault() {
        XCTAssertTrue(NonStreamingModelStore.streamsText(id: "never-heard-of-it"))
        XCTAssertTrue(NonStreamingModelStore.streamsText(id: nil))
        XCTAssertTrue(NonStreamingModelStore.streamsText(id: ""))
    }

    func testRecordsOnlyTheNonStreamingIDs() {
        NonStreamingModelStore.record(ModelSwitchState(active: "opus", models: [
            model("opus", streamsText: true),
            model("codex", streamsText: false),
        ]))
        XCTAssertFalse(NonStreamingModelStore.streamsText(id: "codex"))
        XCTAssertTrue(NonStreamingModelStore.streamsText(id: "opus"))
    }

    func testALaterListIsAuthoritativeSoAModelCanStopBeingRemembered() {
        NonStreamingModelStore.record(ModelSwitchState(active: "opus", models: [
            model("codex", streamsText: false),
        ]))
        XCTAssertFalse(NonStreamingModelStore.streamsText(id: "codex"))
        // The same model now reports that it streams: the record must not be sticky.
        NonStreamingModelStore.record(ModelSwitchState(active: "opus", models: [
            model("codex", streamsText: true),
        ]))
        XCTAssertTrue(NonStreamingModelStore.streamsText(id: "codex"),
                      "a refreshed list must replace the record, not merge into it")
    }

    func testAnAllStreamingListClearsTheRecordEntirely() {
        NonStreamingModelStore.record(ModelSwitchState(active: "opus", models: [
            model("codex", streamsText: false),
        ]))
        NonStreamingModelStore.record(ModelSwitchState(active: "opus", models: [
            model("opus", streamsText: true),
        ]))
        XCTAssertTrue(NonStreamingModelStore.streamsText(id: "codex"))
    }
}

/// THE MID-TURN VIEW OF A WHOLE-ANSWER TURN. A model that delivers its answer whole pushes
/// no deltas, so the activity line is not a garnish here — it is the only thing on screen
/// that distinguishes a turn doing work from a turn that has silently hung.
///
/// COUPLED WITH `ToolActivity` in `bridge/src/jobstore/streams.rs` and the mid-turn event
/// contract at the top of `bridge/src/harness/mod.rs`: the vocabulary asserted below is the
/// one the Codex parser emits.
final class ToolActivityRenderingTests: XCTestCase {

    /// The vocabulary a Codex turn actually produces, rendered.
    func testTheCodexVocabularyRendersAsProse() {
        XCTAssertEqual(ToolActivity(name: "Bash").displayLabel, "Running a command…")
        XCTAssertEqual(ToolActivity(name: "Edit").displayLabel, "Writing a file…")
        XCTAssertEqual(ToolActivity(name: "Read").displayLabel, "Reading the vault…")
    }

    /// An MCP tool is `mcp__<server>__<tool>` on the wire — a routing key, not a thing to
    /// show anyone. A Read-level Codex turn's visible work is mostly qmd calls, so without
    /// this most of the turn would read `Using mcp__qmd__query…`.
    func testAnMCPToolIsNamedByItsServerNotItsRoutingKey() {
        XCTAssertEqual(ToolActivity(name: "mcp__qmd__query").displayLabel, "Using qmd…")
        XCTAssertEqual(ToolActivity(name: "mcp__qmd__status").displayLabel, "Using qmd…")
        // Malformed rather than crashing: an unrecognised shape shows verbatim.
        XCTAssertEqual(ToolActivity(name: "mcp__").displayLabel, "Using mcp__…")
    }

    /// A REFUSED call must never render as the thing it failed to do. "Writing a file…"
    /// while the sandbox refuses every write states something that did not happen.
    func testARefusedCallNeverReadsAsTheActionSucceeding() {
        let refused = ToolActivity(name: "Write", refused: true)
        XCTAssertEqual(refused.displayLabel, "Blocked from writing a file…")
        XCTAssertNotEqual(refused.displayLabel, ToolActivity(name: "Write").displayLabel)
        XCTAssertEqual(ToolActivity(name: "Bash", refused: true).displayLabel,
                       "Blocked from running a command…")
    }

    /// `refused` is OMITTED from the wire when false, so an activity frame from a bridge
    /// that predates the field decodes exactly as it always did.
    func testAnActivityFrameWithoutTheRefusedFieldDecodesAsNotRefused() {
        XCTAssertEqual(SSEParser.decodeStreamFrame(event: "activity", data: #"{"name":"Bash"}"#),
                       .activity(ToolActivity(name: "Bash", refused: false)))
        XCTAssertEqual(
            SSEParser.decodeStreamFrame(event: "activity",
                                        data: #"{"name":"Write","refused":true}"#),
            .activity(ToolActivity(name: "Write", refused: true)))
    }

    /// The standing progress row is the FLOOR, not the whole view: it covers the gap before
    /// the first activity frame and yields the moment one arrives, so there is never a
    /// second spinner and never a caption contradicting the line beside it.
    func testTheStandingRowYieldsToRealActivity() {
        XCTAssertTrue(WholeAnswerProgress.shouldShow(
            isRunning: true, streamsText: false, partialText: nil, activity: nil),
            "before any activity, the row is the only sign of life")
        XCTAssertFalse(WholeAnswerProgress.shouldShow(
            isRunning: true, streamsText: false, partialText: nil,
            activity: ToolActivity(name: "Bash").displayLabel),
            "once the turn reports what it is doing, the generic row steps aside")
    }
}
