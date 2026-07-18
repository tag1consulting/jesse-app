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
    /// Counts activations so a test can assert muting never touches the session.
    private final class OKSession: AudioSessioning {
        var activateCount = 0
        func activate() throws { activateCount += 1 }
        func deactivate() throws {}
    }

    /// Records what was handed to the synthesizer, so delivery can be asserted
    /// without a real `AVSpeechSynthesizer`.
    private final class SpySynth: SpeechSynthesizing {
        var onFinish: (() -> Void)?
        var spoken: [String] = []
        var stopCount = 0
        func speak(_ text: String) { spoken.append(text) }
        func stop() { stopCount += 1 }
    }

    // MARK: - The failure path (Prompt 1)
    //
    // These assert the UN-MUTED delivery/session behavior, so they pin `muted: false`
    // rather than inherit the default (`JESSE_MUTE != nil`). The shared `Jesse` scheme
    // sets `JESSE_MUTE=1` and its TestAction inherits the Run env
    // (`shouldUseLaunchSchemeArgsEnv=YES`), so a default-constructed `Speaker` under
    // `xcodebuild test` would be muted and deliver nothing — pinning keeps these tests
    // hermetic against the dev-mute env. The dedicated mute tests below pin `muted:`
    // explicitly too.

    func testSessionActivationFailureIsSurfacedNotSwallowed() {
        let speaker = Speaker(session: FailingSession(), synth: SpySynth(), muted: false)
        speaker.speak("hello")
        XCTAssertNotNil(speaker.lastSessionError,
                        "an audio-session configuration failure must be surfaced, not swallowed")
    }

    func testSessionActivationSuccessRecordsNoError() {
        let speaker = Speaker(session: OKSession(), synth: SpySynth(), muted: false)
        speaker.speak("hello")
        XCTAssertNil(speaker.lastSessionError, "a successful session config records no error")
    }

    // MARK: - Delivery

    func testSpeakDeliversTrimmedTextToSynth() {
        let spy = SpySynth()
        Speaker(session: OKSession(), synth: spy, muted: false).speak("  hello there  ")
        XCTAssertEqual(spy.spoken, ["hello there"], "the trimmed text is handed to the synthesizer")
    }

    func testEmptyOrWhitespaceTextSpeaksNothing() {
        let spy = SpySynth()
        let speaker = Speaker(session: OKSession(), synth: spy, muted: false)
        speaker.speak("")
        speaker.speak("   \n\t ")
        XCTAssertEqual(spy.spoken, [], "an empty/whitespace reply is never spoken")
    }

    /// Delivery is still attempted even when the audio session fails to activate —
    /// the Prompt-1 fix surfaces the routing error but does NOT drop the voice reply
    /// (playback can still route to the default output).
    func testSpeakStillDeliversWhenSessionActivationFails() {
        let spy = SpySynth()
        let speaker = Speaker(session: FailingSession(), synth: spy, muted: false)
        speaker.speak("important note")
        XCTAssertNotNil(speaker.lastSessionError, "the routing failure is surfaced")
        XCTAssertEqual(spy.spoken, ["important note"], "the reply is still spoken despite the session failure")
    }

    // MARK: - Dev mute (JESSE_MUTE)

    /// When muted, `speak` delivers nothing to the synth AND never activates the
    /// audio session — so it neither speaks nor ducks other audio.
    func testMutedSpeaksNothingAndNeverActivatesSession() {
        let spy = SpySynth()
        let session = OKSession()
        let speaker = Speaker(session: session, synth: spy, muted: true)
        speaker.speak("hello")
        XCTAssertEqual(spy.spoken, [], "a muted speaker hands nothing to the synthesizer")
        XCTAssertEqual(session.activateCount, 0, "muting must not activate the audio session (no ducking)")
    }

    /// The un-muted path is unchanged: text still reaches the synth and the session
    /// is activated.
    func testNotMutedStillSpeaksAndActivatesSession() {
        let spy = SpySynth()
        let session = OKSession()
        let speaker = Speaker(session: session, synth: spy, muted: false)
        speaker.speak("hello")
        XCTAssertEqual(spy.spoken, ["hello"], "an un-muted speaker still delivers to the synthesizer")
        XCTAssertEqual(session.activateCount, 1, "the un-muted path still activates the audio session")
    }

    func testStopForwardsToSynth() {
        let spy = SpySynth()
        Speaker(session: OKSession(), synth: spy).stop()
        XCTAssertEqual(spy.stopCount, 1)
    }
}
