import Foundation
import Observation

// The whole flow of attaching a recording, as one model both apps drive.
//
// It lives here rather than inside a composer view because it is the same flow twice
// over — the iPhone's file picker, the iPhone's share sheet, and the Mac's file picker
// all converge on it — and because it owns the two promises that must not be
// re-implemented per platform:
//
//   1. THE WORKING COPY IS DELETED ON EVERY EXIT PATH. Success, every failure,
//      cancellation, and a language sheet dismissed without choosing. There is exactly
//      one place that ends a run (`settle`) and it is the only place that clears state,
//      so "the transcript arrived but the audio is still on disk" is not a state this
//      type can be in.
//   2. EVERY FAILURE HAS ITS OWN SENTENCE. The taxonomy is `TranscriptionFailure`'s; this
//      only pairs it with the name of the file the user actually picked.
//
// Everything it depends on is injected — the transcriber, the probe, the storage, the
// list of supported languages and the memory of the last one — so the tests drive real
// state transitions with no speech model, no microphone and no permission prompt.

/// A recording that has been transcribed, ready to become a message.
public struct CompletedRecording: Equatable, Sendable {
    public let sourceName: String
    public let durationSeconds: Double
    /// The human name of the language it was read in, as it appears in the header.
    public let language: String
    public let transcript: String

    public init(sourceName: String, durationSeconds: Double, language: String, transcript: String) {
        self.sourceName = sourceName
        self.durationSeconds = durationSeconds
        self.language = language
        self.transcript = transcript
    }

    /// The message body for a composer currently holding `typed`.
    ///
    /// Composed at the moment the transcript lands rather than when the file was picked,
    /// so anything typed WHILE an hour of audio was transcribing is kept.
    public func messageBody(typed: String) -> String {
        RecordingTranscript.messageBody(typed: typed,
                                        sourceName: sourceName,
                                        seconds: durationSeconds,
                                        language: language,
                                        transcript: transcript)
    }
}

/// Where the audio came from, and what has to be cleaned up when it is done with.
public struct RecordingSource: Equatable, Sendable {
    /// The name the user knows the file by, and the one stamped into the header.
    public let displayName: String
    /// The app's own copy, which this model created and this model deletes.
    public let workingURL: URL
    public let durationSeconds: Double
    /// Set when the audio arrived through the share extension, so the app-group
    /// hand-off is discarded alongside the working copy.
    public let handoff: PendingRecording?

    public init(displayName: String, workingURL: URL, durationSeconds: Double,
                handoff: PendingRecording? = nil) {
        self.displayName = displayName
        self.workingURL = workingURL
        self.durationSeconds = durationSeconds
        self.handoff = handoff
    }
}

@MainActor
@Observable
public final class RecordingAttachment {
    /// What the composer should currently be showing.
    public enum Stage: Equatable, Sendable {
        /// Nothing in flight.
        case idle
        /// A readable recording is in hand and the language picker is up.
        case choosingLanguage
        /// Transcribing. The payload is what the progress view draws.
        case running(TranscriptionUpdate)
    }

    public private(set) var stage: Stage = .idle
    /// The one sentence explaining the last failure, or nil. Never a generic one.
    public private(set) var errorMessage: String?
    /// The languages the picker offers, device-preferred first.
    public private(set) var languages: [Locale] = []
    /// The picker's selection. Pre-set by `resolve`; writable because the picker binds
    /// to it.
    public var selectedLanguage: Locale?
    /// The file currently in hand, for the picker's title and the error sentences.
    public private(set) var sourceName: String = ""
    /// A finished transcript waiting to be moved into the composer. Read it with
    /// `takeCompleted()`, which also clears it, so one recording can never land twice.
    public private(set) var completed: CompletedRecording?

    public var isBusy: Bool {
        if case .running = stage { return true }
        return false
    }

    /// Whether a recording is in hand at all — the language picker is up, or the engine is
    /// reading it. Wider than `isBusy`, which is only the transcription itself.
    ///
    /// The composer's durable draft records this: a run that is in flight when the composer
    /// goes away does NOT survive, and cannot, because the working copy is deleted on every
    /// exit path (and swept at the next launch for a run the system killed). So the draft
    /// notes the name and the restored composer says the recording is gone, rather than
    /// handing back text that has quietly lost its transcript.
    public var isInFlight: Bool { stage != .idle }

    private let transcriber: any AudioFileTranscribing
    private let probe: any AudioFileProbing
    private let workingCopy: RecordingWorkingCopy
    private let handoffStore: RecordingHandoffStore?
    private let supportedLocales: @Sendable () async -> [Locale]
    private let preferredLanguages: @Sendable () -> [String]
    private let readLastLanguage: @Sendable () -> String?
    private let writeLastLanguage: @Sendable (String) -> Void

    private var source: RecordingSource?
    private var work: Task<Void, Never>?
    /// Bumped every time a run ends. Callbacks carry the generation they were started
    /// under, so anything arriving after a cancel (or after a second recording has been
    /// picked) is recognised as belonging to a run that is over, and dropped.
    private var generation = 0

    public init(transcriber: any AudioFileTranscribing = SpeechAnalyzerFileTranscriber(),
                probe: any AudioFileProbing = AVAudioFileProbe(),
                workingCopy: RecordingWorkingCopy = .standard(),
                handoffStore: RecordingHandoffStore? = RecordingHandoffStore.shared(),
                supportedLocales: @escaping @Sendable () async -> [Locale]
                    = { await SpeechTranscriptionSupport.supportedLocales() },
                preferredLanguages: @escaping @Sendable () -> [String]
                    = { Locale.preferredLanguages },
                readLastLanguage: @escaping @Sendable () -> String?
                    = { UserDefaults.standard.string(forKey: RecordingAttachment.lastLanguageKey) },
                writeLastLanguage: @escaping @Sendable (String) -> Void
                    = { UserDefaults.standard.set($0, forKey: RecordingAttachment.lastLanguageKey) }) {
        self.transcriber = transcriber
        self.probe = probe
        self.workingCopy = workingCopy
        self.handoffStore = handoffStore
        self.supportedLocales = supportedLocales
        self.preferredLanguages = preferredLanguages
        self.readLastLanguage = readLastLanguage
        self.writeLastLanguage = writeLastLanguage
    }

    /// The remembered language is one device-wide preference, not a per-conversation
    /// one: someone who records in Italian records in Italian everywhere.
    ///
    /// `nonisolated` because the default `UserDefaults` accessors above are `@Sendable`
    /// closures, and a main-actor-isolated constant is not readable from one.
    public nonisolated static let lastLanguageKey = "jesse.recording.lastLanguage"

    // MARK: - Starting

    /// Adopt a file the user picked. `url` is the picker's URL, which may be
    /// security-scoped and is never used after this call returns.
    public func begin(pickedFileAt url: URL, displayName: String? = nil) async {
        let name = displayName ?? url.lastPathComponent
        let working: URL
        do {
            working = try workingCopy.adopt(copying: url)
        } catch {
            fail(.unreadableFile, named: name, run: generation)
            return
        }
        await adopt(RecordingSource(displayName: name,
                                    workingURL: working,
                                    durationSeconds: 0))
    }

    /// Adopt a recording the share extension left in the app group.
    ///
    /// It is copied out of the group container into the app's own working directory and
    /// the hand-off is remembered, so BOTH copies are deleted when the run ends. Leaving
    /// the audio in the group container to transcribe in place would be one fewer copy
    /// and one more way to leave a recording behind.
    public func begin(handoff: PendingRecording) async {
        guard let handoffStore else {
            fail(.engineFailed(reason: "the shared container isn’t available"),
                 named: handoff.originalName, run: generation)
            return
        }
        let working: URL
        do {
            working = try workingCopy.adopt(copying: handoffStore.audioURL(for: handoff))
        } catch {
            handoffStore.discard(handoff)
            fail(.unreadableFile, named: handoff.originalName, run: generation)
            return
        }
        await adopt(RecordingSource(displayName: handoff.originalName,
                                    workingURL: working,
                                    durationSeconds: handoff.durationSeconds ?? 0,
                                    handoff: handoff))
    }

    /// Probe the working copy, load the language list, and raise the picker.
    private func adopt(_ candidate: RecordingSource) async {
        errorMessage = nil
        completed = nil
        sourceName = candidate.displayName

        let facts: AudioFileFacts
        do {
            facts = try probe.facts(forFileAt: candidate.workingURL)
        } catch let failure as TranscriptionFailure {
            source = candidate
            fail(failure, named: candidate.displayName, run: generation)
            return
        } catch {
            source = candidate
            fail(.unreadableFile, named: candidate.displayName, run: generation)
            return
        }

        let supported = await supportedLocales()
        guard !supported.isEmpty else {
            source = candidate
            fail(.engineFailed(reason: "this device has no speech transcription available"),
                 named: candidate.displayName, run: generation)
            return
        }

        source = RecordingSource(displayName: candidate.displayName,
                                 workingURL: candidate.workingURL,
                                 durationSeconds: facts.durationSeconds,
                                 handoff: candidate.handoff)
        languages = TranscriptionLocalePolicy.menu(supported: supported,
                                                   preferred: preferredLanguages())
        selectedLanguage = TranscriptionLocalePolicy.resolve(remembered: readLastLanguage(),
                                                            preferred: preferredLanguages(),
                                                            supported: supported)
        stage = .choosingLanguage
    }

    // MARK: - Running

    /// The picker's confirm. Remembers the language and starts the transcription.
    public func confirmLanguage() {
        guard case .choosingLanguage = stage,
              let source, let locale = selectedLanguage else { return }
        writeLastLanguage(locale.identifier)
        let language = TranscriptionLocalePolicy.displayName(locale)
        stage = .running(TranscriptionUpdate(phase: .preparing, fraction: 0))

        let transcriber = self.transcriber
        let url = source.workingURL
        let name = source.displayName
        let run = generation
        // The task inherits this method's MainActor isolation, so every `self?.` below is
        // an ordinary main-actor call rather than a hop. `onProgress` holds the model for
        // as long as `transcribe` runs — that is what a progress callback is — and the
        // hold ends when the call returns or `cancel()` cancels the task.
        work = Task { [weak self] in
            let onProgress: @Sendable (TranscriptionUpdate) -> Void = { update in
                Task { @MainActor in self?.advance(update, run: run) }
            }
            do {
                let text = try await transcriber.transcribe(fileAt: url,
                                                            locale: locale,
                                                            onProgress: onProgress)
                self?.succeed(transcript: text, language: language, run: run)
            } catch let failure as TranscriptionFailure {
                self?.fail(failure, named: name, run: run)
            } catch is CancellationError {
                self?.fail(.cancelled, named: name, run: run)
            } catch {
                self?.fail(.engineFailed(reason: error.localizedDescription), named: name, run: run)
            }
        }
    }

    /// Progress from the engine, ignored unless it belongs to the run still on screen.
    ///
    /// The race is real rather than theoretical: an engine callback can be mid-hop to
    /// the main actor when Cancel is tapped, and a transcription can finish in the
    /// instant between the tap and the cancellation reaching the engine. Without the
    /// generation check, the first would put the progress view back up after a cancel
    /// and the second would drop a transcript into a composer the user had already
    /// backed out of.
    private func advance(_ update: TranscriptionUpdate, run: Int) {
        guard run == generation, case .running = stage else { return }
        stage = .running(update)
    }

    /// The user's Cancel. Stops the engine and deletes the audio; says nothing, because
    /// the user already knows.
    public func cancel() {
        work?.cancel()
        work = nil
        settle()
    }

    /// The language sheet dismissed without choosing: the same disposal as a cancel.
    public func abandon() {
        guard case .choosingLanguage = stage else { return }
        settle()
    }

    public func dismissError() { errorMessage = nil }

    /// Take the finished transcript, clearing it. The composer calls this once.
    public func takeCompleted() -> CompletedRecording? {
        defer { completed = nil }
        return completed
    }

    // MARK: - Ending

    private func succeed(transcript: String, language: String, run: Int) {
        guard run == generation, let source else { return }
        completed = CompletedRecording(sourceName: source.displayName,
                                       durationSeconds: source.durationSeconds,
                                       language: language,
                                       transcript: transcript)
        work = nil
        settle()
    }

    private func fail(_ failure: TranscriptionFailure, named name: String, run: Int) {
        guard run == generation else { return }
        // A cancel is a decision, not a fault: it deletes the audio and says nothing.
        if failure != .cancelled { errorMessage = failure.message(sourceName: name) }
        work = nil
        settle()
    }

    /// The ONE way a run ends. Deletes the working copy and the hand-off, then returns
    /// to idle. Every terminal path goes through here, which is what makes "no copy of
    /// the audio remains on disk" a property of the type rather than a habit.
    private func settle() {
        if let source {
            workingCopy.remove(source.workingURL)
            if let handoff = source.handoff { handoffStore?.discard(handoff) }
        }
        source = nil
        stage = .idle
        generation &+= 1
    }

    /// Launch-time housekeeping: delete any working copy a crash left behind, and sweep
    /// the shared inbox of hand-offs that were never picked up.
    public func sweepAbandonedAudio(now: Date = Date()) {
        workingCopy.purge()
        handoffStore?.sweep(now: now)
    }

    /// Under this module's default (nonisolated) isolation the synthesized deinit for a
    /// `@MainActor` class is already nonisolated, but it is spelled out for the same
    /// reason the search model spells it out: an instance released off the main actor by
    /// a test host must never route through an isolated-deinit executor hop. The
    /// in-flight task holds `self` weakly, so a dropped model leaves nothing running.
    nonisolated deinit {}
}
