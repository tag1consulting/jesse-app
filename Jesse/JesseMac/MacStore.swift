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
    ///
    /// `TurnArtifact` is here because `Turn.artifacts` points at it: a relationship whose
    /// destination the container does not name is the one way this list can be wrong, and
    /// it fails at RUNTIME on the laptop rather than at compile time here.
    static var schema: Schema {
        Schema([JesseThread.self, Turn.self, TurnAttachment.self, TurnArtifact.self])
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

/// Per-conversation cursor into the transcript, so a hydrate fetches only what was appended
/// since. Kept in UserDefaults (keyed by conversation id) rather than the shared schema, so
/// tracking Mac-side sync state adds no column to the phone's model.
///
/// Two fixes over the byte-offset version this replaces. The cursor is now the bridge's
/// OPAQUE `"<segment>:<offset>"` string, because a conversation can span several transcript
/// files and a bare offset is not a sufficient position. And it is PRESENCE-based: `offset`
/// used to return 0 for an absent key, so the Mac could not tell "never hydrated" from
/// "hydrated from byte zero", which is precisely the ambiguity that let a hydrate re-import
/// turns already on screen.
enum MacCursorStore {
    /// The v2 prefix. Note the ordering hazard the purge below has to respect:
    /// `hydrate.cursor.` is a PREFIX of `hydrate.cursor.v2.`.
    private static let prefix = "hydrate.cursor.v2."
    private static let legacyPrefix = "hydrate.cursor."
    private static let purgedFlag = "hydrate.cursor.v1purged"

    private static func key(_ conversationId: String) -> String { prefix + conversationId }

    /// The stored cursor, or nil when this conversation has never been hydrated.
    static func cursor(_ conversationId: String, defaults: UserDefaults = .standard) -> String? {
        purgeLegacyOnce(defaults: defaults)
        guard let v = defaults.string(forKey: key(conversationId)), !v.isEmpty else { return nil }
        return v
    }
    static func setCursor(_ conversationId: String, _ value: String,
                         defaults: UserDefaults = .standard) {
        purgeLegacyOnce(defaults: defaults)
        defaults.set(value, forKey: key(conversationId))
    }
    /// Forget a conversation's cursor, called when its local thread is deleted (locally or via
    /// a cross-device tombstone) so a re-adopted id later hydrates from scratch.
    static func clear(_ conversationId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(conversationId))
    }

    /// Drop every v1 byte-offset cursor, once. They are keyed on a session id and hold byte
    /// offsets, so neither the key nor the value means anything against the opaque cursor.
    /// The v2 prefix is filtered out explicitly, so this is safe whenever it runs.
    static func purgeLegacyOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: purgedFlag) else { return }
        for k in defaults.dictionaryRepresentation().keys
        where k.hasPrefix(legacyPrefix) && !k.hasPrefix(prefix) && k != purgedFlag {
            defaults.removeObject(forKey: k)
        }
        defaults.set(true, forKey: purgedFlag)
    }
}

// MARK: - Shared model list

/// One shared, last-known-good model list for the Mac's model pickers, so the composer's
/// per-conversation picker never silently vanishes when `GET /jesse/models` is slow, briefly
/// unreachable, or served by an older bridge, and so opening several conversations doesn't
/// re-fetch the list each time. Fetched on first need and refreshable; a transient failure KEEPS
/// the last-known list (only a list that has NEVER loaded stays `nil`, and the picker then falls
/// back to the resolved model id — see `MacModelPickerMenu`). `@Observable` so the pickers
/// re-render the instant the list arrives or a selection changes.
@MainActor
@Observable
final class MacModelListStore {
    /// The last successfully-fetched model list, or `nil` before the first success (an older
    /// bridge with no models route stays `nil` forever, which the picker tolerates).
    private(set) var state: ModelSwitchState?

    /// Guards against overlapping fetches (several pickers driving the same store at once).
    private var loading = false

    /// The fetch seam (production: the real bridge client). Injected so tests drive it without a
    /// live bridge.
    private let fetch: @Sendable (JesseConfig) async throws -> ModelSwitchState

    init(fetch: @escaping @Sendable (JesseConfig) async throws -> ModelSwitchState
            = { try await JesseBridgeClient(config: $0).fetchModels() }) {
        self.fetch = fetch
    }

    /// Load the list once if it has never loaded; a no-op once loaded. Used by a picker on
    /// appear so the first open populates the shared list and later opens reuse it.
    func loadIfNeeded(config: JesseConfig) async {
        guard state == nil else { return }
        await refresh(config: config)
    }

    /// Fetch the list, KEEPING the last-known list on any failure (an unconfigured bridge is a
    /// no-op). Safe to call repeatedly; overlapping calls collapse to one in-flight fetch.
    func refresh(config: JesseConfig) async {
        guard config.isConfigured, !loading else { return }
        loading = true
        defer { loading = false }
        if let fresh = try? await fetch(config) { state = fresh }
        // On failure: leave `state` untouched — never blank a working list, never surface an error
        // (the picker still shows the resolved model). The next `refresh` retries.
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

    /// Shared model list for the composer's per-conversation model picker (and available to any
    /// other model UI), so a slow/unreachable `/jesse/models` never blanks the switcher and every
    /// conversation renders the same list. Fetched lazily on first picker appearance.
    let modelList = MacModelListStore()

    /// The thread whose turn is currently running, if any.
    private(set) var activeThreadID: UUID?
    /// Live assistant text for the active turn (reset REPLACES, delta APPENDS).
    private(set) var streamingText: String = ""
    /// The current tool-activity LINE for the active turn, already human ("Reading the
    /// vault…"), from `ToolActivity.displayLabel` — the same mapping the iOS app uses.
    /// Empty when the turn has not reported any activity yet.
    private(set) var activity: String = ""
    private(set) var isRunning = false
    /// Last user-facing error (send/stream failure, sync failure). Cleared on the next
    /// successful action.
    var lastError: String?

    /// Fires when a turn completes, so the app can post a local notification.
    var onTurnFinished: (@MainActor (JesseThread, _ reply: String) -> Void)?

    /// Guards `refreshSessions` against overlapping runs, exactly as the phone does.
    private var isRefreshingSessions = false

    /// Context held against a thread that was OPENED without firing a turn — today
    /// only the Today tab's Discuss. There is nothing for the agent to do until Jeremy
    /// has said what he wants, so the frozen `TodayDiscuss.prompt` (the item's markdown,
    /// its links, and the sentence that keeps a discussion from tripping the morning
    /// routine) waits here and rides his first message, composed by the SHARED
    /// `TodayThreadContext.firstMessage` — the same composition the phone uses, because
    /// a second spelling of it on this platform would be a second definition of what an
    /// item discussion is scoped to.
    ///
    /// Deliberately OBSERVED (not `@ObservationIgnored`): the composer enables Send on an
    /// empty input only while a context is attached, so the view has to re-evaluate when
    /// the first send consumes it.
    ///
    /// In memory only. An attachment describes a thread that has never been sent to, and
    /// such a thread is not in the store either — both die with the process, and the
    /// Today tab drops the attachment when its sheet is dismissed.
    ///
    /// Widened from a bare `String` to `AttachedContext` for the Health tab's "Ask about
    /// this" — which needs the scope TITLE (so the chat can say what "this" refers to
    /// without pasting a page of numbers into the transcript) and the STARTERS its empty
    /// state offers. The shared type lives in JesseCore, so the phone and this Mac cannot
    /// grow two ideas of what a screen attached.
    private var attachedContexts: [UUID: AttachedContext] = [:]

    /// Hold `context` against a thread opened without firing; its first send carries it.
    func attach(context: String, to threadID: UUID) {
        attachedContexts[threadID] = AttachedContext(body: context)
    }

    /// Hold a titled attachment (the Health tab's ask) against a thread.
    func attach(_ context: AttachedContext, to threadID: UUID) {
        attachedContexts[threadID] = context
    }

    /// The context waiting on this thread's first send, if any. nil once consumed —
    /// which is also what tells the composer that an empty send is no longer a turn.
    func attachedContext(for threadID: UUID) -> String? { attachedContexts[threadID]?.body }

    /// The whole attachment — title and starters included — for the composer's pinned
    /// scope line and its opening questions.
    func attachment(for threadID: UUID) -> AttachedContext? { attachedContexts[threadID] }

    /// Drop an attachment that will never be sent (its sheet was dismissed). A no-op
    /// once the first send has consumed it.
    func clearAttachedContext(for threadID: UUID) {
        attachedContexts[threadID] = nil
    }

    /// Whether the bridge has ACCEPTED the running turn (its 202 came back), as opposed to the
    /// POST still being in flight. `isRunning` deliberately covers both, which is why it cannot
    /// answer this; the detail view's delivery caption reads `phase` below.
    private(set) var accepted = false

    /// Where the running turn is between "typed" and "answered", or nil when nothing is
    /// running on `threadID`. Mirrors the phone's `RunCoordinator.phase`.
    func phase(_ threadID: UUID) -> TurnPhase? {
        guard isRunning, activeThreadID == threadID, lastError == nil else { return nil }
        return accepted ? .accepted : .sending
    }

    /// Adopt the bridge's authoritative conversation id and stamp the first-ACK time. The
    /// bridge stays free to override the requested id, so the echo is always written back; a
    /// nil echo means a bridge too old to report one and the local id stands.
    private func adoptRegistration(thread: JesseThread, conversationId: String?) {
        if let conversationId, !conversationId.isEmpty, thread.conversationId != conversationId {
            thread.conversationId = conversationId
        }
        if thread.registeredAt == nil { thread.registeredAt = Date() }
    }

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

    /// A client for fetching a returned file's bytes, or `nil` when this Mac is not
    /// paired. Goes through the SAME injected `makeClient` seam every turn does, so an
    /// artifact fetch in a test uses the same fake.
    func artifactClient() -> (any BridgeClientProtocol)? {
        let cfg = configStore.config
        guard !cfg.normalizedHost.isEmpty, !cfg.token.isEmpty else { return nil }
        return makeClient(cfg)
    }

    func isRunning(_ threadID: UUID) -> Bool { isRunning && activeThreadID == threadID }

    // MARK: Sending a turn

    /// Send `text` in `thread`, streaming the reply. Creates an optimistic user turn
    /// immediately (cache-first), then appends the assistant turn when the run finishes.
    ///
    /// If the thread carries an ATTACHED context (a screen opened it without firing —
    /// today only the Today tab's Discuss), this send is the one that spends it: the
    /// context is composed AHEAD of whatever was typed and the attachment is dropped, so
    /// it rides the first message and only the first. Composing HERE rather than in the
    /// composer is what makes every send path honor it, and what makes an empty composer
    /// with a context attached a real turn ("just look at it") instead of a silently
    /// dropped one.
    func send(text: String, mode: JesseMode, thread: JesseThread, context: ModelContext) async {
        let attached = attachedContexts[thread.id]
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = attached.map { TodayThreadContext.firstMessage(context: $0.body, typed: text) }
            ?? typed
        // The guards run on the COMPOSED text and before the attachment is spent, so a
        // send refused because a turn is already running leaves the context attached for
        // the send that does go through.
        guard !trimmed.isEmpty, !isRunning, configStore.isConfigured else { return }
        attachedContexts[thread.id] = nil

        // A staged thread is not in the store until its first send (the Chats list reaps
        // empty thread-less threads on appear, which would otherwise delete a discussion
        // out from under the open sheet). Insert it now so its turns persist and it
        // shows in the list. A no-op for every other path, which inserts on creation.
        if thread.modelContext == nil { context.insert(thread) }

        let userTurn = Turn(role: .user, text: trimmed)
        // `trimmed` is what the MODEL is sent and stays the turn's identity; what the
        // TRANSCRIPT shows is the user's own half. A Health snapshot is a page of numbers,
        // and rendering it as something they typed would be unreadable and untrue. Mirrors
        // the phone, through the same shared `Turn.visibleText`.
        if let attached {
            userTurn.displayText = typed
            userTurn.contextLabel = attached.contextLabel
        }
        userTurn.thread = thread
        context.insert(userTurn)
        thread.updatedAt = Date()
        try? context.save()

        activeThreadID = thread.id
        isRunning = true
        accepted = false
        streamingText = ""
        activity = ""
        lastError = nil
        defer {
            isRunning = false
            accepted = false
            activeThreadID = nil
            streamingText = ""
            activity = ""
        }

        let cli = client
        // The PER-TURN model this conversation sends on: its own stored selection, else this
        // device's default (`LastUsedModelStore`). Local to this Mac and this thread — it never
        // mutates the bridge's global default, so the phone is unaffected. nil → bridge default.
        let model = thread.selectedModelID ?? LastUsedModelStore.id
        // The thread identity, sent on every turn. The Mac has no outbox to reuse a request id
        // from, so it keeps generating one per attempt; identity is carried by the conversation.
        let conversationId = thread.conversationId ?? JesseThread.mintConversationId()
        if thread.conversationId != conversationId { thread.conversationId = conversationId }
        do {
            let result = try await cli.send(
                mode: mode, text: trimmed, sessionId: thread.sessionId,
                conversationId: conversationId,
                voice: false, instructions: nil, floorOverride: nil,
                attachments: [], requestId: UUID().uuidString, model: model)
            // Adopt the AUTHORITATIVE id the bridge registered and stamp the first ACK, which
            // is what the detail view's delivery caption reads.
            adoptRegistration(thread: thread, conversationId: result.conversationId)
            switch result {
            case let .reply(reply, _, _):
                await finalize(thread: thread, reply: reply, streamedText: nil,
                               context: context, client: cli)
            case let .running(jobId, _):
                accepted = true
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
                case let .activity(a): activity = a.displayLabel
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
        // Files this turn returned, as METADATA rows — the bytes are downloaded lazily on
        // first display and cached on disk, never held in the store. `sortIndex` keeps the
        // order the bridge swept them in, because the relationship is unordered and every
        // row here is created in the same save. Mirrors the iOS `TurnWriter`.
        for (i, a) in reply.artifacts.enumerated() {
            jesseTurn.artifacts.append(TurnArtifact(artifactID: a.id, filename: a.filename,
                                                    mime: a.mime, byteCount: Int(a.bytes),
                                                    sha256: a.sha256, sortIndex: i))
        }
        jesseTurn.thread = thread
        context.insert(jesseTurn)
        thread.updatedAt = Date()
        try? context.save()

        onTurnFinished?(thread, fields.text)

        guard let cid = thread.conversationId, !cid.isEmpty else { return }

        // Hydrate through the SAME merge the open path uses, which binds the delivered turns'
        // stable `turn_key`s and advances the cursor. This used to advance the cursor without
        // reading anything, precisely because re-reading would have re-appended the turns just
        // rendered; with the key-based merge that is no longer true, and binding the keys here
        // is what makes every later hydrate a cheap no-op.
        await hydrate(thread: thread, context: context)

        // Mint an AI title once, from the thread's first user turn.
        if (thread.aiTitle ?? "").isEmpty,
           let firstUser = thread.orderedTurns.first(where: { $0.isUser })?.text,
           let title = await cli.title(text: firstUser, conversationId: cid) {
            thread.aiTitle = title
            try? context.save()
        }
    }

    // MARK: Hydration

    /// Pull whatever the bridge has appended past this thread's cursor and merge it in. Full
    /// history on first sight (no cursor), then deltas. A thread the sync has not bound to a
    /// conversation has nothing to hydrate.
    ///
    /// The merge is an IDENTITY, not a heuristic. Every hydrated turn carries the bridge's
    /// stable `turn_key`; a turn already held under that key is skipped, an UNKEYED local turn
    /// (the optimistic one this app rendered) has the key BOUND onto it, and only a genuinely
    /// new turn is inserted. That replaces the content-hash multiset this used to keep, which
    /// could not distinguish two genuinely identical messages and so silently dropped the
    /// second one. It is also the same `TranscriptMerge` the phone uses, so the two platforms
    /// cannot disagree about what counts as a turn already held.
    func hydrate(thread: JesseThread, context: ModelContext) async {
        guard configStore.isConfigured, let cid = thread.conversationId, !cid.isEmpty else { return }
        let after = MacCursorStore.cursor(cid)
        do {
            let (turns, next) = try await client.hydrate(conversationId: cid, after: after)
            guard !turns.isEmpty else {
                MacCursorStore.setCursor(cid, next)
                lastError = nil
                return
            }

            let existing = thread.orderedTurns
            let plan = TranscriptMerge.plan(
                existing: existing.map {
                    TranscriptMerge.Existing(role: $0.role, text: $0.text, sourceKey: $0.sourceKey)
                },
                incoming: turns)
            var changed = false
            for (i, action) in plan.enumerated() where i < turns.count {
                let t = turns[i]
                switch action {
                case .skip:
                    break
                case let .bind(existingIndex):
                    guard existingIndex < existing.count, !t.turnKey.isEmpty else { break }
                    existing[existingIndex].sourceKey = t.turnKey
                    changed = true
                case .insert:
                    let turn = Turn(role: TranscriptMerge.role(for: t.role), text: t.text,
                                    createdAt: TranscriptMerge.timestamp(t.timestamp))
                    turn.sourceKey = t.turnKey.isEmpty ? nil : t.turnKey
                    // A turn this Mac never saw — hydrated from the phone's send, or
                    // after a fresh install. The bridge re-attached its returned files, so
                    // history shows the chart instead of silently losing it. Metadata
                    // only; the bytes download lazily on first display. A BOUND turn is
                    // skipped here on purpose: it already holds its own rows.
                    for (i, a) in t.artifacts.enumerated() {
                        turn.artifacts.append(TurnArtifact(artifactID: a.id, filename: a.filename,
                                                           mime: a.mime, byteCount: Int(a.bytes),
                                                           sha256: a.sha256, sortIndex: i))
                    }
                    turn.thread = thread
                    context.insert(turn)
                    thread.updatedAt = Date()
                    changed = true
                }
            }
            if changed { try? context.save() }
            MacCursorStore.setCursor(cid, next)
            // Same rule as `refreshSessions`: a success is what clears the error, not
            // only a send. Opening a thread that hydrates cleanly should take the red off
            // the window.
            lastError = nil
        } catch JesseError.badResponse(404, _) {
            // The conversation is gone server-side (GC'd / deleted): the shared client
            // surfaces an unknown transcript as a 404. Leave the cached copy.
        } catch {
            lastError = Self.friendly(error)
        }
    }

    // MARK: Session-list sync

    /// Reconcile `GET /jesse/conversations` into local threads through the ONE shared
    /// `ConversationReconciler` both apps use: adopt threads started elsewhere, refresh
    /// server-authoritative titles and the current session, converge the favorite/archive
    /// flags across devices (last-writer-wins; see `FlagReconciler`), and honor cross-device
    /// deletion tombstones. ETag-conditioned, so an unchanged list is a cheap 304. Also drains
    /// any queued remote deletions (best-effort) whenever the list is pulled.
    func refreshSessions(context: ModelContext) async {
        guard configStore.isConfigured else { return }
        // Same re-entrancy guard the phone has: two overlapping refreshes would fetch the same
        // list under the same stale ETag and apply the same plan twice.
        guard !isRefreshingSessions else { return }
        isRefreshingSessions = true
        defer { isRefreshingSessions = false }
        drainSessionDeletions()
        let cli = makeClient(configStore.config)
        do {
            switch try await cli.listConversations(since: nil, etag: sessionsETag) {
            case .notModified:
                // A completed round trip, so whatever red the window is painting is about
                // a world that no longer exists. Clearing here and in the adopt path
                // below is what stops ONE transient failure from leaving a permanent
                // "disconnected" banner: `send` cleared this flag and nothing else did,
                // so a Mac that failed a sync at 2am still looked broken at 9.
                lastError = nil
                return
            case let .conversations(list, deleted, etag):
                await upsert(list, deleted: deleted, client: cli, context: context)
                // The ETag is written AFTER the adopt, never before. A partial or
                // throwing `upsert` with the tag already stored would wedge every later
                // pull into a cheap `304` describing a list this device never finished
                // applying — the local store permanently missing threads the bridge
                // believes were delivered. Storing it last means the worst case is one
                // redundant full pull.
                sessionsETag = etag
                lastError = nil
            }
        } catch {
            lastError = Self.friendly(error)
        }
    }

    /// The same FOUR passes the phone runs, in the same order, so the two devices cannot
    /// diverge: legacy-bind a pre-upgrade thread, merge duplicates already on the device, then
    /// plan and apply adopt / update / delete-local, then save.
    private func upsert(_ list: [ConversationSummary], deleted: [ConversationTombstone],
                        client cli: any BridgeClientProtocol, context: ModelContext) async {
        let existing = (try? context.fetch(FetchDescriptor<JesseThread>())) ?? []

        // ── Pass 1: legacy bind ────────────────────────────────────────────────────────
        var conversationForSession: [String: String] = [:]
        for c in list {
            for sid in c.sessionIds { conversationForSession[sid] = c.conversationId }
            if let sid = c.sessionId { conversationForSession[sid] = c.conversationId }
        }
        for t in existing where (t.conversationId ?? "").isEmpty {
            guard let sid = t.sessionId, !sid.isEmpty,
                  let cid = conversationForSession[sid] else { continue }
            t.conversationId = cid
        }

        // ── Pass 2: merge duplicates ───────────────────────────────────────────────────
        mergeDuplicateThreads(existing, remote: list, context: context)

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

        // ADOPT a new stub, then reconcile flags (a zero-clock stub adopts server flags).
        for c in plan.adopt {
            let stamp = Date(timeIntervalSince1970: TimeInterval(c.lastModified))
            let derived = c.firstMessage.map { JesseThread.deriveTitle(from: $0) } ?? ""
            let t = JesseThread(title: derived, mode: .ask, createdAt: stamp)
            // The initializer minted a FRESH random id; an adopted thread must not keep it.
            t.conversationId = c.conversationId
            t.sessionId = c.sessionId
            if c.registeredMs > 0 {
                t.registeredAt = Date(timeIntervalSince1970: TimeInterval(c.registeredMs) / 1000)
            }
            t.aiTitle = c.title
            t.updatedAt = stamp
            context.insert(t)
            await FlagReconciler.reconcile(
                thread: t,
                serverFavorite: c.favorite, serverFavoriteUpdatedMs: Int(c.favoriteUpdatedMs),
                serverArchived: c.archived, serverArchivedUpdatedMs: Int(c.archivedUpdatedMs),
                client: cli)
        }

        // UPDATE an existing thread: the same rules the phone applies, so the two agree.
        for c in plan.update {
            guard let t = byConversation[c.conversationId] else { continue }
            let stamp = Date(timeIntervalSince1970: TimeInterval(c.lastModified))
            if let title = c.title, !title.isEmpty, t.aiTitle != title { t.aiTitle = title }
            if t.title.isEmpty, let fm = c.firstMessage {
                t.title = JesseThread.deriveTitle(from: fm)
            }
            if let sid = c.sessionId, !sid.isEmpty, t.sessionId != sid { t.sessionId = sid }
            if stamp > t.updatedAt { t.updatedAt = stamp }
            await FlagReconciler.reconcile(
                thread: t,
                serverFavorite: c.favorite, serverFavoriteUpdatedMs: Int(c.favoriteUpdatedMs),
                serverArchived: c.archived, serverArchivedUpdatedMs: Int(c.archivedUpdatedMs),
                client: cli)
        }

        // DELETE-LOCAL a thread the bridge tombstoned (deleted on the phone): remove it
        // (turns cascade) and clear its hydration cursor.
        for cid in plan.deleteLocalConversationIds {
            guard let t = byConversation[cid] else { continue }
            context.delete(t)
            MacCursorStore.clear(cid)
        }

        // ── Pass 4: save once ─────────────────────────────────────────────────────────
        try? context.save()
    }

    /// Collapse every group of local threads sharing one conversation id into the group's
    /// OLDEST member. The Mac's half of the repair pass, identical in rules to the phone's:
    /// turns move across under `TranscriptMerge` so nothing duplicates and nothing is lost,
    /// flags resolve by the higher last-writer-wins clock, and it keys on the conversation id
    /// and NEVER on the title (two conversations can legitimately share a title).
    @discardableResult
    private func mergeDuplicateThreads(_ threads: [JesseThread],
                                       remote: [ConversationSummary],
                                       context: ModelContext) -> Int {
        var groups: [String: [JesseThread]] = [:]
        for t in threads {
            guard let cid = t.conversationId, !cid.isEmpty else { continue }
            groups[cid, default: []].append(t)
        }
        let remoteById = Dictionary(remote.map { ($0.conversationId, $0) },
                                   uniquingKeysWith: { a, _ in a })
        var merges = 0
        for (cid, group) in groups where group.count > 1 {
            let ordered = group.sorted { $0.createdAt < $1.createdAt }
            guard let winner = ordered.first else { continue }
            for loser in ordered.dropFirst() {
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
                        turn.thread = winner
                    }
                }
                if loser.favoriteUpdatedMs > winner.favoriteUpdatedMs {
                    winner.applyFavoriteFromSync(loser.isFavorite, updatedMs: loser.favoriteUpdatedMs)
                }
                if loser.archivedUpdatedMs > winner.archivedUpdatedMs {
                    winner.applyArchivedFromSync(loser.isArchived, updatedMs: loser.archivedUpdatedMs)
                }
                if (winner.aiTitle ?? "").isEmpty, let title = loser.aiTitle, !title.isEmpty {
                    winner.aiTitle = title
                }
                if winner.title.isEmpty, !loser.title.isEmpty { winner.title = loser.title }
                winner.updatedAt = max(winner.updatedAt, loser.updatedAt)
                if winner.registeredAt == nil { winner.registeredAt = loser.registeredAt }
                context.delete(loser)
                merges += 1
            }
            if let sid = remoteById[cid]?.sessionId, !sid.isEmpty { winner.sessionId = sid }
        }
        return merges
    }

    // MARK: - Remote session deletion (durable)

    /// Enqueue a thread's bridge `conversationId` for durable remote deletion and kick a
    /// drain. Called from the sidebar delete AFTER the instant local SwiftData delete: the
    /// local delete is unchanged, and every remote transcript bound to the conversation is
    /// reclaimed best-effort (and a tombstone recorded so the phone converges). A blank id is
    /// a no-op.
    func enqueueSessionDeletion(_ conversationId: String) {
        sessionDeletionStore.enqueue(conversationId)
        drainSessionDeletions()
    }

    /// Fire-and-forget drain of the durable pending-deletions queue: for each tombstone,
    /// `DELETE /jesse/conversation/{id}`; success (incl. the bridge's idempotent 404) clears
    /// it, a network failure leaves it for the next drain (enqueue or the next list pull).
    private func drainSessionDeletions() {
        guard configStore.isConfigured else { return }
        let store = sessionDeletionStore
        let cli = makeClient(configStore.config)
        Task {
            for item in store.pending {
                do {
                    try await cli.deleteConversation(item.conversationId)
                    store.remove(item.conversationId)
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
        guard let cid = thread.conversationId, !cid.isEmpty else { return }
        let write = FlagWrite(value: thread.isFavorite, updatedMs: thread.favoriteUpdatedMs)
        let cli = makeClient(configStore.config)
        Task { try? await cli.setFlags(conversationId: cid, favorite: write, archived: nil) }
    }

    /// Optimistic best-effort push of a just-toggled ARCHIVE up. Mirror of
    /// `pushFavoriteChange`; same self-healing best-effort semantics.
    func pushArchivedChange(for thread: JesseThread) {
        guard let cid = thread.conversationId, !cid.isEmpty else { return }
        let write = FlagWrite(value: thread.isArchived, updatedMs: thread.archivedUpdatedMs)
        let cli = makeClient(configStore.config)
        Task { try? await cli.setFlags(conversationId: cid, favorite: nil, archived: write) }
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
