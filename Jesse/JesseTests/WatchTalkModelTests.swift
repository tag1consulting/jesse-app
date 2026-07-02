import XCTest
@testable import Jesse

/// The watch talk orchestrator, driven end to end with fakes (no mic, no
/// WatchConnectivity, no TTS). Pins the tap→record→send→reply→speak flow, the
/// unreachable "queued" path, the manual stop, and — the reason the watch answers
/// on two transports — that a reply arriving twice renders and speaks exactly once.
@MainActor
final class WatchTalkModelTests: XCTestCase {

    private final class FakeRecorder: WatchAudioRecording {
        var onFinish: ((Result<Data, Error>) -> Void)?
        private(set) var isRecording = false
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start() { isRecording = true; startCount += 1 }
        func stop() { isRecording = false; stopCount += 1 }
        /// Simulate a completed take.
        func deliver(_ result: Result<Data, Error>) { isRecording = false; onFinish?(result) }
    }

    private final class FakeSender: WatchRequestSending {
        var isReachable: Bool
        var onReply: ((WatchReply) -> Void)?
        private(set) var sent: [WatchRequest] = []
        init(reachable: Bool = true) { self.isReachable = reachable }
        func send(_ request: WatchRequest) { sent.append(request) }
        /// Simulate the phone answering.
        func reply(_ reply: WatchReply) { onReply?(reply) }
    }

    private final class FakeSpeaker: WatchSpeaking {
        private(set) var spoken: [String] = []
        func speak(_ text: String) { spoken.append(text) }
    }

    private struct Harness {
        let model: WatchTalkModel
        let recorder: FakeRecorder
        let sender: FakeSender
        let speaker: FakeSpeaker
        let hapticCount: () -> Int
    }

    private func makeHarness(reachable: Bool = true) -> Harness {
        let recorder = FakeRecorder()
        let sender = FakeSender(reachable: reachable)
        let speaker = FakeSpeaker()
        var haptics = 0
        let model = WatchTalkModel(recorder: recorder, sender: sender, speaker: speaker,
                                   haptic: { haptics += 1 })
        return Harness(model: model, recorder: recorder, sender: sender,
                       speaker: speaker, hapticCount: { haptics })
    }

    private let clip = Data([0x01, 0x02, 0x03, 0x04])

    func testTapStartsListeningAndRecording() {
        let h = makeHarness()
        XCTAssertEqual(h.model.state, .idle)
        h.model.tapTalk()
        XCTAssertEqual(h.model.state, .listening)
        XCTAssertEqual(h.recorder.startCount, 1)
    }

    func testRecordingSendsRequestAndGoesThinking() {
        let h = makeHarness(reachable: true)
        h.model.tapTalk()
        h.recorder.deliver(.success(clip))
        XCTAssertEqual(h.model.state, .thinking)
        XCTAssertEqual(h.sender.sent.count, 1)
        XCTAssertEqual(h.sender.sent.first?.audio, clip)
        XCTAssertEqual(h.sender.sent.first?.mode, .ask, "default mode is Ask")
    }

    func testTellModeIsCarriedIntoTheRequest() {
        let h = makeHarness()
        h.model.mode = .tell
        h.model.tapTalk()
        h.recorder.deliver(.success(clip))
        XCTAssertEqual(h.sender.sent.first?.mode, .tell)
    }

    func testUnreachableGoesQueuedButStillSends() {
        let h = makeHarness(reachable: false)
        h.model.tapTalk()
        h.recorder.deliver(.success(clip))
        XCTAssertEqual(h.model.state, .queued, "never a silent drop — the user is told it'll send later")
        XCTAssertEqual(h.sender.sent.count, 1)
    }

    func testReplyRendersSpeaksAndHaptics() {
        let h = makeHarness()
        h.model.tapTalk()
        h.recorder.deliver(.success(clip))
        let id = try! XCTUnwrap(h.sender.sent.first).requestId
        h.sender.reply(WatchReply(requestId: id, ok: true,
                                  displayText: "Milk and eggs.", spokenText: "Milk and eggs."))
        XCTAssertEqual(h.model.state, .reply(display: "Milk and eggs.", spoken: "Milk and eggs."))
        XCTAssertEqual(h.speaker.spoken, ["Milk and eggs."])
        XCTAssertEqual(h.hapticCount(), 1)
    }

    func testDuplicateReplyRendersOnce() {
        // The phone answers on transferUserInfo AND sendMessage; the watch must not
        // double-render or double-speak.
        let h = makeHarness()
        h.model.tapTalk()
        h.recorder.deliver(.success(clip))
        let id = try! XCTUnwrap(h.sender.sent.first).requestId
        let reply = WatchReply(requestId: id, ok: true, displayText: "Answer.", spokenText: "Answer.")
        h.sender.reply(reply) // via userInfo
        h.sender.reply(reply) // via sendMessage — duplicate
        XCTAssertEqual(h.speaker.spoken, ["Answer."], "spoken exactly once")
        XCTAssertEqual(h.hapticCount(), 1, "haptic exactly once")
    }

    func testFailureReplyShowsError() {
        let h = makeHarness()
        h.model.tapTalk()
        h.recorder.deliver(.success(clip))
        let id = try! XCTUnwrap(h.sender.sent.first).requestId
        h.sender.reply(WatchReply(requestId: id, ok: false, error: "Couldn't understand the audio."))
        XCTAssertEqual(h.model.state, .error("Couldn't understand the audio."))
        XCTAssertTrue(h.speaker.spoken.isEmpty)
        XCTAssertEqual(h.hapticCount(), 1)
    }

    func testTapWhileListeningIsManualStop() {
        let h = makeHarness()
        h.model.tapTalk() // start
        h.model.tapTalk() // stop
        XCTAssertEqual(h.recorder.stopCount, 1)
    }

    func testEmptyRecordingSurfacesErrorNotSend() {
        let h = makeHarness()
        h.model.tapTalk()
        h.recorder.deliver(.success(Data()))
        XCTAssertEqual(h.sender.sent.count, 0)
        if case .error = h.model.state {} else { XCTFail("expected an error state, got \(h.model.state)") }
    }

    func testRecordingFailureSurfacesError() {
        struct Boom: Error {}
        let h = makeHarness()
        h.model.tapTalk()
        h.recorder.deliver(.failure(Boom()))
        XCTAssertEqual(h.sender.sent.count, 0)
        if case .error = h.model.state {} else { XCTFail("expected an error state") }
    }

    func testTapAfterReplyStartsFreshTake() {
        let h = makeHarness()
        h.model.tapTalk()
        h.recorder.deliver(.success(clip))
        let id = try! XCTUnwrap(h.sender.sent.first).requestId
        h.sender.reply(WatchReply(requestId: id, ok: true, displayText: "A", spokenText: "A"))
        h.model.tapTalk()
        XCTAssertEqual(h.model.state, .listening)
        XCTAssertEqual(h.recorder.startCount, 2)
    }
}
