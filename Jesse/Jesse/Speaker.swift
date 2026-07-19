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

/// Speaks an utterance and signals when it finishes. Injected so a test can assert
/// what was delivered (and that delivery is still attempted when the audio session
/// fails) without a real `AVSpeechSynthesizer`.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// Invoked when an utterance finishes or is cancelled, so the owner can tear the
    /// audio session back down.
    var onFinish: (() -> Void)? { get set }
    /// Speak `text` now, interrupting anything in progress (the prior
    /// `stopSpeaking(.immediate)` + `speak`).
    func speak(_ text: String)
    func stop()
}

/// Production conformer over `AVSpeechSynthesizer`, owning the en-US voice and the
/// delegate that maps finish/cancel to `onFinish`.
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing {
    private let synth = AVSpeechSynthesizer()
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}

extension SystemSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}

@MainActor
final class Speaker {
    static let shared = Speaker()

    private let synth: SpeechSynthesizing
    private let session: AudioSessioning

    /// When true, `speak` is a no-op: it never activates the audio session (so it
    /// never ducks other audio) and never hands text to the synth. A dev/debug
    /// convenience — default is driven by the `JESSE_MUTE` environment variable set
    /// on the run scheme, so production (env unset) speaks exactly as before.
    private let muted: Bool

    /// The last audio-session error, surfaced (not swallowed) for diagnostics and
    /// so a test can assert a routing failure was observed rather than dropped.
    private(set) var lastSessionError: Error?

    /// `synth` defaults to the real `AVSpeechSynthesizer`-backed one, constructed on
    /// the main actor inside the initializer (a non-nil default argument would be
    /// evaluated off the actor). Tests inject a spy.
    init(session: AudioSessioning = SystemAudioSession(),
         synth: SpeechSynthesizing? = nil,
         muted: Bool = ProcessInfo.processInfo.environment["JESSE_MUTE"] != nil) {
        self.session = session
        self.muted = muted
        self.synth = synth ?? SystemSpeechSynthesizer()
        // Tear the audio session down once speech ends (un-ducking other audio).
        self.synth.onFinish = { [weak self] in self?.deactivateSession() }
    }

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Dev/debug mute (JESSE_MUTE): return before activating the audio session so
        // muting never ducks other audio and never reaches the synth.
        guard !muted else { return }
        // Real error handling, not `try?`. A routing/category failure used to be
        // swallowed silently, dropping the voice reply with no trace. Log and record
        // it; still attempt to speak (playback may route to the default output).
        do {
            try session.activate()
        } catch {
            lastSessionError = error
            Log.speaker.error("audio session activate failed: \(error.localizedDescription)")
        }
        synth.speak(t)
    }

    func stop() { synth.stop() }

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
