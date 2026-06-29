import AVFoundation

// On-device TTS for spoken replies. No permission needed.
//
// Audio-session configuration goes through the `AudioSessioning` seam so a routing
// failure is logged/surfaced (not swallowed by `try?`), and so a test can force a
// failure without a real `AVAudioSession`. The session is deactivated once speech
// finishes — leaving `.duckOthers` active would keep other audio ducked after the
// reply is read.

/// Configures and tears down the audio session for spoken playback. Injected so a
/// test can drive a routing failure deterministically.
@MainActor
protocol AudioSessioning {
    /// Activate the playback/duck session before speaking.
    func activate() throws
    /// Deactivate it after speech finishes (un-ducking other audio).
    func deactivate() throws
}

/// Production conformer over the shared `AVAudioSession`.
struct SystemAudioSession: AudioSessioning {
    nonisolated init() {}

    func activate() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try s.setActive(true)
    }

    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

@MainActor
final class Speaker: NSObject {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    private let session: AudioSessioning

    /// The last audio-session error, surfaced (not swallowed) for diagnostics and
    /// so a test can assert a routing failure was observed rather than dropped.
    private(set) var lastSessionError: Error?

    init(session: AudioSessioning = SystemAudioSession()) {
        self.session = session
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Real error handling, not `try?`. A routing/category failure used to be
        // swallowed silently, dropping the voice reply with no trace. Log and record
        // it; still attempt to speak (playback may route to the default output).
        do {
            try session.activate()
        } catch {
            lastSessionError = error
            Log.speaker.error("audio session activate failed: \(error.localizedDescription)")
        }
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// Deactivate the audio session after speech ends, logging (not swallowing) a
    /// failure. Un-ducks other audio that `.duckOthers` was suppressing.
    private func deactivateSession() {
        do {
            try session.deactivate()
        } catch {
            lastSessionError = error
            Log.speaker.error("audio session deactivate failed: \(error.localizedDescription)")
        }
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.deactivateSession() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.deactivateSession() }
    }
}
