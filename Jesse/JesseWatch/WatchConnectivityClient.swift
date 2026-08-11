import Foundation
import WatchConnectivity
import WidgetKit

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
final class WatchConnectivityClient: NSObject, WatchRequestSending, WatchTodaySending {
    static let shared = WatchConnectivityClient()

    var onReply: ((WatchReply) -> Void)?
    var onRegistered: ((WatchRegistered) -> Void)?
    /// The phone pushed a fresh day. Latest-wins, so this always carries a whole
    /// summary and never a delta.
    var onTodayContext: ((WatchTodaySummary) -> Void)?

    private var session: WCSession?

    var isReachable: Bool { session?.isReachable ?? false }

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        session = s
        // The RETAINED context, read at activation rather than waited for.
        //
        // `updateApplicationContext` keeps its latest payload on the receiving side,
        // so a watch app launched hours after the last push already has the day —
        // but only if it asks. Without this the Today screen would render its empty
        // state on every launch and stay there until the phone happened to fetch
        // again, which on a wrist is most of the time.
        let retained = s.receivedApplicationContext
        if !retained.isEmpty, let summary = WatchTodaySummary.decode(retained) {
            adopt(summary)
        }
    }

    /// Take a pushed day: hand it to the screen, leave it where the complication can
    /// find it, and ask WidgetKit to redraw.
    ///
    /// The store write and the reload are HERE rather than in `WatchTodayModel`
    /// because the model is compiled into the phone too, and a phone reloading watch
    /// complications would be reaching across a boundary it has no business
    /// crossing. This file is watch-only.
    private func adopt(_ summary: WatchTodaySummary) {
        onTodayContext?(summary)
        WatchTodayStore.save(summary)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Send one check made on the wrist.
    ///
    /// The SAME transport ladder a relayed chat turn climbs, and for the same
    /// reasons: `sendMessage` when the phone is listening, because a check the user
    /// can watch confirm within a second is the difference between trusting the
    /// wrist and reaching for the phone to be sure; `transferUserInfo` otherwise,
    /// because a check is a WRITE and must not evaporate because the phone was in
    /// another room. The error handler covers the third case — reachable a moment
    /// ago, gone by the time the message went out.
    ///
    /// Duplicates are free: every intent carries an `intentId` and the phone
    /// de-duplicates on it, exactly as the chat wire does with `requestId`.
    func send(_ check: WatchTodayCheck) {
        guard let session else { return }
        if session.isReachable {
            session.sendMessage(check.encode(), replyHandler: nil) { [weak self] _ in
                Task { @MainActor in self?.queue(check) }
            }
            return
        }
        queue(check)
    }

    /// The reliable half of `send(_ check:)`. A method rather than an inline call
    /// because `transferUserInfo` RETURNS a non-`Sendable` transfer handle, and
    /// making it the last expression of a `@MainActor` closure would carry that
    /// handle across the isolation boundary. Discarding it here keeps the hop
    /// carrying nothing but the `Sendable` intent.
    private func queue(_ check: WatchTodayCheck) {
        _ = session?.transferUserInfo(check.encode())
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

    /// Hop an already-decoded (Sendable) message to the main actor. Decoding happens on the
    /// delegate thread so the non-Sendable `[String: Any]` never crosses the isolation
    /// boundary: only the `Sendable` value does.
    ///
    /// Both phone-to-watch envelopes are handled here: the reply, and the REGISTRATION that
    /// says the bridge accepted the turn. Before this, only `.reply` was matched, so the
    /// registration would have been decoded and then silently dropped.
    private nonisolated func deliver(_ message: WatchMessage?) {
        switch message {
        case .reply(let reply)?:
            Task { @MainActor in self.onReply?(reply) }
        case .registered(let registration)?:
            Task { @MainActor in self.onRegistered?(registration) }
        case .request?, .ack?, nil:
            // A request is never sent to the watch, and the phone-received ack only means the
            // phone has the request; the registration above is the signal that matters.
            break
        }
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

    // The pushed day. Decoded off the main actor (the decoder is `nonisolated` and
    // returns a `Sendable` value) so the non-Sendable dictionary never crosses the
    // isolation boundary — the same discipline `deliver` uses for the chat wire.
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let summary = WatchTodaySummary.decode(applicationContext) else { return }
        Task { @MainActor in self.adopt(summary) }
    }
}
