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
    @ObservationIgnored private var backgroundIDs: [UUID: UIBackgroundTaskIdentifier] = [:]

    private let configProvider: @MainActor () -> JesseConfig
    private let makeClient: @MainActor (JesseConfig) -> any JesseClientProtocol
    // Resolves the per-mode wrapper override to send (nil = use the bridge
    // default). Injected so tests can drive it without UserDefaults state.
    private let instructionsProvider: @MainActor (JesseMode) -> String?
    // Resolves the per-mode floor override to send (nil = use the bridge's
    // built-in floor, which is always prepended and never removed). Injected so
    // tests can drive it without UserDefaults state.
    private let floorProvider: @MainActor (JesseMode) -> String?

    init(config: @escaping @MainActor () -> JesseConfig = { ConfigStore.load() },
         makeClient: @escaping @MainActor (JesseConfig) -> any JesseClientProtocol = { JesseClient(config: $0) },
         instructions: @escaping @MainActor (JesseMode) -> String? = { PromptStore.wrapperOverride(for: $0) },
         floor: @escaping @MainActor (JesseMode) -> String? = { PromptStore.floorOverride(for: $0) }) {
        self.configProvider = config
        self.makeClient = makeClient
        self.instructionsProvider = instructions
        self.floorProvider = floor
        self.inFlight = InFlightStore.load()
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
        try? context.save()

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
        // longer turns are re-attached on foreground via `resume`.
        var bgID = UIApplication.shared.beginBackgroundTask(withName: "jesse.turn") { [weak self] in
            self?.endBackground(threadID)
        }
        backgroundIDs[threadID] = bgID
        bgID = .invalid // the dict owns the real id now

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
                    self.finish(threadID: threadID, reply: reply, voice: voice, context: context)
                case .running(let jobId):
                    self.persist(threadID: threadID, job: InFlightJob(jobId: jobId, voice: voice))
                    // Stream the turn live; fall back to polling on any drop.
                    await self.consume(threadID: threadID, jobId: jobId, voice: voice,
                                       client: client, context: context)
                }
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
            // Reconnect the stream — the bridge replays the text-so-far, so a
            // foregrounded turn picks up live where it left off — with the same
            // poll fallback if streaming isn't available.
            await self.consume(threadID: threadID, jobId: job.jobId, voice: job.voice,
                               client: client, context: context)
            self.tasks[threadID] = nil
            self.endBackground(threadID)
        }
    }

    // MARK: - Internals

    /// Consume the live SSE stream for a running turn, rendering text as it
    /// arrives, then **fall back to polling** if the stream drops without a
    /// terminal frame (phone suspended, connection blipped, or an older bridge
    /// without the endpoint). Terminal frames finish the turn exactly as the poll
    /// path would: `done` appends the single persisted `Turn` and clears the
    /// partial buffer; a bridge `error` is recoverable (job retained for
    /// Re-check); a `cancelled` frame matches a cancel the user already made — no
    /// `Turn`, no error. A user Cancel cancels this task, which tears down the
    /// `AsyncThrowingStream` and drops the SSE connection.
    private func consume(threadID: UUID, jobId: String, voice: Bool,
                         client: any JesseClientProtocol, context: ModelContext) async {
        var sawTerminal = false
        do {
            for try await event in client.stream(jobId: jobId) {
                if Task.isCancelled { return }
                switch event {
                case .reset(let text):
                    partialText[threadID] = text
                case .delta(let chunk):
                    partialText[threadID, default: ""] += chunk
                case .activity(let tool):
                    activity[threadID] = Self.activityLabel(for: tool)
                case .done(let reply):
                    sawTerminal = true
                    finish(threadID: threadID, reply: reply, voice: voice, context: context)
                    return
                case .failed(let message):
                    // The bridge ran the turn and reported a failure mid-stream —
                    // keep the job retained so Re-check/poll can pick it back up.
                    sawTerminal = true
                    failRecoverable(threadID: threadID, message: message, voice: voice)
                    return
                case .cancelled:
                    // The user cancelled (the only source of this frame). cancel()
                    // already tore the run down; just make sure nothing lingers.
                    sawTerminal = true
                    clearRun(threadID)
                    return
                }
            }
        } catch {
            // Stream dropped/failed — fall through to the poll fallback below.
            if Task.isCancelled { return }
        }
        if Task.isCancelled { return }
        // The stream ended without a terminal frame: hand off to polling, which
        // owns the same finish/fail/expire logic. Clear the partial so the poll's
        // finished `Turn` is the only rendering (no stale half-reply alongside it).
        if !sawTerminal {
            partialText[threadID] = nil
            activity[threadID] = nil
            await poll(threadID: threadID, jobId: jobId, voice: voice,
                       client: client, context: context)
        }
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

    /// Poll `GET /jesse/result/{jobId}` until the turn resolves. The job_id is
    /// always retained on a non-terminal failure here (dropped socket, timeout,
    /// transport error, or a bridge-reported `.failed`) so Re-check — and the
    /// next `resume` — can pick the reply back up; the run only truly ends, and
    /// the job is dropped, on `.done` (success) or `.expired` (gone past TTL).
    private func poll(threadID: UUID, jobId: String, voice: Bool,
                      client: any JesseClientProtocol, context: ModelContext) async {
        while !Task.isCancelled {
            let state: JesseResultState
            do {
                state = try await client.result(jobId: jobId)
            } catch let error as JesseError {
                // A user-initiated cancel surfaces here as a cancelled URL load
                // (mapped to `.transport`). Treat any cancellation as a clean
                // stop — the run was already cleared by `cancel`, so don't fail.
                if Task.isCancelled { return }
                // Every client error in the poll path is recoverable: the job is
                // retained and the reply stays retrievable. Show it with Re-check.
                failRecoverable(threadID: threadID, message: error.localizedDescription, voice: voice)
                return
            } catch {
                if Task.isCancelled { return }
                failRecoverable(threadID: threadID, message: error.localizedDescription, voice: voice)
                return
            }
            // A `.done` can land in the same instant the user cancels; bail before
            // acting on it so no reply is appended for a cancelled run.
            if Task.isCancelled { return }
            switch state {
            case .running:
                try? await Task.sleep(for: .seconds(2))
            case .done(let reply):
                finish(threadID: threadID, reply: reply, voice: voice, context: context)
                return
            case .failed(let message):
                // The bridge ran the turn and reported a failure (e.g. the 504
                // run-limit). Keep the job retained so Re-check is offered — the
                // failure could have been transient.
                failRecoverable(threadID: threadID, message: message, voice: voice)
                return
            case .expired:
                // The bridge no longer has the reply (held its full TTL, now
                // evicted). This is the only genuinely terminal "gone" state:
                // drop the job and say so plainly.
                fail(threadID: threadID,
                     message: "This reply has expired — it was held but not picked up in time, and Jesse no longer has it.",
                     voice: voice)
                return
            }
        }
    }

    private func finish(threadID: UUID, reply: JesseReply, voice: Bool, context: ModelContext) {
        if let thread = fetchThread(threadID, context: context) {
            let turn = Turn(role: .jesse, text: reply.displayText)
            thread.turns.append(turn)
            thread.sessionId = reply.sessionId ?? thread.sessionId
            thread.updatedAt = Date()
            try? context.save()
        }
        if voice { Speaker.shared.speak(reply.spokenText) }
        clearRun(threadID)
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

    private func endBackground(_ threadID: UUID) {
        if let id = backgroundIDs[threadID], id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
        }
        backgroundIDs[threadID] = nil
    }

    private func fetchThread(_ id: UUID, context: ModelContext) -> JesseThread? {
        var descriptor = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
