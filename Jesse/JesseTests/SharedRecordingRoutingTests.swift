import XCTest
@testable import Jesse
import JesseNetworking
import JesseSpeech

// The app's half of a shared recording: the hand-off the share extension left behind is
// carried from the thread list (which opens a conversation for it) to the composer
// inside that conversation (which transcribes it).
//
// The transcription itself is `JesseSpeech`'s, and tested there. What is asserted here is
// the routing rule that makes the share sheet's one gesture work at all — including the
// one that is easy to get wrong: a hand-off fires EXACTLY ONCE, because the composer's
// `.task` runs again on every re-appearance and re-transcribing an hour of audio because
// the user swiped back is not a small mistake.

@MainActor
final class SharedRecordingRoutingTests: XCTestCase {

    private func recording(named name: String = "memo.m4a") -> PendingRecording {
        PendingRecording(originalName: name,
                         durationSeconds: 192,
                         arrivedAt: Date(timeIntervalSince1970: 1_000),
                         fileExtension: "m4a")
    }

    func testAStagedRecordingIsHandedToItsConversationExactlyOnce() {
        let coordinator = RunCoordinator()
        let threadID = UUID()
        let staged = recording()

        coordinator.stage(recording: staged, for: threadID)
        XCTAssertEqual(coordinator.takeStagedRecording(for: threadID)?.id, staged.id)
        XCTAssertNil(coordinator.takeStagedRecording(for: threadID),
                     "the composer's .task re-runs on every re-appearance; a second read must be empty")
    }

    func testARecordingIsOnlyGivenToTheConversationItWasOpenedFor() {
        let coordinator = RunCoordinator()
        let mine = UUID()
        let other = UUID()
        coordinator.stage(recording: recording(), for: mine)

        XCTAssertNil(coordinator.takeStagedRecording(for: other))
        XCTAssertNotNil(coordinator.takeStagedRecording(for: mine))
    }

    func testTheDrainKnowsWhenSomethingIsAlreadyWaiting() {
        // The guard that stops a second foreground opening a second conversation for a
        // hand-off the first one has not started on yet.
        let coordinator = RunCoordinator()
        let threadID = UUID()
        XCTAssertFalse(coordinator.hasStagedRecording)

        coordinator.stage(recording: recording(), for: threadID)
        XCTAssertTrue(coordinator.hasStagedRecording)

        _ = coordinator.takeStagedRecording(for: threadID)
        XCTAssertFalse(coordinator.hasStagedRecording,
                       "once the composer has it, the next share may open its own conversation")
    }

    func testStagingASecondRecordingForOneThreadReplacesTheFirst() {
        // Two shares in a row before either is picked up. The newer one is what that
        // conversation was opened for; the older stays in the app group and is offered
        // again on the next foreground rather than being transcribed into the wrong chat.
        let coordinator = RunCoordinator()
        let threadID = UUID()
        coordinator.stage(recording: recording(named: "first.m4a"), for: threadID)
        let second = recording(named: "second.m4a")
        coordinator.stage(recording: second, for: threadID)

        XCTAssertEqual(coordinator.takeStagedRecording(for: threadID)?.originalName, "second.m4a")
        XCTAssertNil(coordinator.takeStagedRecording(for: threadID))
    }
}

// The one claim about the recording path that belongs to the APP rather than to the
// package: a recording travels to the paired Jesse bridge by its own route, and NEVER as a
// turn attachment.
//
// THIS REPLACES `AudioIsNeverAnAttachmentTests`, deliberately. That class pinned the rule
// App 1.0 (124) shipped — "audio never crosses the network; the transcript is what
// travels" — and that rule was retired in App 1.0 (133) / bridge 0.135.0: recordings are now
// transcribed on the Studio, so they DO cross the network, to the bridge and nowhere past
// it. The line moved from the network interface to the DESTINATION, and the replacement is
// held in three places rather than one:
//
//   * here: the turn attachment path — which can lead to a hosted vision helper or a hosted
//     child — still refuses every audio type, and the recording route is built from the
//     same pairing every turn uses;
//   * in `JesseSpeechTests.StudioWireTests`: the only request that carries audio targets the
//     paired bridge's transcription route;
//   * in the bridge, on the wire: `recorded_audio_never_reaches_a_hosted_backend` fails if a
//     single connection reaches a hosted backend while a recording is in the bridge.
//
// `@MainActor` because the app module compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`, so `AttachmentLimits` is main-actor isolated.
@MainActor
final class AudioTravelsOnlyToTheStudioTests: XCTestCase {

    func testTheAttachmentWhitelistStillRefusesAudio() {
        // Recordings travel now, but never as a turn attachment: that path hands files to
        // models that may be hosted, and the audio egress ban forbids exactly that.
        for mime in ["audio/mp4", "audio/mpeg", "audio/wav", "audio/x-m4a", "audio/aiff"] {
            XCTAssertFalse(AttachmentLimits.allowedMimes.contains(mime),
                           "\(mime) must never be a turn attachment — recordings take the Studio's own route")
        }
    }

    func testSniffingAnM4AHeaderYieldsNoAttachableType() {
        // An `ftyp` box with an audio brand: the same shape as a HEIC's, and it must not
        // be mistaken for one.
        let m4a = Data([0x00, 0x00, 0x00, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 8)
        XCTAssertNil(JesseAttachment.sniffMime(m4a))
    }

    func testTheRecordingRouteIsThePairedBridgeAndNothingElse() throws {
        // The composers build their Studio endpoint from the same pairing every turn uses,
        // with exactly this expression; the audio goes to that host, that port, that route.
        let config = JesseConfig(host: "studio.example.ts.net", port: 8765, token: "tok")
        let endpoint = try XCTUnwrap(StudioEndpoint(baseURL: config.endpoint("/"), token: config.token))
        let request = URLSessionStudioTransport.uploadRequest(endpoint: endpoint, language: "it",
                                                              contentType: "audio/mp4")
        XCTAssertEqual(request.url?.host, config.normalizedHost)
        XCTAssertEqual(request.url?.port, config.effectivePort)
        XCTAssertEqual(request.url?.path, "/jesse/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        // And an unpaired app has no Studio to send anything to.
        let unpaired = JesseConfig(host: "", port: 8765, token: "")
        XCTAssertNil(StudioEndpoint(baseURL: unpaired.endpoint("/"), token: unpaired.token))
    }
}
