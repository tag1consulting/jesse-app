import Foundation
import SwiftData
import SwiftUI
import UIKit
import JesseCore
import JesseNetworking
import JesseConversations

// App-scoped run manager. Lives above the views (owned by `JesseApp`) so a run
// keeps going while you navigate back to the list and start another. Keyed by
// thread id: N keys == N concurrent runs. The one hard rule is the bridge's —
// never two simultaneous follow-ups against the same session — which falls out
// of "one task per thread id" plus the UI disabling a thread's send while it runs.

/// What we must remember about a backgrounded turn to re-attach to it after the
/// app is suspended or killed: the bridge job id and whether to speak the reply.
struct InFlightJob: Codable, Equatable {
    let jobId: String
    let voice: Bool
    // The outbox `request_id` (`OutboxItem.id`) this job ACKed, retained so
    // `reconcile` can tell "the ACK won the race with a kill" (a still-`.sending`
    // outbox item whose id matches a persisted job → the item is stale, delete it)
    // from "Jesse never received this" (no matching job → mark the item failed).
    // Optional and defaulted so old persisted files that predate the field decode
    // to nil (synthesized Decodable uses `decodeIfPresent` for an optional).
    var requestId: UUID? = nil
}

/// Reads and writes the persisted `inFlight` map. Pulled behind a protocol so the
/// coordinator's persistence is a single injectable seam (a test can supply its own
/// `UserDefaults` suite or an in-memory backend instead of touching the shared
/// store), matching how the client/config/save seams are already injected.
protocol InFlightStoring {
    func load() -> [UUID: InFlightJob]
    func save(_ map: [UUID: InFlightJob])
}

/// Persists `inFlight` across suspension. Small and keyed by thread id, in
/// UserDefaults — the bits needed to present a reply that landed while we were away.
/// The backing `UserDefaults` is injectable; production uses `.standard`.
struct InFlightStore: InFlightStoring {
    private static let key = "jesse.inflight.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [UUID: InFlightJob] {
        guard let data = defaults.data(forKey: Self.key),
              let raw = try? JSONDecoder().decode([String: InFlightJob].self, from: data)
        else { return [:] }
        var out: [UUID: InFlightJob] = [:]
        for (k, v) in raw {
            if let id = UUID(uuidString: k) { out[id] = v }
        }
        return out
    }

    func save(_ map: [UUID: InFlightJob]) {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

@MainActor
@Observable
final class RunCoordinator {
    // threadID → when its current run started; drives the per-thread fill/counter.
    private(set) var startDates: [UUID: Date] = [:]
    // threadID → last error to surface in that thread's transcript.
    private(set) var errors: [UUID: String] = [:]
    // threadID → in-flight bridge job, persisted so it survives a kill.
    private(set) var inFlight: [UUID: InFlightJob] = [:]
    // threadID → reply text streamed so far, rendered live under the spinner
    // until the turn finishes (then it's cleared and the real Turn is appended).
    // Transient and in-memory only — the persisted transcript is the source of
    // truth; the SSE stream replays this on reconnect.
    private(set) var partialText: [UUID: String] = [:]
    // threadID → a coarse "what Jesse is doing" line from tool-use events.
    private(set) var activity: [UUID: String] = [:]
    // threadID → context a screen ATTACHED to a thread it opened without firing a
    // turn, consumed by (and only by) that thread's first send.
    //
    // The Today tab's Discuss is the case this exists for: it opens a conversation
    // about one item with an EMPTY composer and starts nothing, because there is
    // nothing for the agent to do until Jeremy has said what he wants. The frozen
    // `TodayDiscuss.prompt` — the item's markdown, its links, and the sentence that
    // keeps a discussion from tripping the morning routine — waits here and rides his
    // first message (see `TodayThreadContext.firstMessage`). Scope is preserved
    // whether he types a question or sends an empty composer to mean "just look at it".
    //
    // Deliberately OBSERVED (not `@ObservationIgnored`): the composer's send button
    // is enabled on an empty input only while a context is attached, so the view has
    // to re-evaluate when the first send consumes it.
    //
    // In memory only. An attachment describes a thread that has never been sent to,
    // and such a thread is not persisted either — both die together with the process,
    // and `TodayTabView` drops the attachment when its sheet is dismissed.
    //
    // Widened from a bare `String` to `AttachedContext` for the Health tab's "Ask about
    // this", which needs two more things the string could not carry: the SCOPE TITLE (so
    // the chat can say what "this" refers to without pasting a page of numbers into the
    // transcript) and the STARTERS the empty state offers. The Today tab's Discuss is
    // untouched: it attaches a title-less, starter-less value through the same call.
    private var attachedContexts: [UUID: AttachedContext] = [:]

    // Not observed by views — just lifecycle bookkeeping.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    // Owns the per-thread background-task assertions (begin/end bookkeeping and the
    // expiration-before-store race fixed in M7). Holds the handle dict that used to
    // live here directly.
    @ObservationIgnored private let backgroundGuard: BackgroundTaskGuard

    private let configProvider: @MainActor () -> JesseConfig
    private let makeClient: @MainActor (JesseConfig) -> any JesseClientProtocol
    // Resolves the per-mode wrapper override to send (nil = use the bridge
    // default). Injected so tests can drive it without UserDefaults state.
    private let instructionsProvider: @MainActor (JesseMode) -> String?
    // Resolves the per-mode floor override to send (nil = use the bridge's
    // built-in floor, which is always prepended and never removed). Injected so
    // tests can drive it without UserDefaults state.
    private let floorProvider: @MainActor (JesseMode) -> String?
    // How a spoken reply is voiced. Defaults to the real on-device TTS; injected
    // so a test can assert what was spoken (and that the genuinely-empty path
    // speaks nothing). Used only in `finish`.
    private let speak: @MainActor (String) -> Void
    // How a turn's mutations are persisted. Defaults to a real `context.save()`;
    // injected so a test can force a save failure deterministically. Used by the
    // optimistic user-turn save and by `finish`.
    private let save: @MainActor (ModelContext) throws -> Void
    // How the poll loop waits between polls. Defaults to a real `Task.sleep`;
    // injected so a test can drive the backoff sequence deterministically without
    // real waiting.
    private let pollSleep: @MainActor (TimeInterval) async -> Void
    // Clock read when deciding whether a `partialText` publish is due. Injectable so
    // a test drives the coalescing cadence deterministically without real waiting.
    private let now: @MainActor () -> Date
    // How the deferred partial-flush waits out the cooldown. Injectable for the same
    // reason; defaults to a real `Task.sleep`.
    private let flushSleep: @MainActor (TimeInterval) async -> Void
    // Persists the in-flight job map across suspension. Injectable so a test can
    // avoid the shared UserDefaults store.
    private let inFlightStore: InFlightStoring
    // Durable queue of remote Claude Code sessions to delete (thread-delete →
    // `DELETE /jesse/session/{id}`). Persisted so a delete made while the laptop is
    // asleep survives to the next drain. Injectable so a test points it at a scratch
    // UserDefaults suite.
    private let sessionDeletionStore: PendingSessionDeletionStore
    // Presence-based per-session transcript cursor (absent = never hydrated, distinct
    // from byte 0). Drives phone-side hydration on open (seed vs import) and is advanced
    // past the phone's own turns at delivery so a later hydrate never re-imports them.
    // Injectable so a test points it at a scratch UserDefaults suite.
    private let hydrationCursorStore: HydrationCursorStore
    // Owns `finish`'s SwiftData append + save + idempotency-on-jobId. Shares the
    // injected `save` seam so a test's save spy counts both the optimistic
    // user-turn save and the completion save.
    private let turnWriter: TurnWriter
    // Writes any meals a reply logged into Apple Health, idempotently and gated by
    // the toggle + write authorization. Injectable so a test drives it with fakes;
    // production uses the real HealthKit writer + UserDefaults pending queue.
    private let mealWriter: MealHealthWriter

    // threadID → a counter bumped on each stream reset/delta. The poll loop watches
    // it to snap its backoff back to the fast cadence while the stream is actively
    // delivering tokens. Not observed by views.
    @ObservationIgnored private var streamTicks: [UUID: Int] = [:]

    // Coalescing state for the observable `partialText` (streaming re-eval perf).
    // The stream delivers deltas far faster than the UI needs to redraw, yet every
    // mutation of `partialText` re-evaluates `ThreadDetailView.body` and fires its
    // auto-scroll. So the *exact* accumulated text is buffered here (source of truth
    // for the flush tail) and PUBLISHED to `partialText` at most once per
    // `partialFlushInterval` — the same ~10Hz the markdown parse already runs at.
    // Never throttled by dropping content: the buffer is exact and the tail always
    // flushes (terminal frame / stream end), so the final published value equals the
    // concatenation of every chunk. @ObservationIgnored: only `partialText` is observed.
    @ObservationIgnored private var partialBuffer: [UUID: String] = [:]
    // threadID → when `partialText` was last published (for the cooldown check).
    @ObservationIgnored private var partialLastPublish: [UUID: Date] = [:]
    // threadID → a single pending deferred-flush task (surfaces a tail chunk that
    // arrived inside the cooldown, at the interval boundary). At most one per thread.
    @ObservationIgnored private var partialFlushTasks: [UUID: Task<Void, Never>] = [:]
    // Instrumentation: how many times `partialText` was actually published. A test
    // asserts this stays ≪ the delta count (the coalescing win); production ignores it.
    @ObservationIgnored private(set) var partialPublishCount = 0

    // The subscription to path changes that drives `recoverAfterNetworkReturned`.
    @ObservationIgnored private var connectivityTask: Task<Void, Never>?
    // The single armed wakeup for the next due automatic outbox retry. One for the whole
    // outbox (re-armed to the earliest due date), not one per message.
    @ObservationIgnored private var outboxRetryTask: Task<Void, Never>?

    // ANTI-LOOP GUARD 1 of 3: the one-shot budget.
    //
    // Which (thread, channel) pairs have already spent their ONE device-context
    // fulfillment retry for the current user message (a reply carried a directive → we
    // fulfilled + re-sent). Cleared for the thread at the start of each new `send`, so
    // the retry is at most once per channel per user message; a second directive on the
    // retry's reply is then ignored.
    //
    // Keyed by thread AND CHANNEL, not by thread alone. With one key per thread, a turn
    // that legitimately needed both channels — "how far did I run, and how far is the
    // gym from here" — would spend the budget on whichever directive arrived first and
    // starve the other, so the second channel could never be answered on that message
    // no matter what the agent asked for. Each channel gets its own single shot.
    @ObservationIgnored private var deviceContextRetried: Set<RetryKey> = []

    /// One thread's budget for one channel. A struct rather than a string key so a
    /// typo cannot silently address a budget nobody spends.
    struct RetryKey: Hashable {
        let threadID: UUID
        let channel: DeviceContextChannel
    }

    // What a live turn needs to fulfill a device-context directive and re-send: the
    // same mode/text plus the resolved wrapper/floor overrides.
    //
    // ANTI-LOOP GUARD 2 of 3: this is nil — structurally, not by a flag — on every path
    // that must not retry. That is the resume/recheck path, which after a relaunch has
    // no original text to re-send and so could not fulfil anything even if it wanted
    // to. A stranded sentinel there just surfaces the empty-reply Re-check.
    struct TurnRetry {
        let mode: JesseMode
        let text: String
        let instructions: String?
        let floorOverride: String?
        // The PER-TURN model the original turn ran on, so the fulfillment retry answers on
        // the SAME model. nil → the bridge's stored default.
        var model: String? = nil
    }

    /// The PER-TURN model a thread should send on: its own stored selection, else this
    /// device's last-used default (`LastUsedModelStore`). nil → the bridge uses its stored
    /// default (opus). Resolved fresh at send time so a Retry/resume picks up any change.
    private func modelID(for thread: JesseThread) -> String? {
        thread.selectedModelID ?? LastUsedModelStore.id
    }

    // AI-title generation bookkeeping (see `ensureTitle`). Not observed by views —
    // the title lands on the persisted JesseThread, which the list already queries.
    // `titlesInFlight` guards against a second concurrent generation for a thread;
    // `titleAttemptedKeys` records the content key we last *attempted* (success OR
    // failure) so a failing bridge isn't re-hit on every row appearance — a fresh
    // launch clears it, and a new turn (new key) makes one fresh attempt.
    @ObservationIgnored private var titlesInFlight: Set<UUID> = []
    @ObservationIgnored private var titleAttemptedKeys: [UUID: String] = [:]
    // Called after a turn is delivered successfully — the "sensible moment" to ask
    // for push-notification authorization (not on cold launch). `JesseApp` wires
    // this to `PushManager`; the default is a no-op so tests never touch
    // UNUserNotificationCenter.
    private let onFirstSuccess: @MainActor () -> Void

    // The current frugal decision, read at each of the sites that spends bytes. Injected
    // so a test drives the table without a radio; production reads the live path plus the
    // Settings toggle.
    private let frugal: @MainActor () -> FrugalPolicy
    // Whether this device currently has a usable network. Distinct from "the bridge is
    // reachable" — see `ConnectivityMonitor` — and consulted at exactly one place: the
    // poll loop, deciding whether a transport error is "the bridge is asleep" (surface
    // Re-check) or "we are in a tunnel" (wait).
    private let pathIsSatisfied: @MainActor () -> Bool
    // Wait for the network to come back, bounded. Returns whether it did.
    private let awaitPath: @MainActor (TimeInterval) async -> Bool
    // Replays whatever an offline intent queue is holding, on every recovery. A no-op
    // until P8 lands one — see `IntentReplaying`.
    private let intentReplayer: any IntentReplaying

    // Drives the in-flight-turn Live Activity (Lock Screen / Dynamic Island). A
    // thin ActivityKit seam so this file never imports ActivityKit and the test
    // suite injects a no-op — the device-only Live Activity runtime is never
    // touched under test. The begin/update/end decision is the pure
    // `TurnLiveActivity.step`; the calls here just feed it current run state.
    private let liveActivity: any TurnLiveActivityManaging

    init(config: @escaping @MainActor () -> JesseConfig = { ConfigStore.load() },
         makeClient: @escaping @MainActor (JesseConfig) -> any JesseClientProtocol = { JesseClient(config: $0) },
         instructions: @escaping @MainActor (JesseMode) -> String? = { PromptStore.wrapperOverride(for: $0) },
         floor: @escaping @MainActor (JesseMode) -> String? = { PromptStore.floorOverride(for: $0) },
         speak: @escaping @MainActor (String) -> Void = { Speaker.shared.speak($0) },
         save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() },
         backgroundTasker: BackgroundTasking = UIKitBackgroundTasking(),
         pollSleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         now: @escaping @MainActor () -> Date = { Date() },
         flushSleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         inFlightStore: InFlightStoring? = nil,
         liveActivity: (any TurnLiveActivityManaging)? = nil,
         mealWriter: MealHealthWriter? = nil,
         sessionDeletionStore: PendingSessionDeletionStore? = nil,
         hydrationCursorStore: HydrationCursorStore? = nil,
         frugal: @escaping @MainActor () -> FrugalPolicy = { FrugalSettings.current() },
         pathIsSatisfied: @escaping @MainActor () -> Bool = { ConnectivityMonitor.shared.path.isSatisfied },
         awaitPath: @escaping @MainActor (TimeInterval) async -> Bool
             = { await ConnectivityMonitor.shared.awaitSatisfied(timeout: $0) },
         intentReplayer: (any IntentReplaying)? = nil,
         onFirstSuccess: @escaping @MainActor () -> Void = {}) {
        // Resolve the default on the main actor (in the init body), not in the
        // default argument — a default arg is evaluated off the actor and the
        // store's init is main-actor-isolated under MainActor-default isolation.
        let resolvedInFlightStore = inFlightStore ?? InFlightStore()
        // Same rationale for the Live Activity controller (its init adopts existing
        // activities via ActivityKit on the main actor).
        self.liveActivity = liveActivity ?? TurnLiveActivityController()
        self.configProvider = config
        self.makeClient = makeClient
        self.instructionsProvider = instructions
        self.floorProvider = floor
        self.speak = speak
        self.save = save
        self.turnWriter = TurnWriter(save: save)
        // Default meal writer: the real HealthKit writer + UserDefaults pending
        // queue, gated by the persisted toggle. Built on the main actor here (its
        // pieces are main-actor) rather than in a default argument.
        self.mealWriter = mealWriter ?? MealHealthWriter(
            writer: HealthKitMealWriter(),
            pending: PendingMealStore(),
            isEnabled: { WriteMealsToHealthSettings.isEnabled })
        self.backgroundGuard = BackgroundTaskGuard(tasker: backgroundTasker)
        self.pollSleep = pollSleep
        self.now = now
        self.flushSleep = flushSleep
        self.inFlightStore = resolvedInFlightStore
        // Resolved in the body (not a default arg) — its init is main-actor-isolated
        // under this module's MainActor default isolation, mirroring the stores above.
        self.sessionDeletionStore = sessionDeletionStore ?? PendingSessionDeletionStore()
        self.hydrationCursorStore = hydrationCursorStore ?? HydrationCursorStore()
        self.frugal = frugal
        self.pathIsSatisfied = pathIsSatisfied
        self.awaitPath = awaitPath
        // Resolved in the body rather than as a default argument: the type is MainActor-
        // isolated, mirroring the stores above.
        self.intentReplayer = intentReplayer ?? NoIntentReplayer()
        self.onFirstSuccess = onFirstSuccess
        self.inFlight = resolvedInFlightStore.load()
    }

    // MARK: - Poll cadence (H6)

    /// Poll cadence for an in-flight turn (seconds). Polling starts fast, backs off
    /// geometrically toward a ceiling while the turn is quiet (so a long turn isn't
    /// hammered), and snaps back to the fast cadence whenever the live stream shows
    /// new tokens (the turn is clearly alive and producing output).
    nonisolated static let pollInterval: TimeInterval = 2
    nonisolated static let pollIntervalCeiling: TimeInterval = 30
    nonisolated static let pollBackoffFactor: Double = 5

    /// Publish cadence for the observable `partialText`. Matched to the streaming
    /// markdown renderer's parse interval so the transcript body re-evaluates (and
    /// its auto-scroll fires) at the same ~10Hz the parse already runs at, instead
    /// of once per delta chunk.
    nonisolated static let partialFlushInterval: TimeInterval = MarkdownStreamRenderer.interval

    /// The next poll interval after `current`: grow by the backoff factor, capped at
    /// the ceiling. Pure, for direct testing. From `pollInterval`: 2 → 10 → 30 → 30…
    nonisolated static func nextPollInterval(after current: TimeInterval) -> TimeInterval {
        min(current * pollBackoffFactor, pollIntervalCeiling)
    }

    /// The longest the poll loop waits for the network to come back before trying the
    /// request again anyway. Matched to the poll ceiling: the loop's slowest cadence is
    /// already 30s, so waiting for a path costs nothing a quiet turn was not spending.
    nonisolated static let networkWaitCeiling: TimeInterval = pollIntervalCeiling

    /// Whether a poll failure is the kind that means "this device could not get onto the
    /// network", as opposed to the bridge answering with something we did not like.
    ///
    /// Pure and separate from `JesseError.isUnreachable` because it answers a narrower
    /// question — the caller has ALREADY established that the path is unsatisfied, and
    /// what it needs to know is whether this particular error is consistent with that. A
    /// `badResponse` is not: the bridge answered, so the phone plainly had a network a
    /// moment ago and something else is wrong.
    nonisolated static func isWaitForNetwork(_ error: Error) -> Bool {
        (error as? JesseError)?.isUnreachable ?? false
    }

    /// Bump the stream-activity counter for a thread — called by the display stream
    /// on each reset/delta so the poll loop can reset its backoff. Internal so a
    /// test can simulate stream activity deterministically.
    func noteStreamActivity(_ threadID: UUID) {
        streamTicks[threadID, default: 0] += 1
    }

    // MARK: - Partial-text coalescing (streaming re-eval perf)

    /// Append a live stream chunk to the exact buffer and publish the observable
    /// `partialText` at most once per `partialFlushInterval`. A chunk that arrives
    /// inside the cooldown is retained in the buffer and surfaced by a single
    /// scheduled flush at the interval boundary — so the publish rate is bounded but
    /// no content is ever dropped.
    private func appendPartial(_ threadID: UUID, _ chunk: String) {
        partialBuffer[threadID, default: ""] += chunk
        publishPartialIfDue(threadID)
    }

    /// Replace the buffer wholesale (an SSE `reset`/replay) and publish immediately —
    /// a reset is a coarse, rare event, not the per-token hot path.
    private func resetPartial(_ threadID: UUID, to text: String) {
        partialBuffer[threadID] = text
        publishPartial(threadID)
    }

    /// Publish now if the cooldown has elapsed; otherwise arrange a single deferred
    /// flush at the boundary so the buffered tail still lands within one interval.
    private func publishPartialIfDue(_ threadID: UUID) {
        if let last = partialLastPublish[threadID] {
            let elapsed = now().timeIntervalSince(last)
            if elapsed < Self.partialFlushInterval {
                schedulePartialFlush(threadID, after: Self.partialFlushInterval - elapsed)
                return
            }
        }
        publishPartial(threadID)
    }

    /// Copy the current buffer into the observable `partialText`, stamp the publish
    /// time, and cancel any pending scheduled flush (this publish subsumes it).
    private func publishPartial(_ threadID: UUID) {
        partialFlushTasks[threadID]?.cancel()
        partialFlushTasks[threadID] = nil
        partialText[threadID] = partialBuffer[threadID]
        partialLastPublish[threadID] = now()
        partialPublishCount += 1
    }

    /// Schedule one deferred publish at the cooldown boundary. Idempotent: a flush
    /// already pending covers any further chunks that arrive before it fires.
    private func schedulePartialFlush(_ threadID: UUID, after delay: TimeInterval) {
        guard partialFlushTasks[threadID] == nil else { return }
        partialFlushTasks[threadID] = Task { @MainActor [weak self] in
            await self?.flushSleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.partialFlushTasks[threadID] = nil
            // Republish only if the buffer actually advanced past what's shown.
            if self.partialText[threadID] != self.partialBuffer[threadID] {
                self.publishPartial(threadID)
            }
        }
    }

    /// Surface the exact buffered tail immediately — called on a terminal frame or a
    /// bare stream end so the final published `partialText` equals the concatenation
    /// of every chunk, with no last delta stranded in the buffer.
    private func flushPartial(_ threadID: UUID) {
        guard partialBuffer[threadID] != nil else { return }
        if partialText[threadID] != partialBuffer[threadID] {
            publishPartial(threadID)
        } else {
            partialFlushTasks[threadID]?.cancel()
            partialFlushTasks[threadID] = nil
        }
    }

    /// Drop all coalescing state for a thread (buffer, publish stamp, pending flush)
    /// and clear the observable partial. Routed through every run-clear path so a
    /// scheduled flush can never repopulate `partialText` after the turn has ended.
    private func clearPartial(_ threadID: UUID) {
        partialFlushTasks[threadID]?.cancel()
        partialFlushTasks[threadID] = nil
        partialBuffer[threadID] = nil
        partialLastPublish[threadID] = nil
        partialText[threadID] = nil
    }

    // MARK: - Query (read by views)

    /// A run is *actively* in flight (spinner, Cancel, send disabled): either a
    /// turn is executing/polling (`startDates`) or a persisted job is waiting to
    /// be re-attached on foreground (`inFlight`) — but NOT once a recoverable
    /// error has surfaced. A retained-but-errored job reads as idle-with-Re-check
    /// (`canRecheck`), not as running. All three reads are observed properties so
    /// the views update; `tasks` is intentionally not consulted (not observed).
    func isRunning(_ threadID: UUID) -> Bool {
        (startDates[threadID] != nil || inFlight[threadID] != nil) && errors[threadID] == nil
    }

    /// True when a turn failed recoverably but its bridge job_id is still retained
    /// (and persisted) — so the reply may yet be retrievable. Drives the visible
    /// "Re-check" affordance. A genuinely-gone (past-TTL) turn clears the job, so
    /// this goes false and only the terminal error remains.
    func canRecheck(_ threadID: UUID) -> Bool {
        inFlight[threadID] != nil && errors[threadID] != nil
    }

    func startDate(for threadID: UUID) -> Date? { startDates[threadID] }

    /// Where a turn is between "typed" and "answered", derived entirely from state that
    /// already exists rather than a new stored flag. `isRunning` deliberately ORs the pre-ACK
    /// and post-ACK conditions (a spinner is a spinner), which is exactly why it cannot
    /// answer this: before this existed nothing in the UI distinguished a message still
    /// crossing the network from one the server had durably accepted.
    ///
    /// `.accepted` means the bridge returned its 202, so the turn is the server's: it will be
    /// answered even if the app is closed. `nil` means there is nothing in flight (or an
    /// error has surfaced, which the error UI owns).
    func phase(_ threadID: UUID) -> TurnPhase? {
        guard errors[threadID] == nil else { return nil }
        if inFlight[threadID] != nil { return .accepted }
        if startDates[threadID] != nil { return .sending }
        return nil
    }
    func error(for threadID: UUID) -> String? { errors[threadID] }
    func clearError(for threadID: UUID) { errors[threadID] = nil }

    /// The reply text streamed so far for a running turn (nil/empty when nothing
    /// has arrived yet). Rendered live in the transcript while `isRunning`.
    func partialText(for threadID: UUID) -> String? { partialText[threadID] }
    /// The current coarse activity line (e.g. "Reading the vault…"), if any.
    func activity(for threadID: UUID) -> String? { activity[threadID] }

    // MARK: - Attached context

    /// Hold `context` against a thread that was OPENED without firing a turn; the
    /// thread's first send will carry it. Replaces any previous attachment.
    func attach(context: String, to threadID: UUID) {
        attachedContexts[threadID] = AttachedContext(body: context)
    }

    /// Hold a titled attachment (the Health tab's ask) against a thread. Replaces any
    /// previous one, exactly as the string form does.
    func attach(_ context: AttachedContext, to threadID: UUID) {
        attachedContexts[threadID] = context
    }

    /// The whole attachment waiting on this thread's next send — title and starters
    /// included. The composer reads this to pin the scope line and offer the starters.
    func attachment(for threadID: UUID) -> AttachedContext? { attachedContexts[threadID] }

    /// The context waiting on this thread's first send, if any. nil once consumed —
    /// which is also what tells the composer that an empty send is no longer a turn.
    func attachedContext(for threadID: UUID) -> String? { attachedContexts[threadID]?.body }

    /// Drop an attachment that will never be sent (its screen was dismissed). A no-op
    /// once the first send has consumed it.
    func clearAttachedContext(for threadID: UUID) {
        attachedContexts[threadID] = nil
    }

    // MARK: - Send

    /// Start a turn on `thread`. Appends the user message optimistically, then
    /// runs the bridge call on a per-thread task that survives navigation.
    ///
    /// If the thread carries an ATTACHED context (a screen opened it without firing —
    /// today only the Today tab's Discuss), this send is the one that spends it: the
    /// context is composed AHEAD of whatever the user typed and the attachment is
    /// dropped, so it rides the first message and only the first. Composing here
    /// rather than in the composer is deliberate — every send path (the button, a
    /// voice send, a retry) then honors it, and an empty composer with a context
    /// attached is a real turn ("just look at it") instead of a silently dropped one.
    /// `onAck` fires ONCE with whether the bridge accepted this message — `true` on the
    /// `202` (or the legacy inline `200`), `false` on any pre-ACK failure, and `false`
    /// for a send that was refused before it began.
    ///
    /// It exists for the offline queue's replay, which must not send a day's second meal
    /// until the first has landed: a log that arrives out of order is a log that reads as
    /// a different day's. Nothing else uses it, and nothing else should — the transcript
    /// and the outbox row are how a person learns a message went.
    func send(thread: JesseThread, text: String, voice: Bool, context: ModelContext,
              attachments: [JesseAttachment] = [],
              onAck: (@MainActor (Bool) -> Void)? = nil) {
        let threadID = thread.id
        let attached = attachedContexts[threadID]
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = attached.map { TodayThreadContext.firstMessage(context: $0.body, typed: text) }
            ?? typed
        // The guards run on the COMPOSED text and before the attachment is spent, so a
        // send refused because a turn is already running leaves the context attached
        // for the send that does go through.
        guard !trimmed.isEmpty, !isRunning(thread.id) else {
            onAck?(false)
            return
        }
        attachedContexts[threadID] = nil
        errors[threadID] = nil
        // A new turn is a "next turn" drain point for any meal writes that failed
        // earlier (device locked, transient HealthKit error) — retry them now.
        drainPendingMeals(context: context)
        // A new user message gets a fresh device-context retry budget — one per channel
        // per message. Cleared for EVERY channel on this thread, so the budgets and the
        // message they belong to always start together.
        for channel in DeviceContextChannel.allCases {
            deviceContextRetried.remove(RetryKey(threadID: threadID, channel: channel))
        }
        // A new turn supersedes any retained-but-unretrieved job from a prior
        // recoverable failure on this thread — the user has moved on, so don't
        // leave a stale job that Re-check or resume could re-attach to.
        if inFlight[threadID] != nil {
            inFlight[threadID] = nil
            inFlightStore.save(inFlight)
        }

        // A new thread isn't in the store until its first send — insert it now so
        // its turns persist and it shows in the list.
        if thread.modelContext == nil {
            context.insert(thread)
        }

        // ── Stage: the optimistic user Turn AND its OutboxItem in ONE save. The user
        // message appears in the transcript immediately; the OutboxItem (state
        // `.sending`, carrying the ORIGINAL full-resolution — i.e. staged,
        // post-downscale — attachment bytes) OWNS the message until the bridge ACKs.
        // Attachments are shown as persisted thumbnail previews (see `attachPreviews`)
        // rather than an appended "📎 Attached:" text line.
        let userTurn = Turn(role: .user, text: trimmed)
        // `trimmed` is what the MODEL is sent — the screen's context composed ahead of
        // whatever was typed — and it stays that, because it is the turn's identity for
        // the outbox and for hydration. What the TRANSCRIPT shows is the user's own half:
        // a Health snapshot is a page of numbers, and pasting it into their message bubble
        // would both drown the conversation and claim they typed it. An empty typed half
        // is the explicit "just look at it" send and renders as the context label alone.
        if let attached {
            userTurn.displayText = typed
            userTurn.contextLabel = attached.contextLabel
        }
        thread.turns.append(userTurn)
        if thread.title.isEmpty {
            thread.title = JesseThread.deriveTitle(from: trimmed)
        }
        thread.updatedAt = Date()
        let mode = thread.modeValue
        let item = OutboxItem(threadID: threadID, turnID: userTurn.id, text: trimmed,
                              mode: mode, voice: voice)
        for att in attachments {
            item.attachments.append(
                OutboxAttachment(filename: att.filename, mime: att.mime, data: att.data))
        }
        context.insert(item)
        // Real error handling, not `try?`. If this throws the user message is shown
        // but neither it nor the outbox record is persisted, and proceeding would
        // attach the reply to a thread that may never persist. Surface a recoverable
        // failure and abort the turn before any bridge call, rather than swallow it.
        do {
            try save(context)
        } catch {
            Log.run.error("optimistic user-turn + outbox save failed for thread \(threadID): \(error.localizedDescription) — aborting the turn")
            errors[threadID] = "Couldn't save your message — try sending it again."
            onAck?(false)
            return
        }
        // Persist storage-optimized thumbnail previews of any attachments onto the
        // user turn (for history). The full-resolution bytes live in the OutboxItem
        // now; these small JPEGs are generated off the main actor and attached
        // best-effort — a failed preview never affects the turn.
        attachPreviews(to: userTurn, from: attachments, context: context)

        // ── Transmit: POST with `requestId = item.id`. Any success (a `.running`
        // 202 or the legacy inline `.reply` 200) deletes the item — after that the
        // existing InFlight/consume/Re-check machinery owns the turn unchanged; a
        // throw before that ACK flips the item to `.failed` for the per-message Retry.
        transmit(item: item, thread: thread, context: context, onAck: onAck)
    }

    /// The bridge round-trip for one staged (or retried) `OutboxItem`, keyed by its
    /// `id` as the `request_id`. Marks the thread running and, on ACK, hands off to
    /// the same stream+poll/consume path a turn always took — the outbox change is
    /// entirely in the pre-ACK window. Session/instructions/floor/config are resolved
    /// FRESH here (not captured at stage time) so a Retry picks up current state and
    /// the same request_id lets the bridge dedup a POST that actually landed.
    private func transmit(item: OutboxItem, thread: JesseThread, context: ModelContext,
                          onAck: (@MainActor (Bool) -> Void)? = nil) {
        let threadID = thread.id
        let requestId = item.id
        let text = item.text
        let voice = item.voice
        let mode = item.modeValue
        let sessionId = thread.sessionId
        // The thread identity, sent on EVERY turn. A thread always has one (the model mints
        // it at init), but a store row migrated from before the property reads nil until the
        // first sync binds it; mint one now rather than let the bridge invent an identity
        // this client would not recognize.
        let conversationId = thread.conversationId ?? JesseThread.mintConversationId()
        if thread.conversationId != conversationId { thread.conversationId = conversationId }
        let cfg = configProvider()
        // Resolve the wrapper and floor overrides on the main actor before detaching
        // the turn; nil when this mode isn't customized.
        let instructions = instructionsProvider(mode)
        let floorOverride = floorProvider(mode)
        // Resolve the PER-TURN model on the main actor before detaching — the thread's own
        // selection, else this device's default. Sent on this turn only; never the global.
        let model = modelID(for: thread)
        // Reconstitute the outgoing attachments from the persisted ORIGINAL bytes.
        let attachments = item.orderedAttachments.map {
            JesseAttachment(filename: $0.filename, mime: $0.mime, data: $0.data)
        }
        startDates[threadID] = Date()
        // The turn is now in flight — start the Live Activity (Lock Screen / Dynamic
        // Island).
        syncLiveActivity(threadID, attributes: liveActivityAttributes(for: thread))
        // A background grant lets a short turn finish after the app is backgrounded;
        // longer turns are re-attached on foreground via `resume`.
        backgroundGuard.begin(threadID, name: "jesse.turn")

        tasks[threadID] = Task { [weak self] in
            guard let self else { return }
            let client = self.makeClient(cfg)
            do {
                let result = try await client.send(mode: mode, text: text,
                                                   sessionId: sessionId,
                                                   conversationId: conversationId,
                                                   voice: voice,
                                                   instructions: instructions,
                                                   floorOverride: floorOverride,
                                                   attachments: attachments,
                                                   requestId: requestId,
                                                   model: model)
                switch result {
                case .reply(let reply, _, let remoteConversationId):
                    // ACK (legacy inline 200 — effectively dead against the fixed
                    // bridge, kept for an older one). Delivered → drop the outbox
                    // item, then finish against the live `thread` reference.
                    self.adoptRegistration(thread: thread, conversationId: remoteConversationId)
                    self.ackDelete(item, context: context)
                    onAck?(true)
                    self.finish(threadID: threadID, thread: thread, reply: reply,
                                voice: voice, jobId: nil, context: context)
                case .running(let jobId, let remoteConversationId):
                    // ACK (202 — the normal path). Delivered → drop the outbox item,
                    // then persist the in-flight job (carrying the request_id so
                    // `reconcile` can resolve a kill/ACK race) and consume as before:
                    // stream (display) and poll (completion) race, and any later drop
                    // is recoverable via Re-check / `resume`.
                    //
                    // This is also the ACCEPTANCE moment: the bridge has registered the
                    // conversation and the turn is durably its, which is what the
                    // transcript's delivery caption reflects. Recorded in the SAME save
                    // that drops the outbox item.
                    self.adoptRegistration(thread: thread, conversationId: remoteConversationId)
                    self.ackDelete(item, context: context)
                    // The ACK, and the only place a replaying quick log learns it may
                    // send the next one. Fired BEFORE `consume`, which runs for as long
                    // as the turn does — a queue that waited for the ANSWER would send a
                    // day's meals a minute apart.
                    onAck?(true)
                    self.persist(threadID: threadID,
                                 job: InFlightJob(jobId: jobId, voice: voice, requestId: requestId))
                    await self.consume(threadID: threadID, thread: thread, jobId: jobId,
                                       voice: voice, client: client, context: context,
                                       retry: TurnRetry(mode: mode, text: text,
                                                          instructions: instructions,
                                                          floorOverride: floorOverride,
                                                          model: model))
                }
            } catch is CancellationError {
                // Pre-ACK cancel: today this silently cleared, losing the message.
                // Preserve it as `.failed` so the user can Retry/Discard; speak
                // nothing (matching the old silent cancel).
                self.failOutbox(item, threadID: threadID,
                                message: "Cancelled before it was delivered.",
                                voice: voice, speakFailure: false, context: context)
                onAck?(false)
            } catch let error as JesseError {
                // Pre-ACK failure (timeout, dead network, 429/5xx, notConfigured):
                // the message never reached the bridge. Preserve it as `.failed` with
                // the mapped, human-readable message for the per-message Retry — and
                // deliberately DON'T set the thread-level `errors[]` banner (the
                // per-message UI owns this failure class). Still speak on a voice turn.
                self.failOutbox(item, threadID: threadID,
                                message: error.errorDescription ?? "Couldn't send your message.",
                                voice: voice, speakFailure: true, context: context)
                onAck?(false)
            } catch {
                self.failOutbox(item, threadID: threadID, message: error.localizedDescription,
                                voice: voice, speakFailure: true, context: context)
                onAck?(false)
            }
            self.tasks[threadID] = nil
            self.backgroundGuard.end(threadID)
        }
    }

    /// A delivered message: drop its `OutboxItem` (cascade-deleting its stored
    /// attachment bytes) and persist. Deliberately NOT routed through the injected
    /// `save` seam — it's best-effort cleanup that self-heals (a failed delete leaves
    /// a still-`.sending` item that `reconcile` collapses via the persisted job's
    /// request_id), and keeping it off the seam preserves the seam's meaning as "the
    /// optimistic-turn stage save + the finish save" that the finish tests count on.
    /// Adopt the bridge's AUTHORITATIVE conversation id from a 202 (or an inline 200) and
    /// stamp the first-ACK time.
    ///
    /// The client mints the id and the bridge registers it, so the echoed value normally
    /// equals what was sent; it is still written back unconditionally because the bridge
    /// stays free to override (it does exactly that when binding a legacy transcript). A nil
    /// echo means a bridge too old to report one, in which case the local id stands.
    ///
    /// `registeredAt` is set ONCE, on the first accepted turn: it is the flag that separates
    /// "still sending" from "the server has it", and re-stamping it on every follow-up would
    /// make it a last-activity timestamp instead.
    private func adoptRegistration(thread: JesseThread, conversationId: String?) {
        if let conversationId, !conversationId.isEmpty, thread.conversationId != conversationId {
            thread.conversationId = conversationId
        }
        if thread.registeredAt == nil { thread.registeredAt = Date() }
    }

    private func ackDelete(_ item: OutboxItem, context: ModelContext) {
        context.delete(item)
        do {
            try context.save()
        } catch {
            Log.run.error("outbox ACK delete save failed: \(error.localizedDescription) — reconcile will collapse it via the persisted job")
        }
    }

    /// A pre-ACK failure: preserve the message as `.failed` (mapped error + bumped
    /// attempt count) for the per-message Retry, and clear the active run WITHOUT
    /// setting the thread-level error banner — the per-message UI owns this class.
    /// The background grant is released by the transmit task's tail.
    private func failOutbox(_ item: OutboxItem, threadID: UUID, message: String,
                            voice: Bool, speakFailure: Bool, context: ModelContext) {
        item.stateRaw = OutboxState.failed.rawValue
        item.lastError = message
        item.attempts += 1
        // Record when this message may try itself again, and stop recording once the
        // automatic budget is spent — `nil` is what turns the per-message Retry button
        // back into the only way forward. Persisted on the item rather than held in a
        // timer, so a relaunch resumes this schedule instead of granting a fresh one.
        item.nextRetryAt = OutboxRetrySchedule.nextDue(after: now(),
                                                       automaticAttempts: item.automaticAttempts)
        do {
            try context.save()
        } catch {
            Log.run.error("outbox failure save failed: \(error.localizedDescription)")
        }
        startDates[threadID] = nil
        clearPartial(threadID)
        activity[threadID] = nil
        syncLiveActivity(threadID)
        // The due date was just written; this is the moment to wait for it. Arming here
        // rather than in the retry loop's tail is what makes a failed AUTOMATIC retry
        // schedule the next one instead of ending the sequence.
        scheduleOutboxRetry(context: context)
        if speakFailure, voice { Speaker.shared.speak("Sorry, that didn't work. " + message) }
    }

    // MARK: - Send outbox (recover / retry / discard)

    /// Recover the send outbox after a relaunch/foreground: for every `OutboxItem`
    /// still `.sending` with no live transmit task, decide whether the bridge ACKed
    /// before the app died. If the persisted in-flight job for its thread carries a
    /// matching `request_id`, the ACK won the race with the kill (the item's own
    /// delete never persisted) — the item is stale, so delete it. Otherwise the POST
    /// never landed: mark it `.failed` so the per-message Retry appears. This recovers
    /// the app-killed-mid-POST case, which today fails with no error at all. Called
    /// from `resume` before its re-attach loop.
    func reconcile(context: ModelContext) {
        let sending = OutboxState.sending.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.stateRaw == sending })
        guard let items = try? context.fetch(descriptor), !items.isEmpty else { return }
        var changed = false
        for item in items where tasks[item.threadID] == nil {
            if inFlight[item.threadID]?.requestId == item.id {
                context.delete(item)
            } else {
                item.stateRaw = OutboxState.failed.rawValue
                item.lastError = "Jesse never received this."
            }
            changed = true
        }
        guard changed else { return }
        do {
            try context.save()
        } catch {
            Log.run.error("outbox reconcile save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Session-list flag sync

    /// The last ETag from `GET /jesse/sessions`, so an unchanged list is a cheap 304.
    /// Kept in UserDefaults (a tiny string), not the model store, since this is transient
    /// sync state, not conversation data.
    /// Guards `refreshSessions` against overlapping runs. `ContentView` fires one on
    /// `onAppear` and another on `scenePhase == .active`, and both can leave holding the same
    /// stale ETag, so both would fetch the same list and apply the same plan.
    private var isRefreshingSessions = false

    /// Test-only reset of the cached list ETag, so a test can drive a SECOND full refresh
    /// (the "background and reopen the app" case) without the 304 short-circuit hiding it.
    var sessionsETagForTesting: String? {
        get { sessionsETag }
        set { sessionsETag = newValue }
    }

    private var sessionsETag: String? {
        get { UserDefaults.standard.string(forKey: "jesse.sessions.etag") }
        set { UserDefaults.standard.set(newValue, forKey: "jesse.sessions.etag") }
    }

    /// Pull `GET /jesse/sessions` and reconcile it into local threads through the ONE
    /// shared `SessionReconciler` both apps use, cache-first and offline-tolerant. This is
    /// the iOS half of two-way conversation sync, the mirror of the Mac's `MacStore` sync:
    ///  - ADOPT a brand-new bridge session (started on the Mac) as a local stub that
    ///    hydrates its transcript when opened,
    ///  - UPDATE a matched thread (refresh the server title, reconcile favorite/archive
    ///    last-writer-wins via `FlagReconciler`), and
    ///  - DELETE-LOCAL a thread the bridge tombstoned (a delete made on the Mac), clearing
    ///    its hydration cursor.
    ///
    /// The pending-local-delete ids feed the reconciler's resurrection guard, so a
    /// conversation the user just deleted here is never re-adopted before its remote delete
    /// drains. Best-effort throughout: an unreachable or older bridge, or any failure, is
    /// swallowed (logged, never a user error); the next pass retries. Against a pre-0.26.0
    /// bridge the `deleted` array is empty, so delete propagation is inert (exactly today's
    /// behavior), while adoption and flag convergence still work.
    func refreshSessions(context: ModelContext) async {
        let config = configProvider()
        guard config.isConfigured else { return }
        // Re-entrancy guard. `ContentView` fires a refresh on `onAppear` AND on
        // `scenePhase == .active`, and both can leave holding the same stale ETag, so both
        // would fetch the same list and apply the same plan twice. Deliberately a flag with
        // an early return rather than a queue: the second call's work is redundant by
        // construction, so dropping it is correct, and a queue would just delay it.
        guard !isRefreshingSessions else {
            Log.run.debug("conversations refresh already in progress, skipping the overlap")
            return
        }
        isRefreshingSessions = true
        defer { isRefreshingSessions = false }
        let client = makeClient(config)
        do {
            switch try await client.listConversations(etag: sessionsETag) {
            case .notModified:
                return
            case let .conversations(list, deleted, etag):
                sessionsETag = etag
                await applySessionSync(list, deleted: deleted, client: client, context: context)
            }
        } catch {
            Log.run.debug("conversations refresh failed: \(error.localizedDescription)")
        }
    }

    /// A client for fetching a returned file's bytes, or `nil` when the app is not
    /// paired.
    ///
    /// It lives here rather than in the view because `configProvider` and `makeClient`
    /// are the coordinator's injected seams — the same two a test already replaces — so
    /// an artifact fetch in a test goes through the same fake every other turn does.
    @MainActor
    func artifactClient() -> (any JesseClientProtocol)? {
        let cfg = configProvider()
        guard !cfg.normalizedHost.isEmpty, !cfg.token.isEmpty else { return nil }
        return makeClient(cfg)
    }

    /// Apply the shared reconciler's plan to the local store, in FOUR passes whose order is
    /// load-bearing.
    ///
    /// 1. **Legacy bind.** A thread with no `conversationId` but a `sessionId` is a
    ///    pre-upgrade row: find the remote conversation whose `session_ids` contains that
    ///    session and adopt its id. This is how an existing install carries its whole
    ///    history across with no client-side UUIDv5 implementation, and it must run BEFORE
    ///    the plan or every such thread would be classified unknown and adopted as a
    ///    duplicate of itself.
    /// 2. **Merge duplicates.** Group local threads by conversation id and collapse each
    ///    group into its oldest member. This is what repairs the duplicates already sitting
    ///    on a device: it runs on every sync, is a no-op once clean, and is cheap.
    /// 3. **Plan and apply.** Build the held set from `conversationId`, run the shared
    ///    reconciler, then adopt / update / delete-local and reconcile the flags.
    /// 4. **Save once**, if anything changed.
    private func applySessionSync(_ list: [ConversationSummary], deleted: [ConversationTombstone],
                                  client: any JesseClientProtocol, context: ModelContext) async {
        let existing = (try? context.fetch(FetchDescriptor<JesseThread>())) ?? []
        var changed = false

        // ── Pass 1: legacy bind ────────────────────────────────────────────────────────
        // A thread with no session id was never sent, so it already carries a locally
        // minted conversation id and needs nothing.
        var conversationForSession: [String: String] = [:]
        for c in list {
            for sid in c.sessionIds { conversationForSession[sid] = c.conversationId }
            if let sid = c.sessionId { conversationForSession[sid] = c.conversationId }
        }
        for t in existing where (t.conversationId ?? "").isEmpty {
            guard let sid = t.sessionId, !sid.isEmpty,
                  let cid = conversationForSession[sid] else { continue }
            t.conversationId = cid
            changed = true
        }

        // ── Pass 2: merge duplicates ───────────────────────────────────────────────────
        let merged = mergeDuplicateThreads(existing, remote: list, context: context)
        changed = changed || merged > 0

        // ── Pass 3: plan and apply ────────────────────────────────────────────────────
        let live = (try? context.fetch(FetchDescriptor<JesseThread>())) ?? []
        var byConversation: [String: JesseThread] = [:]
        for t in live {
            guard let cid = t.conversationId, !cid.isEmpty else { continue }
            byConversation[cid] = t
        }

        let plan = ConversationReconciler.plan(
            heldConversationIds: Set(byConversation.keys),
            conversations: list,
            tombstones: Set(deleted.map(\.conversationId)),
            pendingDeletion: sessionDeletionStore.pendingIds)

        // ADOPT: create a stub for a conversation started elsewhere (the Mac, the CLI).
        for c in plan.adopt {
            let stamp = Date(timeIntervalSince1970: TimeInterval(c.lastModified))
            let derived = c.firstMessage.map { JesseThread.deriveTitle(from: $0) } ?? ""
            let thread = JesseThread(title: derived, mode: .ask, createdAt: stamp)
            // The initializer minted a FRESH random conversation id; an adopted thread must
            // not keep it, or the next sync would see an id the bridge never heard of and
            // this device would drift back out of convergence.
            thread.conversationId = c.conversationId
            thread.sessionId = c.sessionId
            if c.registeredMs > 0 {
                thread.registeredAt = Date(timeIntervalSince1970: TimeInterval(c.registeredMs) / 1000)
            }
            thread.aiTitle = c.title
            thread.updatedAt = stamp
            context.insert(thread)
            await FlagReconciler.reconcile(
                thread: thread,
                serverFavorite: c.favorite, serverFavoriteUpdatedMs: Int(c.favoriteUpdatedMs),
                serverArchived: c.archived, serverArchivedUpdatedMs: Int(c.archivedUpdatedMs),
                client: client)
            changed = true
        }

        // UPDATE: refresh the server title, the CURRENT session (which moves when the CLI
        // forks), the activity stamp, and the flags. Applied identically on iOS and macOS:
        // the two used to diverge here, which was its own source of confusion.
        for c in plan.update {
            guard let thread = byConversation[c.conversationId] else { continue }
            if let title = c.title, !title.isEmpty, thread.aiTitle != title {
                thread.aiTitle = title
                changed = true
            }
            if let sid = c.sessionId, !sid.isEmpty, thread.sessionId != sid {
                thread.sessionId = sid
                changed = true
            }
            let stamp = Date(timeIntervalSince1970: TimeInterval(c.lastModified))
            if stamp > thread.updatedAt {
                thread.updatedAt = stamp
                changed = true
            }
            let didChange = await FlagReconciler.reconcile(
                thread: thread,
                serverFavorite: c.favorite, serverFavoriteUpdatedMs: Int(c.favoriteUpdatedMs),
                serverArchived: c.archived, serverArchivedUpdatedMs: Int(c.archivedUpdatedMs),
                client: client)
            changed = changed || didChange
        }

        // DELETE-LOCAL: the bridge tombstoned this conversation (deleted on another device).
        for cid in plan.deleteLocalConversationIds {
            guard let thread = byConversation[cid] else { continue }
            cancel(thread.id)
            context.delete(thread)
            hydrationCursorStore.clear(cid)
            changed = true
        }

        // ── Pass 4: save once ─────────────────────────────────────────────────────────
        if changed {
            do { try save(context) } catch {
                Log.run.error("conversation sync save failed: \(error.localizedDescription)")
            }
        }
    }

    /// Collapse every group of local threads sharing one conversation id into the group's
    /// OLDEST member, and return how many merges happened.
    ///
    /// This is the pass that repairs damage already on the device: before the bridge owned
    /// conversation identity, a sync landing mid-turn adopted a second thread for a
    /// conversation the client already held, and the old matcher's `bySession[sid] = t`
    /// silently collapsed the collision (last write wins) so one copy was permanently
    /// orphaned from sync: never title-refreshed, never flag-reconciled, never tombstone
    /// deleted, but still visible in the list.
    ///
    /// It keys on the conversation id and NEVER on the title: two conversations can
    /// legitimately share a title, and merging those would destroy real content.
    private func mergeDuplicateThreads(_ threads: [JesseThread],
                                       remote: [ConversationSummary],
                                       context: ModelContext) -> Int {
        var groups: [String: [JesseThread]] = [:]
        for t in threads {
            guard let cid = t.conversationId, !cid.isEmpty else { continue }
            groups[cid, default: []].append(t)
        }
        let remoteById = Dictionary(remote.map { ($0.conversationId, $0) }, uniquingKeysWith: { a, _ in a })
        var merges = 0
        for (cid, group) in groups where group.count > 1 {
            // Oldest wins: it is the one the user has been looking at, and it holds the
            // earliest turns.
            let ordered = group.sorted { $0.createdAt < $1.createdAt }
            guard let winner = ordered.first else { continue }
            let losers = ordered.dropFirst()

            for loser in losers {
                // Move every turn across under the merge rules, so nothing is duplicated
                // and nothing is lost.
                let plan = TranscriptMerge.plan(
                    existing: winner.orderedTurns.map {
                        TranscriptMerge.Existing(role: $0.role, text: $0.text, sourceKey: $0.sourceKey)
                    },
                    incoming: loser.orderedTurns.map {
                        HydratedTurn(role: $0.role, text: $0.text, timestamp: nil,
                                     turnKey: $0.sourceKey ?? "")
                    })
                let loserTurns = loser.orderedTurns
                let winnerTurns = winner.orderedTurns
                for (i, action) in plan.enumerated() where i < loserTurns.count {
                    let turn = loserTurns[i]
                    switch action {
                    case .skip:
                        break
                    case let .bind(existingIndex):
                        if existingIndex < winnerTurns.count,
                           let key = turn.sourceKey, !key.isEmpty,
                           (winnerTurns[existingIndex].sourceKey ?? "").isEmpty {
                            winnerTurns[existingIndex].sourceKey = key
                        }
                    case .insert:
                        // Re-parent rather than copy, so attachments and provenance ride along.
                        turn.thread = winner
                    }
                }
                // Favorite and archived resolve by the HIGHER last-writer-wins clock, each
                // carrying its own display timestamp, so a merge cannot lose a star made on
                // the copy that happens not to be the oldest.
                if loser.favoriteUpdatedMs > winner.favoriteUpdatedMs {
                    winner.applyFavoriteFromSync(loser.isFavorite, updatedMs: loser.favoriteUpdatedMs)
                }
                if loser.archivedUpdatedMs > winner.archivedUpdatedMs {
                    winner.applyArchivedFromSync(loser.isArchived, updatedMs: loser.archivedUpdatedMs)
                }
                if (winner.aiTitle ?? "").isEmpty, let title = loser.aiTitle, !title.isEmpty {
                    winner.aiTitle = title
                }
                if winner.title.isEmpty, !loser.title.isEmpty {
                    winner.title = loser.title
                }
                winner.updatedAt = max(winner.updatedAt, loser.updatedAt)
                if winner.registeredAt == nil { winner.registeredAt = loser.registeredAt }
                context.delete(loser)
                merges += 1
            }
            // The current session comes from the remote row when there is one, since the
            // bridge is authoritative about which transcript a resume targets.
            if let sid = remoteById[cid]?.sessionId, !sid.isEmpty {
                winner.sessionId = sid
            }
        }
        if merges > 0 {
            Log.run.notice("conversation sync merged \(merges) duplicate thread(s) into their originals")
        }
        return merges
    }

    // MARK: - Hydration (phone-side, on open)

    /// Pull a conversation's transcript from the bridge when it is opened, cache-first and
    /// offline-tolerant:
    ///  - cursor PRESENT, import only the delta past it;
    ///  - cursor ABSENT and the thread already has local turns, it is this device's own
    ///    record, so SEED the cursor to the transcript end and import nothing;
    ///  - cursor ABSENT and no local turns, it is an adopted stub, so import the FULL
    ///    history.
    ///
    /// A 404 (a conversation the bridge does not know, or one gc'd) leaves the cached copy;
    /// a thread with no conversation id has nothing to hydrate. Importing is safe to repeat:
    /// `TranscriptMerge` keys on the bridge's stable `turn_key`, so a turn already rendered
    /// gets its key bound rather than duplicated.
    func hydrateOnOpen(thread: JesseThread, context: ModelContext) async {
        let config = configProvider()
        guard config.isConfigured, let cid = thread.conversationId, !cid.isEmpty else { return }
        let client = makeClient(config)

        if let cursor = hydrationCursorStore.cursor(cid) {
            await importTranscript(cid, after: cursor, into: thread, client: client, context: context)
        } else if thread.turns.isEmpty {
            await importTranscript(cid, after: nil, into: thread, client: client, context: context)
        } else {
            await seedCursorToEnd(cid, from: nil, client: client)
        }
    }

    /// Import the transcript delta from `cursor` into `thread` and advance the cursor to the
    /// returned end. A 404 leaves the cache untouched.
    ///
    /// Every incoming turn goes through the shared `TranscriptMerge`, which is what makes
    /// this idempotent: a turn whose `turn_key` is already held is skipped, an UNKEYED turn
    /// the app created optimistically has the key bound onto it (one bubble, not two), and
    /// only a genuinely new turn is inserted. iOS previously appended every hydrated turn
    /// unconditionally, which is exactly the double-bubble bug.
    private func importTranscript(_ conversationId: String, after cursor: String?,
                                  into thread: JesseThread,
                                  client: any JesseClientProtocol, context: ModelContext) async {
        do {
            let (turns, next) = try await client.hydrate(conversationId: conversationId,
                                                        after: cursor)
            let existing = thread.orderedTurns
            let plan = TranscriptMerge.plan(
                existing: existing.map {
                    TranscriptMerge.Existing(role: $0.role, text: $0.text, sourceKey: $0.sourceKey)
                },
                incoming: turns)
            var inserted = 0
            var bound = 0
            for (i, action) in plan.enumerated() where i < turns.count {
                let t = turns[i]
                switch action {
                case .skip:
                    break
                case let .bind(existingIndex):
                    guard existingIndex < existing.count, !t.turnKey.isEmpty else { break }
                    existing[existingIndex].sourceKey = t.turnKey
                    // A BOUND turn is one this device already delivered, so it already
                    // holds its own artifact rows and must not gain a second set.
                    bound += 1
                case .insert:
                    let turn = Turn(role: TranscriptMerge.role(for: t.role), text: t.text,
                                    createdAt: TranscriptMerge.timestamp(t.timestamp))
                    turn.sourceKey = t.turnKey.isEmpty ? nil : t.turnKey
                    // A turn this device never saw — hydrated from another device's send,
                    // or after a reinstall. The bridge re-attached its returned files, so
                    // history shows the chart instead of silently losing it.
                    Self.attach(t.artifacts, to: turn)
                    turn.thread = thread
                    context.insert(turn)
                    inserted += 1
                }
            }
            if inserted > 0 { thread.updatedAt = Date() }
            if inserted > 0 || bound > 0 {
                do { try save(context) } catch {
                    Log.run.error("hydrate save failed: \(error.localizedDescription)")
                }
            }
            hydrationCursorStore.setCursor(conversationId, next)
        } catch JesseError.badResponse(404, _) {
            // Conversation gone server-side (gc'd / deleted): leave the cached copy.
        } catch {
            Log.run.debug("hydrate failed: \(error.localizedDescription)")
        }
    }

    /// Copy a hydrated turn's returned-file metadata onto a newly inserted `Turn`, in the
    /// order the bridge served them. Metadata only — the bytes are downloaded lazily on
    /// first display, exactly as they are for a turn delivered live.
    @MainActor
    static func attach(_ artifacts: [JesseArtifact], to turn: Turn) {
        for (i, a) in artifacts.enumerated() {
            turn.artifacts.append(TurnArtifact(artifactID: a.id, filename: a.filename,
                                               mime: a.mime, byteCount: Int(a.bytes),
                                               sha256: a.sha256, sortIndex: i))
        }
    }

    /// Advance a conversation's cursor to the current transcript end WITHOUT importing, used
    /// to seed a locally-started thread on its first open. Best-effort: a 404 or transport
    /// failure leaves the cursor unchanged (the next open re-decides).
    private func seedCursorToEnd(_ conversationId: String, from cursor: String?,
                                 client: any JesseClientProtocol) async {
        if let (_, next) = try? await client.hydrate(conversationId: conversationId, after: cursor) {
            hydrationCursorStore.setCursor(conversationId, next)
        }
    }

    /// After a reply is delivered locally, pull the transcript through the SAME merge the
    /// open path uses, so the delivered turns acquire their stable `turn_key`s and the cursor
    /// advances past them.
    ///
    /// This replaces a seed-to-end that imported nothing. That hack existed only because the
    /// merge was unsafe: hydrating right after a delivery would re-append the turns the app
    /// had just rendered. With the key-based merge, hydrating here is idempotent (a rendered
    /// turn gets its key BOUND, never a second bubble) and strictly better, because it is what
    /// binds the keys in the first place. Fire-and-forget and best-effort, so it never blocks
    /// or fails the turn.
    private func advanceCursorAfterDelivery(threadID: UUID, conversationId: String?,
                                            context: ModelContext) {
        guard let cid = conversationId, !cid.isEmpty, configProvider().isConfigured else { return }
        let client = makeClient(configProvider())
        Task { [weak self] in
            guard let self else { return }
            let cursor = self.hydrationCursorStore.cursor(cid)
            // Re-fetch by id: the task runs after the delivery, and the thread may have been
            // deleted (or merged away) in between.
            guard let thread = self.thread(threadID, context: context) else {
                // Nothing to merge into: just move the cursor so a later open does not
                // replay the whole transcript.
                await self.seedCursorToEnd(cid, from: cursor, client: client)
                return
            }
            await self.importTranscript(cid, after: cursor, into: thread,
                                        client: client, context: context)
        }
    }

    /// Fetch one thread by its local id.
    private func thread(_ threadID: UUID, context: ModelContext) -> JesseThread? {
        var d = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == threadID })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Optimistic best-effort push of a just-toggled FAVORITE up to the bridge. The local
    /// write already happened (cache-first, the view saved it); this mirrors it up so the
    /// other device converges on the next sync. No-op for a thread the sync has not bound to
    /// a conversation yet. A failed push is intentionally swallowed: the local
    /// `favoriteUpdatedMs` is now newer than the server, so the next `refreshSessions`
    /// reconcile re-pushes it (the LWW reconcile is self-healing), so no durable retry queue
    /// is needed and a failure never surfaces to the user.
    func pushFavoriteChange(for thread: JesseThread) {
        guard let cid = thread.conversationId, !cid.isEmpty else { return }
        let write = FlagWrite(value: thread.isFavorite, updatedMs: thread.favoriteUpdatedMs)
        let client = makeClient(configProvider())
        Task { try? await client.setFlags(conversationId: cid, favorite: write, archived: nil) }
    }

    /// Optimistic best-effort push of a just-toggled ARCHIVE up to the bridge. Mirror of
    /// `pushFavoriteChange`; same self-healing best-effort semantics.
    func pushArchivedChange(for thread: JesseThread) {
        guard let cid = thread.conversationId, !cid.isEmpty else { return }
        let write = FlagWrite(value: thread.isArchived, updatedMs: thread.archivedUpdatedMs)
        let client = makeClient(configProvider())
        Task { try? await client.setFlags(conversationId: cid, favorite: nil, archived: write) }
    }

    /// Manually retry a `.failed` outbox message — NEVER automatic. Re-runs the
    /// transmit with the SAME `OutboxItem` (same `request_id`, so the bridge dedups
    /// if the original POST actually landed), reusing the existing user `Turn` — never
    /// a second bubble. Guarded: the item must be `.failed` and its thread not
    /// running; session/instructions/floor/config are re-resolved fresh in `transmit`.
    func retry(itemID: UUID, context: ModelContext) {
        guard let item = fetchOutboxItem(itemID, context: context),
              item.state == .failed,
              !isRunning(item.threadID),
              let thread = fetchThread(item.threadID, context: context) else { return }
        item.stateRaw = OutboxState.sending.rawValue
        item.lastError = nil
        // A human saying "try again" is a statement that the situation has changed —
        // they are back on Wi-Fi, they just woke the laptop — so the automatic budget
        // starts over. Tapping Retry therefore never *spends* an automatic attempt, and
        // exhausting the automatic attempts never disables the button.
        item.automaticAttempts = 0
        item.nextRetryAt = nil
        do {
            try context.save()
        } catch {
            Log.run.error("outbox retry flip save failed: \(error.localizedDescription)")
        }
        transmit(item: item, thread: thread, context: context)
    }

    /// Send every `.failed` outbox message that is due, on its own schedule.
    ///
    /// # Why automatic retry is safe here and was not before
    ///
    /// Re-sending a message the bridge may already have is the one thing that could
    /// duplicate a turn, and it is safe by construction rather than by timing: the item's
    /// `id` IS the wire `request_id`, the bridge dedups on it, and a re-send of a POST
    /// that landed returns the same job with no second turn spawned. That has been true
    /// since the outbox shipped; what was missing was anything that acted on it without a
    /// human tap.
    ///
    /// # Why it is bounded
    ///
    /// Five automatic sends, then the message is the button's again
    /// (`OutboxRetrySchedule`). A message that cannot be delivered is usually a laptop
    /// that is asleep, and a phone that retries that forever is a phone with a flat
    /// battery and nothing to show for it.
    ///
    /// `pathJustRecovered` skips the backoff wait: the delays exist to avoid hammering a
    /// network that is not there, and a network that just came back is exactly the case
    /// that reasoning does not apply to. The attempt cap still applies, so a flapping
    /// connection cannot use it to retry without end.
    func retryDueOutbox(context: ModelContext, pathJustRecovered: Bool = false) {
        let failed = OutboxState.failed.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.stateRaw == failed })
        guard let items = try? context.fetch(descriptor), !items.isEmpty else { return }
        let stamp = now()
        var due: [OutboxItem] = []
        for item in items where tasks[item.threadID] == nil && !isRunning(item.threadID) {
            guard OutboxRetrySchedule.isDue(automaticAttempts: item.automaticAttempts,
                                            nextDue: item.nextRetryAt,
                                            now: stamp,
                                            pathJustRecovered: pathJustRecovered) else { continue }
            due.append(item)
        }
        guard !due.isEmpty else { return }
        for item in due {
            item.automaticAttempts += 1
            item.stateRaw = OutboxState.sending.rawValue
            item.lastError = nil
            item.nextRetryAt = nil
        }
        do {
            try context.save()
        } catch {
            Log.run.error("outbox auto-retry flip save failed: \(error.localizedDescription)")
        }
        // Transmit AFTER the save, so a crash between the two leaves items marked
        // `.sending` with no live task — which is precisely the state `reconcile`
        // already resolves on the next launch.
        for item in due {
            guard let thread = fetchThread(item.threadID, context: context) else { continue }
            transmit(item: item, thread: thread, context: context)
        }
    }

    /// Arm the next automatic outbox retry, so a message due in 30 seconds is sent in 30
    /// seconds rather than whenever something else happens to call `retryDueOutbox`.
    ///
    /// One timer for the whole outbox, armed to the EARLIEST due date. A timer per message
    /// would be N wakeups for a queue that is almost always one message long, and N
    /// chances to leak one.
    func scheduleOutboxRetry(context: ModelContext) {
        outboxRetryTask?.cancel()
        outboxRetryTask = nil
        guard let earliest = earliestOutboxRetry(context) else { return }
        let wait = max(0, earliest.timeIntervalSince(now()))
        outboxRetryTask = Task { [weak self] in
            await self?.pollSleep(wait)
            guard let self, !Task.isCancelled else { return }
            self.outboxRetryTask = nil
            self.retryDueOutbox(context: context)
            // Re-arm ONLY if the outbox's earliest due date has actually moved. It has,
            // whenever this wakeup did its job — the message it was armed for is now
            // sending, or its budget is spent. It has NOT if the wait somehow ended
            // early, and re-arming for an instant we have already waited out would be a
            // spin rather than a timer. (A retry that goes on to FAIL arms the next one
            // from `failOutbox`, which is where the new due date is written.)
            if self.earliestOutboxRetry(context) != earliest {
                self.scheduleOutboxRetry(context: context)
            }
        }
    }

    /// The soonest moment any `.failed` outbox message may be sent again, or nil when
    /// none may be — every message delivered, or every automatic budget spent.
    private func earliestOutboxRetry(_ context: ModelContext) -> Date? {
        let failed = OutboxState.failed.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.stateRaw == failed })
        guard let items = try? context.fetch(descriptor) else { return nil }
        return items.compactMap { item in
            OutboxRetrySchedule.mayRetry(automaticAttempts: item.automaticAttempts)
                ? item.nextRetryAt : nil
        }.min()
    }

    /// Discard a failed outbox message: delete the item and its optimistic user
    /// `Turn`, and — if that leaves the thread with no turns and no bridge session —
    /// delete the now-empty thread too. Save.
    func discard(itemID: UUID, context: ModelContext) {
        guard let item = fetchOutboxItem(itemID, context: context) else { return }
        let threadID = item.threadID
        let turnID = item.turnID
        context.delete(item)
        if let thread = fetchThread(threadID, context: context) {
            let remaining = thread.turns.filter { $0.id != turnID }
            if let turn = thread.turns.first(where: { $0.id == turnID }) {
                context.delete(turn)
            }
            if remaining.isEmpty && thread.sessionId == nil {
                context.delete(thread)
            }
        }
        do {
            try context.save()
        } catch {
            Log.run.error("outbox discard save failed: \(error.localizedDescription)")
        }
    }

    private func fetchOutboxItem(_ id: UUID, context: ModelContext) -> OutboxItem? {
        var d = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    private func fetchThread(_ id: UUID, context: ModelContext) -> JesseThread? {
        var d = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Cancellation is authoritative over the run's state, not just the task.
    /// We cancel the task *and* clear the run synchronously so the thread is idle
    /// the instant the user taps Cancel: `inFlight` is dropped and `startDates` is
    /// cleared. Dropping the task handle here — together with the poll loop's
    /// cancelled-exit — means `isRunning` reports `false` immediately; the task's
    /// own tail still runs to release the background grant.
    ///
    /// Additionally, if a bridge job is in flight, fire a best-effort server-side
    /// cancel so the `claude` turn actually stops instead of running to completion
    /// and burning tokens on a reply nobody will read. The network call is
    /// detached so the UI is idle instantly regardless of connectivity; if it
    /// fails (laptop asleep, offline) the orphan runs on and is reaped by the
    /// bridge's job TTL — the prior status quo. `cancelJob` is idempotent, so a
    /// race with the turn's natural completion is harmless.
    func cancel(_ threadID: UUID) {
        // Capture the in-flight job id BEFORE clearRun drops it.
        let jobId = inFlight[threadID]?.jobId
        tasks[threadID]?.cancel()
        tasks[threadID] = nil
        clearRun(threadID)

        if let jobId {
            let client = makeClient(configProvider())
            Task { try? await client.cancelJob(jobId: jobId) }
        }
    }

    // MARK: - Remote session deletion (durable)

    /// Enqueue a thread's bridge `sessionId` for durable remote deletion and kick a
    /// drain. Called from the thread swipe-delete AFTER the instant local SwiftData
    /// delete: the local delete is unchanged, and the remote transcript is reclaimed
    /// best-effort (retried on the next foreground if the laptop is asleep now). A
    /// blank id is a no-op (a thread with no reply has no remote session).
    func enqueueSessionDeletion(_ sessionId: String) {
        sessionDeletionStore.enqueue(sessionId)
        drainSessionDeletions()
    }

    /// Fire-and-forget drain of the durable pending-deletions queue: for each
    /// tombstone, `DELETE /jesse/session/{id}`; success (incl. the bridge's
    /// idempotent 404) clears it, a network failure leaves it for next time. Driven
    /// on enqueue and on `scenePhase → .active` (via `resume`).
    private func drainSessionDeletions() {
        let drainer = SessionDeletionDrainer(
            store: sessionDeletionStore,
            makeClient: { [makeClient, configProvider] in makeClient(configProvider()) })
        Task { await drainer.drain() }
    }

    // MARK: - Resume (foreground re-attach)

    /// Called when the app returns to the foreground. For every persisted job
    /// with no live task, start polling its result and reconcile. A retained job
    /// from a recoverable failure is re-attached too — clearing its stale error
    /// as the poll restarts — so foregrounding auto-recovers what Re-check does
    /// by hand.
    func resume(context: ModelContext) {
        // Recover the send outbox first: a message killed mid-POST (still `.sending`
        // with no live task) is resolved to delivered-and-stale (delete) or
        // never-received (`.failed`) BEFORE any re-attach, so its per-message state
        // is correct the moment the UI reads it.
        reconcile(context: context)
        // End any Live Activity stranded by a kill mid-turn whose thread is neither
        // actively running nor a retained in-flight job (its turn resolved while we
        // were gone). Running/retained threads are kept and re-driven below.
        liveActivity.endStale(keeping: Set(startDates.keys).union(inFlight.keys))
        // Foreground is a drain point for meal writes that failed while backgrounded
        // or with the device locked — retry them now (best-effort, gated).
        drainPendingMeals(context: context)
        // Foreground is also the drain point for remote session deletions queued
        // while the laptop was asleep/offline (thread-delete → DELETE /jesse/session).
        drainSessionDeletions()
        for (threadID, job) in inFlight where tasks[threadID] == nil {
            reattach(threadID: threadID, job: job, context: context)
        }
        // Whatever is in the outbox and due goes now, and the next one is armed. On
        // foreground this is usually a no-op; when it is not, it is a message the user
        // sent before walking out of range and has been assuming was delivered.
        retryDueOutbox(context: context)
        scheduleOutboxRetry(context: context)
        // A queued intent (P8) replays alongside the two above rather than on a timer of
        // its own, so the three recoveries cannot race each other. A no-op today.
        replayQueuedIntents()
    }

    // MARK: - Recovery on a network change

    /// Start watching the network, so coming back onto it recovers everything that was
    /// waiting — without anything on screen having to notice.
    ///
    /// # Why this exists
    ///
    /// Every recovery in this app used to be a human one. A failed poll ended in a manual
    /// "Re-check". The send outbox retried only on a tap. The phone knew the whole time
    /// that it had walked back into signal, and nothing asked it. This is the ask.
    ///
    /// Idempotent — the app calls it at launch and could call it again on activation.
    func startConnectivityRecovery(context: ModelContext,
                                   monitor: ConnectivityMonitor = .shared) {
        guard connectivityTask == nil else { return }
        monitor.start()
        let stream = monitor.paths()
        connectivityTask = Task { [weak self] in
            var previous: NetworkPathSnapshot?
            for await snapshot in stream {
                guard let self else { return }
                defer { previous = snapshot }
                // Only a genuine came-back transition. `NWPathMonitor` reports every
                // interface event, and a Wi-Fi → cellular swap with both satisfied is not
                // a recovery: nothing was waiting on it, and treating it as one turns a
                // walk past the front door into a burst of re-attaches and refetches.
                guard let previous, pathDidRecover(from: previous, to: snapshot) else { continue }
                self.recoverAfterNetworkReturned(context: context)
            }
        }
    }

    /// Stop watching. The app never calls this — connectivity is an app-lifetime concern
    /// — but a test tearing down a coordinator must.
    func stopConnectivityRecovery() {
        connectivityTask?.cancel()
        connectivityTask = nil
        outboxRetryTask?.cancel()
        outboxRetryTask = nil
    }

    /// The four things a recovered network makes possible, in the order that matters.
    ///
    /// Internal rather than private so a test can drive it directly, without a radio and
    /// without waiting on a stream.
    func recoverAfterNetworkReturned(context: ModelContext) {
        // 1. Resolve any message killed mid-POST BEFORE re-sending anything, so a
        //    delivered-but-unacked item is deleted rather than re-sent.
        reconcile(context: context)
        // 2. Re-attach every persisted in-flight job. The turn kept running on the
        //    laptop the whole time; this is the app catching up with it.
        for (threadID, job) in inFlight where tasks[threadID] == nil {
            reattach(threadID: threadID, job: job, context: context)
        }
        // 3. Drain the send outbox, skipping the backoff — a network that just came back
        //    is exactly the case the delays exist to avoid, so they do not apply.
        retryDueOutbox(context: context, pathJustRecovered: true)
        scheduleOutboxRetry(context: context)
        // 4. And whatever an offline intent queue is holding (P8; a no-op today).
        replayQueuedIntents()
    }

    /// Kick the intent queue. Detached so a slow replay never delays the re-attach and
    /// outbox drain it rides alongside.
    private func replayQueuedIntents() {
        let replayer = intentReplayer
        Task { await replayer.replayAll() }
    }

    /// Drain the intent queue and WAIT for it — what the background refresh task needs,
    /// which must not report completion while its work is still running.
    ///
    /// The same replayer as the recovery path's, so the "one run at a time" rule holds
    /// across both: a background task that fired while a foreground recovery was mid-run
    /// finds the replayer busy and returns immediately rather than racing its ETags.
    func replayQueuedIntentsNow() async {
        await intentReplayer.replayAll()
    }

    /// Manual "Re-check" for one thread: re-attach to its retained job and fetch
    /// the result now. Ready → delivered into the thread; still running → resumes
    /// the 2s poll; gone past the bridge TTL → terminal "expired". A no-op if the
    /// thread is already polling or has no retained job.
    func recheck(_ threadID: UUID, context: ModelContext) {
        guard tasks[threadID] == nil, let job = inFlight[threadID] else { return }
        reattach(threadID: threadID, job: job, context: context)
    }

    /// Shared re-attach used by both `resume` (auto, on foreground) and `recheck`
    /// (manual): clear any stale error, mark the thread running, and poll the job.
    private func reattach(threadID: UUID, job: InFlightJob, context: ModelContext) {
        errors[threadID] = nil
        if startDates[threadID] == nil { startDates[threadID] = Date() }
        let cfg = configProvider()
        tasks[threadID] = Task { [weak self] in
            guard let self else { return }
            let client = self.makeClient(cfg)
            // Reconnect the stream for live display — the bridge replays the
            // text-so-far, so a foregrounded turn picks up where it left off —
            // while the concurrent poll (see `consume`) owns completion, so a
            // stream that won't reopen never blocks the re-attach.
            //
            // No live `thread` reference survives a relaunch, so `finish` falls
            // back to a by-id fetch here. If that fetch can't resolve the thread,
            // `finish` surfaces a recoverable error + Re-check rather than dropping
            // the reply (see `finish`).
            await self.consume(threadID: threadID, thread: nil, jobId: job.jobId,
                               voice: job.voice, client: client, context: context)
            self.tasks[threadID] = nil
            self.backgroundGuard.end(threadID)
        }
    }

    // MARK: - Internals

    /// The single terminal result of a turn, produced by whichever concurrent
    /// child (stream or poll) reaches it first. Mapping it to the finish/fail
    /// action happens exactly once, in `consume`, so a late second terminal from
    /// the other source can't double-finish.
    // Internal (not private) so the testable `pollForOutcome` can name it.
    enum TurnOutcome {
        case done(JesseReply)
        case failed(String)   // recoverable — keep the job for Re-check/resume
        case expired          // terminal — the reply is gone past its TTL
        case cancelled        // a server `cancelled` frame (the user's own cancel)
    }

    /// Drive a running turn to completion by racing two concurrent children under
    /// this thread's task: (1) a **display** consumer of the live SSE stream that
    /// only updates `partialText`/`activity`, and (2) the **poll** loop on
    /// `client.result`. Whichever produces a terminal `TurnOutcome` first finishes
    /// the turn; the group then cancels the other, so exactly one finish/fail
    /// action runs — the TaskGroup's first-result semantics are the "already
    /// finished" guard.
    ///
    /// Root cause this guards against: streaming used to be the sole completion
    /// path. `consume` blocked in `for try await event in client.stream` and only
    /// fell back to polling once the stream *ended*. A half-open stream — opened,
    /// then never a frame and never a close (phone suspended, NAT/idle timeout, a
    /// wedged proxy) — never ends, so the turn hung forever. The fix: **streaming
    /// is display-only; the poll owns completion.** Polling runs from the start,
    /// not as a fallback, so a stalled, erroring, or never-opening stream can no
    /// longer delay or block the reply.
    ///
    /// A user Cancel cancels the parent task (and thus the group): both children
    /// stop, any outcome is dropped (the `Task.isCancelled` guard below), and
    /// `cancel()`'s own synchronous teardown stands — preserving "ignore a late
    /// terminal after cancel".
    /// `thread` is the live reference the send path holds; `nil` on the
    /// resume/recheck path (after a relaunch), where `finish` re-fetches by id.
    private func consume(threadID: UUID, thread: JesseThread?, jobId: String, voice: Bool,
                         client: any JesseClientProtocol, context: ModelContext,
                         retry: TurnRetry? = nil) async {
        let outcome: TurnOutcome? = await withTaskGroup(of: TurnOutcome?.self) { group in
            group.addTask { await self.streamForDisplay(threadID: threadID, jobId: jobId, client: client) }
            group.addTask { await self.pollForOutcome(threadID: threadID, jobId: jobId, client: client) }
            // First non-nil terminal outcome wins; cancel the loser. A nil child
            // (stream stalled/errored/ended bare, or poll cancelled) just drops
            // out — keep waiting on the other.
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        // Apply the one terminal action. Bail if the user cancelled meanwhile so
        // no reply lands on an already-cleared run.
        if Task.isCancelled { return }
        // The group yielded nil without a user cancel: the stream ended bare AND
        // the poll returned nil (e.g. its task was cancelled out from under us
        // without the parent being cancelled). Returning silently here would leave
        // `startDates`/`inFlight` set so `isRunning` stays true — a spinner forever.
        // Treat it as a recoverable failure instead: the job_id is retained, so
        // Re-check / the next `resume` can still pick the reply up. consume must
        // never return with the run still marked running unless the user cancelled.
        guard let outcome else {
            failRecoverable(threadID: threadID,
                            message: "Lost contact with the turn — tap Re-check.",
                            voice: voice)
            return
        }
        switch outcome {
        case .done(let reply):
            // Agent-driven device-context channels: if this reply is a
            // JESSE_NEEDS_HEALTH or JESSE_NEEDS_LOCATION directive and that CHANNEL
            // still has its one retry for this message, fulfill it and re-send the SAME
            // turn with the data attached — DON'T persist the sentinel turn (its
            // stripped text is empty by construction). `retry` is nil on the resume path
            // and on the retry's own consume, so a second directive is ignored and the
            // stripped text is persisted as the answer.
            //
            // The budget is per (thread, channel), so a reply that asks for location
            // after health was already spent still gets its own retry.
            if let needs = reply.deviceContextRequest, let retry {
                let key = RetryKey(threadID: threadID, channel: needs.channel)
                if !deviceContextRetried.contains(key) {
                    deviceContextRetried.insert(key)
                    await fulfillAndRetry(threadID: threadID, thread: thread, needs: needs,
                                          retry: retry, voice: voice, sessionId: reply.sessionId,
                                          client: client, context: context)
                    return
                }
            }
            finish(threadID: threadID, thread: thread, reply: Self.appCapped(reply), voice: voice,
                   jobId: jobId, context: context)
        case .failed(let message):
            // The turn failed recoverably (a bridge `error`/`.failed`, or a
            // transport error in the poll) — keep the job retained for Re-check.
            failRecoverable(threadID: threadID, message: message, voice: voice)
        case .expired:
            // The bridge no longer has the reply (held its full TTL, now evicted).
            // The only genuinely terminal "gone" state: drop the job and say so.
            fail(threadID: threadID,
                 message: "This reply has expired — it was held but not picked up in time, and Jesse no longer has it.",
                 voice: voice)
        case .cancelled:
            // The user cancelled (the only source of this frame). cancel() already
            // tore the run down; just make sure nothing lingers.
            clearRun(threadID)
        }
    }

    /// Fulfill a device-context directive (health or location) and re-send the SAME turn
    /// on the SAME thread with the data attached, then consume the answer job. The
    /// sentinel turn is never persisted (we returned before `finish`); this delivers the
    /// real answer.
    ///
    /// ANTI-LOOP GUARD 3 of 3, and the one that makes a refusal produce an ANSWER rather
    /// than a hang: if fulfillment fails — toggle off, permission denied, Location
    /// Services off, the fix timed out, no fix on the device, a simulator with no
    /// location set — the client STILL re-sends, marked `unavailable`, so the bridge
    /// appends its "answer without it and do NOT emit it again this turn" note. Either
    /// way exactly one answer turn lands. Returning early on a failure instead would
    /// leave the thread showing an empty sentinel forever.
    ///
    /// The answer job's consume runs with `retry: nil`, so a second directive is ignored
    /// and its stripped text is persisted (capped).
    ///
    /// Written ONCE for both channels: `needs` carries which channel it belongs to, so
    /// there is one copy of the three guards rather than one per channel.
    private func fulfillAndRetry(threadID: UUID, thread: JesseThread?,
                                 needs: DeviceContextRequest,
                                 retry: TurnRetry, voice: Bool, sessionId: String?,
                                 client: any JesseClientProtocol, context: ModelContext) async {
        // The retry is the SAME turn on the SAME conversation, so it must carry the same
        // identity: a fresh id here would register a second conversation for one message.
        let conversationId = thread?.conversationId
            ?? self.thread(threadID, context: context)?.conversationId
            ?? JesseThread.mintConversationId()
        do {
            let result = try await client.sendFulfilling(
                needs, mode: retry.mode, text: retry.text, sessionId: sessionId,
                conversationId: conversationId, voice: voice,
                instructions: retry.instructions, floorOverride: retry.floorOverride,
                model: retry.model)
            switch result {
            case .reply(let reply, _, _):
                finish(threadID: threadID, thread: thread, reply: Self.appCapped(reply),
                       voice: voice, jobId: nil, context: context)
            case .running(let jobId, let remoteConversationId):
                // The new job replaces the sentinel's, so Re-check/resume target the
                // answer turn.
                //
                // `retry` is carried FORWARD rather than nilled, and the budget is what
                // bounds the exchange. This is the whole point of keying the budget by
                // channel: a turn that legitimately needs both — "how far did I run,
                // and how far is the gym from here" — can only learn it needs the
                // second thing after the first has been answered. Nilling here made
                // whichever directive arrived first win and starved the other for the
                // rest of the message, which is exactly the starvation the per-channel
                // key exists to prevent.
                //
                // It is still strictly bounded, and by construction rather than by
                // luck: each channel's key is inserted BEFORE its fulfilment runs, so a
                // user message can produce at most one retry per channel —
                // `DeviceContextChannel.allCases.count` in total, whatever the agent
                // emits. A channel repeating itself finds its own key already spent and
                // is ignored, exactly as before.
                if let thread { adoptRegistration(thread: thread, conversationId: remoteConversationId) }
                persist(threadID: threadID, job: InFlightJob(jobId: jobId, voice: voice))
                await consume(threadID: threadID, thread: thread, jobId: jobId,
                              voice: voice, client: client, context: context, retry: retry)
            }
        } catch is CancellationError {
            clearRun(threadID)
        } catch let error as JesseError {
            handle(error: error, threadID: threadID, voice: voice)
        } catch {
            fail(threadID: threadID, message: error.localizedDescription, voice: voice)
        }
    }

    /// App-side cap on a persisted answer — a safety bound so a runaway reply (e.g.
    /// a retry whose own reply also carried a directive plus a huge body) can never
    /// store an unbounded string. The bridge already caps its output; this is
    /// defense in depth, applied where a reply is finished. Char-boundary safe.
    static let maxPersistedAnswerBytes = 32 * 1024
    static func appCapped(_ reply: JesseReply) -> JesseReply {
        guard reply.text.utf8.count > maxPersistedAnswerBytes else { return reply }
        var end = reply.text.startIndex
        var used = 0
        for ch in reply.text {
            let n = String(ch).utf8.count
            if used + n > maxPersistedAnswerBytes { break }
            used += n
            end = reply.text.index(after: end)
        }
        return JesseReply(text: String(reply.text[..<end]), sessionId: reply.sessionId,
                          directives: reply.directives, provenance: reply.provenance)
    }

    /// Display-only consumer of the live SSE stream: updates `partialText` and
    /// `activity` as frames arrive. Returns a terminal `TurnOutcome` if the stream
    /// happens to win the race (a `done`/`failed`/`cancelled` frame), else `nil` —
    /// if it errors, stalls into cancellation, or ends without a terminal frame —
    /// in which case the concurrent poll owns completion. Never finishes the turn
    /// itself; `consume` applies the single terminal action.
    private func streamForDisplay(threadID: UUID, jobId: String,
                                  client: any JesseClientProtocol) async -> TurnOutcome? {
        do {
            for try await event in client.stream(jobId: jobId) {
                if Task.isCancelled { return nil }
                switch event {
                case .reset(let text):
                    resetPartial(threadID, to: text)
                    noteStreamActivity(threadID)
                case .delta(let chunk):
                    appendPartial(threadID, chunk)
                    noteStreamActivity(threadID)
                case .activity(let a):
                    activity[threadID] = Self.activityLabel(for: a)
                    // Push the new human activity line to the Live Activity.
                    syncLiveActivity(threadID)
                case .done(let reply):
                    return .done(reply)
                case .failed(let message):
                    return .failed(message)
                case .cancelled:
                    return .cancelled
                }
            }
        } catch {
            // Stream dropped/failed — display only, so swallow it; the concurrent
            // poll completes the turn.
        }
        // Stream ended (bare or errored) without a terminal frame: surface any tail
        // still buffered by the coalescer so the last delta isn't stranded, then let
        // the poll own completion.
        flushPartial(threadID)
        return nil
    }

    /// Map a coarse tool activity to a human line. The mapping itself lives on
    /// `ToolActivity` in JesseKit, because the Mac app renders the same line and a
    /// whole-answer turn has nothing else to show — see `ToolActivity.displayLabel`.
    static func activityLabel(for activity: ToolActivity) -> String { activity.displayLabel }

    /// Poll `GET /jesse/result/{jobId}` until the turn resolves, returning the
    /// terminal `TurnOutcome` (or `nil` on cancellation). This is the
    /// authoritative completion path: it runs concurrently with the display stream
    /// from the start (see `consume`), so a stalled or absent stream never delays
    /// the reply. The job_id is retained on a recoverable failure — a transport
    /// error here or a bridge-reported `.failed`, both mapped to `failRecoverable`
    /// by `consume` — so Re-check and the next `resume` can pick the reply back up;
    /// the run only truly ends, and the job is dropped, on `.done` (success) or
    /// `.expired` (gone past TTL).
    func pollForOutcome(threadID: UUID, jobId: String,
                        client: any JesseClientProtocol) async -> TurnOutcome? {
        var interval = Self.pollInterval
        var lastTick = streamTicks[threadID] ?? 0
        while !Task.isCancelled {
            let state: JesseResultState
            do {
                state = try await client.result(jobId: jobId)
            } catch {
                // A user-initiated cancel surfaces here as a cancelled URL load
                // (mapped to `.transport`). Treat any cancellation as a clean stop
                // — the run was already cleared by `cancel`.
                if Task.isCancelled { return nil }
                // A transport error while THIS DEVICE HAS NO NETWORK is not a failed
                // turn. It is a tunnel, a lift, a plane — and the turn is still running
                // on the laptop, which never noticed. Surfacing "tap Re-check" there was
                // the app blaming the bridge for the phone's own radio, and it made the
                // manual button the only way back even though the phone knew perfectly
                // well when it had returned. So: WAIT for the path, bounded, then poll
                // again. The job is untouched, the spinner keeps spinning, and nothing
                // about the turn has changed.
                //
                // With a satisfied path the same error means something entirely
                // different — the laptop is asleep, or the bridge is down — and that IS
                // a recoverable failure with a visible Re-check, exactly as before.
                if Self.isWaitForNetwork(error), !pathIsSatisfied() {
                    let returned = await awaitPath(Self.networkWaitCeiling)
                    if Task.isCancelled { return nil }
                    // Whether or not it came back inside the ceiling, loop and let the
                    // next request produce the evidence — an unbounded wait is how a
                    // spinner becomes permanent.
                    _ = returned
                    continue
                }
                let message = (error as? JesseError)?.localizedDescription
                    ?? error.localizedDescription
                return .failed(message)
            }
            // A `.done` can land in the same instant the user cancels; bail before
            // returning it so no reply is appended for a cancelled run.
            if Task.isCancelled { return nil }
            switch state {
            case .running:
                // Snap back to the fast cadence if the live stream delivered new
                // tokens since the last poll — the turn is clearly alive and
                // producing output, so poll promptly. Otherwise keep backing off.
                let tick = streamTicks[threadID] ?? 0
                if tick != lastTick {
                    interval = Self.pollInterval
                    lastTick = tick
                }
                // On a metered link the floor overrides even the snap-back: the stream is
                // already delivering the tokens the poll would only be confirming.
                await pollSleep(max(interval, frugal().pollFloorSeconds))
                interval = Self.nextPollInterval(after: interval)
            case .done(let reply):
                return .done(reply)
            case .failed(let message):
                return .failed(message)
            case .expired:
                return .expired
            case .cancelled:
                // The bridge reports the turn was cancelled server-side. Treat it
                // exactly like the stream's `cancelled` frame: a clean terminal
                // state, not a recoverable failure — `consume` drops the job and
                // returns the thread to idle (no stuck Re-check).
                return .cancelled
            }
        }
        return nil
    }

    /// Deliver a completed reply. The invariant: this either shows the reply (a
    /// `jesse` Turn, persisted — its content is the screen text, or, for a
    /// spoken-only reply, the spoken line) or surfaces a recoverable error +
    /// Re-check — it is never allowed to `clearRun` into nothing, and it never both
    /// "shows empty" and "stays silent."
    ///
    /// The SwiftData append + save + idempotency-on-`jobId` are owned by
    /// `TurnWriter`; this method maps the writer's `Outcome` to the run-state it
    /// owns (the spinner, the error banner, the spoken reply, the push prompt). The
    /// three ways the old `finish` could silently lose a reply are each a distinct
    /// `Outcome` that surfaces a visible, recoverable state here.
    ///
    /// `thread` is the live reference the send path holds — preferred so the common
    /// case never re-fetches. It's `nil` only on the resume/recheck path (after a
    /// relaunch), where the writer falls back to a by-id fetch. `jobId` is the bridge
    /// job whose reply this is (`nil` only on the dead inline `.reply` path).
    // Private so callers can't bypass `send()` (which owns the optimistic turn,
    // persistence, and the stream/poll race). `consume` and the dead inline
    // `.reply` path are the only callers, both inside this type.
    private func finish(threadID: UUID, thread: JesseThread?, reply: JesseReply,
                        voice: Bool, jobId: String?, context: ModelContext) {
        // Write any logged meals into Apple Health before mapping the delivery
        // outcome — idempotent by meal id, so it's safe on a re-delivery (the same
        // reply re-checked/resumed writes nothing new). Best-effort and detached;
        // never affects whether the reply is shown.
        writeMeals(from: reply, context: context)
        let outcome = turnWriter.write(threadID: threadID, thread: thread, reply: reply,
                                       jobId: jobId, context: context)
        // The single canonical delivery point: a fresh turn just landed, so advance the
        // hydration cursor past it (best-effort) so a later open never re-imports the
        // phone's own reply. `.alreadyDelivered` re-entries already advanced on first sight.
        if case .delivered = outcome {
            advanceCursorAfterDelivery(threadID: threadID,
                                       conversationId: thread?.conversationId,
                                       context: context)
        }
        switch outcome {
        case .unresolvableThread:
            // The reply has nowhere visible to land — keep the job for Re-check.
            failRecoverable(threadID: threadID,
                            message: "Got the reply but couldn't attach it to this thread — tap Re-check.",
                            voice: voice)
        case .empty:
            // Genuinely empty — surface Re-check rather than a blank turn.
            failRecoverable(threadID: threadID,
                            message: "Jesse's reply came back empty — tap Re-check to fetch it again.",
                            voice: voice)
        case .alreadyDelivered(let saved):
            // Idempotent re-entry: never speak again. Clear on a successful retry;
            // otherwise keep the recoverable save error + retained job.
            if saved {
                errors[threadID] = nil
                clearRun(threadID)
            } else {
                surfaceSaveFailure(threadID)
            }
        case .delivered(let saved):
            if saved {
                if voice { speak(reply.spokenText) }
                // A turn just landed successfully — the moment to ask for push
                // permission (idempotent; PushManager prompts once, when configured).
                onFirstSuccess()
                clearRun(threadID)
            } else {
                // The in-memory turn already shows; surface the save failure (keeping
                // the job for Re-check) and still speak the reply that was shown.
                surfaceSaveFailure(threadID)
                if voice { speak(reply.spokenText) }
            }
        }
    }

    /// A save failure after the in-memory reply is already shown: surface the
    /// recoverable error and stop the active run, but KEEP the retained job for
    /// Re-check (the in-memory append + idempotency key persist on the live object,
    /// so a same-session Re-check retries the save without re-appending).
    private func surfaceSaveFailure(_ threadID: UUID) {
        errors[threadID] = "Showed the reply, but couldn't save it — tap Re-check."
        startDates[threadID] = nil
        clearPartial(threadID)
        activity[threadID] = nil
    }

    // MARK: - Push hooks

    /// On backgrounding, ask the bridge to push us when any still-in-flight turn
    /// finishes — the "I'm leaving, ping me" signal that lets the bridge push only
    /// when the phone actually needs it. Best-effort and fire-and-forget per job;
    /// if it fails (offline, laptop asleep), the foreground `resume` still
    /// re-attaches, so nothing is lost — there's just no push.
    func notifyBackgroundInFlight() {
        guard !inFlight.isEmpty else { return }
        let cfg = configProvider()
        guard cfg.isConfigured else { return }
        let client = makeClient(cfg)
        for job in inFlight.values {
            let jobId = job.jobId
            Task { try? await client.notifyOnComplete(jobId: jobId) }
        }
    }

    /// A reply for `jobId` was fetched and written while the app was in the BACKGROUND.
    ///
    /// The write already happened, through the same `TurnWriter` (see
    /// `BackgroundDelivery`); this is only the in-memory half the background path cannot
    /// reach — the spinner, the retained job, the Live Activity. Without it a foregrounded
    /// app would still show a running turn for a reply already sitting in its transcript,
    /// and would poll once more to find that out.
    ///
    /// Guarded on the job id: a stale notification for a job this thread has since
    /// replaced (a new turn supersedes the old one in `send`) must not clear the run of
    /// the turn that replaced it.
    func noteBackgroundDelivery(threadID: UUID, jobId: String) {
        guard inFlight[threadID]?.jobId == jobId else { return }
        errors[threadID] = nil
        tasks[threadID]?.cancel()
        tasks[threadID] = nil
        clearRun(threadID)
    }

    /// The thread whose in-flight job has this id — used to route a notification
    /// tap to the right conversation. nil if no in-flight job matches.
    func threadID(forJobId jobId: String) -> UUID? {
        inFlight.first(where: { $0.value.jobId == jobId })?.key
    }

    /// The thread a tapped notification should open, resolved in three steps.
    ///
    /// This used to be step one alone, and step one answers for exactly one case: a turn
    /// THIS DEVICE started and has not yet settled. Everything else fell off the end of it
    /// and the tap silently landed on the thread list —
    ///
    /// 1. **The in-flight job.** Fastest, and the live case. `liveThreadID` is that lookup,
    ///    performed by the caller BEFORE `resume`, which re-attaches and may deliver the
    ///    reply and clear the entry out from under it.
    /// 2. **The conversation, locally.** An already-settled turn has no in-flight entry —
    ///    background delivery removes it the moment it writes the reply — but its thread is
    ///    right there in the store under the conversation the push named.
    /// 3. **The conversation, after a sync.** A SCHEDULED run is a conversation this phone
    ///    has never seen: the bridge mints a fresh one per fire and the phone was not
    ///    involved. `refreshSessions` adopts unknown remote conversations as local threads,
    ///    so the retry after it finds one. This branch is what makes a morning-routine push
    ///    open its own thread; without it that push is unroutable however good the payload.
    ///
    /// `nil` only when all three miss — an older bridge that sent no conversation, an
    /// unreachable bridge, or a conversation that genuinely does not exist. The caller
    /// lands on the thread list, which is the pre-existing behaviour, and says so.
    func thread(forTap tap: PushTap, liveThreadID: UUID?, context: ModelContext) async -> JesseThread? {
        if let liveThreadID, let thread = thread(id: liveThreadID, context: context) {
            return thread
        }
        guard let conversationId = tap.conversationId else { return nil }
        if let thread = thread(conversationId: conversationId, context: context) {
            return thread
        }
        await refreshSessions(context: context)
        return thread(conversationId: conversationId, context: context)
    }

    /// One thread by SwiftData identity.
    private func thread(id: UUID, context: ModelContext) -> JesseThread? {
        var d = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// One thread by bridge conversation id.
    ///
    /// The stored value is a CANONICAL LOWERCASE uuid (see `JesseThread.mintConversationId`
    /// — `UUID.uuidString` is uppercase and the bridge rejects it outright), and the
    /// comparison here is a plain `==`. So the incoming id is lowercased first: matching is
    /// exact, and the normalisation is what makes it exact rather than accidental.
    private func thread(conversationId: String, context: ModelContext) -> JesseThread? {
        let cid = conversationId.lowercased()
        var d = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.conversationId == cid })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: - AI titles

    /// Ensure a visible thread has an up-to-date AI title, generating at most ONE
    /// title per stale content state and never blocking the list. Called on row
    /// appearance (the "visible row" trigger). No-ops — no network — when:
    ///  - the thread has no turns yet (nothing to title),
    ///  - the cached title is already current (`titleSourceKey` == the live key),
    ///  - a generation is already in flight for this thread, or
    ///  - this exact content key was already attempted this launch (so a bridge
    ///    without /jesse/title, which returns nil, isn't re-hit on every appearance).
    ///
    /// Invalidation is "a new entry busts the cache": when a turn is appended or
    /// edited the content key changes, so the guards fall through and exactly one
    /// regeneration fires. On a non-nil result the title + the key it was minted
    /// from are written and saved; a nil result (any failure) leaves the derived
    /// title in place — no error, no spinner. The cached (possibly stale) title
    /// keeps displaying while a refresh runs, so the row never flickers to blank.
    func ensureTitle(for thread: JesseThread, context: ModelContext) {
        let key = threadContentKey(for: thread)
        guard !key.isEmpty,
              thread.titleSourceKey != key,
              !titlesInFlight.contains(thread.id),
              titleAttemptedKeys[thread.id] != key else { return }

        let threadID = thread.id
        titlesInFlight.insert(threadID)
        titleAttemptedKeys[threadID] = key
        let digest = titleDigest(for: thread)
        // Persist the minted title under the conversation, so every device's list shows it.
        let conversationId = thread.conversationId
        let cfg = configProvider()

        Task { [weak self] in
            guard let self else { return }
            let client = self.makeClient(cfg)
            let title = await client.title(forDigest: digest, conversationId: conversationId)
            self.titlesInFlight.remove(threadID)
            // nil = the bridge had no title (offline / no endpoint / empty) — keep
            // the derived title; `titleAttemptedKeys` prevents a re-fire for this
            // same content until a new turn changes the key.
            guard let title else { return }
            thread.aiTitle = title
            thread.titleSourceKey = key
            try? self.save(context)
        }
    }

    /// A terminal failure: surface the message and drop everything, including the
    /// retained job (nothing left to re-check). Used for a genuinely-gone reply
    /// (`.expired`) and for send-path errors that never got a job_id.
    private func fail(threadID: UUID, message: String, voice: Bool) {
        errors[threadID] = message
        if voice { Speaker.shared.speak("Sorry, that didn't work. " + message) }
        clearRun(threadID)
    }

    /// A recoverable failure: surface the message but KEEP the retained (and
    /// already-persisted) job_id so Re-check — and the next foreground `resume` —
    /// can still fetch the reply. Stops the active run (clears `startDates`) so
    /// the thread reads as idle-with-Re-check rather than still "Thinking…".
    /// `inFlight` is deliberately left intact and is not re-saved (it's unchanged).
    private func failRecoverable(threadID: UUID, message: String, voice: Bool) {
        errors[threadID] = message
        startDates[threadID] = nil
        // The live view stops (no longer running); drop any half-streamed text so
        // it isn't left dangling. A Re-check/resume reconnects and replays it.
        clearPartial(threadID)
        activity[threadID] = nil
        // The run stopped (idle-with-Re-check) — end the Live Activity.
        syncLiveActivity(threadID)
        if voice { Speaker.shared.speak("Sorry, that didn't work yet. " + message) }
    }

    /// A `.connectionLost` with a job in flight is recoverable — keep the job and
    /// stop quietly so `resume` re-attaches. Without a job id there's nothing to
    /// re-attach to, so surface it.
    private func handle(error: JesseError, threadID: UUID, voice: Bool) {
        if case .connectionLost = error, inFlight[threadID] != nil { return }
        fail(threadID: threadID, message: error.localizedDescription, voice: voice)
    }

    /// Generate downscaled JPEG previews of `attachments` and attach them to
    /// `userTurn` as `TurnAttachment`s. The expensive downscale/encode runs off the
    /// main actor (a detached task over the Sendable staged bytes); the attach +
    /// save then hop back to the main actor. Best-effort and non-blocking — the
    /// turn is already saved, so previews simply appear a moment later. The original
    /// full-resolution bytes are never persisted (only the thumbnail is stored) and
    /// are released once this returns. A generation/save failure is logged, not
    /// surfaced: a preview is not critical to the turn.
    private func attachPreviews(to userTurn: Turn, from attachments: [JesseAttachment],
                                context: ModelContext) {
        guard !attachments.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            // Off the main actor: the CPU/ImageIO/PDFKit work only, over the
            // Sendable staged bytes. Returns Sendable (filename, mime, thumbnail).
            let previews: [(String, String, Data)] = await Task.detached(priority: .utility) {
                attachments.compactMap { att in
                    AttachmentThumbnail.make(data: att.data, mime: att.mime)
                        .map { (att.filename, att.mime, $0) }
                }
            }.value
            guard !previews.isEmpty else { return }
            for (filename, mime, thumbnail) in previews {
                userTurn.attachments.append(
                    TurnAttachment(filename: filename, mime: mime, thumbnail: thumbnail))
            }
            do {
                try self.save(context)
            } catch {
                Log.run.error("attachment previews save failed: \(error.localizedDescription) — shown in memory but unsaved")
            }
        }
    }

    private func persist(threadID: UUID, job: InFlightJob) {
        inFlight[threadID] = job
        inFlightStore.save(inFlight)
    }

    // MARK: - Meal write-back (Apple Health)

    /// Write any meals this reply logged into Apple Health, idempotently. A pure
    /// side effect: fire-and-forget on its own task so it never blocks or fails the
    /// turn (the reply is already delivered). Gated by the toggle + write auth
    /// inside `MealHealthWriter`; deduped by meal id against the SwiftData written
    /// store, so re-delivery (Re-check, resume, a re-opened thread) never
    /// double-writes; a failed write enqueues to the pending store for a later
    /// drain. No-op for the overwhelming majority of turns (no `meal_log`).
    private func writeMeals(from reply: JesseReply, context: ModelContext) {
        guard let batch = reply.mealBatch, !batch.isEmpty else { return }
        let written = SwiftDataWrittenMealStore(context: context)
        let mealWriter = self.mealWriter
        Task { await mealWriter.apply(batch, written: written) }
    }

    /// Retry any meals whose Health write previously failed (drained on foreground
    /// and at the start of each new turn). Fire-and-forget; gated identically.
    private func drainPendingMeals(context: ModelContext) {
        let written = SwiftDataWrittenMealStore(context: context)
        let mealWriter = self.mealWriter
        Task { await mealWriter.drainPending(written: written) }
    }

    /// Clear all transient + persisted run state for a thread, including any live
    /// stream buffer (so a finished/cancelled turn leaves no half-streamed text).
    private func clearRun(_ threadID: UUID) {
        startDates[threadID] = nil
        clearPartial(threadID)
        activity[threadID] = nil
        if inFlight[threadID] != nil {
            inFlight[threadID] = nil
            inFlightStore.save(inFlight)
        }
        // The run is now definitively idle — end the Live Activity (a no-op if none).
        syncLiveActivity(threadID)
    }

    // MARK: - Live Activity

    /// Reconcile the thread's Live Activity against its current run state. `attributes`
    /// is supplied only when a turn first goes in flight (the send / re-attach path);
    /// on update/end it's nil. The begin/update/end/idle decision is the pure
    /// `TurnLiveActivity.step`, fed the coordinator's own observable run state.
    private func syncLiveActivity(_ threadID: UUID,
                                  attributes: JesseTurnActivityAttributes? = nil) {
        liveActivity.sync(threadID: threadID,
                          isRunning: isRunning(threadID),
                          startedAt: startDate(for: threadID),
                          activityLine: activity(for: threadID),
                          attributes: attributes)
    }

    /// Attributes for a thread's Live Activity — its id, title, and short mode label.
    /// The title is the shared `displayTitle(for:)`, so the Lock Screen names a thread
    /// the same way the list and the open conversation do; it used to read `thread.title`
    /// raw with its own inline fallback and so could never show an AI title either.
    func liveActivityAttributes(for thread: JesseThread) -> JesseTurnActivityAttributes {
        JesseTurnActivityAttributes(
            threadID: thread.id,
            threadTitle: displayTitle(for: thread),
            modeLabel: thread.modeValue == .ask ? "Ask" : "Tell")
    }

}

// MARK: - Watch relay (headless turn execution)

extension RunCoordinator {
    /// The result of a headless relayed turn: the reply, or a clean error message.
    /// Deliberately a value, not a thrown error — the relay entry point never
    /// throws into its caller (the watch bridge in PR2). Internal so `WatchRelay`
    /// can map it into a `RelayOutcome`.
    enum RelayTurnResult {
        case reply(JesseReply)
        case failure(String)
    }

    /// Run ONE turn to completion headlessly and RETURN its reply, reusing the
    /// exact path a typed turn takes — `makeClient(config)` → `client.send` →
    /// `pollForOutcome` → `TurnWriter.write` — so there is no second, weaker
    /// networking or persistence path. The differences from `send` are only what a
    /// relayed turn needs: it drives NO live run-state (no spinner, no background
    /// grant, no spoken reply — a relayed turn has no on-screen thread view), and
    /// it hands the reply back to the caller instead of finishing into the UI.
    ///
    /// The caller (`WatchRelay`) owns creating and persisting the destination
    /// `thread` (tagged `.watch`) and its optimistic user `Turn`, mirroring how
    /// `send` appends the user turn before `consume` appends Jesse's. This method
    /// appends the `jesse` `Turn` via the shared `TurnWriter` on success. It never
    /// throws: every failure — a transport error, a bridge `.failed`, an expired or
    /// empty reply — becomes a `.failure(message)`.
    /// `requestId` is the relay's idempotency key (the watch utterance's id), so a queued
    /// `transferUserInfo` redelivered after the phone app restarts dedups at the bridge
    /// rather than spawning a second turn.
    ///
    /// `onAccepted` fires with the conversation id at the 202, which is the ONLY point a
    /// relayed turn has an acceptance signal: `runRelayTurn` itself does not return until the
    /// whole poll completes, minutes later. Without this seam the watch could not tell
    /// "still sending" from "the phone has it".
    func runRelayTurn(thread: JesseThread, text: String, voice: Bool,
                      requestId: UUID, context: ModelContext,
                      onAccepted: @escaping (String) -> Void = { _ in }) async -> RelayTurnResult {
        let mode = thread.modeValue
        let sessionId = thread.sessionId
        let threadID = thread.id
        // A relayed turn is a turn: it carries the destination thread's conversation id, so
        // the bridge registers it under the same thread a typed turn would.
        let conversationId = thread.conversationId ?? JesseThread.mintConversationId()
        if thread.conversationId != conversationId { thread.conversationId = conversationId }
        let client = makeClient(configProvider())
        let instructions = instructionsProvider(mode)
        let floorOverride = floorProvider(mode)
        // A relayed watch turn runs on the destination thread's model (its own selection,
        // else this device's default) exactly like a typed turn.
        let model = modelID(for: thread)

        let outcome: TurnOutcome
        do {
            let result = try await client.send(mode: mode, text: text, sessionId: sessionId,
                                               conversationId: conversationId,
                                               voice: voice, instructions: instructions,
                                               floorOverride: floorOverride, attachments: [],
                                               requestId: requestId, model: model)
            switch result {
            case .reply(let reply, _, let remoteConversationId):
                // An older bridge that answered inline. Deliver it directly.
                adoptRegistration(thread: thread, conversationId: remoteConversationId)
                onAccepted(conversationId)
                outcome = .done(reply)
            case .running(let jobId, let remoteConversationId):
                // The ACCEPTANCE moment for a relayed turn: report it back up so the watch
                // can stop showing "Thinking" and say the phone has it.
                adoptRegistration(thread: thread, conversationId: remoteConversationId)
                onAccepted(remoteConversationId ?? conversationId)
                // The normal path: poll the same authoritative completion loop a
                // typed turn uses. No display stream is opened — the relay has no
                // live view — so the poll alone owns completion here.
                guard let polled = await pollForOutcome(threadID: threadID, jobId: jobId,
                                                        client: client) else {
                    return .failure("Lost contact with the turn.")
                }
                outcome = polled
            }
        } catch let error as JesseError {
            return .failure(error.localizedDescription)
        } catch {
            return .failure(error.localizedDescription)
        }

        switch outcome {
        case .done(let reply):
            // Persist Jesse's turn through the SAME writer `finish` uses, so a
            // relayed turn lands in the normal history identically. `jobId: nil`
            // (the relay dedups at the requestId layer, not via the delivery key).
            // Write any logged meals into Apple Health. HealthKit saves succeed even
            // while the device is locked, so a watch-relayed meal logged with the
            // phone in a pocket still lands (idempotent, gated, detached).
            writeMeals(from: reply, context: context)
            let outcome = turnWriter.write(threadID: threadID, thread: thread, reply: reply,
                                           jobId: nil, context: context)
            // Same delivery point as `finish`: advance the hydration cursor past the
            // relayed reply so a later open never re-imports the phone's own record.
            if case .delivered = outcome {
                advanceCursorAfterDelivery(threadID: threadID,
                                           conversationId: thread.conversationId,
                                           context: context)
            }
            switch outcome {
            case .delivered, .alreadyDelivered:
                return .reply(reply)
            case .empty:
                return .failure("Jesse's reply came back empty.")
            case .unresolvableThread:
                return .failure("Couldn't attach the reply to the conversation.")
            }
        case .failed(let message):
            return .failure(message)
        case .expired:
            return .failure("This reply has expired.")
        case .cancelled:
            return .failure("The turn was cancelled.")
        }
    }
}
