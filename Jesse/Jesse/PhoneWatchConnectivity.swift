import Foundation
import SwiftData
import WatchConnectivity
import JesseCore

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
    ///
    /// `onAccepted` fires with the conversation id the instant the BRIDGE accepts the turn,
    /// which is minutes before this function returns. Without it the watch would have no
    /// signal between "the phone took my request" and the finished answer.
    func handle(_ request: WatchRequest, context: ModelContext,
                onAccepted: @escaping (String) -> Void = { _ in }) async -> WatchReply {
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
        switch await relay.relay(turn, context: context, onAccepted: onAccepted) {
        case .delivered(let result):
            return WatchReply(requestId: request.requestId, ok: true,
                              displayText: result.displayText, spokenText: result.spokenText,
                              sessionId: result.sessionId, threadId: result.threadId,
                              artifactNames: result.artifactNames)
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

    /// Applies a check the user made on their wrist. Set by the app shell once the
    /// Today model exists (`RootTabView`), because that model is the one the Today
    /// tab drives and a wrist check must go through it rather than around it.
    ///
    /// A closure rather than a stored model reference: this delegate is an
    /// app-lifetime singleton constructed at launch, and the day model is owned by a
    /// view that appears later.
    ///
    /// Setting it FLUSHES anything that arrived in the meantime — see
    /// `bufferedChecks`, which exists because that race is the normal case rather
    /// than the exotic one.
    var onTodayCheck: ((WatchTodayCheck) -> Void)? {
        didSet { flushBufferedChecks() }
    }

    /// Wrist checks received before `onTodayCheck` was wired.
    ///
    /// The ordering here is not a rare race, it is the ordinary launch: a queued
    /// intent is delivered as soon as the session activates (which happens in
    /// `didFinishLaunchingWithOptions`), and the view that owns the day model does
    /// not exist for another beat. Dropping them meant the exact case the reliable
    /// queue is FOR — the user ticked something with their phone in another room —
    /// was the one that silently did nothing.
    ///
    /// Bounded, because a phone that never shows its UI must not accumulate: the
    /// window only has to cover one launch, and every intent is de-duplicated by id
    /// downstream anyway.
    private var bufferedChecks: [WatchTodayCheck] = []
    private static let maxBufferedChecks = 32

    private func flushBufferedChecks() {
        guard let handler = onTodayCheck, !bufferedChecks.isEmpty else { return }
        let queued = bufferedChecks
        bufferedChecks.removeAll()
        Log.run.notice("watch today: flushing \(queued.count) buffered wrist check(s)")
        for check in queued { handler(check) }
    }

    /// Take one wrist check: apply it now, or hold it until there is something to
    /// apply it to.
    func receiveTodayCheck(_ check: WatchTodayCheck) {
        if let handler = onTodayCheck {
            handler(check)
            return
        }
        bufferedChecks.append(check)
        if bufferedChecks.count > Self.maxBufferedChecks { bufferedChecks.removeFirst() }
    }

    /// Production init wires the on-device transcriber and a `WatchRelay` over a
    /// fresh coordinator, persisting into the app's shared SwiftData store so a
    /// relayed turn lands in the same history the UI shows.
    override convenience init() {
        let relay = WatchRelay(coordinator: RunCoordinator())
        self.init(handler: WatchTurnHandler(transcriber: SpeechFrameworkTranscriber(), relay: relay),
                  context: AppModelContainer.shared.container.mainContext)
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

    // MARK: - Delivery to the watch (two paths, watch de-dupes by requestId)

    /// Ship one phone-to-watch envelope on BOTH paths. Generalised from a reply-only sender so
    /// the acceptance registration rides the exact same reliable + immediate delivery rather
    /// than needing a second, weaker private sender.
    private func send(_ message: WatchMessage) {
        let dict = message.encode()
        guard let session, session.activationState == .activated else { return }
        // Reliable, background-delivered source of truth — survives the watch app not
        // being frontmost.
        session.transferUserInfo(dict)
        // Immediate delivery too when the watch is reachable; the watch drops the
        // duplicate by requestId.
        if session.isReachable {
            session.sendMessage(dict, replyHandler: nil) { error in
                Log.run.error("watch send failed: \(error.localizedDescription)")
            }
        }
    }

    /// **Push the day to the wrist.** One-way, latest-wins, and cheap enough to do on
    /// every snapshot the phone fetches.
    ///
    /// `updateApplicationContext` is the right transport and the only one: it keeps
    /// exactly one payload, overwrites it in place, delivers it in the background, and
    /// hands it to a watch app that launches hours later. Those are precisely the
    /// semantics of "here is the day now" — where `sendMessage` needs the watch awake
    /// and `transferUserInfo` would queue up every intermediate state of a day the
    /// user only ever wants the latest of.
    ///
    /// A throw here means the dictionary was not property-list-safe (a coding bug the
    /// wire tests cover) or the session was not activated. Neither is worth failing a
    /// fetch over: the wrist keeps the previous context and the next push tries again.
    func pushToday(_ summary: WatchTodaySummary) {
        guard let session, session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext(summary.encode())
        } catch {
            Log.run.error("watch today push failed: \(error.localizedDescription)")
        }
    }

    /// Decode an incoming request, run the turn, and send the reply back. The bridge's
    /// acceptance is forwarded to the watch as soon as it happens, so the wrist can stop
    /// showing "Thinking" long before the answer lands.
    ///
    /// The `WatchAck` is also sent here, on EVERY path. It used to ride only the `sendMessage`
    /// reply handler, which meant a request delivered by `transferUserInfo` (the queued
    /// redelivery case) was never acknowledged at all.
    private func process(_ request: WatchRequest, ackNow: Bool) {
        Task { @MainActor in
            if ackNow {
                send(.ack(WatchAck(requestId: request.requestId, accepted: true)))
            }
            let reply = await handler.handle(request, context: context) { [weak self] conversationId in
                self?.send(.registered(WatchRegistered(requestId: request.requestId,
                                                       conversationId: conversationId)))
            }
            send(.reply(reply))
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
        Task { @MainActor in self.process(request, ackNow: false) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        dispatchIncoming(message, ackQueuedRequest: true)
    }

    // Reliable/queued path.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        dispatchIncoming(userInfo, ackQueuedRequest: true)
    }

    /// **The one watch-to-phone dispatcher.** THREE wires share these two transports —
    /// a relayed chat turn, and a wrist check, arriving on either `sendMessage` or
    /// `transferUserInfo` depending on whether the phone was listening when the user
    /// acted. Dispatching in one place is what stops a payload being understood on
    /// one transport and silently dropped on the other, which is exactly the bug
    /// shape this file has had before.
    ///
    /// The two decoders reject each other's dictionaries (`WatchTodayWireTests`), so
    /// the try-in-order below can never hand one to the wrong handler; the Today
    /// decoder runs first only because it is the cheaper of the two.
    private nonisolated func dispatchIncoming(_ payload: [String: Any],
                                              ackQueuedRequest: Bool) {
        if let check = WatchTodayCheck.decode(payload) {
            Log.run.notice("watch today: wrist check for \(check.itemId) -> \(check.checked)")
            Task { @MainActor in self.receiveTodayCheck(check) }
            return
        }
        guard case .request(let request)? = WatchMessage.decode(payload) else { return }
        Task { @MainActor in self.process(request, ackNow: ackQueuedRequest) }
    }

    // Audio delivered out-of-band as a file (clips too big for `sendMessage`).
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let request = request(fromFile: file) else { return }
        Task { @MainActor in self.process(request, ackNow: true) }
    }
}
