import Foundation
import SwiftData
import Observation
import JesseCore
import JesseNetworking

// The Mac client's local store + sync + turn runner. Cache-first (locked 2026-07-13):
// the UI always renders from this local SwiftData store; the bridge is the sync
// source, not the render source. Offline is read-only — threads, transcripts, and
// titles come from cache; a new turn needs the server (the brain is on the Studio).
//
// The store reuses the shared `JesseThread`/`Turn` models (JesseCore) so the schema
// matches the phone's, minus the iOS-only outbox/meal entities the Mac never writes.

// MARK: - Container

enum MacModelContainer {
    /// The Mac schema: the conversation models only (no send-outbox / meal-mirror
    /// entities — those are iOS concerns). A fresh store on the laptop, independent of
    /// the phone's; the bridge is what the two share, not a store file.
    static var schema: Schema {
        Schema([JesseThread.self, Turn.self, TurnAttachment.self])
    }

    /// Open the on-disk store, falling back to a flagged in-memory store if it can't be
    /// opened (so the app runs this session without clobbering the on-disk file).
    static func open() -> (container: ModelContainer, openFailure: Error?) {
        let onDisk = ModelConfiguration(schema: schema)
        do {
            return (try ModelContainer(for: schema, configurations: onDisk), nil)
        } catch {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            if let fallback = try? ModelContainer(for: schema, configurations: memory) {
                return (fallback, error)
            }
            fatalError("could not create any SwiftData container: \(error)")
        }
    }
}

// MARK: - Hydration cursors

/// Per-session byte offset into the append-only transcript jsonl, so a hydrate fetches
/// only the delta appended since (`?after=`). Kept in UserDefaults (small ints keyed by
/// session id) rather than the shared schema, so tracking Mac-side sync state adds no
/// column to the phone's model.
enum MacCursorStore {
    private static func key(_ sessionId: String) -> String { "hydrate.cursor.\(sessionId)" }

    static func offset(_ sessionId: String, defaults: UserDefaults = .standard) -> UInt64 {
        UInt64(max(0, defaults.integer(forKey: key(sessionId))))
    }
    static func setOffset(_ sessionId: String, _ value: UInt64, defaults: UserDefaults = .standard) {
        defaults.set(Int(value), forKey: key(sessionId))
    }
    /// Forget a session's cursor, called when its local thread is deleted (locally or via
    /// a cross-device tombstone) so a re-adopted id later hydrates from scratch.
    static func clear(_ sessionId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(sessionId))
    }
}

// MARK: - Coordinator

/// App-scoped runner + sync. `@MainActor` (the UI binds to it and it mutates the
/// main-actor `ModelContext`); network calls hop off-main inside the `nonisolated`
/// client. One turn runs at a time on the Mac MVP — which also matches the bridge's
/// single global write lock.
@MainActor
@Observable
final class MacCoordinator {
    let configStore: MacConfigStore

    /// The thread whose turn is currently running, if any.
    private(set) var activeThreadID: UUID?
    /// Live assistant text for the active turn (reset REPLACES, delta APPENDS).
    private(set) var streamingText: String = ""
    /// Coarse current tool activity ("Read", "Write", …) for the active turn.
    private(set) var activity: String = ""
    private(set) var isRunning = false
    /// Last user-facing error (send/stream failure, sync failure). Cleared on the next
    /// successful action.
    var lastError: String?

    /// Fires when a turn completes, so the app can post a local notification.
    var onTurnFinished: (@MainActor (JesseThread, _ reply: String) -> Void)?

    private var sessionsETag: String? {
        get { UserDefaults.standard.string(forKey: "sessions.etag") }
        set { UserDefaults.standard.set(newValue, forKey: "sessions.etag") }
    }

    /// Builds the bridge client every network path uses (send, streaming, hydrate, the
    /// session list, `setFlags`, and remote deletes). Injected as one seam so a test drives
    /// the WHOLE coordinator (turn running and hydration included, not just flag sync)
    /// with a fake `BridgeClientProtocol`; production builds the real shared client from the
    /// current config. Unifying the send/hydrate path onto this factory (it used to build a
    /// concrete `JesseBridgeClient` inline, untestable) is what lets the hydration-on-open
    /// tests exist at all.
    private let makeClient: @MainActor (JesseConfig) -> any BridgeClientProtocol

    /// Durable queue of remote sessions to delete (thread-delete → `DELETE /jesse/session/{id}`),
    /// the Mac mirror of the phone's store (shared type in JesseNetworking). Persisted so a
    /// delete made while the Studio is asleep survives to the next drain, and its ids feed
    /// the session reconciler's resurrection guard. Injectable so a test uses a scratch suite.
    private let sessionDeletionStore: PendingSessionDeletionStore

    init(configStore: MacConfigStore,
         makeClient: @escaping @MainActor (JesseConfig) -> any BridgeClientProtocol
            = { JesseBridgeClient(config: $0) },
         sessionDeletionStore: PendingSessionDeletionStore = PendingSessionDeletionStore()) {
        self.configStore = configStore
        self.makeClient = makeClient
        self.sessionDeletionStore = sessionDeletionStore
    }

    private var client: any BridgeClientProtocol { makeClient(configStore.config) }

    func isRunning(_ threadID: UUID) -> Bool { isRunning && activeThreadID == threadID }

    // MARK: Sending a turn

    /// Send `text` in `thread`, streaming the reply. Creates an optimistic user turn
    /// immediately (cache-first), then appends the assistant turn when the run finishes.
    func send(text: String, mode: JesseMode, thread: JesseThread, context: ModelContext) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning, configStore.isConfigured else { return }

        let userTurn = Turn(role: .user, text: trimmed)
        userTurn.thread = thread
        context.insert(userTurn)
        thread.updatedAt = Date()
        try? context.save()

        activeThreadID = thread.id
        isRunning = true
        streamingText = ""
        activity = ""
        lastError = nil
        defer {
            isRunning = false
            activeThreadID = nil
            streamingText = ""
            activity = ""
        }

        let cli = client
        // The PER-TURN model this conversation sends on: its own stored selection, else this
        // device's default (`LastUsedModelStore`). Local to this Mac and this thread — it never
        // mutates the bridge's global default, so the phone is unaffected. nil → bridge default.
        let model = thread.selectedModelID ?? LastUsedModelStore.id
        do {
            let result = try await cli.send(
                mode: mode, text: trimmed, sessionId: thread.sessionId,
                voice: false, instructions: nil, floorOverride: nil,
                attachments: [], requestId: UUID().uuidString, model: model)
            switch result {
            case let .reply(reply, _):
                await finalize(thread: thread, reply: reply, streamedText: nil,
                               context: context, client: cli)
            case let .running(jobId):
                await runStream(jobId: jobId, thread: thread, context: context, client: cli)
            }
        } catch {
            lastError = Self.friendly(error)
        }
    }

    private func runStream(jobId: String, thread: JesseThread, context: ModelContext,
                           client cli: any BridgeClientProtocol) async {
        // The full terminal reply (text + session + structured provenance), so the model
        // badge chip survives the stream path exactly as it does on the poll path.
        var terminalReply: JesseReply?
        var sawTerminal = false
        var failure: String?

        do {
            for try await ev in cli.stream(jobId: jobId) {
                switch ev {
                case let .reset(s): streamingText = s
                case let .delta(s): streamingText += s
                case let .activity(a): activity = a
                case let .done(reply):
                    terminalReply = reply
                    sawTerminal = true
                case let .failed(msg):
                    failure = msg
                    sawTerminal = true
                case .cancelled:
                    sawTerminal = true
                }
            }
        } catch {
            // Stream dropped — fall through to a poll, which resolves what actually
            // happened to the job.
        }

        if sawTerminal {
            if let failure {
                lastError = failure
            } else {
                // A `done` frame with an empty final response falls back to the live
                // accumulator (already badge-free); a cancel with no terminal reply keeps
                // whatever streamed, exactly as before.
                let reply = terminalReply ?? JesseReply(text: streamingText, sessionId: nil)
                await finalize(thread: thread, reply: reply, streamedText: streamingText,
                               context: context, client: cli)
            }
            return
        }

        // No terminal frame (stream dropped mid-run): poll the job to resolution.
        await pollToCompletion(jobId: jobId, thread: thread, context: context, client: cli)
    }

    private func pollToCompletion(jobId: String, thread: JesseThread, context: ModelContext,
                                  client cli: any BridgeClientProtocol) async {
        for _ in 0..<600 {  // ~10 min ceiling at 1s spacing
            if Task.isCancelled { return }
            do {
                switch try await cli.result(jobId: jobId) {
                case .running:
                    try? await Task.sleep(for: .seconds(1))
                case let .done(reply):
                    await finalize(thread: thread, reply: reply, streamedText: nil,
                                   context: context, client: cli)
                    return
                case let .failed(msg):
                    lastError = msg
                    return
                case .cancelled:
                    return
                case .expired:
                    lastError = "That reply is no longer available on the bridge."
                    return
                }
            } catch {
                lastError = Self.friendly(error)
                return
            }
        }
    }

    /// The `(text, provenanceJSON)` a Jesse turn persists from a delivered reply: the
    /// badge/warning/SPOKEN-stripped body (via `JesseReply.displayText`) plus the compact
    /// provenance JSON, or the verbatim text and `nil` when no structured provenance rode
    /// the reply (an older bridge / badges off). `streamedText` is the live accumulator,
    /// used only when a terminal frame carried an EMPTY final response (the stream already
    /// holds the badge-free body). Pure, so the ingestion contract is unit-tested directly.
    static func turnFields(from reply: JesseReply, streamedText: String? = nil)
        -> (text: String, provenanceJSON: String?) {
        let raw = reply.text.isEmpty ? (streamedText ?? "") : reply.text
        let effective = JesseReply(text: raw, sessionId: reply.sessionId, provenance: reply.provenance)
        return (effective.displayText, reply.provenance?.jsonString)
    }

    /// Append the assistant turn, adopt any new `session_id`, advance the hydration
    /// cursor past this exchange (so a later hydrate won't re-add it), and mint a title
    /// for a still-untitled thread. The reply's structured provenance (model + per-turn
    /// cost) is persisted on the turn so the native chip renders under it and survives a
    /// reload, and the badge is stripped from the stored body (matching iOS).
    private func finalize(thread: JesseThread, reply: JesseReply, streamedText: String?,
                          context: ModelContext, client cli: any BridgeClientProtocol) async {
        if let sid = reply.sessionId, !sid.isEmpty, thread.sessionId != sid {
            thread.sessionId = sid
        }
        let fields = Self.turnFields(from: reply, streamedText: streamedText)
        let jesseTurn = Turn(role: .jesse, text: fields.text)
        jesseTurn.provenanceJSON = fields.provenanceJSON
        jesseTurn.thread = thread
        context.insert(jesseTurn)
        thread.updatedAt = Date()
        try? context.save()

        onTurnFinished?(thread, fields.text)

        guard let sid = thread.sessionId, !sid.isEmpty else { return }

        // Advance the cursor to the current transcript end WITHOUT re-appending: we keep
        // the optimistic + streamed turns as the record, and just move past them so a
        // future delta hydrate returns only genuinely-new content.
        if let (_, next) = try? await cli.hydrate(sessionId: sid, after: MacCursorStore.offset(sid)) {
            MacCursorStore.setOffset(sid, next)
        }

        // Mint an AI title once, from the thread's first user turn.
        if (thread.aiTitle ?? "").isEmpty,
           let firstUser = thread.orderedTurns.first(where: { $0.isUser })?.text,
           let title = await cli.title(text: firstUser, sessionId: sid) {
            thread.aiTitle = title
            try? context.save()
        }
    }

    // MARK: Hydration

    /// Pull any transcript turns appended since this thread's cursor and append them.
    /// Full transcript on first sight (cursor 0), then byte-deltas. A thread with no
    /// `session_id` yet (never got a reply) has nothing to hydrate.
    func hydrate(thread: JesseThread, context: ModelContext) async {
        guard configStore.isConfigured, let sid = thread.sessionId, !sid.isEmpty else { return }
        let after = MacCursorStore.offset(sid)
        do {
            let (turns, next) = try await client.hydrate(sessionId: sid, after: after)
            guard !turns.isEmpty else { MacCursorStore.setOffset(sid, next); return }
            for t in turns {
                let role: TurnRole = (t.role == "assistant") ? .jesse : .user
                let turn = Turn(role: role, text: t.text, createdAt: Self.parseTimestamp(t.timestamp))
                turn.thread = thread
                context.insert(turn)
            }
            thread.updatedAt = Date()
            try? context.save()
            MacCursorStore.setOffset(sid, next)
        } catch JesseError.badResponse(404, _) {
            // The session is gone server-side (GC'd / deleted): the shared client surfaces
            // an unknown/expired transcript as a 404. Leave the cached copy.
        } catch {
            lastError = Self.friendly(error)
        }
    }

    // MARK: Session-list sync

    /// Reconcile `GET /jesse/sessions` into local threads through the ONE shared
    /// `SessionReconciler` both apps use: adopt Mac/phone-started threads, refresh
    /// server-authoritative titles, converge the favorite/archive flags across devices
    /// (last-writer-wins; see `FlagReconciler`), and honor cross-device deletion tombstones
    /// (bridge 0.26.0). ETag-conditioned, so an unchanged list is a cheap 304. Also drains
    /// any queued remote deletions (best-effort) whenever the list is pulled.
    func refreshSessions(context: ModelContext) async {
        guard configStore.isConfigured else { return }
        drainSessionDeletions()
        let cli = makeClient(configStore.config)
        do {
            switch try await cli.listSessions(since: nil, etag: sessionsETag) {
            case .notModified:
                return
            case let .sessions(list, deleted, etag):
                sessionsETag = etag
                await upsert(list, deleted: deleted, client: cli, context: context)
            }
        } catch {
            lastError = Self.friendly(error)
        }
    }

    private func upsert(_ list: [SessionSummary], deleted: [SessionTombstone],
                        client cli: any BridgeClientProtocol, context: ModelContext) async {
        // Index existing threads that carry a session id.
        let existing = (try? context.fetch(FetchDescriptor<JesseThread>())) ?? []
        var bySession: [String: JesseThread] = [:]
        for t in existing { if let sid = t.sessionId, !sid.isEmpty { bySession[sid] = t } }

        let plan = SessionReconciler.plan(
            localSessionIds: Set(bySession.keys),
            sessions: list,
            tombstones: Set(deleted.map(\.sessionId)),
            pendingDeletion: sessionDeletionStore.pendingIds)

        // ADOPT a new stub, then reconcile flags (a zero-clock stub adopts server flags).
        for s in plan.adopt {
            let stamp = Date(timeIntervalSince1970: TimeInterval(s.lastModified))
            let derived = s.firstMessage.map { JesseThread.deriveTitle(from: $0) } ?? ""
            let t = JesseThread(title: derived, mode: .ask, createdAt: stamp)
            t.sessionId = s.sessionId
            t.aiTitle = s.title
            t.updatedAt = stamp
            context.insert(t)
            await FlagReconciler.reconcile(
                thread: t,
                serverFavorite: s.favorite, serverFavoriteUpdatedMs: Int(s.favoriteUpdatedMs),
                serverArchived: s.archived, serverArchivedUpdatedMs: Int(s.archivedUpdatedMs),
                client: cli)
        }

        // UPDATE an existing thread: refresh title, then reconcile flags.
        for s in plan.update {
            guard let t = bySession[s.sessionId] else { continue }
            let stamp = Date(timeIntervalSince1970: TimeInterval(s.lastModified))
            if let title = s.title, !title.isEmpty { t.aiTitle = title }
            if t.title.isEmpty, let fm = s.firstMessage {
                t.title = JesseThread.deriveTitle(from: fm)
            }
            if stamp > t.updatedAt { t.updatedAt = stamp }
            await FlagReconciler.reconcile(
                thread: t,
                serverFavorite: s.favorite, serverFavoriteUpdatedMs: Int(s.favoriteUpdatedMs),
                serverArchived: s.archived, serverArchivedUpdatedMs: Int(s.archivedUpdatedMs),
                client: cli)
        }

        // DELETE-LOCAL a thread the bridge tombstoned (deleted on the phone): remove it
        // (turns cascade) and clear its hydration cursor.
        for sid in plan.deleteLocalSessionIds {
            guard let t = bySession[sid] else { continue }
            context.delete(t)
            MacCursorStore.clear(sid)
        }

        try? context.save()
    }

    // MARK: - Remote session deletion (durable)

    /// Enqueue a thread's bridge `sessionId` for durable remote deletion and kick a drain.
    /// Called from the sidebar delete AFTER the instant local SwiftData delete: the local
    /// delete is unchanged, and the remote transcript is reclaimed best-effort (and a
    /// tombstone recorded so the phone converges). A blank id is a no-op.
    func enqueueSessionDeletion(_ sessionId: String) {
        sessionDeletionStore.enqueue(sessionId)
        drainSessionDeletions()
    }

    /// Fire-and-forget drain of the durable pending-deletions queue: for each tombstone,
    /// `DELETE /jesse/session/{id}`; success (incl. the bridge's idempotent 404) clears it,
    /// a network failure leaves it for the next drain (enqueue or the next sessions pull).
    private func drainSessionDeletions() {
        guard configStore.isConfigured else { return }
        let store = sessionDeletionStore
        let cli = makeClient(configStore.config)
        Task {
            for item in store.pending {
                do {
                    try await cli.deleteSession(item.sessionId)
                    store.remove(item.sessionId)
                } catch {
                    // Transport/auth/5xx: leave the tombstone; the next drain retries.
                }
            }
        }
    }

    // MARK: Flag push

    /// Optimistic best-effort push of a just-toggled FAVORITE up to the bridge so the
    /// phone converges on its next sync. No-op for a thread with no `session_id`. A failed
    /// push is swallowed: the local `favoriteUpdatedMs` is now newer than the server, so
    /// the next `refreshSessions` reconcile re-pushes it (the LWW reconcile self-heals, so
    /// no retry queue is needed and a failure never surfaces to the user).
    func pushFavoriteChange(for thread: JesseThread) {
        guard let sid = thread.sessionId, !sid.isEmpty else { return }
        let write = FlagWrite(value: thread.isFavorite, updatedMs: thread.favoriteUpdatedMs)
        let cli = makeClient(configStore.config)
        Task { try? await cli.setFlags(sessionId: sid, favorite: write, archived: nil) }
    }

    /// Optimistic best-effort push of a just-toggled ARCHIVE up. Mirror of
    /// `pushFavoriteChange`; same self-healing best-effort semantics.
    func pushArchivedChange(for thread: JesseThread) {
        guard let sid = thread.sessionId, !sid.isEmpty else { return }
        let write = FlagWrite(value: thread.isArchived, updatedMs: thread.archivedUpdatedMs)
        let cli = makeClient(configStore.config)
        Task { try? await cli.setFlags(sessionId: sid, favorite: nil, archived: write) }
    }

    // MARK: Helpers

    static func friendly(_ error: Error) -> String {
        switch error {
        case JesseError.notConfigured:
            return "Set the bridge address and token in Settings first."
        case JesseError.badResponse(404, _):
            return "That conversation is no longer on the bridge."
        case let JesseError.badResponse(code, _):
            return "The bridge returned an error (HTTP \(code))."
        case JesseError.decoding:
            return "The bridge sent a response the app couldn’t read."
        case let je as JesseError:
            // cannotFindHost / cannotConnect / timedOut / transport / connectionLost —
            // each already names the host it tried.
            return je.errorDescription ?? "Couldn’t reach the bridge."
        default:
            return error.localizedDescription
        }
    }

    /// Parse a transcript ISO-8601 timestamp; fall back to now so ordering stays stable.
    static func parseTimestamp(_ s: String?) -> Date {
        guard let s else { return Date() }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s) ?? Date()
    }
}
