import Foundation
import Observation

// The watch's talk orchestrator — the piece the watch tests drive. It owns the
// state machine behind the one big "talk" button (single tap to start, tap again
// to stop; auto-stop is the recorder's job), turns a finished recording into a
// `WatchRequest`, hands it to the sender, and renders/speaks the reply exactly
// once (de-duped by requestId, since the phone answers on two transports).
//
// Every side effect is behind an injected seam (recorder, sender, speaker,
// haptic), so the tests exercise the whole flow — tap → record → send → reply →
// speak, plus the two-path dedup and the unreachable "queued" path — with fakes
// and no watch hardware.

/// Records audio and reports the finished clip (or a failure).
@MainActor
protocol WatchAudioRecording: AnyObject {
    var onFinish: ((Result<Data, Error>) -> Void)? { get set }
    var isRecording: Bool { get }
    func start()
    /// Manual stop (tap-to-stop override); the recorder also stops itself on silence
    /// or the hard cap, delivering via `onFinish` either way.
    func stop()
}

/// Sends a relayed turn to the phone and reports replies. The conformer chooses the
/// transport (immediate vs reliable vs file) and queues when the phone is
/// unreachable — the model only needs to know reachability for its status copy.
@MainActor
protocol WatchRequestSending: AnyObject {
    var isReachable: Bool { get }
    var onReply: ((WatchReply) -> Void)? { get set }
    func send(_ request: WatchRequest)
}

/// Speaks the reply aloud on the wrist.
@MainActor
protocol WatchSpeaking: AnyObject {
    func speak(_ text: String)
}

@MainActor
@Observable
final class WatchTalkModel {
    /// What the single view shows.
    enum State: Equatable {
        case idle
        case listening
        case thinking
        case reply(display: String, spoken: String)
        case error(String)
        /// Sent while the phone was unreachable — it'll be relayed once the phone is
        /// back, never silently dropped.
        case queued
    }

    private(set) var state: State = .idle
    /// Ask (read) vs Tell (capture). Defaults to Ask per the brief.
    var mode: WatchMode = .ask

    private let recorder: WatchAudioRecording
    private let sender: WatchRequestSending
    private let speaker: WatchSpeaking
    private let haptic: @MainActor () -> Void

    private var deduper = ReplyDeduper()
    private var currentRequestId: UUID?

    init(recorder: WatchAudioRecording,
         sender: WatchRequestSending,
         speaker: WatchSpeaking,
         haptic: @escaping @MainActor () -> Void) {
        self.recorder = recorder
        self.sender = sender
        self.speaker = speaker
        self.haptic = haptic
        self.recorder.onFinish = { [weak self] in self?.recordingFinished($0) }
        self.sender.onReply = { [weak self] in self?.receive($0) }
    }

    /// The single button. One tap starts listening; a second tap while listening is
    /// the manual stop. Taps while the phone is working are ignored; a tap after a
    /// reply/error starts a fresh take.
    func tapTalk() {
        switch state {
        case .listening:
            recorder.stop()
        case .idle, .reply, .error, .queued:
            state = .listening
            recorder.start()
        case .thinking:
            break
        }
    }

    /// The recorder finished (silence, cap, or manual stop). Build the request and
    /// send it; a capture failure surfaces, never a silent drop.
    private func recordingFinished(_ result: Result<Data, Error>) {
        guard case .listening = state else { return } // stale callback after a reset
        switch result {
        case .success(let audio):
            guard !audio.isEmpty else {
                state = .error("I didn't catch anything — tap to try again.")
                return
            }
            let id = UUID()
            currentRequestId = id
            let request = WatchRequest(requestId: id, mode: mode, audio: audio)
            // Reachable → the phone is working on it now; unreachable → it's queued
            // for reliable delivery and we say so.
            state = sender.isReachable ? .thinking : .queued
            sender.send(request)
        case .failure(let error):
            state = .error("Couldn't record: \(error.localizedDescription)")
        }
    }

    /// A reply arrived (possibly on both transports). Render/speak the FIRST arrival
    /// per requestId and drop the rest.
    private func receive(_ reply: WatchReply) {
        guard deduper.shouldDeliver(reply.requestId) else { return }
        if reply.ok {
            state = .reply(display: reply.displayText, spoken: reply.spokenText)
            haptic()
            if !reply.spokenText.isEmpty { speaker.speak(reply.spokenText) }
        } else {
            state = .error(reply.error ?? "Something went wrong.")
            haptic()
        }
    }
}
