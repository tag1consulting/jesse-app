import Foundation
import SwiftData
import SwiftUI
import UIKit

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
    // Persists the in-flight job map across suspension. Injectable so a test can
    // avoid the shared UserDefaults store.
    private let inFlightStore: InFlightStoring
    // Owns `finish`'s SwiftData append + save + idempotency-on-jobId. Shares the
    // injected `save` seam so a test's save spy counts both the optimistic
    // user-turn save and the completion save.
    private let turnWriter: TurnWriter

    // threadID → a counter bumped on each stream reset/delta. The poll loop watches
    // it to snap its backoff back to the fast cadence while the stream is actively
    // delivering tokens. Not observed by views.
    @ObservationIgnored private var streamTicks: [UUID: Int] = [:]
    // Called after a turn is delivered successfully — the "sensible moment" to ask
    // for push-notification authorization (not on cold launch). `JesseApp` wires
    // this to `PushManager`; the default is a no-op so tests never touch
    // UNUserNotificationCenter.
    private let onFirstSuccess: @MainActor () -> Void

    init(config: @escaping @MainActor () -> JesseConfig = { ConfigStore.load() },
         makeClient: @escaping @MainActor (JesseConfig) -> any JesseClientProtocol = { JesseClient(config: $0) },
         instructions: @escaping @MainActor (JesseMode) -> String? = { PromptStore.wrapperOverride(for: $0) },
         floor: @escaping @MainActor (JesseMode) -> String? = { PromptStore.floorOverride(for: $0) },
         speak: @escaping @MainActor (String) -> Void = { Speaker.shared.speak($0) },
         save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() },
         backgroundTasker: BackgroundTasking = UIKitBackgroundTasking(),
         pollSleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         inFlightStore: InFlightStoring? = nil,
         onFirstSuccess: @escaping @MainActor () -> Void = {}) {
        // Resolve the default on the main actor (in the init body), not in the
        // default argument — a default arg is evaluated off the actor and the
        // store's init is main-actor-isolated under MainActor-default isolation.
        let resolvedInFlightStore = inFlightStore ?? InFlightStore()
        self.configProvider = config
        self.makeClient = makeClient
        self.instructionsProvider = instructions
        self.floorProvider = floor
        self.speak = speak
        self.save = save
        self.turnWriter = TurnWriter(save: save)
        self.backgroundGuard = BackgroundTaskGuard(tasker: backgroundTasker)
        self.pollSleep = pollSleep
        self.inFlightStore = resolvedInFlightStore
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

    /// The next poll interval after `current`: grow by the backoff factor, capped at
    /// the ceiling. Pure, for direct testing. From `pollInterval`: 2 → 10 → 30 → 30…
    nonisolated static func nextPollInterval(after current: TimeInterval) -> TimeInterval {
        min(current * pollBackoffFactor, pollIntervalCeiling)
    }

    /// Bump the stream-activity counter for a thread — called by the display stream
    /// on each reset/delta so the poll loop can reset its backoff. Internal so a
    /// test can simulate stream activity deterministically.
    func noteStreamActivity(_ threadID: UUID) {
        streamTicks[threadID, default: 0] += 1
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
    func error(for threadID: UUID) -> String? { errors[threadID] }
    func clearError(for threadID: UUID) { errors[threadID] = nil }

    /// The reply text streamed so far for a running turn (nil/empty when nothing
    /// has arrived yet). Rendered live in the transcript while `isRunning`.
    func partialText(for threadID: UUID) -> String? { partialText[threadID] }
    /// The current coarse activity line (e.g. "Reading the vault…"), if any.
    func activity(for threadID: UUID) -> String? { activity[threadID] }

    // MARK: - Send

    /// Start a turn on `thread`. Appends the user message optimistically, then
    /// runs the bridge call on a per-thread task that survives navigation.
    func send(thread: JesseThread, text: String, voice: Bool, context: ModelContext,
              attachments: [JesseAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning(thread.id) else { return }
        let threadID = thread.id
        errors[threadID] = nil
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

        // Optimistic user turn — appears in the transcript immediately. The
        // persisted/displayed text notes any attachments (the bridge keeps the
        // files only for the turn), while the *sent* text stays just `trimmed`.
        var displayText = trimmed
        if !attachments.isEmpty {
            let names = attachments.map(\.filename).joined(separator: ", ")
            displayText += "\n\n📎 Attached: \(names)"
        }
        let userTurn = Turn(role: .user, text: displayText)
        thread.turns.append(userTurn)
        if thread.title.isEmpty {
            thread.title = JesseThread.deriveTitle(from: trimmed)
        }
        thread.updatedAt = Date()
        // Real error handling, not `try?`. If this throws the user message is shown
        // but not persisted, and proceeding would attach the reply to a thread that
        // may never persist. Surface a recoverable failure (the same shape `finish`
        // uses) and abort the turn before any bridge call, rather than swallowing it.
        do {
            try save(context)
        } catch {
            Log.run.error("optimistic user-turn save failed for thread \(threadID): \(error.localizedDescription) — aborting the turn")
            errors[threadID] = "Couldn't save your message — try sending it again."
            return
        }

        let mode = thread.modeValue
        let sessionId = thread.sessionId
        let cfg = configProvider()
        // Resolve the wrapper and floor overrides on the main actor before
        // detaching the turn; nil when this mode isn't customized (the bridge uses
        // its default wrapper / its built-in floor).
        let instructions = instructionsProvider(mode)
        let floorOverride = floorProvider(mode)
        startDates[threadID] = Date()

        // A background grant lets a short turn finish after the app is backgrounded;
        // longer turns are re-attached on foreground via `resume`. The guard owns
        // the begin/end bookkeeping and the expiration-before-store race (M7).
        backgroundGuard.begin(threadID, name: "jesse.turn")

        tasks[threadID] = Task { [weak self] in
            guard let self else { return }
            let client = self.makeClient(cfg)
            do {
                let result = try await client.send(mode: mode, text: trimmed,
                                                   sessionId: sessionId, voice: voice,
                                                   instructions: instructions,
                                                   floorOverride: floorOverride,
                                                   attachments: attachments)
                switch result {
                case .reply(let reply, _):
                    // Inline reply. The fixed bridge always returns `.running`
                    // (it hands back the job_id immediately and never holds the
                    // connection), so this path is effectively dead — kept only so
                    // an older bridge that still answers inline doesn't break.
                    // Deliver against the live `thread` reference (the send path
                    // holds it), so there's no fetch-by-id that could miss.
                    self.finish(threadID: threadID, thread: thread, reply: reply,
                                voice: voice, jobId: nil, context: context)
                case .running(let jobId):
                    // The normal path. `persist` runs FIRST, synchronously, so
                    // `inFlight` is on disk the instant the job_id arrives — before
                    // `consume` opens a single socket. Any later drop (stream or
                    // poll, app suspended) is therefore recoverable via Re-check /
                    // `resume`, because the id was captured up front. This is the
                    // app half of the orphan fix: the bridge delivers the id early,
                    // and we persist it before doing anything that can fail.
                    self.persist(threadID: threadID, job: InFlightJob(jobId: jobId, voice: voice))
                    // Stream (display) and poll (completion) run concurrently; see
                    // `consume`. Polling is not a fallback — it owns the reply.
                    // Pass the live `thread` reference so completion appends to it
                    // directly — no fetch-by-id that could resolve to nil and drop
                    // the reply (the silent-stop bug this guards against).
                    await self.consume(threadID: threadID, thread: thread, jobId: jobId,
                                       voice: voice, client: client, context: context)
                }
                // Belt-and-suspenders: if `client.send` itself throws (a flaky
                // connection drops the POST before its response lands), the bridge
                // may have created the turn with a job_id the phone never saw —
                // that one turn is unrecoverable without an id. With the immediate
                // job_id this window is just the single request/response round-trip
                // (it used to be the whole multi-second grace hold), which is the
                // point of the fix. See `handle(error:)` for the connection-lost
                // case where a job_id *was* already retained.
            } catch is CancellationError {
                self.clearRun(threadID)
            } catch let error as JesseError {
                self.handle(error: error, threadID: threadID, voice: voice)
            } catch {
                self.fail(threadID: threadID, message: error.localizedDescription, voice: voice)
            }
            self.tasks[threadID] = nil
            self.backgroundGuard.end(threadID)
        }
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

    // MARK: - Resume (foreground re-attach)

    /// Called when the app returns to the foreground. For every persisted job
    /// with no live task, start polling its result and reconcile. A retained job
    /// from a recoverable failure is re-attached too — clearing its stale error
    /// as the poll restarts — so foregrounding auto-recovers what Re-check does
    /// by hand.
    func resume(context: ModelContext) {
        for (threadID, job) in inFlight where tasks[threadID] == nil {
            reattach(threadID: threadID, job: job, context: context)
        }
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
                         client: any JesseClientProtocol, context: ModelContext) async {
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
            finish(threadID: threadID, thread: thread, reply: reply, voice: voice,
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
                    partialText[threadID] = text
                    noteStreamActivity(threadID)
                case .delta(let chunk):
                    partialText[threadID, default: ""] += chunk
                    noteStreamActivity(threadID)
                case .activity(let tool):
                    activity[threadID] = Self.activityLabel(for: tool)
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
        return nil
    }

    /// Map a coarse tool name from a `tool_use` event to a human activity line.
    private static func activityLabel(for tool: String) -> String {
        switch tool {
        case "Read", "Glob", "Grep": return "Reading the vault…"
        case "Write", "Edit", "NotebookEdit": return "Writing a file…"
        case "Bash": return "Running a command…"
        case "WebFetch", "WebSearch": return "Searching the web…"
        case "Task": return "Working on it…"
        default: return "Using \(tool)…"
        }
    }

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
                // — the run was already cleared by `cancel`. Otherwise every client
                // error in the poll path is recoverable: the job stays retained and
                // the reply retrievable, shown with Re-check.
                if Task.isCancelled { return nil }
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
                await pollSleep(interval)
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
        switch turnWriter.write(threadID: threadID, thread: thread, reply: reply,
                                jobId: jobId, context: context) {
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
        partialText[threadID] = nil
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

    /// The thread whose in-flight job has this id — used to route a notification
    /// tap to the right conversation. nil if no in-flight job matches.
    func threadID(forJobId jobId: String) -> UUID? {
        inFlight.first(where: { $0.value.jobId == jobId })?.key
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
        partialText[threadID] = nil
        activity[threadID] = nil
        if voice { Speaker.shared.speak("Sorry, that didn't work yet. " + message) }
    }

    /// A `.connectionLost` with a job in flight is recoverable — keep the job and
    /// stop quietly so `resume` re-attaches. Without a job id there's nothing to
    /// re-attach to, so surface it.
    private func handle(error: JesseError, threadID: UUID, voice: Bool) {
        if case .connectionLost = error, inFlight[threadID] != nil { return }
        fail(threadID: threadID, message: error.localizedDescription, voice: voice)
    }

    private func persist(threadID: UUID, job: InFlightJob) {
        inFlight[threadID] = job
        inFlightStore.save(inFlight)
    }

    /// Clear all transient + persisted run state for a thread, including any live
    /// stream buffer (so a finished/cancelled turn leaves no half-streamed text).
    private func clearRun(_ threadID: UUID) {
        startDates[threadID] = nil
        partialText[threadID] = nil
        activity[threadID] = nil
        if inFlight[threadID] != nil {
            inFlight[threadID] = nil
            inFlightStore.save(inFlight)
        }
    }

}
