import Foundation
import SwiftData
import Observation
import JesseCore
import JesseNetworking
import JesseVault

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

// MARK: - Stream liveness

/// When anything last arrived on a turn's stream, and whether the watchdog has given up on it.
///
/// A class because two tasks share it — the task reading the stream and the watchdog timing it —
/// and a local `var` cannot be shared. Main-actor, like everything else the coordinator touches,
/// so both tasks read and write it on one actor and no lock is needed.
@MainActor
private final class StreamTicker {
    /// The last time ANY byte arrived: a frame, or one of the bridge's keep-alive comments.
    private(set) var lastArrival = Date()
    private(set) var gaveUp = false

    func tick() { lastArrival = Date() }
    func giveUp() { gaveUp = true }
}

// MARK: - Coordinator

/// One conversation's running turn: everything that used to be a single app-wide slot.
///
/// Nothing here is persisted. The Mac has no send outbox and does not re-attach a job after a
/// relaunch (the phone's `InFlightJob` does, and is stored for that reason); a turn this Mac
/// loses is recovered by hydrating the conversation, not by resuming the stream.
struct MacTurnRun: Equatable {
    /// Whether the bridge has ACCEPTED this turn (its 202 came back), as opposed to the POST
    /// still being in flight. A spinner covers both, which is why the delivery caption reads
    /// `phase` instead.
    var accepted = false
    /// Live assistant text for this turn (a `reset` frame REPLACES it, a `delta` APPENDS).
    var streamingText = ""
    /// The current tool-activity LINE, already human ("Reading the vault…"), from
    /// `ToolActivity.displayLabel` — the same mapping the iOS app uses. Empty until this turn
    /// reports any activity.
    var activity = ""
}

/// App-scoped runner + sync. `@MainActor` (the UI binds to it and it mutates the
/// main-actor `ModelContext`); network calls hop off-main inside the `nonisolated`
/// client. Turns run CONCURRENTLY, one per conversation, exactly as they do on the phone —
/// the bridge has always accepted that, and the single slot this used to keep was what made
/// Send silently do nothing in every conversation but the busy one.
@MainActor
@Observable
final class MacCoordinator {
    let configStore: MacConfigStore

    /// Shared model list for the composer's per-conversation model picker (and available to any
    /// other model UI), so a slow/unreachable `/jesse/models` never blanks the switcher and every
    /// conversation renders the same list. Fetched lazily on first picker appearance.
    let modelList = MacModelListStore()

    /// The turns in flight, one entry per CONVERSATION — the phone's `RunCoordinator.inFlight`
    /// shape, and for the same reason.
    ///
    /// This used to be one global slot (`isRunning`, `activeThreadID`, `streamingText`,
    /// `activity`, `accepted`), which made a Mac that was answering one conversation unable to
    /// send in any other: the composer's gate was per conversation and staging's was global, so
    /// Send stayed live and silently did nothing. The bridge has run concurrent turns in
    /// different conversations since the phone started doing it; the single slot was this
    /// client's own limit, not the server's.
    private(set) var runs: [UUID: MacTurnRun] = [:]

    /// Per-conversation errors: a refused or failed TURN, reported in the conversation it
    /// belongs to. App-wide failures (the session list, a hydrate) stay in `lastError` below,
    /// because they belong to no single conversation.
    ///
    /// Separate from `lastError` because concurrent turns made one shared string wrong: a send
    /// that failed in one conversation would paint its error across every other, and would
    /// silence the delivery caption of a turn that was running perfectly well elsewhere.
    private(set) var errors: [UUID: String] = [:]

    /// Bumped every time a turn settles, in any conversation. Screens that reload when the
    /// agent has finished acting (the Today tab, whose turns rewrite `Today.md`) watch THIS
    /// rather than a global "is anything running" Bool: with turns overlapping, such a Bool can
    /// go from true to true and never report the settle in between.
    private(set) var settleCount = 0

    /// Last user-facing error that belongs to no one conversation (a session-list or hydrate
    /// failure). Cleared on the next successful round trip.
    var lastError: String?

    /// How long a live stream may be COMPLETELY silent — no frames and no keep-alive comments —
    /// before this Mac treats the connection as dead and resolves the turn by polling instead.
    ///
    /// 60 seconds is four missed keep-alives: the bridge's SSE responder comments every 15
    /// seconds, so a healthy stream is never quiet for this long. Injectable so the stall test
    /// runs in milliseconds.
    let streamStallWindow: TimeInterval

    /// How long the completion poll waits between attempts. One second in production; injectable
    /// only so the test that spends the poll's whole 600-attempt budget takes under a second.
    let pollSpacing: TimeInterval

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
    // ── THE OFFLINE ANSWER PATH, the phone's shape exactly, behind the same protocol. It
    //    answers "no" on a Mac with no vault folder and no usable model, which is what keeps
    //    this invisible until a folder is picked.
    let offline: any OfflineAnswering
    // ── THE PENDING OFFLINE REVIEW. The Mac has no send outbox — `OutboxItem` is an iOS-only
    //    entity and this store's schema deliberately does not carry it — so the smallest
    //    durable thing that fits is the EXCHANGES, keyed by conversation, in `UserDefaults`.
    //    They are rendered into a turn and sent the moment the bridge is reachable again.
    //    Injectable so a test uses a scratch suite.
    let reviewStore: PendingOfflineReviewStore
    // ── THE OFFLINE CAPTURE PATH, and its one asymmetry with the answer path above: it needs
    //    no model at all. A capture is a coordinated append to one file under `Inbox/`, so the
    //    only thing it asks of this Mac is the vault folder.
    let capture: InboxCaptureService

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

    /// Where this conversation's turn is between "typed" and "answered", or nil when nothing is
    /// running on `threadID`. Mirrors the phone's `RunCoordinator.phase`.
    func phase(_ threadID: UUID) -> TurnPhase? {
        guard let run = runs[threadID], errors[threadID] == nil else { return nil }
        return run.accepted ? .accepted : .sending
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

    /// Whether this Mac can currently reach the bridge, as `JesseVault` states it. Injected
    /// so a test drives the offline path without a network and without touching the one shared
    /// probe; production reads exactly that probe (`reachabilityState`).
    private let reachability: @MainActor () -> BridgeReachabilityState

    /// The store write, as one seam. Production is `try $0.save()`; a test injects a throw
    /// to drive the staging failure the composer's draft handoff has to survive — the phone
    /// has had this seam since the outbox landed, and the Mac's staging used to swallow its
    /// save with `try?`, which is why a failed stage there was invisible.
    private let save: @MainActor (ModelContext) throws -> Void

    init(configStore: MacConfigStore,
         makeClient: @escaping @MainActor (JesseConfig) -> any BridgeClientProtocol
            = { JesseBridgeClient(config: $0) },
         sessionDeletionStore: PendingSessionDeletionStore = PendingSessionDeletionStore(),
         offline: (any OfflineAnswering)? = nil,
         reviewStore: PendingOfflineReviewStore = PendingOfflineReviewStore(),
         reachability: @escaping @MainActor () -> BridgeReachabilityState
            = { MacCoordinator.reachabilityState() },
         capture: InboxCaptureService? = nil,
         streamStallWindow: TimeInterval = 60,
         pollSpacing: TimeInterval = 1,
         save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }) {
        // Resolved in the body, not in a default argument: the service's default is
        // main-actor-isolated and a default argument is evaluated off the actor.
        self.offline = offline ?? OfflineAnswerService.shared
        self.reviewStore = reviewStore
        self.reachability = reachability
        self.capture = capture ?? InboxCaptureService.shared
        self.configStore = configStore
        self.makeClient = makeClient
        self.sessionDeletionStore = sessionDeletionStore
        self.streamStallWindow = streamStallWindow
        self.pollSpacing = pollSpacing
        self.save = save
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

    /// Whether THIS conversation has a turn in flight. The only question the composer, the
    /// sidebar spinner and the empty-thread reaper ever mean.
    func isRunning(_ threadID: UUID) -> Bool { runs[threadID] != nil }

    /// Whether anything at all is in flight on this Mac. Deliberately rare: the answer is
    /// almost never what a screen wants, and reading it where `isRunning(_:)` was meant is the
    /// defect this whole change is about.
    var isRunning: Bool { !runs.isEmpty }

    /// This conversation's live assistant text, empty when it has none.
    func streamingText(for threadID: UUID) -> String { runs[threadID]?.streamingText ?? "" }

    /// This conversation's current activity line, empty when it has none.
    func activity(for threadID: UUID) -> String { runs[threadID]?.activity ?? "" }

    /// The error to show in this conversation: its own turn's, else the app-wide one.
    func error(for threadID: UUID) -> String? { errors[threadID] ?? lastError }

    /// Open this conversation's run slot. Its error goes with it: a send that is going out is
    /// the answer to whatever the last one said.
    private func beginRun(_ threadID: UUID) {
        runs[threadID] = MacTurnRun()
        errors[threadID] = nil
    }

    /// Close this conversation's run slot and report the settle. Never touches another
    /// conversation's, which is the whole point.
    private func endRun(_ threadID: UUID) {
        runs[threadID] = nil
        settleCount += 1
    }

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
        guard let composed = stage(text: text, thread: thread, context: context) else { return }
        await deliver(composed, mode: mode, thread: thread, context: context)
    }

    /// The COMPOSER's send: stages synchronously, then delivers in a detached task.
    ///
    /// It exists so the draft handoff happens in the same main-actor turn as the click or
    /// the Return key. `send` above is awaitable, which means its staging is a hop away from
    /// its caller, and a composer that cleared its text around an `await` is the shape of
    /// bug this whole change is about. Returns whether the message was DURABLY STAGED, which
    /// is the only condition on which the composer may clear itself.
    @discardableResult
    func stageAndSend(text: String, mode: JesseMode, thread: JesseThread,
                      context: ModelContext) -> Bool {
        // ── OFFLINE: this Mac may be able to answer the question from the vault folder
        //    it holds. Only from the COMPOSER — `send(text:mode:thread:context:)` above
        //    is what the morning routine and the Today actions fire, and those are turns
        //    the bridge owes an answer to, not questions.
        // ONE route call per send, for the reason the phone's carries: reachable is the
        // common case and must not pay for a bookmark resolution twice.
        if offlineRoute() == .onDevice {
            return stageAndAnswerOnDevice(text: text, mode: mode, thread: thread,
                                          context: context)
        }
        // ── NO CARRY HERE ANY MORE. What this Mac answered while the Studio was asleep used
        //    to ride this message as attached context, in memory, on one conversation, until
        //    something happened to be sent. It is persisted the moment the Mac answers now
        //    (`reviewStore`) and `deliver` sends it ahead of this message.
        guard let composed = stage(text: text, thread: thread, context: context) else {
            return false
        }
        Task { await deliver(composed, mode: mode, thread: thread, context: context) }
        return true
    }

    // MARK: - Capturing into the vault's Inbox

    /// Whether this composer offers a capture beside the ordinary send.
    func captureOffer() -> InboxCaptureOffer {
        capture.offer(reachability: reachability())
    }

    /// Write the composer's text into the vault's `Inbox/` on this Mac, and put it in the
    /// transcript.
    ///
    /// The Mac has no send outbox, which makes this the MORE valuable of the two paths here:
    /// an ordinary send with the Studio asleep reaches nothing and surfaces an error, while a
    /// capture is on disk before the button finishes animating.
    ///
    /// Returns whether the capture is durably in the vault — what the composer clears itself
    /// on. A refusal leaves the draft exactly where it was.
    @discardableResult
    func captureToInbox(text: String, thread: JesseThread,
                        context: ModelContext) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Per CONVERSATION, like every other gate here: a capture is a local write and a turn
        // running in another conversation has nothing to do with it.
        guard !trimmed.isEmpty, !isRunning(thread.id) else { return false }

        let outcome = await capture.capture(trimmed)
        guard case .success(let write) = outcome else {
            if case .failure(let failure) = outcome { errors[thread.id] = failure.description }
            return false
        }

        // A staged thread is not in the store until its first send. A capture is one.
        if thread.modelContext == nil { context.insert(thread) }
        errors[thread.id] = nil

        // The user's own half, then the local turn that says where it went. Two turns rather
        // than one: what they typed is theirs, and the badge is the app reporting back.
        let userTurn = Turn(role: .user, text: trimmed)
        userTurn.thread = thread
        context.insert(userTurn)
        let reply = Turn(role: .jesse, text: InboxCaptureReply.body(write))
        reply.thread = thread
        context.insert(reply)
        thread.updatedAt = Date()
        do {
            try save(context)
        } catch {
            // THE FILE IS ALREADY WRITTEN. A failed save loses the transcript's record of the
            // capture, not the capture — and the write log still holds it, which is why this
            // says so rather than inviting a second attempt that would append a second
            // identical line.
            errors[thread.id] = "Captured to \(write.relativePath), but this conversation couldn't be saved."
            return true
        }
        return true
    }

    // MARK: - Answering on this Mac

    /// This Mac's reachability, as `JesseVault` states it. One place, and the only place the
    /// two enums meet.
    static func reachabilityState() -> BridgeReachabilityState {
        switch BridgeReachabilityModel.shared.state {
        case .unknown: return .unknown
        case .reachable: return .reachable
        case .unreachable: return .unreachable
        }
    }

    private func offlineRoute() -> OfflineSendRoute {
        offline.route(reachability: reachability())
    }

    /// Stage the user's turn, then answer it from the copy of the vault on this Mac.
    ///
    /// `stage` is the ordinary one, so the optimistic turn, the draft release, the run
    /// gate and the spinner all behave exactly as they do for a bridge turn; only what
    /// happens after it differs.
    private func stageAndAnswerOnDevice(text: String, mode: JesseMode, thread: JesseThread,
                                        context: ModelContext) -> Bool {
        guard let composed = stage(text: text, thread: thread, context: context) else {
            return false
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.offline.answer(composed)
            await self.finishOnDevice(outcome, question: composed, mode: mode,
                                      thread: thread, context: context)
        }
        return true
    }

    /// Put this Mac's answer in the transcript, or hand the question to the ordinary send.
    ///
    /// THE MAC HAS NO SEND OUTBOX — the phone's `OutboxItem` is an iOS-only entity and
    /// this store's schema deliberately does not carry it. So "queued for the bridge" is
    /// not available here and is not claimed: a question this Mac cannot answer takes the
    /// ordinary send path, which reaches an unreachable bridge and surfaces its own error,
    /// which is precisely what it did before this feature existed.
    private func finishOnDevice(_ outcome: VaultAnswerOutcome, question: String,
                                mode: JesseMode, thread: JesseThread,
                                context: ModelContext) async {
        if case .answered(let answer) = outcome {
            // This conversation's run only. An on-device answer settles one turn; whatever the
            // bridge is doing for another conversation keeps its own slot and its own spinner.
            endRun(thread.id)
            let reply = Turn(role: .jesse,
                             text: OfflineLookupReply.body(.answered(answer), queued: false))
            reply.thread = thread
            context.insert(reply)
            thread.updatedAt = Date()
            try? save(context)
            // ── THE REVIEW, PERSISTED. An answered exchange is not a message the bridge owes
            // a reply to, but it is one the bridge has to see: the question was Jeremy's and
            // may be a request only the bridge can perform, and the answer is a 3B model's
            // unverified guess at it. It used to be an in-memory pair waiting for whatever
            // was sent next, so a quit lost it. It goes out by itself now, the moment this Mac
            // can reach the bridge (`sendPendingOfflineReviews`, and `deliver`'s own drain).
            //
            // AFTER the save, and appended even if that save threw: the review lives in
            // `UserDefaults` and cannot ride a SwiftData save, and of the two ways to be wrong
            // here — a review reporting an exchange whose reply turn did not persist, or a
            // request reaching nobody — only the second is the defect this exists to fix.
            reviewStore.append(OfflineAnswerPair(question: question, answer: answer.text,
                                                 paths: answer.citations.map(\.path)),
                               threadID: thread.id)
            return
        }
        // Both unanswered outcomes say so before the ordinary send takes over, and they
        // say DIFFERENT things, because "this device looked and did not find it" and
        // "this device never looked, because the question asks for a draft" are different
        // facts and a person who asked deserves the right one. Neither claims a queue:
        // there is none here, and `body` is told so.
        //
        // A not-a-lookup used to say nothing at all on this platform, which left a gate
        // refusal looking exactly like the bridge being down — the same confusion the
        // phone's "Queued for the bridge." caused, arrived at by silence instead.
        let note: Turn
        if case .unanswered(.gateRefused(let refusal)) = outcome {
            note = Turn(role: .jesse,
                        text: OfflineLookupReply.body(.notALookup(because: refusal.because),
                                                      queued: false))
        } else {
            note = Turn(role: .jesse,
                        text: OfflineLookupReply.body(.abstained, queued: false))
        }
        note.thread = thread
        context.insert(note)
        thread.updatedAt = Date()
        try? save(context)
        await deliver(question, mode: mode, thread: thread, context: context)
    }

    /// Persist the optimistic user turn (and spend the attachment and the draft) for a send,
    /// returning the COMPOSED text to transmit, or nil if the send was refused or could not
    /// be saved.
    ///
    /// Synchronous by design: everything that decides whether this message now exists —
    /// the guards, the run gate, the insert, the draft release, the save — happens before
    /// this function returns, so no caller can observe a half-staged send and no keystroke
    /// can land inside the handoff.
    private func stage(text: String, thread: JesseThread, context: ModelContext) -> String? {
        let attached = attachedContexts[thread.id]
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = attached.map { TodayThreadContext.firstMessage(context: $0.body, typed: text) }
            ?? typed
        // The gate is the SHARED one the composer's `canSend` reads, asked about THIS
        // conversation. It runs before the attachment is spent, so a refused send leaves the
        // context attached for the send that does go through — and leaves the composer's draft
        // untouched, since nothing below has run.
        //
        // And it SAYS WHY. A refusal that wrote nothing to the screen is the bug: an enabled
        // button, a pressed Return, and a message that stayed in the composer with no
        // explanation anywhere. The one silent refusal left is an empty composer, which is not
        // an error.
        if let refusal = MacSendGate.refusal(typed: text, hasAttachment: attached != nil,
                                             isConfigured: configStore.isConfigured,
                                             isRunningInThisConversation: isRunning(thread.id)) {
            if let message = refusal.message { errors[thread.id] = message }
            return nil
        }
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
        // ── The DRAFT IS NOT RELEASED HERE, and that is the ordering rule the two-store
        // design rests on: the turn is persisted FIRST, and the composer releases the draft
        // SECOND, only on a true return (see `MacThreadDetailView.send`). A save that
        // throws below therefore leaves the draft exactly where it was, with nothing to put
        // back. `ComposerDraftStaleness` closes the reverse window — a kill after this save
        // and before the release.
        //
        // Real error handling, not the `try?` this used to be. A staging save that fails is
        // the case where the user's message exists nowhere on disk, and swallowing it meant
        // going on to send a turn whose transcript might never persist — and, now, clearing
        // a composer whose text was the only remaining copy.
        do {
            try save(context)
        } catch {
            // The screen context goes back too. It was spent above on the assumption that
            // this send was going to happen; leaving it spent would mean the preserved
            // draft, sent again, went WITHOUT the reading the conversation was opened
            // about — the same message turning into a different one.
            attachedContexts[thread.id] = attached
            errors[thread.id] = "Couldn't save your message — try sending it again."
            return nil
        }

        beginRun(thread.id)
        // A staged send is a completed round trip with the local store, which is the one thing
        // that can take an app-wide "couldn't reach the Studio" off the screen from here.
        lastError = nil
        return trimmed
    }

    /// The network half of a send: this conversation's pending offline review first, if it has
    /// one, then the POST for `trimmed` — the composed text `stage` already persisted as the
    /// user turn.
    ///
    /// THE REVIEW GOES FIRST, and under the same run: a follow-up delivered ahead of the
    /// exchange it is about is the non sequitur this whole path exists to prevent, and the Mac
    /// has no outbox to order the two in. Every Mac send path goes through here, so the
    /// morning routine and the Today actions honour it too.
    private func deliver(_ trimmed: String, mode: JesseMode, thread: JesseThread,
                         context: ModelContext) async {
        // THIS conversation's slot, and nothing else's. The defer used to clear the app's one
        // slot, so the turn that finished first opened the gate for every conversation and
        // closed the spinner on turns that were still running.
        defer { endRun(thread.id) }
        if let review = stagePendingReview(thread: thread, context: context) {
            await post(review, mode: mode, thread: thread, context: context)
        }
        await post(trimmed, mode: mode, thread: thread, context: context)
    }

    /// One POST and whatever it turns into. Split out of `deliver` so a conversation's pending
    /// review and the message behind it are two posts inside ONE run, rather than two runs
    /// whose spinners and error lines fight each other.
    private func post(_ trimmed: String, mode: JesseMode, thread: JesseThread,
                      context: ModelContext) async {
        let cli = client
        // The PER-TURN model this conversation sends on: its own stored selection, else this
        // device's default (`LastUsedModelStore`). Local to this Mac and this thread — it never
        // mutates the bridge's global default, so the phone is unaffected. nil → bridge default.
        let model = thread.selectedModelID ?? LastUsedModelStore.id
        // The thread's EFFORT, sent only alongside its own model (`ModelMenuAction`), so a thread
        // riding this Mac's default model never carries an effort chosen on another one.
        let effort = ModelMenuAction.effortToSend(threadModelID: thread.selectedModelID,
                                                  threadEffort: thread.selectedEffort)
        // The thread identity, sent on every turn. The Mac has no outbox to reuse a request id
        // from, so it keeps generating one per attempt; identity is carried by the conversation.
        let conversationId = thread.conversationId ?? JesseThread.mintConversationId()
        if thread.conversationId != conversationId { thread.conversationId = conversationId }
        do {
            let result = try await cli.send(
                mode: mode, text: trimmed, sessionId: thread.sessionId,
                conversationId: conversationId,
                voice: false, instructions: nil, floorOverride: nil,
                attachments: [], requestId: UUID().uuidString, model: model,
                effort: effort)
            // Adopt the AUTHORITATIVE id the bridge registered and stamp the first ACK, which
            // is what the detail view's delivery caption reads.
            adoptRegistration(thread: thread, conversationId: result.conversationId)
            switch result {
            case let .reply(reply, _, _):
                await finalize(thread: thread, reply: reply, streamedText: nil,
                               context: context, client: cli)
            case let .running(jobId, _):
                runs[thread.id]?.accepted = true
                await runStream(jobId: jobId, thread: thread, context: context, client: cli)
            }
        } catch {
            errors[thread.id] = Self.friendly(error)
        }
    }

    /// Stage this conversation's pending offline review as a turn and return its text, or nil
    /// when there is nothing pending or nowhere to send it.
    ///
    /// REACHABLE ONLY. A review staged against a bridge that is not there would be spent (the
    /// store is cleared on a durable stage) on a POST that cannot land, and this Mac has no
    /// outbox to hold it — so the exchanges stay where they are until there is somewhere for
    /// them to go. That is also why `finishOnDevice`'s own fall-through to `deliver`, which
    /// runs while unreachable by definition, never spends one.
    ///
    /// The turn is a user turn with an EMPTY typed half and the review's label, exactly as on
    /// the phone: the transcript shows that this went out and what it was, and never claims
    /// Jeremy typed it.
    private func stagePendingReview(thread: JesseThread, context: ModelContext) -> String? {
        guard reachability() == .reachable else { return nil }
        let pairs = reviewStore.pairs(threadID: thread.id)
        guard let body = OfflineAnswerCarry.body(pairs) else {
            // Nothing pending, or pairs that render to nothing — either way this conversation
            // owes no review, and a store entry that renders to nothing would be retried for
            // ever.
            if !pairs.isEmpty { reviewStore.clear(threadID: thread.id) }
            return nil
        }
        let turn = Turn(role: .user, text: body)
        turn.displayText = ""
        turn.contextLabel = OfflineAnswerCarry.title
        turn.thread = thread
        context.insert(turn)
        thread.updatedAt = Date()
        do {
            try save(context)
        } catch {
            // Nothing spent: the exchanges stay in the store for the next attempt.
            return nil
        }
        // Spent only on a durable stage, the rule the phone's outbox item follows too.
        reviewStore.clear(threadID: thread.id)
        return body
    }

    /// Send every conversation's pending offline review, with no new message from Jeremy.
    ///
    /// This is the Mac's half of "nothing said offline vanishes": the phone has an outbox and a
    /// retry schedule that deliver a review by themselves, and this is what stands in for them
    /// here. Called when reachability turns `.reachable` (see `MacRootView`), which on a laptop
    /// is a lid opening, a network coming back, or the Studio waking up.
    func sendPendingOfflineReviews(context: ModelContext) {
        guard reachability() == .reachable else { return }
        for threadID in reviewStore.all.keys {
            // A conversation with a turn in flight is left for the next trigger: its own
            // `deliver` drains the review anyway, and staging a second turn into a running
            // conversation is how two spinners end up fighting.
            guard !isRunning(threadID),
                  let thread = fetchThread(threadID, context: context),
                  let review = stagePendingReview(thread: thread, context: context)
            else { continue }
            beginRun(threadID)
            Task { [weak self] in
                guard let self else { return }
                defer { self.endRun(threadID) }
                await self.post(review, mode: thread.modeValue, thread: thread, context: context)
            }
        }
    }

    /// One conversation by id. The reviews are keyed by id (they outlive the process), so this
    /// is how the drain finds the thread each one belongs to.
    private func fetchThread(_ id: UUID, context: ModelContext) -> JesseThread? {
        var d = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// How reading a turn's live stream ended.
    private enum StreamOutcome {
        /// A terminal frame arrived. `reply` nil with `failure` nil is a cancel, which keeps
        /// whatever had streamed.
        case terminal(reply: JesseReply?, failure: String?)
        /// The stream ended, or threw, with no terminal frame — the dropped-connection case.
        case dropped
        /// Nothing arrived at all for `streamStallWindow`, so the connection is treated as dead
        /// and abandoned. Resolved by polling, exactly as a dropped stream is.
        case stalled
    }

    private func runStream(jobId: String, thread: JesseThread, context: ModelContext,
                           client cli: any BridgeClientProtocol) async {
        switch await readStream(jobId: jobId, thread: thread, client: cli) {
        case let .terminal(reply, failure):
            if let failure {
                errors[thread.id] = failure
                return
            }
            // A `done` frame with an empty final response falls back to the live accumulator
            // (already badge-free); a cancel with no terminal reply keeps whatever streamed,
            // exactly as before.
            let streamed = runs[thread.id]?.streamingText ?? ""
            await finalize(thread: thread,
                           reply: reply ?? JesseReply(text: streamed, sessionId: nil),
                           streamedText: streamed, context: context, client: cli)
        case .dropped, .stalled:
            // Both are "this stream will not tell us how the turn ended" — the poll resolves
            // what actually happened to the job.
            await pollToCompletion(jobId: jobId, thread: thread, context: context, client: cli)
        }
    }

    /// Read `jobId`'s live stream into this conversation's run state, and say how it ended.
    ///
    /// The read runs in its OWN task so a watchdog can end it. A stream whose connection dies
    /// without closing — a lid shut, a Wi-Fi change, the Studio off the network — leaves the
    /// read suspended for as long as the stream session allows, which is a day by design
    /// (`JesseBridgeClient.streamingSession`, because an agent turn legitimately runs for
    /// hours). Before this, that day was also how long the conversation kept saying a reply was
    /// coming, and how long the global run slot stayed shut: the reported symptom that only a
    /// relaunch cleared.
    ///
    /// Silence is measurable because the bridge is never silent: its SSE responder comments
    /// every 15 seconds, and `streamItems` reports those comments as `alive` (the parser drops
    /// them as frames, correctly — they are not events). So nothing arriving for four keep-alive
    /// periods is evidence about the socket, not about the model, and the turn is resolved by
    /// polling instead. The day-long ceiling stays: a long turn is legitimate, a silent one is
    /// not.
    private func readStream(jobId: String, thread: JesseThread,
                            client cli: any BridgeClientProtocol) async -> StreamOutcome {
        let ticker = StreamTicker()
        let reader = Task { @MainActor () -> StreamOutcome in
            // The full terminal reply (text + session + structured provenance), so the model
            // badge chip survives the stream path exactly as it does on the poll path.
            var terminal: (reply: JesseReply?, failure: String?)?
            do {
                for try await item in cli.streamItems(jobId: jobId) {
                    ticker.tick()
                    guard case let .event(ev) = item else { continue }
                    switch ev {
                    case let .reset(s): self.runs[thread.id]?.streamingText = s
                    case let .delta(s): self.runs[thread.id]?.streamingText += s
                    case let .activity(a): self.runs[thread.id]?.activity = a.displayLabel
                    case let .done(reply): terminal = (reply, nil)
                    case let .failed(msg): terminal = (nil, msg)
                    case .cancelled: terminal = (nil, nil)
                    }
                }
            } catch {
                // Transport failure — the poll below resolves what happened to the job.
            }
            if let terminal { return .terminal(reply: terminal.reply, failure: terminal.failure) }
            return .dropped
        }

        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                let quiet = Date().timeIntervalSince(ticker.lastArrival)
                let remaining = self.streamStallWindow - quiet
                guard remaining > 0 else {
                    ticker.giveUp()
                    // Tearing the read down cancels the URL task with it (the stream's
                    // `onTermination`), so the dead socket is released rather than held for the
                    // rest of the day.
                    reader.cancel()
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }

        let outcome = await reader.value
        watchdog.cancel()
        // A terminal frame that DID arrive wins, even if the socket then went quiet before
        // closing: what the turn ended in is already known and a poll would only re-learn it.
        if case .terminal = outcome { return outcome }
        // Otherwise a cancelled read reports `dropped`, and the watchdog is the only thing that
        // knows whether that was a close or a silence. Both go to the poll.
        return ticker.gaveUp ? .stalled : outcome
    }

    private func pollToCompletion(jobId: String, thread: JesseThread, context: ModelContext,
                                  client cli: any BridgeClientProtocol) async {
        for _ in 0..<600 {  // ~10 min ceiling at the 1s production spacing
            if Task.isCancelled { return }
            do {
                switch try await cli.result(jobId: jobId) {
                case .running:
                    try? await Task.sleep(for: .seconds(pollSpacing))
                case let .done(reply):
                    await finalize(thread: thread, reply: reply, streamedText: nil,
                                   context: context, client: cli)
                    return
                case let .failed(msg):
                    errors[thread.id] = msg
                    return
                case .cancelled:
                    return
                case .expired:
                    errors[thread.id] = "That reply is no longer available on the bridge."
                    return
                }
            } catch {
                errors[thread.id] = Self.friendly(error)
                return
            }
        }
        // THE CEILING RAN OUT, and it used to run out in silence: the spinner stopped, no turn
        // was appended, and nothing on screen said the reply was still owed. The job itself is
        // fine — it is the bridge's, and a hydrate will bring its answer in.
        errors[thread.id] =
            "Still waiting on the bridge. The reply will appear when this conversation next syncs."
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
        // The account quota this turn refreshed, into the one store the picker and Settings
        // read. Mirrors the iOS `TurnWriter`.
        UsageStore.shared.apply(reply.provenance?.quota)
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
        // A REPLY ARRIVED, which `updatedAt` above cannot say on its own (the user's own
        // turns bump it too). The bridge's finalize time is preferred over this Mac's
        // clock so both sides of the unread comparison come off one clock; `0` means a
        // bridge too old to send it and the device clock stands in. Mirrors the iOS
        // `TurnWriter`, deliberately — the two must not drift on when a reply "arrived".
        thread.noteReply(atUnixMillis: reply.lastReplyMs > 0
                         ? Int(reply.lastReplyMs)
                         : JesseThread.unixMillis(Date()))
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
                    // A JESSE turn this Mac never saw — sent from the phone, or landed
                    // while this app was closed. It is a reply arriving, so it moves the
                    // unread stamp, dated by the TURN's own timestamp rather than now:
                    // hydration can carry history that is hours old, and `noteReply`'s
                    // max rule keeps an older one from pulling the stamp backwards.
                    if turn.roleValue == .jesse {
                        thread.noteReply(atUnixMillis: JesseThread.unixMillis(turn.createdAt))
                    }
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
            // When this conversation last replied, on the BRIDGE's clock, so a stub
            // adopted from the phone shows its dot without waiting to be opened.
            t.noteReply(atUnixMillis: Int(c.lastReplyMs))
            context.insert(t)
            await FlagReconciler.reconcile(
                thread: t,
                serverFavorite: c.favorite, serverFavoriteUpdatedMs: Int(c.favoriteUpdatedMs),
                serverArchived: c.archived, serverArchivedUpdatedMs: Int(c.archivedUpdatedMs),
                serverReadThroughMs: Int(c.readThroughMs),
                serverReadUpdatedMs: Int(c.readUpdatedMs),
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
            // A reply that landed on the phone shows its dot here from the list pull
            // alone. `max`, never assignment — see the phone's half.
            t.noteReply(atUnixMillis: Int(c.lastReplyMs))
            await FlagReconciler.reconcile(
                thread: t,
                serverFavorite: c.favorite, serverFavoriteUpdatedMs: Int(c.favoriteUpdatedMs),
                serverArchived: c.archived, serverArchivedUpdatedMs: Int(c.archivedUpdatedMs),
                serverReadThroughMs: Int(c.readThroughMs),
                serverReadUpdatedMs: Int(c.readUpdatedMs),
                client: cli)
        }

        // DELETE-LOCAL a thread the bridge tombstoned (deleted on the phone): remove it
        // (turns cascade) and clear its hydration cursor.
        for cid in plan.deleteLocalConversationIds {
            guard let t = byConversation[cid] else { continue }
            ComposerDraftStore.shared.delete(t.id)
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
                // The read mark resolves the same way, on its own clock — otherwise a merge
                // could revive a dot the user cleared on the copy that is not the oldest.
                // The reply stamp takes the max instead: both copies describe the same
                // conversation, so the later reply is simply the one that happened.
                if loser.readUpdatedMs > winner.readUpdatedMs {
                    winner.applyReadFromSync(loser.readThroughMs, updatedMs: loser.readUpdatedMs)
                }
                winner.noteReply(atUnixMillis: loser.lastReplyMs)
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
        Task { try? await cli.setFlags(conversationId: cid, favorite: write, archived: nil, read: nil) }
    }

    /// Optimistic best-effort push of a just-toggled ARCHIVE up. Mirror of
    /// `pushFavoriteChange`; same self-healing best-effort semantics.
    func pushArchivedChange(for thread: JesseThread) {
        guard let cid = thread.conversationId, !cid.isEmpty else { return }
        let write = FlagWrite(value: thread.isArchived, updatedMs: thread.archivedUpdatedMs)
        let cli = makeClient(configStore.config)
        Task { try? await cli.setFlags(conversationId: cid, favorite: nil, archived: write, read: nil) }
    }

    /// Optimistic best-effort push of a just-changed READ MARK up, so the phone's dot
    /// clears (or comes back) on its next sync. Mirror of `pushFavoriteChange`; same
    /// self-healing best-effort semantics. Call it only when the mark actually changed —
    /// this runs on every selection and every activation.
    func pushReadChange(for thread: JesseThread) {
        guard let cid = thread.conversationId, !cid.isEmpty else { return }
        let write = ReadWrite(throughMs: thread.readThroughMs, updatedMs: thread.readUpdatedMs)
        let cli = makeClient(configStore.config)
        Task { try? await cli.setFlags(conversationId: cid, favorite: nil, archived: nil, read: write) }
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
