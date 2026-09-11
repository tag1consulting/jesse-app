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
// There are two implementations, and the app composes them: `StudioFirstTranscriber`
// sends the recording to the Jesse bridge on the Studio, which runs far stronger models
// than a phone can, and falls back to `SpeechAnalyzerFileTranscriber` — this device's own
// engine — only when the Studio cannot be reached. The fallback is never silent: its
// result carries a `notice` the composer shows.
//
// Being a protocol is what makes the whole feature testable: the composer model, the
// share hand-off, the cleanup rules, the progress policy and the fallback are all
// exercised against fakes, so no test needs a microphone, a recognizer, a speech model
// or a network.

/// How far a transcription has got, published while it runs.
public struct TranscriptionUpdate: Sendable, Equatable {
    /// Which wait the user is currently in. They are distinguished because they are
    /// wildly different in length and only some of them are the transcription: a
    /// first-time recording can wait on a model download before a single word is
    /// recognized, and a progress bar that sat at zero through it would look broken.
    public enum Phase: Sendable, Equatable {
        /// Opening the file and resolving the locale. Brief.
        case preparing
        /// Sending the recording to the Studio. `fraction` is bytes sent over bytes total.
        case uploading
        /// On the Studio, waiting for its one transcription slot.
        case queued
        /// Fetching a speech model: this device's for the chosen language, or the
        /// Studio's own on its first recording. A model asset, never the recording.
        case downloadingModel
        /// The Studio is cleaning up far-field audio before reading it.
        case conditioning
        /// Recognizing speech. `fraction` is audio consumed over audio total.
        case transcribing
        /// The Studio's second engine is reading the same audio, to find where the
        /// first reading is unsure.
        case secondReading
        /// The two readings are being compared.
        case reconciling
    }

    public var phase: Phase
    /// 0...1. Meaningful in every phase; the caller may draw it as a bar.
    public var fraction: Double
    /// The text recognized so far. Empty until the first result lands (and always empty
    /// for a Studio run, which returns its text at the end).
    public var transcript: String
    /// Who is doing the work right now — "the Studio · Whisper large-v3", "this device".
    /// Nil until it is known. Named so a long run on a large model never reads as a hang.
    public var engine: String?

    public init(phase: Phase, fraction: Double, transcript: String = "", engine: String? = nil) {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
        self.transcript = transcript
        self.engine = engine
    }
}

/// One stretch where two engines heard the recording differently.
public struct TranscriptDisagreement: Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    /// What the transcript says there — the primary reading.
    public let primary: String
    /// What the second engine heard instead. Empty when it heard nothing there.
    public let alternative: String

    public init(startSeconds: Double, endSeconds: Double, primary: String, alternative: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.primary = primary
        self.alternative = alternative
    }
}

/// A finished transcription and everything it knows about itself.
public struct TranscriptionResult: Sendable, Equatable {
    /// The transcript, never empty.
    public var text: String
    /// Where, and by what, it was transcribed — "the Studio (Whisper large-v3, checked
    /// against Whisper large-v3 turbo)", "this device". The message header states it.
    public var engine: String
    /// Where two engines disagreed. Empty for a single reading.
    public var disagreements: [TranscriptDisagreement]
    /// Anything the transcriber wants the reader to know about the reading itself.
    public var notes: [String]
    /// Set when the recording was NOT transcribed where it normally would have been — the
    /// Studio could not be reached — so the composer says so. A weaker reading must never
    /// arrive looking like the usual one.
    public var notice: String?

    public init(text: String, engine: String, disagreements: [TranscriptDisagreement] = [],
                notes: [String] = [], notice: String? = nil) {
        self.text = text
        self.engine = engine
        self.disagreements = disagreements
        self.notes = notes
        self.notice = notice
    }
}

/// What this device is called in a provenance line.
public enum TranscriptionPlace {
    public static var thisDevice: String {
        #if os(macOS)
        return "this Mac"
        #else
        return "this device"
        #endif
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
    /// The Studio answered and would not take this recording: larger than its cap, a
    /// type it cannot read, or this device's token refused. Not a reason to fall back —
    /// the Studio was reached, and its answer is the one to show.
    case studioRefused(reason: String)
    /// The Studio took the recording and its run ended without a transcript.
    case studioFailed(reason: String)
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
            return "Couldn’t install the \(language) speech model: \(Self.terminated(reason))"
        case .unreadableFile:
            return "Couldn’t read “\(sourceName)” — it isn’t audio this device can open."
        case .noSpeechFound:
            return "No speech was recognized in “\(sourceName)”. Check the language is right and that there is audible speech in it."
        case .stalled:
            return "Transcribing “\(sourceName)” stopped making progress, so it was given up on. Try again."
        case .engineFailed(let reason):
            return "Couldn’t transcribe “\(sourceName)”: \(Self.terminated(reason))"
        case .studioRefused(let reason):
            return "The Studio wouldn’t take “\(sourceName)”: \(Self.terminated(reason))"
        case .studioFailed(let reason):
            return "Transcribing “\(sourceName)” on the Studio failed: \(Self.terminated(reason))"
        case .cancelled:
            return "Transcribing “\(sourceName)” was cancelled."
        }
    }

    /// Finish a borrowed clause as a sentence.
    ///
    /// Several cases above end in a `reason` that came from somewhere else —
    /// `error.localizedDescription`, or the bridge's own message — and those arrive
    /// punctuated about half the time. Appending unconditionally would produce "no space
    /// left.." on the half that already are, so the terminator is added only when one is
    /// missing, and the result is a whole sentence either way.
    static func terminated(_ clause: String) -> String {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}

/// Turns a recorded audio FILE into text, reporting progress and honouring cancellation.
///
/// Cancellation is the caller's `Task`: cancel the task that is awaiting `transcribe`
/// and the implementation stops the engine and throws `.cancelled`. There is no
/// separate cancel handle to keep in sync with the task.
public protocol AudioFileTranscribing: Sendable {
    /// Transcribe `url` in `locale`.
    ///
    /// - Parameter onProgress: called on an arbitrary executor, possibly many times a
    ///   second. Callers that update UI hop to the main actor themselves.
    /// - Returns: the transcript and its provenance; the text is never empty (an empty
    ///   result is `.noSpeechFound`).
    func transcribe(fileAt url: URL,
                    locale: Locale,
                    onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws -> TranscriptionResult
}
