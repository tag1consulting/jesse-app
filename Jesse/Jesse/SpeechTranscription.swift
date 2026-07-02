import Foundation
import Speech

// Phone-side speech-to-text for watch-relayed audio. The watch captures audio and
// hands it to the phone; the phone transcribes it HERE (on-device where the
// hardware supports it) and feeds the text into `WatchRelay`. The watch never
// transcribes and never reaches the bridge.
//
// Transcription sits behind the `AudioTranscribing` seam so the relay path is
// testable without a microphone or the Speech framework: a test injects a fake
// transcriber and asserts the produced text is exactly what gets relayed.

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
        guard await Self.ensureAuthorized() else { return nil }
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

    /// Ensure Speech authorization, prompting once if undetermined. Any state other
    /// than authorized yields false (the relay then answers "couldn't understand").
    private static func ensureAuthorized() async -> Bool {
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
