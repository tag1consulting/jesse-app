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

    /// A run is in flight if a task owns it OR a job is persisted for re-attach.
    func isRunning(_ threadID: UUID) -> Bool {
        tasks[threadID] != nil || inFlight[threadID] != nil
    }

    func startDate(for threadID: UUID) -> Date? { startDates[threadID] }
    func error(for threadID: UUID) -> String? { errors[threadID] }
    func clearError(for threadID: UUID) { errors[threadID] = nil }

    // MARK: - Send

    /// Start a turn on `thread`. Appends the user message optimistically, then
    /// runs the bridge call on a per-thread task that survives navigation.
    func send(thread: JesseThread, text: String, voice: Bool, context: ModelContext,
              attachments: [JesseAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning(thread.id) else { return }
        let threadID = thread.id
        errors[threadID] = nil

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
                    await self.poll(threadID: threadID, jobId: jobId, voice: voice,
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
    /// the instant the user taps Cancel: `inFlight` is dropped (the bridge has no
    /// cancel endpoint, so the turn keeps running server-side, but the user asked
    /// to stop, so its eventual result is discarded rather than re-attached) and
    /// `startDates` is cleared. Dropping the task handle here — together with the
    /// poll loop's cancelled-exit — means `isRunning` reports `false` immediately;
    /// the task's own tail still runs to release the background grant.
    func cancel(_ threadID: UUID) {
        tasks[threadID]?.cancel()
        tasks[threadID] = nil
        clearRun(threadID)
    }

    // MARK: - Resume (foreground re-attach)

    /// Called when the app returns to the foreground. For every persisted job
    /// with no live task, start polling its result and reconcile.
    func resume(context: ModelContext) {
        for (threadID, job) in inFlight where tasks[threadID] == nil {
            if startDates[threadID] == nil { startDates[threadID] = Date() }
            let cfg = configProvider()
            tasks[threadID] = Task { [weak self] in
                guard let self else { return }
                let client = self.makeClient(cfg)
                await self.poll(threadID: threadID, jobId: job.jobId, voice: job.voice,
                                client: client, context: context)
                self.tasks[threadID] = nil
                self.endBackground(threadID)
            }
        }
    }

    // MARK: - Internals

    /// Poll `GET /jesse/result/{jobId}` until the turn resolves. A dropped socket
    /// (`.connectionLost`) leaves the job persisted and stops quietly — the next
    /// `resume` picks it back up.
    private func poll(threadID: UUID, jobId: String, voice: Bool,
                      client: any JesseClientProtocol, context: ModelContext) async {
        while !Task.isCancelled {
            let state: JesseResultState
            do {
                state = try await client.result(jobId: jobId)
            } catch let error as JesseError {
                // A user-initiated cancel surfaces here as a cancelled URL load
                // (mapped to `.transport`). Treat any cancellation as a clean
                // stop — the run was already cleared by `cancel`, so don't `fail`.
                if Task.isCancelled { return }
                if case .connectionLost = error { return } // keep job; retry on resume
                fail(threadID: threadID, message: error.localizedDescription, voice: voice)
                return
            } catch {
                if Task.isCancelled { return }
                fail(threadID: threadID, message: error.localizedDescription, voice: voice)
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
                fail(threadID: threadID, message: message, voice: voice)
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

    private func fail(threadID: UUID, message: String, voice: Bool) {
        errors[threadID] = message
        if voice { Speaker.shared.speak("Sorry, that didn't work. " + message) }
        clearRun(threadID)
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

    /// Clear all transient + persisted run state for a thread.
    private func clearRun(_ threadID: UUID) {
        startDates[threadID] = nil
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
