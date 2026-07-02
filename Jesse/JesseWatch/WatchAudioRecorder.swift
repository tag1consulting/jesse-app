import AVFoundation
import Foundation

// Captures a spoken turn on the watch: AVAudioRecorder writing a compressed
// (AAC/m4a) clip, metered on a timer, auto-stopping on ~1.5 s of trailing silence
// (via the pure `SilenceDetector`) or a hard max-record cap — with a manual
// tap-to-stop override. It reads the finished file's bytes and hands them back
// through `onFinish`. The watch never transcribes and never reaches the bridge; it
// only produces audio for the phone to relay.

@MainActor
final class WatchAudioRecorder: NSObject, WatchAudioRecording {
    var onFinish: ((Result<Data, Error>) -> Void)?
    private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var samples: [MeterSample] = []
    private var startedAt: Date?
    private var fileURL: URL?

    private let detector: SilenceDetector
    /// How often to sample the meter (seconds).
    private let meterInterval: TimeInterval

    enum RecorderError: LocalizedError {
        case micPermissionDenied
        case couldNotStart(String)
        var errorDescription: String? {
            switch self {
            case .micPermissionDenied: return "Microphone access is off for Jesse."
            case .couldNotStart(let m): return m
            }
        }
    }

    init(detector: SilenceDetector = SilenceDetector(), meterInterval: TimeInterval = 0.1) {
        self.detector = detector
        self.meterInterval = meterInterval
        super.init()
    }

    func start() {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            Task { @MainActor in
                guard granted else { self.finish(.failure(RecorderError.micPermissionDenied)); return }
                self.beginRecording(session: session)
            }
        }
    }

    private func beginRecording(session: AVAudioSession) {
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            finish(.failure(RecorderError.couldNotStart(error.localizedDescription)))
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        // Low-bitrate mono AAC keeps the clip small enough for a fast relay.
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
            guard r.record() else {
                finish(.failure(RecorderError.couldNotStart("The recorder wouldn't start.")))
                return
            }
            recorder = r
            fileURL = url
            samples = []
            startedAt = Date()
            isRecording = true
            let timer = Timer.scheduledTimer(withTimeInterval: meterInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.tick() }
            }
            meterTimer = timer
        } catch {
            finish(.failure(RecorderError.couldNotStart(error.localizedDescription)))
        }
    }

    /// One metering tick: record the sample, ask the pure detector whether to stop.
    private func tick() {
        guard let recorder, isRecording, let startedAt else { return }
        recorder.updateMeters()
        let elapsed = Date().timeIntervalSince(startedAt)
        samples.append(MeterSample(t: elapsed, power: recorder.averagePower(forChannel: 0)))
        switch detector.decide(samples: samples) {
        case .listening:
            break
        case .stopSilence, .stopMaxDuration:
            stop()
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        guard let url = fileURL else {
            finish(.failure(RecorderError.couldNotStart("No recording was made.")))
            return
        }
        do {
            let data = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            finish(.success(data))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        isRecording = false
        onFinish?(result)
    }
}
