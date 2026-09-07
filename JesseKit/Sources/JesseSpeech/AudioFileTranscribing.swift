import Foundation

// The seam for turning a RECORDED FILE into text, and the vocabulary the whole
// feature speaks: what progress looks like while it runs, and every way it can fail.
//
// It sits beside the phone's existing `AudioTranscribing` (watch-relayed clips) rather
// than replacing it, because the two are not the same job and must not share an
// implementation:
//
//   * The watch relay hands over a few seconds of speech captured seconds ago, wants an
//     answer promptly, and is happy to give up. `AudioTranscribing` — Data in, String?
//     out, a 30-second wall-clock bound — says exactly that.
//   * A shared recording is ten to sixty minutes of audio that will take minutes of real
//     time to transcribe, in a language chosen at pick time, with a progress bar and a
//     Cancel button, and it must not be abandoned because a timer expired.
//
// So this protocol carries what the other one cannot: a URL rather than bytes (an hour
// of audio does not want to be a `Data` in memory), an explicit locale, progress, and a
// TYPED failure instead of `nil`. Every failure mode reaches the user as its own
// sentence; see `TranscriptionFailure.message(sourceName:)`.
//
// Being a protocol is what makes the whole feature testable: the composer model, the
// share hand-off, the cleanup rules and the progress policy are all exercised against a
// fake conforming type, so no test needs a microphone, a recognizer, or a speech model.

/// How far a transcription has got, published while it runs.
public struct TranscriptionUpdate: Sendable, Equatable {
    /// Which of the three waits the user is currently in. They are distinguished
    /// because they are wildly different in length and only one of them is the
    /// transcription: a first-time Italian recording downloads a speech model before a
    /// single word is recognized, and a progress bar that sat at zero through it would
    /// look broken.
    public enum Phase: Sendable, Equatable {
        /// Opening the file and resolving the locale. Brief.
        case preparing
        /// Fetching the on-device speech model for the chosen language. Once per
        /// language per device, and it is the only phase that touches the network —
        /// Apple's model asset, never the recording.
        case downloadingModel
        /// Recognizing speech. `fraction` is audio consumed over audio total.
        case transcribing
    }

    public var phase: Phase
    /// 0...1. Meaningful in every phase; the caller may draw it as a bar.
    public var fraction: Double
    /// The text recognized so far. Empty until the first result lands.
    public var transcript: String

    public init(phase: Phase, fraction: Double, transcript: String = "") {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
        self.transcript = transcript
    }
}

/// Why a file produced no transcript.
///
/// Deliberately an enum of NAMED causes rather than a wrapped `Error`: the acceptance
/// bar for this feature is that permission-denied, no-such-recognizer, unreadable-file
/// and no-speech-found each say their own specific thing in the composer. A single
/// "Couldn't transcribe that" is the failure this type exists to prevent.
///
/// The file's name is NOT carried in the cases. It is the caller's — the composer knows
/// what the user picked, and the transcriber only ever sees a working copy named after a
/// UUID. `message(sourceName:)` puts the two together.
public enum TranscriptionFailure: Error, Equatable, Sendable {
    /// Speech Recognition authorization is denied, restricted, or was refused.
    case speechPermissionDenied
    /// This device cannot transcribe the chosen language at all (it is not in
    /// `SpeechTranscriber.supportedLocales`).
    case localeUnavailable(language: String)
    /// The language is supported but its on-device model could not be installed.
    case modelUnavailable(language: String, reason: String)
    /// The file could not be opened as audio: wrong type, truncated, or corrupt.
    case unreadableFile
    /// The audio opened and ran to completion, and no speech was recognized in it.
    case noSpeechFound
    /// Recognition stopped making progress for longer than the stall limit. NOT a
    /// wall-clock deadline — see `TranscriptionStallDetector`.
    case stalled
    /// The speech engine itself failed.
    case engineFailed(reason: String)
    /// The user cancelled. Carried as a failure so every exit path is one `catch` and
    /// the working copy is deleted the same way; the caller shows nothing for it.
    case cancelled

    /// The exact sentence the composer shows for this failure, naming the file the user
    /// actually picked. Pure, so the wording is asserted in tests rather than read off a
    /// screenshot.
    public func message(sourceName: String) -> String {
        switch self {
        case .speechPermissionDenied:
            return "Speech Recognition is off — turn it on in Settings › Privacy & Security › Speech Recognition, then attach “\(sourceName)” again."
        case .localeUnavailable(let language):
            return "This device can’t transcribe \(language). Choose a different language and try again."
        case .modelUnavailable(let language, let reason):
            return "Couldn’t install the \(language) speech model: \(reason)"
        case .unreadableFile:
            return "Couldn’t read “\(sourceName)” — it isn’t audio this device can open."
        case .noSpeechFound:
            return "No speech was recognized in “\(sourceName)”. Check the language is right and that there is audible speech in it."
        case .stalled:
            return "Transcribing “\(sourceName)” stopped making progress, so it was given up on. Try again."
        case .engineFailed(let reason):
            return "Couldn’t transcribe “\(sourceName)”: \(reason)"
        case .cancelled:
            return "Transcribing “\(sourceName)” was cancelled."
        }
    }
}

/// Turns a recorded audio FILE into text, on this device, reporting progress and
/// honouring cancellation.
///
/// Cancellation is the caller's `Task`: cancel the task that is awaiting `transcribe`
/// and the implementation stops the engine and throws `.cancelled`. There is no
/// separate cancel handle to keep in sync with the task.
public protocol AudioFileTranscribing: Sendable {
    /// Transcribe `url` in `locale`.
    ///
    /// - Parameter onProgress: called on an arbitrary executor, possibly many times a
    ///   second. Callers that update UI hop to the main actor themselves.
    /// - Returns: the transcript, never empty (an empty result is `.noSpeechFound`).
    func transcribe(fileAt url: URL,
                    locale: Locale,
                    onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws -> String
}
