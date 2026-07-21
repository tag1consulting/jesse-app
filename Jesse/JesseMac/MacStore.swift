import Foundation
import SwiftData
import Observation

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

    init(configStore: MacConfigStore) {
        self.configStore = configStore
    }

    private var client: MacJesseClient { MacJesseClient(config: configStore.config) }

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
        do {
            let result = try await cli.send(
                mode: mode, text: trimmed, sessionId: thread.sessionId,
                requestId: UUID().uuidString)
            switch result {
            case let .reply(replyText, sid):
                await finalize(thread: thread, reply: replyText, sessionId: sid, context: context, client: cli)
            case let .running(jobId):
                await runStream(jobId: jobId, thread: thread, context: context, client: cli)
            }
        } catch {
            lastError = Self.friendly(error)
        }
    }

    private func runStream(jobId: String, thread: JesseThread, context: ModelContext,
                           client cli: MacJesseClient) async {
        var terminalReply: String?
        var terminalSession: String?
        var sawTerminal = false
        var failure: String?

        do {
            for try await ev in cli.stream(jobId: jobId) {
                switch ev {
                case let .reset(s): streamingText = s
                case let .delta(s): streamingText += s
                case let .activity(a): activity = a
                case let .done(text, sid):
                    terminalReply = text.isEmpty ? streamingText : text
                    terminalSession = sid
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
                await finalize(thread: thread, reply: terminalReply ?? streamingText,
                               sessionId: terminalSession, context: context, client: cli)
            }
            return
        }

        // No terminal frame (stream dropped mid-run): poll the job to resolution.
        await pollToCompletion(jobId: jobId, thread: thread, context: context, client: cli)
    }

    private func pollToCompletion(jobId: String, thread: JesseThread, context: ModelContext,
                                  client cli: MacJesseClient) async {
        for _ in 0..<600 {  // ~10 min ceiling at 1s spacing
            if Task.isCancelled { return }
            do {
                switch try await cli.result(jobId: jobId) {
                case .running:
                    try? await Task.sleep(for: .seconds(1))
                case let .done(text, sid):
                    await finalize(thread: thread, reply: text, sessionId: sid, context: context, client: cli)
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

    /// Append the assistant turn, adopt any new `session_id`, advance the hydration
    /// cursor past this exchange (so a later hydrate won't re-add it), and mint a title
    /// for a still-untitled thread.
    private func finalize(thread: JesseThread, reply: String, sessionId: String?,
                          context: ModelContext, client cli: MacJesseClient) async {
        if let sid = sessionId, !sid.isEmpty, thread.sessionId != sid {
            thread.sessionId = sid
        }
        let jesseTurn = Turn(role: .jesse, text: reply)
        jesseTurn.thread = thread
        context.insert(jesseTurn)
        thread.updatedAt = Date()
        try? context.save()

        onTurnFinished?(thread, reply)

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
           let title = await cli.title(for: firstUser, sessionId: sid) {
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
        } catch MacJesseError.unknownSession {
            // The session is gone server-side (GC'd / deleted). Leave the cached copy.
        } catch {
            lastError = Self.friendly(error)
        }
    }

    // MARK: Session-list sync

    /// Reconcile `GET /jesse/sessions` into local threads: adopt phone-started threads,
    /// refresh server-authoritative titles. ETag-conditioned, so an unchanged list is a
    /// cheap 304.
    func refreshSessions(context: ModelContext) async {
        guard configStore.isConfigured else { return }
        do {
            switch try await client.listSessions(etag: sessionsETag) {
            case .notModified:
                return
            case let .sessions(list, etag):
                sessionsETag = etag
                upsert(list, context: context)
            }
        } catch {
            lastError = Self.friendly(error)
        }
    }

    private func upsert(_ list: [MacSessionSummary], context: ModelContext) {
        // Index existing threads that carry a session id.
        let existing = (try? context.fetch(FetchDescriptor<JesseThread>())) ?? []
        var bySession: [String: JesseThread] = [:]
        for t in existing { if let sid = t.sessionId, !sid.isEmpty { bySession[sid] = t } }

        for s in list {
            let stamp = Date(timeIntervalSince1970: TimeInterval(s.lastModified))
            if let t = bySession[s.sessionId] {
                if let title = s.title, !title.isEmpty { t.aiTitle = title }
                if t.title.isEmpty, let fm = s.firstMessage {
                    t.title = JesseThread.deriveTitle(from: fm)
                }
                if stamp > t.updatedAt { t.updatedAt = stamp }
            } else {
                let derived = s.firstMessage.map { JesseThread.deriveTitle(from: $0) } ?? ""
                let t = JesseThread(title: derived, mode: .ask, createdAt: stamp)
                t.sessionId = s.sessionId
                t.aiTitle = s.title
                t.updatedAt = stamp
                context.insert(t)
            }
        }
        try? context.save()
    }

    // MARK: Helpers

    static func friendly(_ error: Error) -> String {
        switch error {
        case MacJesseError.notConfigured:
            return "Set the bridge address and token in Settings first."
        case let MacJesseError.transport(msg):
            return "Couldn’t reach the bridge: \(msg)"
        case let MacJesseError.badStatus(code, _):
            return "The bridge returned an error (HTTP \(code))."
        case MacJesseError.unknownSession:
            return "That conversation is no longer on the bridge."
        case MacJesseError.decoding:
            return "The bridge sent a response the app couldn’t read."
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
