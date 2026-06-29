import XCTest
import AVFoundation
@testable import Jesse

/// (M9) A failure configuring the audio session must be surfaced/logged, not
/// swallowed by `try?` — otherwise a routing failure silently drops a voice reply.
@MainActor
final class SpeakerTests: XCTestCase {

    /// An audio session whose activation always fails (a routing/category error).
    private final class FailingSession: AudioSessioning {
        struct Boom: Error {}
        func activate() throws { throw Boom() }
        func deactivate() throws {}
    }

    /// A session that succeeds, to confirm the success path records no error.
    private final class OKSession: AudioSessioning {
        func activate() throws {}
        func deactivate() throws {}
    }

    func testSessionActivationFailureIsSurfacedNotSwallowed() {
        let speaker = Speaker(session: FailingSession())
        speaker.speak("hello")
        XCTAssertNotNil(speaker.lastSessionError,
                        "an audio-session configuration failure must be surfaced, not swallowed")
    }

    func testSessionActivationSuccessRecordsNoError() {
        let speaker = Speaker(session: OKSession())
        speaker.speak("hello")
        XCTAssertNil(speaker.lastSessionError, "a successful session config records no error")
    }
}
