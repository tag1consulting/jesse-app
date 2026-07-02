import Foundation
import SwiftData
import WatchConnectivity

// The phone half of the watch relay. Receives a spoken turn from the Jesse Watch
// App over WatchConnectivity, transcribes the audio on-device (via the
// `AudioTranscribing` seam), feeds the text into the existing `WatchRelay` entry
// point (which tags the thread `.watch`, dedups by requestId, persists, and
// returns the reply), and ships the reply back to the watch on two paths:
// `transferUserInfo` (reliable, background-delivered source of truth) and, when
// reachable, `sendMessage` (immediate). The watch de-dupes by requestId.
//
// The turn logic lives in `WatchTurnHandler`, which is pure of WatchConnectivity
// so it can be unit-tested end to end (fake transcriber → transcript → relay).
// `PhoneWatchConnectivity` is the thin `WCSessionDelegate` that decodes the wire,
// calls the handler, and sends the reply — no turn/persistence logic of its own.

/// The testable core: transcribe (or take the dictated fallback), relay, and shape
/// the reply the watch will render. Holds no WatchConnectivity — a test drives it
/// with a fake transcriber and the same `WatchRelay` fakes the relay tests use.
@MainActor
final class WatchTurnHandler {
    private let transcriber: AudioTranscribing
    private let relay: WatchRelay

    init(transcriber: AudioTranscribing, relay: WatchRelay) {
        self.transcriber = transcriber
        self.relay = relay
    }

    /// Resolve the request to text (transcribe audio, or use the dictated fallback),
    /// relay it through `WatchRelay`, and map the outcome to a `WatchReply`. Never
    /// throws — every failure becomes an `ok: false` reply with a user-safe message.
    func handle(_ request: WatchRequest, context: ModelContext) async -> WatchReply {
        let text: String
        if let dictated = request.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dictated.isEmpty {
            // Documented text fallback (dictation) — no audio to transcribe.
            text = dictated
        } else if let audio = request.audio {
            guard let transcript = await transcriber.transcribe(audio)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty else {
                return WatchReply(requestId: request.requestId, ok: false,
                                  error: "Couldn't understand the audio.")
            }
            text = transcript
        } else {
            return WatchReply(requestId: request.requestId, ok: false,
                              error: "No audio was received.")
        }

        let mode: JesseMode = (request.mode == .tell) ? .tell : .ask
        let turn = RelayedTurn(requestId: request.requestId, text: text, mode: mode, voice: true)
        switch await relay.relay(turn, context: context) {
        case .delivered(let result):
            return WatchReply(requestId: request.requestId, ok: true,
                              displayText: result.displayText, spokenText: result.spokenText,
                              sessionId: result.sessionId, threadId: result.threadId)
        case .failure(let message, let threadId):
            return WatchReply(requestId: request.requestId, ok: false,
                              threadId: threadId, error: message)
        }
    }
}

/// The app-lifetime `WCSession` delegate on the phone. Activated once at launch.
@MainActor
final class PhoneWatchConnectivity: NSObject {
    static let shared = PhoneWatchConnectivity()

    private let handler: WatchTurnHandler
    private let context: ModelContext
    private var session: WCSession?

    /// Production init wires the on-device transcriber and a `WatchRelay` over a
    /// fresh coordinator, persisting into the app's shared SwiftData store so a
    /// relayed turn lands in the same history the UI shows.
    override convenience init() {
        let relay = WatchRelay(coordinator: RunCoordinator())
        self.init(handler: WatchTurnHandler(transcriber: SpeechFrameworkTranscriber(), relay: relay),
                  context: AppModelContainer.shared.mainContext)
    }

    init(handler: WatchTurnHandler, context: ModelContext) {
        self.handler = handler
        self.context = context
        super.init()
    }

    /// Activate the session if the device supports a paired watch. Safe to call on
    /// an iPad (where `WCSession` is unsupported): it simply no-ops.
    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        session = s
    }

    // MARK: - Reply delivery (two paths, watch de-dupes by requestId)

    private func send(_ reply: WatchReply) {
        let dict = WatchMessage.reply(reply).encode()
        guard let session, session.activationState == .activated else { return }
        // Reliable, background-delivered source of truth — survives the watch app not
        // being frontmost.
        session.transferUserInfo(dict)
        // Immediate delivery too when the watch is reachable; the watch drops the
        // duplicate by requestId.
        if session.isReachable {
            session.sendMessage(dict, replyHandler: nil) { error in
                Log.run.error("watch reply sendMessage failed: \(error.localizedDescription)")
            }
        }
    }

    /// Decode an incoming request, run the turn, and send the reply back.
    private func process(_ request: WatchRequest) {
        Task { @MainActor in
            let reply = await handler.handle(request, context: context)
            send(reply)
        }
    }

    /// Build a `WatchRequest` from a transferred audio file plus its metadata.
    private nonisolated func request(fromFile file: WCSessionFile) -> WatchRequest? {
        guard let metadata = file.metadata,
              case .request(let meta)? = WatchMessage.decode(metadata) else { return nil }
        guard let bytes = try? Data(contentsOf: file.fileURL), !bytes.isEmpty else { return nil }
        return WatchRequest(requestId: meta.requestId, mode: meta.mode, audio: bytes,
                            audioViaFile: false, transcript: meta.transcript)
    }
}

// WCSessionDelegate methods arrive off the main actor; each hops back on before
// touching the handler or session state.
extension PhoneWatchConnectivity: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            Log.run.error("watch session activation failed: \(error.localizedDescription)")
        }
    }

    // iOS requires these so the session can re-activate when the user switches
    // watches. Re-activate to keep receiving relayed turns.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    // Immediate path: reply with an ack, then process and deliver the reply.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard case .request(let request)? = WatchMessage.decode(message) else {
            replyHandler(["v": WatchMessage.version, "type": "ack", "requestId": "",
                          "ok": false])
            return
        }
        replyHandler(WatchMessage.ack(WatchAck(requestId: request.requestId, accepted: true)).encode())
        Task { @MainActor in self.process(request) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard case .request(let request)? = WatchMessage.decode(message) else { return }
        Task { @MainActor in self.process(request) }
    }

    // Reliable/queued path: a request that rode `transferUserInfo` (e.g. sent while
    // the phone was unreachable).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard case .request(let request)? = WatchMessage.decode(userInfo) else { return }
        Task { @MainActor in self.process(request) }
    }

    // Audio delivered out-of-band as a file (clips too big for `sendMessage`).
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let request = request(fromFile: file) else { return }
        Task { @MainActor in self.process(request) }
    }
}
