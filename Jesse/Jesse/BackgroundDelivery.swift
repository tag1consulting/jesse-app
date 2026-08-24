import Foundation
import SwiftData
import UIKit
import JesseCore
import JesseNetworking

/// What a background wake-up produced, in the app's own vocabulary rather than UIKit's.
///
/// Separate from `UIBackgroundFetchResult` so the whole unit is testable without
/// `UIApplication`, and mapped at the `AppDelegate` boundary — the same shape as
/// `BackgroundTasking`, and for the same reason.
nonisolated enum BackgroundWorkOutcome: Equatable, Sendable {
    /// Something landed: a reply was written, or a snapshot was refreshed.
    case newData
    /// Nothing to do, or nothing changed. iOS reads this as "you did not need waking".
    case noData
    /// It was tried and it did not work. Reported honestly rather than as `noData`,
    /// because iOS budgets future wake-ups on what it is told.
    case failed
}

/// The work the app does when it is woken WITHOUT being opened: a push carrying a
/// finished turn, a push saying the day file moved, or a periodic refresh task.
///
/// # Why this exists
///
/// The app had no `UIBackgroundModes` at all. A reply that finished while the phone was
/// in a pocket sat on the laptop until the app was next opened; the only continuation was
/// the ~30s `beginBackgroundTask` grant, which covers a short turn and nothing else. The
/// push already carried the `job_id` — everything needed to fetch the reply was on the
/// device — and nothing was allowed to run and fetch it.
///
/// # Why it is a separate type and not code in the AppDelegate
///
/// Because the important properties are all about what happens on the SECOND wake-up. A
/// push can be delivered more than once for the same job; a `BGAppRefreshTask` can fire
/// while a push is still being handled. So delivery must be idempotent, and the way to be
/// sure of that is to write it where a test can send the same push twice.
///
/// Delivery goes through the SAME `TurnWriter` the foreground uses, so the idempotency is
/// not a second implementation: the writer keys on `JesseThread.lastDeliveredJobId` and a
/// re-delivery retries only the save.
@MainActor
final class BackgroundDelivery {
    // See `BackgroundRefreshCoordinator`: a MainActor-isolated synthesized deinit aborts
    // when a test host releases the object off the main actor.
    nonisolated deinit {}

    /// The wire keys a push carries. Named here so the sender's contract has one spelling
    /// on this side (see `bridge/src/apns.rs`).
    nonisolated enum PayloadKey {
        static let jobId = "job_id"
        static let prefetch = "prefetch"
    }

    /// What a push actually asked for, as a value.
    ///
    /// A push's `userInfo` is `[AnyHashable: Any]` — not `Sendable`, and the least
    /// trustworthy dictionary the app ever reads. Converting it to this at the delegate's
    /// synchronous entry means the untrusted shape is parsed in exactly one place, and
    /// nothing but a checked value ever crosses into the background work.
    nonisolated struct Payload: Sendable, Equatable {
        let jobId: String?
        let snapshots: [Snapshot]

        init(userInfo: [AnyHashable: Any]) {
            let raw = (userInfo[PayloadKey.jobId] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.jobId = (raw?.isEmpty == false) ? raw : nil
            self.snapshots = BackgroundDelivery.requestedSnapshots(userInfo[PayloadKey.prefetch])
        }

        init(jobId: String?, snapshots: [Snapshot]) {
            self.jobId = jobId
            self.snapshots = snapshots
        }

        /// Nothing this app build knows how to act on. Not an error — a push whose only
        /// content is an alert is a perfectly ordinary push.
        var isEmpty: Bool { jobId == nil && snapshots.isEmpty }
    }

    /// The snapshot names the bridge may ask for, and what each one fetches. An unknown
    /// name is IGNORED rather than treated as an error: the bridge is free to learn a
    /// third document before this app build does, and being woken for one is not a
    /// failure.
    nonisolated enum Snapshot: String, Sendable, Hashable {
        case today
        case diet
    }

    private let makeClient: @MainActor () -> (any JesseClientProtocol)?
    private let makeTodayClient: @MainActor () -> (any TodayProviding)?
    private let context: @MainActor () -> ModelContext?
    private let inFlightStore: InFlightStoring
    private let turnWriter: TurnWriter
    private let pushWatchSummary: @MainActor (WatchTodaySummary) -> Void
    private let now: @MainActor () -> Date
    /// The live coordinator, when the app's UI is actually running. Weak and optional
    /// because a push can launch the app straight into the background, where no scene has
    /// been built and there is no coordinator to tell — delivery must work either way.
    private weak var coordinator: RunCoordinator?

    init(makeClient: @escaping @MainActor () -> (any JesseClientProtocol)? = {
             let cfg = ConfigStore.load()
             return cfg.isConfigured ? JesseClient(config: cfg, snapshotCache: SnapshotCache.shared) : nil
         },
         makeTodayClient: @escaping @MainActor () -> (any TodayProviding)? = {
             let cfg = ConfigStore.load()
             return cfg.isConfigured
                 ? JesseBridgeClient(config: cfg, snapshotCache: SnapshotCache.shared) : nil
         },
         context: @escaping @MainActor () -> ModelContext? = {
             ModelContext(AppModelContainer.shared.container)
         },
         inFlightStore: InFlightStoring? = nil,
         turnWriter: TurnWriter? = nil,
         pushWatchSummary: @escaping @MainActor (WatchTodaySummary) -> Void = {
             PhoneWatchConnectivity.shared.pushToday($0)
         },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.makeClient = makeClient
        self.makeTodayClient = makeTodayClient
        self.context = context
        self.inFlightStore = inFlightStore ?? InFlightStore()
        self.turnWriter = turnWriter ?? TurnWriter()
        self.pushWatchSummary = pushWatchSummary
        self.now = now
    }

    /// Point this at the running coordinator so a background delivery also clears the
    /// in-memory run state (spinner, retained job, Live Activity) instead of leaving the
    /// UI to discover the reply on the next foreground poll.
    func attach(coordinator: RunCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - The one entry point

    /// Handle one remote notification. Does both halves when the payload carries both,
    /// concurrently — a scheduled-outcome push that also asks for a prefetch has a turn to
    /// fetch AND two documents to refresh, and the wake-up window is not long enough to do
    /// them one after the other politely.
    func handle(_ payload: Payload) async -> BackgroundWorkOutcome {
        guard !payload.isEmpty else { return .noData }
        async let reply: BackgroundWorkOutcome = {
            guard let jobId = payload.jobId else { return .noData }
            return await deliverReply(jobId: jobId)
        }()
        async let prefetched: BackgroundWorkOutcome = {
            guard !payload.snapshots.isEmpty else { return .noData }
            return await refresh(payload.snapshots)
        }()
        return Self.combine(await reply, await prefetched)
    }

    /// Convenience for a caller that still holds the raw `userInfo`.
    func handle(userInfo: [AnyHashable: Any]) async -> BackgroundWorkOutcome {
        await handle(Payload(userInfo: userInfo))
    }

    /// The periodic `BGAppRefreshTask`'s work: refresh both documents and re-attach to
    /// anything still in flight. Deliberately the same two operations the push path does,
    /// because the task exists for the case where no push arrived at all.
    func periodicRefresh() async -> BackgroundWorkOutcome {
        let jobs = inFlightStore.load()
        async let snapshots = refresh([.today, .diet])
        async let replies: BackgroundWorkOutcome = {
            var outcome = BackgroundWorkOutcome.noData
            for (_, job) in jobs {
                outcome = Self.combine(outcome, await deliverReply(jobId: job.jobId))
            }
            return outcome
        }()
        return Self.combine(await snapshots, await replies)
    }

    // MARK: - Delivering a finished reply

    /// Fetch one job's result and write it into its thread, exactly as the foreground
    /// does. Returns `.noData` for a turn that is still running (nothing to write yet, and
    /// no reason to tell iOS the wake-up was productive) and `.failed` for a fetch that
    /// could not complete.
    func deliverReply(jobId: String) async -> BackgroundWorkOutcome {
        guard let client = makeClient() else { return .noData }
        let jobs = inFlightStore.load()
        guard let entry = jobs.first(where: { $0.value.jobId == jobId }) else {
            // No persisted job for this id. Either it was already delivered (a second push
            // for the same turn — the common case, and not a failure) or it belongs to a
            // conversation this device has never held.
            return .noData
        }
        let threadID = entry.key
        let state: JesseResultState
        do {
            state = try await client.result(jobId: jobId)
        } catch {
            Log.push.error("background delivery: result fetch failed for \(jobId): \(error.localizedDescription)")
            return .failed
        }
        guard let context = context() else { return .failed }
        switch state {
        case .running:
            // Still working. Leave the job persisted so the foreground (or the next push)
            // picks it up; nothing has changed.
            return .noData
        case .done(let reply):
            let outcome = turnWriter.write(threadID: threadID, thread: nil, reply: reply,
                                           jobId: jobId, context: context)
            switch outcome {
            case .delivered(let saved), .alreadyDelivered(let saved):
                guard saved else {
                    // The reply is fetched but not persisted, and there is no in-memory
                    // turn out here to carry it — so KEEP the job and let the foreground
                    // re-check, which is what that path is for.
                    Log.push.error("background delivery: save failed for job \(jobId) — job retained for Re-check")
                    return .failed
                }
                settle(threadID: threadID, jobId: jobId, context: context)
                return .newData
            case .unresolvableThread, .empty:
                // Both are recoverable states the FOREGROUND surfaces with a Re-check
                // button. There is no UI out here to show one, so retain the job and let
                // the app do it when it is next opened.
                Log.push.error("background delivery: job \(jobId) not deliverable in the background (\(String(describing: outcome))) — retained")
                return .failed
            }
        case .failed, .expired, .cancelled:
            // A terminal non-success. Retain the job and leave it to the foreground: the
            // error banner, the Re-check affordance and the expired copy all live there,
            // and inventing a second delivery of a failure out here would mean two places
            // decide what a failed turn looks like.
            return .noData
        }
    }

    /// Drop a delivered job from every place that still thinks it is running: the
    /// persisted map, the outbox row it ACKed, and the live coordinator's run state.
    private func settle(threadID: UUID, jobId: String, context: ModelContext) {
        var jobs = inFlightStore.load()
        let requestId = jobs[threadID]?.requestId
        jobs[threadID] = nil
        inFlightStore.save(jobs)
        // The outbox row is normally deleted at ACK. It survives only when the app was
        // killed between the 202 and that delete — the same race `reconcile` resolves, by
        // the same rule: a persisted job carrying this request id means the ACK won.
        if let requestId {
            let descriptor = FetchDescriptor<OutboxItem>(
                predicate: #Predicate { $0.id == requestId })
            if let stale = try? context.fetch(descriptor) {
                for item in stale { context.delete(item) }
                try? context.save()
            }
        }
        // And tell the running app, if there is one, so the spinner stops and the Live
        // Activity ends rather than waiting for the next foreground poll to notice.
        coordinator?.noteBackgroundDelivery(threadID: threadID, jobId: jobId)
    }

    // MARK: - Prefetching the two browsable documents

    /// Refresh the named snapshots into `SnapshotCache`, and push the day to the wrist
    /// when it is one of them.
    ///
    /// The cache write is the CLIENT's, not this type's: `getToday` and
    /// `fetchDietSnapshot` each store their own response body when the client carries a
    /// cache, which is the one place the bridge's own bytes exist. Re-encoding a decoded
    /// snapshot here would be a second definition of the wire format — see `SnapshotCache`.
    func refresh(_ snapshots: [Snapshot]) async -> BackgroundWorkOutcome {
        var outcome = BackgroundWorkOutcome.noData
        for snapshot in snapshots {
            outcome = Self.combine(outcome, await refreshOne(snapshot))
        }
        return outcome
    }

    private func refreshOne(_ snapshot: Snapshot) async -> BackgroundWorkOutcome {
        switch snapshot {
        case .today:
            guard let client = makeTodayClient() else { return .noData }
            do {
                // Unconditional — no `If-None-Match`. A `304` would refresh nothing, and
                // the push exists precisely because the document is known to have changed.
                let result = try await client.getToday(ifNoneMatch: nil)
                guard case .snapshot(let day) = result else { return .noData }
                pushWatchSummary(TodayWatchSummary.build(from: day, etag: day.etag, at: now()))
                return .newData
            } catch {
                Log.push.error("background prefetch: today failed: \(error.localizedDescription)")
                return .failed
            }
        case .diet:
            guard let client = makeClient() else { return .noData }
            do {
                _ = try await client.fetchDietSnapshot(date: nil)
                return .newData
            } catch {
                Log.push.error("background prefetch: diet failed: \(error.localizedDescription)")
                return .failed
            }
        }
    }

    // MARK: - Pure helpers

    /// The snapshots a payload asked for. Unknown names are dropped, and a payload with no
    /// `prefetch` key (every push before bridge 0.95.0, and most after it) yields none.
    ///
    /// Pure and `static` so the parsing of a value that arrives from the network is tested
    /// directly, including the shapes it should refuse: a bare string, a number, a nested
    /// array. It is a push payload — the least trustworthy dictionary the app ever reads.
    nonisolated static func requestedSnapshots(_ raw: Any?) -> [Snapshot] {
        guard let names = raw as? [Any] else { return [] }
        var seen = Set<Snapshot>()
        var out: [Snapshot] = []
        for name in names {
            guard let string = name as? String, let snapshot = Snapshot(rawValue: string),
                  seen.insert(snapshot).inserted else { continue }
            out.append(snapshot)
        }
        return out
    }

    /// Fold two outcomes into the one this wake-up reports. `newData` wins over
    /// everything — something did land — and `failed` beats `noData`, so a wake-up where
    /// half the work broke is not reported to iOS as a quiet nothing.
    nonisolated static func combine(_ a: BackgroundWorkOutcome, _ b: BackgroundWorkOutcome) -> BackgroundWorkOutcome {
        if a == .newData || b == .newData { return .newData }
        if a == .failed || b == .failed { return .failed }
        return .noData
    }
}


extension BackgroundWorkOutcome {
    /// The UIKit answer a push completion handler wants. The mapping is the whole reason
    /// this app's own enum exists: `BackgroundDelivery` is testable without `UIApplication`
    /// because the translation happens here and nowhere inside it.
    var fetchResult: UIBackgroundFetchResult {
        switch self {
        case .newData: return .newData
        case .noData: return .noData
        case .failed: return .failed
        }
    }
}
