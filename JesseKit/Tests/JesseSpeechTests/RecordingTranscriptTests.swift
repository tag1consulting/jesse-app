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
            .cancelled,
        ]
        var seen = Set<String>()
        for failure in failures {
            let message = failure.message(sourceName: "memo.m4a")
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.hasSuffix(".") || message.hasSuffix("!"),
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
