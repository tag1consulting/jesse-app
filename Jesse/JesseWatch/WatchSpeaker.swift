import AVFoundation
import Foundation

// Speaks the reply aloud on the wrist. Configures a playback audio session so the
// utterance routes to the watch speaker or a paired Bluetooth output, then speaks
// via AVSpeechSynthesizer. Mirrors the phone's Speaker but trimmed for watchOS.

@MainActor
final class WatchSpeaker: NSObject, WatchSpeaking {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // Still attempt to speak; playback may route to the default output.
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.stopSpeaking(at: .immediate)
        synth.speak(utterance)
    }
}
