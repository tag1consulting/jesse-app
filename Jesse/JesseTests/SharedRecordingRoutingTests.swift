import XCTest
@testable import Jesse
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
// package: audio is not, and must never become, an attachment.
//
// `@MainActor` because the app module compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`, so `AttachmentLimits` is main-actor isolated.
@MainActor
final class AudioIsNeverAnAttachmentTests: XCTestCase {

    func testTheAttachmentWhitelistStillRefusesAudio() {
        // The brief's explicit out-of-scope item, pinned so a later "while we're here"
        // cannot quietly add it. The bridge sniffs magic bytes and accepts images and
        // PDF only; the client mirrors that list, and an audio MIME appearing in it
        // would mean recordings were being uploaded.
        for mime in ["audio/mp4", "audio/mpeg", "audio/wav", "audio/x-m4a", "audio/aiff"] {
            XCTAssertFalse(AttachmentLimits.allowedMimes.contains(mime),
                           "\(mime) must never be attachable — the transcript is what travels")
        }
    }

    func testSniffingAnM4AHeaderYieldsNoAttachableType() {
        // An `ftyp` box with an audio brand: the same shape as a HEIC's, and it must not
        // be mistaken for one.
        let m4a = Data([0x00, 0x00, 0x00, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 8)
        XCTAssertNil(JesseAttachment.sniffMime(m4a))
    }
}
