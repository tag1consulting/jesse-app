import Foundation
import WatchConnectivity

// The watch half of the relay: sends a spoken turn to the phone over
// WatchConnectivity and surfaces the phone's reply. It NEVER talks to the bridge
// and holds no bridge token — the phone is the only thing it speaks to.
//
// Transport choice:
//   * Reachable + small clip → `sendMessage` (immediate), with the phone's ack in
//     the reply handler.
//   * Larger clip → `transferFile` (no strict size limit), audio out-of-band with a
//     metadata dictionary; reliable and background-delivered.
//   * Unreachable → `transferUserInfo` (reliable, queued until the phone is back) —
//     the request is never silently dropped.
// The phone answers on `transferUserInfo` (source of truth) AND `sendMessage`
// (immediacy); `WatchTalkModel` de-dupes by requestId so a reply renders once.

@MainActor
final class WatchConnectivityClient: NSObject, WatchRequestSending {
    static let shared = WatchConnectivityClient()

    var onReply: ((WatchReply) -> Void)?

    private var session: WCSession?

    var isReachable: Bool { session?.isReachable ?? false }

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        session = s
    }

    func send(_ request: WatchRequest) {
        guard let session else { return }
        let audio = request.audio ?? Data()

        // Small enough for a live message and the phone is reachable → send now.
        if session.isReachable, audio.count <= WatchMessage.maxInlineAudioBytes, !audio.isEmpty {
            let dict = WatchMessage.request(request).encode()
            session.sendMessage(dict, replyHandler: { _ in
                // Ack received; the real reply arrives later via the delegate paths.
            }, errorHandler: { [weak self] _ in
                // The live send failed — fall back to a reliable transfer so the turn
                // still goes through. Hop to the main actor first.
                Task { @MainActor in self?.transferReliably(request) }
            })
            return
        }
        transferReliably(request)
    }

    /// Reliable, background-delivered fallback: a file for the audio (no size cap) or
    /// a queued userInfo for the text/no-audio case.
    private func transferReliably(_ request: WatchRequest) {
        guard let session, let audio = request.audio, !audio.isEmpty else {
            // No audio (dictation fallback) — queue the request itself.
            let dict = WatchMessage.request(request).encode()
            session?.transferUserInfo(dict)
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(request.requestId.uuidString)
            .appendingPathExtension("m4a")
        do {
            try audio.write(to: url, options: .atomic)
            // Metadata carries everything BUT the bytes (those ride the file).
            let meta = WatchRequest(requestId: request.requestId, mode: request.mode,
                                    audio: nil, audioViaFile: true, transcript: request.transcript)
            session.transferFile(url, metadata: WatchMessage.request(meta).encode())
        } catch {
            // Couldn't stage the file — last-resort queue without audio would be
            // useless, so surface a failure the model can show.
            onReply?(WatchReply(requestId: request.requestId, ok: false,
                                error: "Couldn't stage the recording to send."))
        }
    }

    /// Hop an already-decoded (Sendable) reply to the main actor. Decoding happens
    /// on the delegate thread so the non-Sendable `[String: Any]` never crosses the
    /// isolation boundary — only the `Sendable` `WatchReply` does.
    private nonisolated func deliver(_ message: WatchMessage?) {
        guard case .reply(let reply)? = message else { return }
        Task { @MainActor in self.onReply?(reply) }
    }
}

extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}

    // Immediate reply path. `WatchMessage.decode` is `nonisolated` and returns a
    // `Sendable` value, so decode here (off the main actor) and send only that.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(WatchMessage.decode(message))
    }

    // Reliable/background reply path (source of truth).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        deliver(WatchMessage.decode(userInfo))
    }
}
