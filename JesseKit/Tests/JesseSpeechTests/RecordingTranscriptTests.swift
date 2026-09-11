import XCTest
@testable import JesseSpeech

// The bytes that actually reach the bridge.
//
// Audio never crosses the network, so this string IS the feature's output — there is no
// attachment behind it to fall back on and no second rendering anywhere. Pinning it here
// is what makes "the transcript arrives as text, with its provenance" a checked claim.

final class RecordingTranscriptTests: XCTestCase {

    // MARK: - Duration

    func testDurationKeepsSecondsAtEveryScale() {
        XCTAssertEqual(RecordingTranscript.durationText(seconds: 0), "0s")
        XCTAssertEqual(RecordingTranscript.durationText(seconds: 9.4), "9s")
        XCTAssertEqual(RecordingTranscript.durationText(seconds: 59.6), "1m 0s")
        XCTAssertEqual(RecordingTranscript.durationText(seconds: 192), "3m 12s")
        // The case this feature is designed around.
        XCTAssertEqual(RecordingTranscript.durationText(seconds: 3600), "1h 00m 00s")
        XCTAssertEqual(RecordingTranscript.durationText(seconds: 3852), "1h 04m 12s")
    }

    func testDurationSurvivesNonsense() {
        // A probe that could not measure the file hands back 0; nothing here may render
        // "nans" or a negative into a message.
        XCTAssertEqual(RecordingTranscript.durationText(seconds: -5), "0s")
        XCTAssertEqual(RecordingTranscript.durationText(seconds: .nan), "0s")
        XCTAssertEqual(RecordingTranscript.durationText(seconds: .infinity), "0s")
    }

    // MARK: - Header

    func testHeaderNamesTheFileItsLengthAndItsLanguage() {
        XCTAssertEqual(
            RecordingTranscript.header(sourceName: "Nuova registrazione 3.m4a",
                                       seconds: 192,
                                       language: "Italian"),
            "Recording: “Nuova registrazione 3.m4a” · 3m 12s · Italian")
    }

    // MARK: - Body

    func testBodyIsHeaderThenTranscriptWhenNothingWasTyped() {
        // The common case: share a memo, send it as it stands.
        let body = RecordingTranscript.messageBody(typed: "",
                                                   sourceName: "memo.m4a",
                                                   seconds: 65,
                                                   language: "Italian",
                                                   transcript: "Ciao, sono il pizzaiolo.")
        XCTAssertEqual(body, """
        Recording: “memo.m4a” · 1m 5s · Italian

        Ciao, sono il pizzaiolo.
        """)
    }

    func testTypedTextStaysAheadOfTheTranscript() {
        // The user's framing precedes the material it is about. An hour of transcript
        // followed by "here is what the plumber said" would be unreadable.
        let body = RecordingTranscript.messageBody(typed: "What did the plumber commit to?",
                                                   sourceName: "memo.m4a",
                                                   seconds: 65,
                                                   language: "Italian",
                                                   transcript: "Ciao, sono il pizzaiolo.")
        XCTAssertEqual(body, """
        What did the plumber commit to?

        Recording: “memo.m4a” · 1m 5s · Italian

        Ciao, sono il pizzaiolo.
        """)
    }

    func testWhitespaceOnlyTypedTextIsNoTypedTextAtAll() {
        // A composer holding a stray newline must not produce a leading blank line in
        // the message.
        let body = RecordingTranscript.messageBody(typed: "  \n\t ",
                                                   sourceName: "memo.m4a",
                                                   seconds: 10,
                                                   language: "English",
                                                   transcript: "Hello.")
        XCTAssertTrue(body.hasPrefix("Recording: "), "got: \(body)")
    }

    func testTranscriptIsTrimmedButNotOtherwiseTouched() {
        // Paragraph breaks inside a long recording are meaning, and must survive intact.
        let transcript = "\n\nPrima parte.\n\nSeconda parte.\n\n"
        let body = RecordingTranscript.messageBody(typed: "",
                                                   sourceName: "a.m4a",
                                                   seconds: 30,
                                                   language: "Italian",
                                                   transcript: transcript)
        XCTAssertTrue(body.hasSuffix("Prima parte.\n\nSeconda parte."), "got: \(body)")
    }

    func testCompletedRecordingComposesThroughTheSameRule() {
        // The model's convenience must not become a second spelling of the format.
        let completed = CompletedRecording(sourceName: "memo.m4a",
                                           durationSeconds: 192,
                                           language: "Italian",
                                           transcript: "Buongiorno.")
        XCTAssertEqual(completed.messageBody(typed: "Note from the site visit."),
                       RecordingTranscript.messageBody(typed: "Note from the site visit.",
                                                       sourceName: "memo.m4a",
                                                       seconds: 192,
                                                       language: "Italian",
                                                       transcript: "Buongiorno."))
    }

    // MARK: - Where it was transcribed, and where it is unsure

    func testTheHeaderSaysWhereTheTranscriptWasMade() {
        XCTAssertEqual(
            RecordingTranscript.header(sourceName: "memo.m4a", seconds: 192, language: "Italian",
                                       engine: "the Studio (Whisper large-v3)"),
            "Recording: “memo.m4a” · 3m 12s · Italian · transcribed on the Studio (Whisper large-v3)")
        XCTAssertEqual(
            RecordingTranscript.header(sourceName: "memo.m4a", seconds: 192, language: "Italian",
                                       engine: "this device"),
            "Recording: “memo.m4a” · 3m 12s · Italian · transcribed on this device")
    }

    /// The field case: two engines disagreed on a pickup date. The transcript keeps the
    /// primary reading untouched; both readings follow it, with where to find them, so the
    /// model the message goes to can check the weekday against the calendar.
    func testDisagreementsFollowTheTranscriptWithoutEditingIt() {
        let body = RecordingTranscript.messageBody(
            typed: "",
            sourceName: "hall.m4a",
            seconds: 2820,
            language: "English",
            transcript: "Pickup is on Thursday the 14th.",
            engine: "the Studio (Whisper large-v3, checked against Whisper large-v3 turbo)",
            disagreements: [
                TranscriptDisagreement(startSeconds: 723, endSeconds: 727,
                                       primary: "14th", alternative: "15th"),
                TranscriptDisagreement(startSeconds: 3852, endSeconds: 3855,
                                       primary: "the boiler", alternative: ""),
            ])
        XCTAssertEqual(body, """
        Recording: “hall.m4a” · 47m 0s · English · transcribed on the Studio (Whisper large-v3, checked against Whisper large-v3 turbo)

        Pickup is on Thursday the 14th.

        Uncertain passages — two engines heard these differently; the transcript above follows the first reading:
        [12:03] “14th” — or “15th”
        [1:04:12] “the boiler” — or nothing
        """)
    }

    func testNotesFollowTheDisagreementsAndBlankOnesAreDropped() {
        let block = RecordingTranscript.uncertaintyBlock(
            disagreements: [],
            notes: ["The second reading failed, so nothing was cross-checked.", "  "])
        XCTAssertEqual(block, """
        Transcription notes:
        - The second reading failed, so nothing was cross-checked.
        """)
        XCTAssertNil(RecordingTranscript.uncertaintyBlock(disagreements: [], notes: []),
                     "a clean single reading adds nothing to the message")
    }

    func testTimestampsReadLikeAPlayer() {
        XCTAssertEqual(RecordingTranscript.timestamp(seconds: 0), "0:00")
        XCTAssertEqual(RecordingTranscript.timestamp(seconds: 65.9), "1:05")
        XCTAssertEqual(RecordingTranscript.timestamp(seconds: 3852), "1:04:12")
        XCTAssertEqual(RecordingTranscript.timestamp(seconds: .nan), "0:00")
    }
}

final class TranscriptionFailureMessageTests: XCTestCase {

    /// Every failure mode says its own thing, names the file, and is a whole sentence.
    /// The bar this pins is the one in the brief: not a generic failure, and not a
    /// silent no-op.
    func testEveryFailureHasItsOwnSpecificSentence() {
        let failures: [TranscriptionFailure] = [
            .speechPermissionDenied,
            .localeUnavailable(language: "Italian"),
            .modelUnavailable(language: "Italian", reason: "no space left"),
            .unreadableFile,
            .noSpeechFound,
            .stalled,
            .engineFailed(reason: "the recognizer died"),
            .studioRefused(reason: "the recording is larger than the Studio accepts"),
            .studioFailed(reason: "the engine ran out of memory"),
            .cancelled,
        ]
        var seen = Set<String>()
        for failure in failures {
            let message = failure.message(sourceName: "memo.m4a")
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.last.map { ".!?".contains($0) } ?? false,
                          "“\(message)” should read as a sentence")
            XCTAssertTrue(seen.insert(message).inserted,
                          "two failures share the wording “\(message)”")
        }
    }

    func testPermissionDeniedSaysWhereToTurnItOn() {
        // "A path to retry after granting it" — the message has to name the setting,
        // because Speech Recognition is not where most people would look.
        let message = TranscriptionFailure.speechPermissionDenied.message(sourceName: "memo.m4a")
        XCTAssertTrue(message.contains("Settings"))
        XCTAssertTrue(message.contains("Speech Recognition"))
        XCTAssertTrue(message.contains("memo.m4a"))
    }

    /// A borrowed clause is finished as a sentence, and only once — the reasons these
    /// two cases interpolate come from `error.localizedDescription`, which is punctuated
    /// about half the time.
    func testAnInterpolatedReasonIsPunctuatedExactlyOnce() {
        XCTAssertTrue(TranscriptionFailure.engineFailed(reason: "the recognizer died")
            .message(sourceName: "memo.m4a").hasSuffix("the recognizer died."))
        XCTAssertTrue(TranscriptionFailure.engineFailed(reason: "The recognizer died.")
            .message(sourceName: "memo.m4a").hasSuffix("The recognizer died."))
        XCTAssertTrue(TranscriptionFailure.modelUnavailable(language: "Italian", reason: "no space left ")
            .message(sourceName: "memo.m4a").hasSuffix("no space left."))
    }

    func testTheUnreadableFileMessageNamesTheFileAndSaysWhy() {
        XCTAssertEqual(TranscriptionFailure.unreadableFile.message(sourceName: "notes.pdf"),
                       "Couldn’t read “notes.pdf” — it isn’t audio this device can open.")
    }

    func testNoSpeechFoundPointsAtTheLanguageChoice() {
        // The most likely cause of an empty transcript is the wrong language, and the
        // message has to say so or the user has no next move.
        let message = TranscriptionFailure.noSpeechFound.message(sourceName: "memo.m4a")
        XCTAssertTrue(message.contains("language"))
    }
}
