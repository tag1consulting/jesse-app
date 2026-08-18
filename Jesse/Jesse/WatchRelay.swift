import Foundation
import SwiftData
import JesseCore

// The phone-side entry point an Apple Watch will call (in PR2) to relay a spoken
// turn through the phone. Everything here is exercisable as plain TEXT with no
// watch hardware: the seam takes a relayed turn as a value and returns a value.
//
// What it does NOT do: any WatchConnectivity, audio, or speech-to-text — that is
// PR2. This is pure phone-side plumbing. The turn runs through the SAME
// `RunCoordinator` path a typed turn uses (`runRelayTurn` → `JesseClient` →
// poll → `TurnWriter`), so there is no forked, weaker networking or persistence
// path; the only relay-specific behaviors are (1) tagging the thread `.watch`,
// (2) deduplicating by `requestId`, and (3) returning a small result value the
// watch can speak back.

/// One relayed turn, as a plain value the watch hands the phone. `requestId` keys
/// deduplication (a Watch retry re-sends the same id and must not start a second
/// turn). `voice` defaults to `true` so the reply carries a `SPOKEN:` line for the
/// watch to read aloud.
struct RelayedTurn: Equatable {
    let requestId: UUID
    let text: String
    let mode: JesseMode
    var voice: Bool = true
}

/// What the phone hands back for a delivered relayed turn — exactly what PR2 will
/// ship to the watch. `displayText` is the full answer (SPOKEN line stripped);
/// `spokenText` is the line to read aloud; `sessionId` continues the thread; and
/// `threadId` locates the conversation the turn landed in.
struct RelayResult: Equatable {
    let displayText: String
    let spokenText: String
    let sessionId: String?
    let threadId: UUID
    /// The NAMES of any files the turn returned, and nothing else about them. The watch
    /// link is low-bandwidth with a hard payload ceiling and a returned file can be 25 MB,
    /// so moving one over it would fail the whole reply rather than just the file. The
    /// watch learns a chart exists and what it is called; opening it is the phone's job.
    var artifactNames: [String] = []
}

/// The outcome of a relay call. Always a value — the entry point NEVER throws into
/// the caller. On failure the thread was still created (so the user turn isn't
/// lost) and `threadId` points at it, alongside a clean, user-safe message.
enum RelayOutcome: Equatable {
    case delivered(RelayResult)
    case failure(message: String, threadId: UUID)
}

/// A durable record of one relayed utterance's destination, so a `transferUserInfo`
/// redelivered AFTER the phone app was killed and relaunched resolves to the thread that
/// already exists instead of constructing a second one. `Codable` because it must survive
/// app death: the in-memory dedup map cannot, which is exactly how the same watch utterance
/// produced two conversations.
struct RelayedTurnRecord: Codable, Equatable {
    let requestId: UUID
    let threadID: UUID
    let conversationId: String
    let recordedAt: Date
}

/// The durable, bounded `requestId -> (threadID, conversationId)` map behind the relay's
/// dedup. `UserDefaults`-backed (a small JSON array, so no SwiftData migration), FIFO-capped,
/// with the suite injected for tests.
struct RelayedTurnStore {
    private let defaults: UserDefaults
    private let key = "watchRelayedTurns"
    /// The window only needs to cover a redelivery burst plus a relaunch, not all history.
    static let cap = 128

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var all: [RelayedTurnRecord] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([RelayedTurnRecord].self, from: data)
        else { return [] }
        return items
    }

    func record(_ requestId: UUID) -> RelayedTurnRecord? {
        all.first { $0.requestId == requestId }
    }

    /// Remember where a relayed utterance landed, evicting the oldest past the cap.
    /// Idempotent: re-recording the same request id keeps the original entry.
    func remember(_ record: RelayedTurnRecord) {
        var items = all
        guard !items.contains(where: { $0.requestId == record.requestId }) else { return }
        items.append(record)
        if items.count > Self.cap { items.removeFirst(items.count - Self.cap) }
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }
}

/// The relay entry point. Owns deduplication by `requestId` and shaping the
/// `RelayResult`; delegates the actual turn to `RunCoordinator.runRelayTurn` so
/// networking and persistence stay on the one shared path.
@MainActor
final class WatchRelay {
    private let coordinator: RunCoordinator
    /// How the thread + optimistic user turn are persisted. Defaults to a real
    /// `context.save()`; injectable so a test can force a save failure, matching
    /// the coordinator's `save` seam.
    private let save: @MainActor (ModelContext) throws -> Void
    /// The DURABLE half of the dedup: where each relayed utterance landed, surviving app
    /// death. The in-memory maps below only cover the concurrent case.
    private let relayedStore: RelayedTurnStore

    /// requestId → the in-flight relay task. A duplicate call with a live id awaits
    /// this same task and returns its result, so exactly one turn ever runs.
    private var inFlight: [UUID: Task<RelayOutcome, Never>] = [:]
    /// A small recently-completed cache so a duplicate that arrives AFTER the first
    /// finished still returns the same outcome instead of re-running. Bounded by
    /// `completedCap` (FIFO eviction) — the dedup window only needs to cover a
    /// watch's retry burst, not all history.
    private var completed: [UUID: RelayOutcome] = [:]
    private var completedOrder: [UUID] = []
    private let completedCap = 32

    init(coordinator: RunCoordinator,
         save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() },
         relayedStore: RelayedTurnStore = RelayedTurnStore()) {
        self.coordinator = coordinator
        self.save = save
        self.relayedStore = relayedStore
    }

    /// Relay one turn and return its outcome. Deduplicated by `requestId`: a second
    /// call with the same id NEVER starts a second turn — it awaits the in-flight
    /// one (or returns the cached result if it already finished) and hands back the
    /// same outcome. Runs the turn through the existing `RunCoordinator` path and
    /// tags the created thread `.watch`. Never throws.
    func relay(_ turn: RelayedTurn, context: ModelContext,
               onAccepted: @escaping (String) -> Void = { _ in }) async -> RelayOutcome {
        // Already finished once — return the same outcome, no second turn.
        if let cached = completed[turn.requestId] {
            return cached
        }
        // Already running — await that one task's result. Because this actor is
        // serialized, the first call installs `inFlight[requestId]` before any
        // second call can observe it, so the second never spawns its own turn.
        if let existing = inFlight[turn.requestId] {
            return await existing.value
        }
        // The DURABLE case, and the one the in-memory maps above cannot cover: a
        // `transferUserInfo` redelivered after the phone app was killed and relaunched. Both
        // maps are empty then, so without this the relay constructs a SECOND thread for the
        // same utterance. The persisted record resolves it to the thread that already exists.
        if let known = relayedStore.record(turn.requestId) {
            if let existing = thread(known.threadID, in: context) {
                Log.run.notice("watch relay: request \(turn.requestId) already landed in thread \(known.threadID), not relaying again")
                onAccepted(known.conversationId)
                let last = existing.orderedTurns.last { !$0.isUser }
                return .delivered(RelayResult(displayText: last?.text ?? "",
                                              spokenText: last?.text ?? "",
                                              sessionId: existing.sessionId,
                                              threadId: existing.id,
                                              artifactNames: (last?.orderedArtifacts ?? [])
                                                  .map(\.filename)))
            }
            // The record survived but its thread did not (the user deleted it). Nothing to
            // resurrect and nothing to duplicate: report it rather than starting a new turn.
            Log.run.notice("watch relay: request \(turn.requestId) landed in a thread that has since been deleted")
            return .failure(message: "That conversation was deleted.", threadId: known.threadID)
        }

        let task = Task { await self.execute(turn, context: context, onAccepted: onAccepted) }
        inFlight[turn.requestId] = task
        let outcome = await task.value
        inFlight[turn.requestId] = nil
        remember(turn.requestId, outcome)
        return outcome
    }

    /// Fetch one thread by its local id, for the durable-dedup resolution above.
    private func thread(_ threadID: UUID, in context: ModelContext) -> JesseThread? {
        var d = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == threadID })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Create + persist the `.watch` thread with its optimistic user turn (exactly
    /// as a typed turn would, origin aside), run the turn, and shape the result.
    private func execute(_ turn: RelayedTurn, context: ModelContext,
                         onAccepted: @escaping (String) -> Void) async -> RelayOutcome {
        let thread = JesseThread(mode: turn.mode)
        thread.origin = ThreadOrigin.watch.rawValue
        context.insert(thread)

        let userTurn = Turn(role: .user, text: turn.text)
        thread.turns.append(userTurn)
        thread.title = JesseThread.deriveTitle(from: turn.text)
        thread.updatedAt = Date()
        do {
            try save(context)
        } catch {
            Log.run.error("watch relay: optimistic user-turn save failed for thread \(thread.id): \(error.localizedDescription)")
            return .failure(message: "Couldn't save the relayed message.", threadId: thread.id)
        }

        // Remember WHERE this utterance landed before the turn runs, so a redelivery arriving
        // after an app kill mid-turn still resolves here rather than starting a second one.
        relayedStore.remember(RelayedTurnRecord(
            requestId: turn.requestId, threadID: thread.id,
            conversationId: thread.conversationId ?? "", recordedAt: Date()))

        // The utterance's own id IS the bridge `request_id`, so a relayed turn engages the
        // bridge's idempotency exactly like a typed one. It used to send nothing there,
        // which disabled that dedup for precisely the traffic most likely to be redelivered.
        switch await coordinator.runRelayTurn(thread: thread, text: turn.text,
                                              voice: turn.voice, requestId: turn.requestId,
                                              context: context, onAccepted: onAccepted) {
        case .reply(let reply):
            return .delivered(RelayResult(displayText: reply.displayText,
                                          spokenText: reply.spokenText,
                                          sessionId: thread.sessionId,
                                          threadId: thread.id,
                                          artifactNames: reply.artifacts.map(\.filename)))
        case .failure(let message):
            return .failure(message: message, threadId: thread.id)
        }
    }

    /// Record a finished outcome in the bounded recently-completed cache.
    private func remember(_ requestId: UUID, _ outcome: RelayOutcome) {
        if completed[requestId] == nil {
            completedOrder.append(requestId)
            if completedOrder.count > completedCap {
                let evicted = completedOrder.removeFirst()
                completed[evicted] = nil
            }
        }
        completed[requestId] = outcome
    }
}
