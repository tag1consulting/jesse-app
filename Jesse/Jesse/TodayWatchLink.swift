import Foundation
import JesseCore
import JesseNetworking
import JesseTodayDisplay

// The phone half of Today-on-the-wrist: one small object that turns the day model's
// snapshot into a pushed context, and turns a wrist intent back into an ordinary
// check on THAT SAME MODEL.
//
// The sameness is the whole design. A wrist check that reached the bridge on its own
// would be a second implementation of the ETag handling, the optimistic overlay, the
// re-key after a move and the `410`/`412`/`428` recovery — and the second one is
// always the one that writes to a document nobody is looking at. So the intent
// arrives, and then it is just `TodayDashboardModel.check(id:checked:)`, exactly as
// if a thumb had hit the box on the phone.
//
// It holds NO WatchConnectivity. `push` is a closure the shell fills in with
// `PhoneWatchConnectivity.shared.pushToday`, which is what lets the tests drive the
// whole thing — snapshot in, summary out, intent in, mutation out — with no session,
// no paired watch and no simulator.

@MainActor
final class TodayWatchLink {
    nonisolated deinit {}

    private let model: TodayDashboardModel
    private let pending: (any PendingIntentStoring)?
    private let push: (WatchTodaySummary) -> Void
    private let now: () -> Date

    /// Intents already applied. `transferUserInfo` REDELIVERS, and without this a
    /// queued intent arriving twice would re-tick an item the user has since
    /// unticked. Bounded, like the chat wire's dedup: the window only has to cover a
    /// redelivery burst, not all history.
    private var applied = ReplyDeduper(capacity: 64)

    init(model: TodayDashboardModel,
         pending: (any PendingIntentStoring)? = nil,
         push: @escaping (WatchTodaySummary) -> Void,
         now: @escaping () -> Date = { Date() }) {
        self.model = model
        self.pending = pending
        self.push = push
        self.now = now
    }

    /// Push the day as it currently stands. A no-op before the first successful load
    /// — there is nothing to say yet, and an empty context would look to the watch
    /// exactly like a day with no work in it.
    ///
    /// It pushes the SERVER's snapshot, never the optimistic overlay: the watch keeps
    /// its own pending claims, and a phone that pushed its optimism too would be
    /// telling the wrist a claim had settled when it had not.
    func pushCurrent() {
        guard let snapshot = model.serverSnapshot else { return }
        push(TodayWatchSummary.build(from: snapshot, etag: model.etag, at: now(),
                                     queuedIds: queuedIds))
    }

    /// The ids this phone is HOLDING a check for, so the wrist can say `queued` rather
    /// than `pending`.
    ///
    /// Without this the watch has no way to learn the difference. It cannot ask the
    /// bridge, so its only evidence is the pushed summary — and a summary built from the
    /// server's snapshot looks identical whether the phone sent the check and is waiting,
    /// or is sitting on it with no network at all. The claim would stay `pending`
    /// forever, which is the wrist being told a lie by omission.
    ///
    /// The watch's own `queued` (it could not reach the PHONE) and this one (the phone
    /// could not reach the BRIDGE) mean the same thing to the person wearing it: it is
    /// saved, and it has not gone yet.
    private var queuedIds: Set<String> {
        guard let pending else { return [] }
        return Set(pending.outstanding()
            .filter { $0.state == .queued || $0.state == .replaying }
            .compactMap(\.itemId))
    }

    /// Apply one wrist intent, then confirm it.
    ///
    /// The confirming push is the watch's only way to learn the check landed — it
    /// cannot ask the bridge — so it follows the mutation immediately rather than
    /// waiting for whenever the phone next polls. That is also why it pushes on the
    /// unhappy paths: a `410` (the row left the day file) or a refused write still
    /// leave the wrist holding a claim, and the honest answer to that claim is the
    /// day as it now really is.
    func apply(_ check: WatchTodayCheck) async {
        guard applied.shouldDeliver(check.intentId) else {
            Log.run.notice("watch today: intent \(check.intentId) already applied, ignoring redelivery")
            return
        }
        // THE SECOND DE-DUPER, and the one that survives a kill. `applied` is in memory,
        // so a relaunch empties it — and `transferUserInfo` redelivers across exactly
        // that boundary. The queue is on disk and keyed by the watch's OWN `intentId`, so
        // a redelivered intent whose capture is still held is recognised as the same one
        // rather than queued twice.
        if let pending, pending.all().contains(where: { $0.id == check.intentId }) {
            Log.run.notice("watch today: intent \(check.intentId) is already queued, ignoring redelivery")
            pushCurrent()
            return
        }
        // An intent can arrive before this phone has ever read the day — a queued
        // check redelivered after a relaunch. With no ETag in hand `check` would do
        // nothing but fetch one and return, silently dropping the wrist's tap.
        if model.etag == nil { await model.load() }
        await model.check(id: check.itemId, checked: check.checked,
                          intentId: check.intentId)
        pushCurrent()
    }
}
