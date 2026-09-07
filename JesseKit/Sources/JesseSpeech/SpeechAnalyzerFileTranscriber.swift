import AVFoundation
import Foundation
import Speech

// The production file transcriber, over `SpeechAnalyzer` + `SpeechTranscriber`.
//
// WHY NOT SFSpeechRecognizer, WHICH THE APP ALREADY HAS. `SFSpeechURLRecognitionRequest`
// is a short-form dictation interface: it is documented for about a minute of audio, it
// reports one growing result rather than a stream of finalized ranges (so there is
// nothing to draw a progress bar from and nothing to base a stall rule on), and its
// on-device path depends on `supportsOnDeviceRecognition` being true for the locale
// rather than on an installable model. An hour of Italian is not the job it was built
// for.
//
// `SpeechAnalyzer` is, and the difference is structural rather than a matter of limits:
// it takes an `AVAudioFile` directly, it downloads and runs a per-locale on-device model
// through `AssetInventory`, and it emits `SpeechTranscriber.Result`s each carrying the
// `CMTimeRange` of audio they cover. That range is what makes the two hard requirements
// here satisfiable at all — the progress bar is audio-consumed over audio-total, and the
// stall rule watches that same number stop moving. Both are facts the engine reports,
// not timers over it.
//
// The watch relay keeps `SFSpeechRecognizer` (see the app's `SpeechTranscription.swift`)
// and is untouched: seconds of speech wanting a prompt answer is exactly the job that
// interface is right for, and its 30-second bound is a sensible guard there.
//
// NOTHING LEAVES THE DEVICE. `SpeechTranscriber` runs against a locally installed model;
// the only network traffic in this file is `AssetInstallationRequest.downloadAndInstall`
// fetching Apple's language model, once per language per device. The recording itself is
// never uploaded anywhere by anyone.

/// Speech authorization, requested lazily and answered as a plain bool.
///
/// Shared so the phone has ONE spelling of the question. It was previously private to
/// the watch-relay transcriber; that file now calls this, with identical behaviour.
public enum SpeechAuthorization {
    /// True iff transcription may proceed. Prompts once when undetermined; any other
    /// state (denied, restricted) is false, which callers surface as
    /// `TranscriptionFailure.speechPermissionDenied`.
    public static func ensure() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }
}

/// The languages this device can transcribe files in, as the picker needs them.
public enum SpeechTranscriptionSupport {
    /// Every locale `SpeechTranscriber` supports here. Empty when the feature is
    /// unavailable on the device at all.
    public static func supportedLocales() async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales
    }
}

public struct SpeechAnalyzerFileTranscriber: AudioFileTranscribing {
    /// Seconds without progress before the run is abandoned. See
    /// `TranscriptionStallDetector` for why this is not a wall-clock deadline.
    public let stallLimit: TimeInterval

    public init(stallLimit: TimeInterval = TranscriptionStallDetector.defaultLimit) {
        self.stallLimit = stallLimit
    }

    public func transcribe(fileAt url: URL,
                           locale: Locale,
                           onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws -> String {
        onProgress(TranscriptionUpdate(phase: .preparing, fraction: 0))
        guard await SpeechAuthorization.ensure() else {
            throw TranscriptionFailure.speechPermissionDenied
        }
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionFailure.engineFailed(reason: "speech transcription isn’t available on this device")
        }

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw TranscriptionFailure.unreadableFile
        }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { throw TranscriptionFailure.unreadableFile }
        let duration = Double(file.length) / rate

        let language = TranscriptionLocalePolicy.displayName(locale)
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionFailure.localeUnavailable(language: language)
        }

        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        let state = RunState(limit: stallLimit)

        try await installModelIfNeeded(for: transcriber,
                                       language: language,
                                       state: state,
                                       onProgress: onProgress)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await state.restart()
        onProgress(TranscriptionUpdate(phase: .transcribing, fraction: 0))

        let transcript = try await run(analyzer: analyzer,
                                       transcriber: transcriber,
                                       file: file,
                                       duration: duration,
                                       state: state,
                                       onProgress: onProgress)

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionFailure.noSpeechFound }
        return trimmed
    }

    // MARK: - The model

    /// Fetch the on-device model for the chosen language if this device does not have it.
    ///
    /// `assetInstallationRequest(supporting:)` answers nil when nothing needs installing,
    /// which is the second and every later recording in a language — so the common case
    /// costs one await and no UI. A first Italian recording downloads, and reports the
    /// download as its own phase because it is minutes of waiting in which no word will
    /// be recognized.
    private func installModelIfNeeded(for transcriber: SpeechTranscriber,
                                      language: String,
                                      state: RunState,
                                      onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws {
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch {
            throw TranscriptionFailure.modelUnavailable(language: language,
                                                        reason: error.localizedDescription)
        }
        guard let request else { return }

        await state.restart()
        onProgress(TranscriptionUpdate(phase: .downloadingModel, fraction: 0))
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await request.downloadAndInstall() }
                group.addTask {
                    // The download's own progress feeds the SAME stall rule the
                    // transcription does, so a fetch that dies mid-flight fails in
                    // `stallLimit` seconds rather than hanging until the app is killed.
                    while true {
                        try await Task.sleep(for: .milliseconds(500))
                        let fraction = request.progress.fractionCompleted
                        await state.note(fraction)
                        onProgress(TranscriptionUpdate(phase: .downloadingModel, fraction: fraction))
                        if await state.isStalled() {
                            throw TranscriptionFailure.modelUnavailable(
                                language: language,
                                reason: "the download stopped making progress")
                        }
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch is CancellationError {
            throw TranscriptionFailure.cancelled
        } catch {
            throw TranscriptionFailure.modelUnavailable(language: language,
                                                        reason: error.localizedDescription)
        }
    }

    // MARK: - The analysis

    /// Three concurrent jobs for one file: consume results, push audio through, and
    /// watch for a stall. The first two end together (the result stream closes when the
    /// analyzer finalizes); the third is cancelled when they do.
    private func run(analyzer: SpeechAnalyzer,
                     transcriber: SpeechTranscriber,
                     file: AVAudioFile,
                     duration: Double,
                     state: RunState,
                     onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    var accumulated = ""
                    for try await result in transcriber.results {
                        accumulated += String(result.text.characters)
                        let consumed = result.range.end.seconds
                        // Progress is AUDIO CONSUMED, reported by the engine. A result
                        // that covers no new audio does not advance it, and does not
                        // reset the stall clock — which is the point.
                        await state.note(consumed)
                        onProgress(TranscriptionUpdate(
                            phase: .transcribing,
                            fraction: duration > 0 ? consumed / duration : 0,
                            transcript: accumulated))
                    }
                    return accumulated
                }
                group.addTask {
                    if let last = try await analyzer.analyzeSequence(from: file) {
                        try await analyzer.finalizeAndFinish(through: last)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                    return nil
                }
                group.addTask {
                    do {
                        while true {
                            try await Task.sleep(for: .seconds(1))
                            guard await state.isStalled() else { continue }
                            await analyzer.cancelAndFinishNow()
                            throw TranscriptionFailure.stalled
                        }
                    } catch is CancellationError {
                        // Either the user cancelled, or the work finished and this
                        // watchdog is being wound down. Only the first needs the engine
                        // stopped; `finished` is what tells them apart, so a completed
                        // run never calls cancel on an analyzer that has already
                        // finalized.
                        if await !state.isFinished() { await analyzer.cancelAndFinishNow() }
                        throw CancellationError()
                    }
                }

                var transcript = ""
                var completed = 0
                while let value = try await group.next() {
                    if let value { transcript = value }
                    completed += 1
                    if completed == 2 { break }
                }
                await state.finish()
                group.cancelAll()
                return transcript
            }
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch is CancellationError {
            throw TranscriptionFailure.cancelled
        } catch {
            throw TranscriptionFailure.engineFailed(reason: error.localizedDescription)
        }
    }
}

/// The stall detector, plus the "we got there" flag, behind an actor so the results
/// consumer and the watchdog can both touch them.
///
/// `ProcessInfo.systemUptime` rather than `Date`: it is monotonic, so a clock adjustment
/// mid-transcription cannot invent a stall or hide one.
private actor RunState {
    private var detector: TranscriptionStallDetector
    private var finished = false

    init(limit: TimeInterval) {
        detector = TranscriptionStallDetector(limit: limit, startedAt: Self.now())
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func note(_ marker: Double) { detector.note(marker: marker, at: Self.now()) }
    func restart() { detector.restart(at: Self.now()) }
    func isStalled() -> Bool { detector.isStalled(at: Self.now()) }
    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}
