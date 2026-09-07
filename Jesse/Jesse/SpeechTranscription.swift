import Foundation
import Speech
import JesseSpeech

// Phone-side speech-to-text for watch-relayed audio. The watch captures audio and
// hands it to the phone; the phone transcribes it HERE (on-device where the
// hardware supports it) and feeds the text into `WatchRelay`. The watch never
// transcribes and never reaches the bridge.
//
// Transcription sits behind the `AudioTranscribing` seam so the relay path is
// testable without a microphone or the Speech framework: a test injects a fake
// transcriber and asserts the produced text is exactly what gets relayed.
//
// THIS IS THE SHORT-FORM PATH, AND IT STAYS THAT WAY. Attaching a recorded FILE — ten to
// sixty minutes of it, in a language chosen at pick time, with progress and a Cancel —
// is a different job with different failure modes, and it lives in
// `JesseSpeech.SpeechAnalyzerFileTranscriber` over iOS 26's long-form
// `SpeechAnalyzer`/`SpeechTranscriber`. Nothing here changed for it: seconds of speech
// wanting a prompt answer is exactly what `SFSpeechRecognizer` is right for, and the
// 30-second bound below is a sensible guard for a relay that must not be parked forever.
// (It is emphatically NOT a sensible guard for an hour of audio, which is why the file
// path measures progress instead of wall clock.)

/// Turns compressed audio bytes into text. Returns nil on ANY failure — no
/// permission, an unavailable recognizer, or audio that couldn't be understood —
/// so the caller surfaces a clean "couldn't understand" rather than a throw.
protocol AudioTranscribing: Sendable {
    func transcribe(_ audio: Data) async -> String?
}

/// Single-resume guard for a recognition callback that may fire more than once
/// (partial/final/error). Reference-typed with a lock so the `@Sendable` callback
/// and the timeout task can race safely.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true exactly once — the first caller wins and owns the resume.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Production transcriber over `SFSpeechRecognizer`, preferring on-device/offline
/// recognition when the device supports it (so audio isn't sent to Apple's servers
/// for a private vault assistant). Requires the Speech + microphone usage strings
/// and Speech authorization, requested lazily on first use.
struct SpeechFrameworkTranscriber: AudioTranscribing {
    let locale: Locale

    init(locale: Locale = Locale(identifier: "en-US")) { self.locale = locale }

    func transcribe(_ audio: Data) async -> String? {
        guard !audio.isEmpty else { return nil }
        guard await SpeechAuthorization.ensure() else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { return nil }

        // SFSpeechURLRecognitionRequest wants a file; write the received clip out and
        // clean it up afterward.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        do { try audio.write(to: url, options: .atomic) } catch {
            Log.run.error("STT: couldn't stage audio for transcription: \(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    if once.claim() { cont.resume(returning: nil) }
                }
            }
            // A stuck recognizer must not park the relay forever — bound the wait.
            Task {
                try? await Task.sleep(for: .seconds(30))
                if once.claim() {
                    task.cancel()
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // Authorization moved to `JesseSpeech.SpeechAuthorization` when the file path needed
    // the same question asked. Behaviour is byte for byte what it was: authorized is
    // true, undetermined prompts once, everything else is false — and the relay still
    // answers "couldn't understand" for a false.
}
