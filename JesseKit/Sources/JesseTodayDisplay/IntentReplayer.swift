import Foundation
import JesseCore
import JesseNetworking

// **The replay half of the offline capture queue**, and the file where every refusal
// rule lives.
//
// ## The one question this whole file answers
//
// Is the thing this change was about still the thing it was about? `Today.md` is
// rewritten in full every morning, so "yes" is not something the app may assume. It has
// to be established, per intent, against the day the bridge is holding right now — and
// when it cannot be, the answer is a refusal the user can see and act on, never a write
// aimed at a line nobody chose.
//
// Three checks, in order, and each one is a different way the answer can be no:
//
//  1. **The day.** `dayDate` against the live snapshot's `date`. Same day → the id is
//     still authoritative. Different day → the document was rebuilt, so the id proves
//     nothing and step 2 takes over.
//  2. **The identity.** On a rebuilt day, the change is re-found by its WORDS
//     (`TodayLeadMatch`) among the items that are still OPEN, and only when exactly one
//     matches. No match, or several, refuses.
//  3. **The bridge's own guard.** Every replayed write carries `day`, so the bridge
//     refuses with `409 day-mismatch` if the file rolled between our fetch and our write
//     (bridge 0.96.0). That race is small and real, and closing it client-side alone
//     would be closing it with a check we know can go stale.
//
// ## Why one at a time, and never beside a live tap
//
// Every write here carries an `If-Match`, and every write invalidates the previous
// ETag. Two replays in flight together would guarantee that one of them gets a `412`;
// a replay racing the user's own tap would guarantee the same for whichever lost. So
// the whole run is serialized behind one flag, and the flag is what `isReplaying`
// reports so a screen can say the queue is draining.

/// What a replay needs from the world beside the day model: a way to send a Tell.
///
/// A seam rather than a `RunCoordinator` reference, because `RunCoordinator` lives in
/// the iOS app target and this file must compile for the Mac and for a test host with
/// no SwiftData and no conversations. The conformer in the app creates the thread, the
/// user turn and the outbox row exactly as the composer does.
@MainActor
public protocol IntentTellSending: AnyObject {
    /// Send `text` as a Tell on a FRESH thread, and answer whether the bridge accepted
    /// it (a `202`, or the legacy inline `200`).
    ///
    /// `false` must mean "not delivered". A quick-log replay stops at the first `false`
    /// so a day's meals cannot arrive out of order, and a conformer that answered
    /// optimistically would break that ordering rather than merely mis-report.
    func sendTell(_ text: String) async -> Bool
}

/// The outcome of replaying one intent. Returned so a caller (and a test) can see what
/// happened without reading the store back.
public enum IntentReplayOutcome: Equatable, Sendable {
    /// The bridge took it.
    case applied
    /// It cannot be applied, and here is why in the user's words.
    case refused(String)
    /// Nothing was attempted — no network, no day, or the run was cut short. The intent
    /// stays queued.
    case deferred
}

/// Replays the offline capture queue, oldest first.
@MainActor
public final class IntentReplayer {
    nonisolated deinit {}

    private let store: any PendingIntentStoring
    private let day: TodayDashboardModel
    private let makeClient: @MainActor () -> any TodayProviding
    private let tell: (any IntentTellSending)?
    /// The live diet day, for the two Health kinds. `nil` when the app has not loaded a
    /// diet snapshot, which is a reason to defer rather than to refuse: not knowing what
    /// day it is is not evidence that the day changed.
    private let dietDay: @MainActor () -> String?
    private let now: @MainActor () -> Date

    /// Whether a run is in progress. One at a time — see the file note.
    public private(set) var isReplaying = false

    public init(store: any PendingIntentStoring,
                day: TodayDashboardModel,
                makeClient: @escaping @MainActor () -> any TodayProviding,
                tell: (any IntentTellSending)? = nil,
                dietDay: @escaping @MainActor () -> String? = { nil },
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.store = store
        self.day = day
        self.makeClient = makeClient
        self.tell = tell
        self.dietDay = dietDay
        self.now = now
    }

    /// **Replay everything held, oldest first.**
    ///
    /// Idempotent and never throwing, because of where it is called from: a network
    /// recovery that also has to re-attach in-flight jobs and drain the send outbox, and
    /// which cannot be blocked or broken by this one.
    ///
    /// A re-entrant call is a no-op rather than a second run — the recovery paths
    /// deliberately overlap (a path event, an app activation and a successful fetch can
    /// all land within a second of each other) and two runs would race each other's
    /// ETags.
    @discardableResult
    public func replayAll() async -> [IntentReplayOutcome] {
        guard !isReplaying else { return [] }
        isReplaying = true
        defer {
            isReplaying = false
            store.prune(now: now())
            day.refreshPending()
        }

        var outcomes: [IntentReplayOutcome] = []
        // Read the work list ONCE, up front. Re-reading between intents would pick up
        // anything captured during the run — a tap made while the queue drains — and
        // replay it immediately against state it was not made against.
        let work = store.replayable()
        for intent in work {
            let outcome = await replay(intent)
            outcomes.append(outcome)
            day.refreshPending()
            // A deferred intent means the world stopped answering (no network, no day).
            // Everything after it would defer too, and each attempt costs a round trip
            // into a void.
            if outcome == .deferred { break }
        }
        return outcomes
    }

    /// Replay exactly one. Public so a per-row Retry can act now rather than wait for
    /// the next recovery.
    @discardableResult
    public func replay(_ intent: PendingIntentRecord) async -> IntentReplayOutcome {
        mark(intent, state: .replaying)
        let outcome: IntentReplayOutcome
        switch intent.kind {
        case .check, .uncheck, .defer, .undefer, .move:
            outcome = await replayDayFileWrite(intent)
        case .quickLog:
            outcome = await replayQuickLog(intent)
        case .startNewDay:
            outcome = await replayStartNewDay(intent)
        case .processUpdates:
            // Never captured (see `PendingIntentKind.processUpdates`); a row of this
            // kind can only have come from a build that did capture it, and running a
            // hours-old batch against today's ticked items is exactly what must not
            // happen.
            outcome = .refused(Self.processUpdatesNotice)
        }
        settle(intent, outcome)
        return outcome
    }

    // MARK: - The day-file kinds

    private func replayDayFileWrite(_ intent: PendingIntentRecord) async -> IntentReplayOutcome {
        guard let itemId = intent.itemId else { return .refused(Self.noItemNotice) }
        let client = makeClient()
        // FETCHED PER INTENT, not once for the run. Every write invalidates the ETag it
        // used, so a second intent carrying the first one's tag would earn a `412` by
        // construction — and the day it is judged against must be the day it is written
        // to, not the day the run started on. A run that straddles the morning rebuild is
        // exactly when that matters.
        guard let live = await fetch(client) else { return .deferred }
        guard let etag = live.etag, !etag.isEmpty else { return .deferred }

        let sameDay = (live.date ?? "") == intent.dayDate
        // THE RESOLUTION RULE. On the same day the id is still authoritative — it is a
        // hash of content the rebuild has not touched. On a different day it proves
        // nothing, and the words are the only handle left.
        let targetId: String
        let sendDay: String
        if sameDay {
            guard live.item(id: itemId) != nil else { return .refused(Self.goneNotice) }
            targetId = itemId
            sendDay = intent.dayDate
        } else {
            guard intent.kind != .move else { return .refused(Self.movedOnNotice) }
            guard let lead = intent.leadText,
                  let match = TodayLeadMatch.resolve(lead: lead, in: live)
            else { return .refused(Self.notFoundNotice) }
            targetId = match.id
            // The LIVE day, not the captured one: the write is being made against the
            // document in front of us, and claiming otherwise would earn the bridge's
            // own `409` for a request we know is about today.
            sendDay = live.date ?? ""
        }

        return await send(intent, itemId: targetId, day: sendDay, ifMatch: etag,
                          client: client, allowRefetch: true)
    }

    /// One write, with exactly one refetch-and-retry for a `412`.
    ///
    /// One, not a loop, and the second failure REFUSES rather than deferring. A stale
    /// ETag means something else wrote between our fetch and our write; losing that race
    /// twice in a row means an agent is mid-turn on the day file, and a queue that
    /// quietly went round again would be an invisible retry loop the user could neither
    /// see nor stop. A refused row is visible and carries a Retry, which is the same
    /// behaviour made honest.
    private func send(_ intent: PendingIntentRecord, itemId: String, day sendDay: String,
                      ifMatch: String, client: any TodayProviding,
                      allowRefetch: Bool) async -> IntentReplayOutcome {
        let result: TodayMutationResult
        do {
            result = try await call(intent, itemId: itemId, day: sendDay,
                                    ifMatch: ifMatch, client: client)
        } catch {
            // Transport again. The queue is exactly the right place for it to sit.
            return .deferred
        }

        switch result {
        case .snapshot:
            return .applied
        case .itemGone:
            return .refused(Self.goneNotice)
        case .preconditionFailed:
            guard allowRefetch else { return .refused(Self.busyNotice) }
            guard let live = await fetch(client), let etag = live.etag, !etag.isEmpty
            else { return .deferred }
            // The refetch may have landed on a NEW day, which changes the answer rather
            // than merely the tag — so the whole decision is re-made rather than the tag
            // swapped underneath it.
            guard (live.date ?? "") == sendDay, live.item(id: itemId) != nil else {
                return .refused(Self.movedUnderUsNotice)
            }
            return await send(intent, itemId: itemId, day: sendDay, ifMatch: etag,
                              client: client, allowRefetch: false)
        case .preconditionRequired:
            // We sent no tag at all — a client bug, not a race. Leave it queued rather
            // than burn the intent on it.
            return .deferred
        case .conflict(let message):
            if let mismatch = result.dayMismatch { return .refused(mismatch.notice) }
            return .refused(message.isEmpty ? Self.conflictNotice : message)
        }
    }

    private func call(_ intent: PendingIntentRecord, itemId: String, day sendDay: String,
                      ifMatch: String, client: any TodayProviding)
        async throws -> TodayMutationResult {
        // `at` is the moment the USER acted, never now. That is the whole reason the
        // capture stored it: the bridge stamps `app-completed` from this, and a replayed
        // check that carried the replay's clock would write a lie into the vault.
        let at = intent.createdAt
        switch intent.kind {
        case .check, .uncheck:
            return try await client.checkItem(id: itemId, checked: intent.kind == .check,
                                              evidence: intent.payload.evidence,
                                              at: at, day: sendDay, ifMatch: ifMatch)
        case .defer, .undefer:
            return try await client.postpone(id: itemId, deferred: intent.kind == .defer,
                                             at: at, day: sendDay, ifMatch: ifMatch)
        case .move:
            let op = Self.moveOp(intent.payload) ?? .topOfSection
            return try await client.moveItem(id: itemId, op: op, at: at,
                                             day: sendDay, ifMatch: ifMatch)
        default:
            return .conflict(Self.conflictNotice)
        }
    }

    /// Rebuild a stored move op. An unrecognized op is `nil` rather than a guess.
    nonisolated static func moveOp(_ payload: PendingIntentPayload) -> TodayMoveOp? {
        switch payload.moveOp {
        case "top_of_section": return .topOfSection
        case "to_do_now": return .toDoNow
        case "up": return .up
        case "down": return .down
        case "to_section":
            guard let section = payload.moveSection, !section.isEmpty else { return nil }
            return .toSection(section)
        default: return nil
        }
    }

    // MARK: - The Health kinds

    /// A quick log replays as a Tell, always — there is no day-file identity to lose.
    ///
    /// It carries a leading `(eaten at <RFC3339 with offset>)` stamp, which the diet
    /// pipeline treats as AUTHORITATIVE (`eaten_at_stamp` in the bridge), so a lunch
    /// logged on a boat at 13:10 and sent at 19:00 is still dated 13:10 — and, past the
    /// 04:00 diet-day boundary, still lands on the right DAY. That is why a quick log
    /// needs no day guard: the stamp carries the day inside it.
    private func replayQuickLog(_ intent: PendingIntentRecord) async -> IntentReplayOutcome {
        guard let tell else { return .deferred }
        guard let text = intent.payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return .refused(Self.emptyLogNotice) }
        let stamped = "(eaten at \(intent.createdAtStamp)) " + text
        // Deferred, not refused, when the send does not land: nothing about the log has
        // become untrue, so it waits. `replayAll` stops the run here, which is what keeps
        // a day's meals in the order they were eaten.
        return await tell.sendTell(stamped) ? .applied : .deferred
    }

    /// Start-new-day replays only if the day has not already rolled.
    ///
    /// The routine audits yesterday and builds today. Running it after the roll it was
    /// queued to cause would audit the day it was supposed to open — so a queued one
    /// whose day has passed is refused, silently in the sense that it needs no action
    /// from the user: the morning it was for has already happened.
    private func replayStartNewDay(_ intent: PendingIntentRecord) async -> IntentReplayOutcome {
        guard let tell else { return .deferred }
        // Not knowing the diet day is not evidence that it changed.
        guard let live = dietDay() else { return .deferred }
        guard live == intent.dayDate else { return .refused(Self.dayRolledNotice) }
        return await tell.sendTell(HealthNewDay.prompt) ? .applied : .deferred
    }

    // MARK: - Store bookkeeping

    private func fetch(_ client: any TodayProviding) async -> TodaySnapshot? {
        // UNCONDITIONAL. A conditional fetch would answer `304` and hand back no
        // document, and a replay that has to compare a date and re-find a lead needs the
        // document rather than a promise that it has not changed.
        guard let result = try? await client.getToday(ifNoneMatch: nil) else { return nil }
        guard case .snapshot(let snapshot) = result else { return nil }
        return snapshot
    }

    private func mark(_ intent: PendingIntentRecord, state: PendingIntentState) {
        var next = intent
        next.state = state
        store.update(next)
    }

    private func settle(_ intent: PendingIntentRecord, _ outcome: IntentReplayOutcome) {
        var next = intent
        switch outcome {
        case .applied:
            next.state = .applied
            next.refusalReason = nil
            next.attempts += 1
        case .refused(let reason):
            next.state = .refused
            next.refusalReason = reason
            next.attempts += 1
            // The day must stop claiming a change that did not happen. The pending row
            // survives with its reason and its Tell-Jesse fallback; only the optimism
            // goes.
            if let itemId = next.itemId { day.settleOptimism(itemId: itemId) }
        case .deferred:
            next.state = .queued
        }
        store.update(next)
    }

    // MARK: - What a refusal says

    static let goneNotice =
        "That item isn't in the day file any more, so this couldn't be applied."
    static let notFoundNotice =
        "Today moved on; item not found."
    static let movedOnNotice =
        "The day was rebuilt, so there was nothing left to reorder."
    static let movedUnderUsNotice =
        "The day file changed while this was being sent, so it wasn't applied."
    static let dayRolledNotice =
        "The day had already started without this, so it wasn't run again."
    static let busyNotice =
        "The day file was being rewritten while this was sent, so it wasn't applied."
    static let conflictNotice =
        "The bridge refused this change."
    static let noItemNotice =
        "This was saved without an item to apply it to."
    static let emptyLogNotice =
        "This log was saved empty, so there was nothing to send."
    static let processUpdatesNotice =
        "Process updates can't be replayed — run it again from the day."
}

// MARK: - The fallback that loses nothing

public extension PendingIntentRecord {
    /// **The sentence a refused check offers to send instead.**
    ///
    /// This is what keeps a refusal from being a loss. The app cannot find the line any
    /// more, but the agent can: it reads the vault, it knows what yesterday held, and a
    /// plain sentence naming the task, the day and the hour is enough for it to close
    /// the thing at source. So the refusal comes with a button rather than an apology.
    ///
    /// `nil` for the kinds where there is nothing to say — an un-check, a postponement
    /// and a move are all decisions about a day that has since been rebuilt, and asking
    /// the agent to un-do something on a document that no longer exists would be asking
    /// it to guess.
    var tellFallback: String? {
        guard kind == .check, let lead = leadText, !lead.isEmpty else { return nil }
        return "I completed \"\(lead)\" on \(dayDate) at \(createdAtClock) (logged offline)"
    }
}
