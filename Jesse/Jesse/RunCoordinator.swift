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

/// Persists `inFlight` across suspension. Small and keyed by thread id, in
/// UserDefaults — the bits needed to present a reply that landed while we were away.
enum InFlightStore {
    private static let key = "jesse.inflight.v1"

    static func load() -> [UUID: InFlightJob] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: InFlightJob].self, from: data)
        else { return [:] }
        var out: [UUID: InFlightJob] = [:]
        for (k, v) in raw {
            if let id = UUID(uuidString: k) { out[id] = v }
        }
        return out
    }

    static func save(_ map: [UUID: InFlightJob]) {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: key)
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
    // threadID → the granted background-task handle. A box (not a raw id) so the
    // expiration handler can end the exact id it was granted even if it fires
    // before the store below — see `BackgroundTasking`.
    @ObservationIgnored private var backgroundIDs: [UUID: BackgroundTaskHandle] = [:]

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
    // Background-task seam. Defaults to the real `UIApplication`-backed tasker;
    // injected so a test can drive the expiration-before-store race.
    private let backgroundTasker: BackgroundTasking
    // How the poll loop waits between polls. Defaults to a real `Task.sleep`;
    // injected so a test can drive the backoff sequence deterministically without
    // real waiting.
    private let pollSleep: @MainActor (TimeInterval) async -> Void

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
         onFirstSuccess: @escaping @MainActor () -> Void = {}) {
        self.configProvider = config
        self.makeClient = makeClient
        self.instructionsProvider = instructions
        self.floorProvider = floor
        self.speak = speak
        self.save = save
        self.backgroundTasker = backgroundTasker
        self.pollSleep = pollSleep
        self.onFirstSuccess = onFirstSuccess
        self.inFlight = InFlightStore.load()
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
            InFlightStore.save(inFlight)
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
        // longer turns are re-attached on foreground via `resume`. The expiration
        // handler ends the id via the captured `handle`, so even if it fires before
        // the dict store below, the granted assertion is always released (M7).
        let handle = BackgroundTaskHandle()
        backgroundTasker.beginTask(name: "jesse.turn", handle: handle) { [weak self] in
            self?.endBackground(threadID, handle: handle)
        }
        backgroundIDs[threadID] = handle

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
            self.endBackground(threadID)
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
            self.endBackground(threadID)
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
        guard let outcome else { return }
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
    /// "shows empty" and "stays silent." The ways the old `finish` could silently
    /// lose a reply are each now a visible, recoverable state:
    ///   1. the thread can't be resolved (the by-id re-fetch returns nil),
    ///   2. the reply is *genuinely* empty (both screen and spoken text empty),
    ///   3. `context.save()` throws.
    /// A reply whose content lives only in the `SPOKEN:` line (empty `displayText`,
    /// non-empty `spokenText`) is a real reply — recorded as a turn and spoken —
    /// not a silent drop.
    ///
    /// Delivery is idempotent on `jobId`: a re-entry of `finish` for a job whose
    /// reply this thread already received (Re-check / resume re-polling a completed
    /// job after a save failure retained `inFlight`) does NOT append a second turn —
    /// it only retries the persist and clears the run. See `lastDeliveredJobId`.
    ///
    /// `thread` is the live reference the send path holds — preferred so the common
    /// case never re-fetches. It's `nil` only on the resume/recheck path (after a
    /// relaunch), where we fall back to a by-id fetch. `jobId` is the bridge job
    /// whose reply this is (`nil` only on the dead inline `.reply` path, which has
    /// no id to key on).
    // Private so callers can't bypass `send()` (which owns the optimistic turn,
    // persistence, and the stream/poll race). `consume` and the dead inline
    // `.reply` path are the only callers, both inside this type.
    private func finish(threadID: UUID, thread: JesseThread?, reply: JesseReply,
                        voice: Bool, jobId: String?, context: ModelContext) {
        // (1) Resolve the destination. Prefer the held reference; fall back to a
        // by-id fetch only when there isn't one (resume/recheck). If neither
        // resolves, keep the job retained and surface Re-check — do NOT drop it.
        guard let target = thread ?? fetchThread(threadID, context: context) else {
            Log.run.error("finish: reply for thread \(threadID) has no resolvable thread " +
                  "(re-fetch returned nil) — retaining job_id for Re-check, not dropping the reply")
            failRecoverable(threadID: threadID,
                            message: "Got the reply but couldn't attach it to this thread — tap Re-check.",
                            voice: voice)
            return
        }

        // (2) Idempotency: this exact job's reply was already delivered into this
        // thread (a Re-check / resume re-ran `finish` for a completed job whose
        // save had failed). Do NOT append again — just finish the bookkeeping:
        // retry the persist (so a previously-failed save can now succeed), clear
        // the error, and clear the run. A still-failing retry leaves the recoverable
        // error + retained job intact, still without a duplicate.
        if let jobId, target.lastDeliveredJobId == jobId {
            Log.run.notice("finish: job \(jobId) already delivered to thread \(threadID) — " +
                  "retrying the save only, not re-appending")
            do {
                try save(context)
            } catch {
                Log.run.error("finish: retry save() failed for thread \(threadID): \(error.localizedDescription) — " +
                      "still retaining job_id for Re-check")
                errors[threadID] = "Showed the reply, but couldn't save it — tap Re-check."
                startDates[threadID] = nil
                partialText[threadID] = nil
                activity[threadID] = nil
                return
            }
            errors[threadID] = nil
            clearRun(threadID)
            return
        }

        // (3) Decide what to record. Prefer the screen text; when it's empty, fall
        // back to the spoken line — a spoken-only reply's content lives there and
        // must not be lost. Only when BOTH are empty is the reply genuinely empty,
        // and we surface Re-check instead of appending a blank turn.
        let displayText = reply.displayText
        let recordedText: String
        if !displayText.isEmpty {
            recordedText = displayText
        } else if !reply.spokenText.isEmpty {
            recordedText = reply.spokenText
        } else {
            Log.run.error("finish: genuinely empty reply for thread \(threadID) " +
                  "(no screen text, no spoken text) — surfacing Re-check rather than a blank turn")
            failRecoverable(threadID: threadID,
                            message: "Jesse's reply came back empty — tap Re-check to fetch it again.",
                            voice: voice)
            return
        }

        let turn = Turn(role: .jesse, text: recordedText)
        target.turns.append(turn)
        target.sessionId = reply.sessionId ?? target.sessionId
        target.updatedAt = Date()
        if let jobId { target.lastDeliveredJobId = jobId }

        // (4) Real error handling, not `try?`. The in-memory append above already
        // shows the reply; on a save failure, log it and surface a recoverable
        // error (keeping the job for Re-check) so the failure isn't swallowed. The
        // in-memory turn + idempotency key persist on the live object, so a
        // same-session Re-check sees the key match (step 2) and retries the save
        // without re-appending.
        do {
            try save(context)
        } catch {
            Log.run.error("finish: context.save() failed for thread \(threadID): \(error.localizedDescription) — " +
                  "reply is shown but unsaved; retaining job_id for Re-check")
            errors[threadID] = "Showed the reply, but couldn't save it — tap Re-check."
            startDates[threadID] = nil
            partialText[threadID] = nil
            activity[threadID] = nil
            if voice { speak(reply.spokenText) }
            return
        }

        if voice { speak(reply.spokenText) }
        // A turn just landed successfully — the moment to ask for push permission
        // (idempotent; PushManager only prompts once and only when configured).
        onFirstSuccess()
        clearRun(threadID)
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
        InFlightStore.save(inFlight)
    }

    /// Clear all transient + persisted run state for a thread, including any live
    /// stream buffer (so a finished/cancelled turn leaves no half-streamed text).
    private func clearRun(_ threadID: UUID) {
        startDates[threadID] = nil
        partialText[threadID] = nil
        activity[threadID] = nil
        if inFlight[threadID] != nil {
            inFlight[threadID] = nil
            InFlightStore.save(inFlight)
        }
    }

    /// End a thread's background grant. The expiration handler passes the captured
    /// `handle` directly, so the granted id is ended even if expiration fires before
    /// `send` stored the handle in `backgroundIDs` (M7). Other callers (the task
    /// tails) pass no handle and fall back to the stored one. Ending sets the id to
    /// `.invalid`, so a later call for the same thread is a harmless no-op — the
    /// grant is released exactly once.
    private func endBackground(_ threadID: UUID, handle: BackgroundTaskHandle? = nil) {
        if let h = handle ?? backgroundIDs[threadID], h.id != .invalid {
            backgroundTasker.endTask(h.id)
            h.id = .invalid
        }
        backgroundIDs[threadID] = nil
    }

    private func fetchThread(_ id: UUID, context: ModelContext) -> JesseThread? {
        var descriptor = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
