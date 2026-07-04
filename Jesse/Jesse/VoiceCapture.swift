import AVFoundation
import Combine
import Foundation

// In-app capture of a spoken request for the hands-free wake path. The doorbell
// intent (`WakeJesseIntent`) only foregrounds the app; the request itself is
// recorded and transcribed HERE — never through Siri's unreliable free-text
// `requestValueDialog`. That separation is the whole point of the doorbell
// architecture: Siri parses only a short, distinctive trigger, and the
// open-ended request is captured by the app once it's open.
//
// It reuses the exact proven pieces the watch relay already uses — the shared
// pure `SilenceDetector` for end-of-speech, and the app's on-device
// `SpeechFrameworkTranscriber` for STT — so there's no second speech stack to
// keep working.

/// Records a single spoken phrase to compressed audio, auto-stopping on trailing
/// silence. Behind a seam so `VoiceCaptureModel` is testable without a mic.
@MainActor
protocol VoiceRecording: AnyObject {
    /// Record until trailing silence / the hard cap / an explicit `stop()`.
    /// Returns the recorded bytes, or nil on permission denial, failure, or
    /// `cancel()`.
    func record() async -> Data?
    /// End the take early but keep it (the user tapped Stop).
    func stop()
    /// Abort and discard the take (the user tapped Cancel) — `record()` yields nil.
    func cancel()
}

/// Orchestrates the wake capture: record a phrase, then transcribe it. ContentView
/// observes `phase` to show a listening/transcribing overlay and calls `stop()` /
/// `cancel()` from its buttons.
@MainActor
final class VoiceCaptureModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, transcribing }
    @Published private(set) var phase: Phase = .idle

    private let recorder: VoiceRecording
    private let transcriber: AudioTranscribing

    /// Both collaborators default to the real ones, constructed inside the
    /// initializer on the main actor (a non-nil default argument would be evaluated
    /// off the actor). Tests inject fakes.
    init(recorder: VoiceRecording? = nil, transcriber: AudioTranscribing? = nil) {
        self.recorder = recorder ?? PhoneVoiceRecorder()
        self.transcriber = transcriber ?? SpeechFrameworkTranscriber()
    }

    /// Record a phrase then transcribe it. Returns the trimmed transcript, or nil
    /// if the user cancelled, denied the mic, or nothing intelligible was said.
    /// Re-entrancy-safe: a call while already capturing is a no-op.
    func capture() async -> String? {
        guard phase == .idle else { return nil }
        phase = .listening
        let audio = await recorder.record()
        guard let audio, !audio.isEmpty else { phase = .idle; return nil }
        phase = .transcribing
        let text = await transcriber.transcribe(audio)
        phase = .idle
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// End recording early; the take so far is kept and transcribed.
    func stop() { recorder.stop() }

    /// Abort recording; the take is discarded and `capture()` returns nil.
    func cancel() { recorder.cancel() }
}

/// Production recorder over `AVAudioRecorder`, metered on a timer and auto-stopped
/// by the pure `SilenceDetector` — the phone-side twin of `WatchAudioRecorder`,
/// exposed as an `async` call for the wake flow. Low-bitrate mono AAC, the same
/// format the transcriber already ingests.
@MainActor
final class PhoneVoiceRecorder: NSObject, VoiceRecording {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var samples: [MeterSample] = []
    private var startedAt: Date?
    private var fileURL: URL?
    private var continuation: CheckedContinuation<Data?, Never>?

    private let detector: SilenceDetector
    /// How often to sample the meter (seconds).
    private let meterInterval: TimeInterval

    init(detector: SilenceDetector = SilenceDetector(), meterInterval: TimeInterval = 0.1) {
        self.detector = detector
        self.meterInterval = meterInterval
        super.init()
    }

    func record() async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            self.continuation = cont
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    // A cancel() during the permission prompt already resumed the
                    // waiter — don't start an ownerless recording.
                    guard self.continuation != nil else { return }
                    guard granted else { self.finish(nil); return }
                    self.beginRecording()
                }
            }
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            Log.run.error("voice capture: couldn't start audio session: \(error.localizedDescription)")
            finish(nil)
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 24_000,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { finish(nil); return }
            recorder = r
            fileURL = url
            samples = []
            startedAt = Date()
            let timer = Timer.scheduledTimer(withTimeInterval: meterInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.tick() }
            }
            meterTimer = timer
        } catch {
            Log.run.error("voice capture: recorder failed to start: \(error.localizedDescription)")
            finish(nil)
        }
    }

    /// One metering tick: record the sample, ask the pure detector whether to stop.
    private func tick() {
        guard let recorder, let startedAt, meterTimer != nil else { return }
        recorder.updateMeters()
        let elapsed = Date().timeIntervalSince(startedAt)
        samples.append(MeterSample(t: elapsed, power: recorder.averagePower(forChannel: 0)))
        switch detector.decide(samples: samples) {
        case .listening:
            break
        case .stopSilence, .stopMaxDuration:
            finalize(keep: true)
        }
    }

    func stop() { finalize(keep: true) }

    func cancel() { finalize(keep: false) }

    /// Stop metering + recording, tear the session down, then resume the waiter with
    /// the recorded bytes (or nil when discarding / on a read failure). Idempotent —
    /// the auto-stop tick and a manual stop can both land here.
    private func finalize(keep: Bool) {
        guard meterTimer != nil || recorder != nil else {
            // Not recording yet (e.g. cancel during the permission prompt): resume
            // the pending waiter so `record()` doesn't hang.
            if !keep { finish(nil) }
            return
        }
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        let url = fileURL
        fileURL = nil
        guard keep, let url else { finish(nil); return }
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        finish(data)
    }

    /// Resume the pending continuation exactly once.
    private func finish(_ data: Data?) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: data)
    }
}
