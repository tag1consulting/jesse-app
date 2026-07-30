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
