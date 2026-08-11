import Foundation
import Observation

// The wrist's Today reducer: it holds the last context the phone pushed, the local
// checks the user made that the phone has not answered yet, and the rows that
// result from laying the second over the first.
//
// Everything difficult about this screen comes from one fact: THE WATCH CANNOT ASK.
// It never talks to the bridge, so it has no way to learn whether a check landed —
// it can only say "I claimed this" and wait for the next application context to
// either agree with the claim or replace it. Every state below is one of the ways
// that wait can end, and each has a test on both platforms.
//
// The claim ledger is IN MEMORY ONLY. Nothing here is persisted: a relaunched watch
// asks WatchConnectivity for the retained application context and starts from what
// the phone last said, which is the only thing that was ever authoritative. A
// durable local ledger would be a promise about a day file the watch cannot see —
// `Today.md` is rewritten in full every morning — and the phone's own day model
// refuses to make that promise for the same reason.

/// Sends a check intent to the phone and reports pushed contexts. The conformer owns
/// the transport (application context in, reliable user-info out); the model only
/// needs reachability, for its "queued" copy.
@MainActor
protocol WatchTodaySending: AnyObject {
    var isReachable: Bool { get }
    /// The phone pushed a fresh day. Latest-wins, so this fires with whole
    /// summaries and never with deltas.
    var onTodayContext: ((WatchTodaySummary) -> Void)? { get set }
    func send(_ check: WatchTodayCheck)
}

@MainActor
@Observable
final class WatchTodayModel {
    // A @MainActor class's synthesized deinit is MainActor-isolated, and a unit-test
    // host releases the model off the main actor — which routes through the
    // isolated-deinit executor hop and aborts. Same guard the JesseKit models carry.
    nonisolated deinit {}

    /// How one row reads right now.
    enum RowState: Equatable {
        /// Open, and nothing local is claimed about it.
        case open
        /// The phone says it is ticked.
        case done
        /// Ticked (or unticked) here, sent, and not yet answered for.
        case pending
        /// Ticked here while the phone was unreachable. It is on the reliable queue
        /// and will go the moment the phone is back — never silently dropped, which
        /// is the same promise the watch's chat path makes.
        case queued
        /// A local check the phone confirmed by dropping the row from the day's open
        /// work. Kept as a receipt rather than letting the row vanish, because a row
        /// that disappears on tap reads exactly like a failure.
        case confirmed
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let lead: String
        let section: String
        let state: RowState

        var isLead: Bool { section.isEmpty }
        /// Whether the box is drawn ticked. A pending claim shows its INTENDED
        /// state, which is the whole point of showing it at all.
        var showsChecked: Bool {
            state == .done || state == .confirmed || state == .pending || state == .queued
        }
        var isSettled: Bool { state == .confirmed }
    }

    /// A local claim awaiting the phone's answer.
    private struct Claim: Equatable {
        let checked: Bool
        /// Whether it went onto the reliable queue rather than to a phone that was
        /// listening. Presentation only — both paths deliver.
        let queued: Bool
    }

    private(set) var summary: WatchTodaySummary?
    private var claims: [String: Claim] = [:]
    /// Rows that left the payload while a local check was outstanding, kept as
    /// receipts in the order they settled.
    private var receipts: [WatchTodayRow] = []

    private let sender: any WatchTodaySending
    private let now: () -> Date

    init(sender: any WatchTodaySending, now: @escaping () -> Date = { Date() }) {
        self.sender = sender
        self.now = now
        self.sender.onTodayContext = { [weak self] in self?.receive($0) }
    }

    // MARK: - What the view reads

    /// Whether a day has ever been pushed. A watch that has never heard from its
    /// phone shows an explanation, not an empty list.
    var hasDay: Bool { summary != nil }

    /// The day file's date, for the stale banner.
    var dayLabel: String? { summary?.date }

    /// **The stale guard.** A context the phone pushed more than eighteen hours ago
    /// is presented under a banner rather than as today's list.
    ///
    /// The failure this prevents is specific and quiet: the watch keeps the last
    /// application context across a relaunch and across a night with the phone in
    /// another room, so yesterday's Do Now list renders perfectly and looks current.
    ///
    /// **Stored, not computed**, and that is the whole difference between a guard
    /// that works and one that reads correctly and never fires. A computed property
    /// over `now()` changes its answer as time passes but publishes nothing, so
    /// SwiftUI has no reason to redraw and the banner stays hidden until something
    /// else happens to invalidate the view. Recomputed at the two moments that can
    /// change the answer — a fresh push, and the app becoming active — which between
    /// them cover every way a person actually meets this screen.
    private(set) var isStale = false

    /// Re-answer "is this still today's?" — called when the watch app becomes
    /// active.
    ///
    /// This is the moment that matters and the reason there is no timer: a wrist is
    /// glanced at, not watched, so the question is asked when the screen lights up.
    /// A repeating timer would spend battery to be right during the seconds nobody
    /// is looking.
    func refreshFreshness() { updateFreshness() }

    private func updateFreshness() {
        guard let pushedAt = summary?.pushedAt else {
            isStale = false
            return
        }
        // A future-dated context (the phone's clock ahead of the watch's) is odd,
        // not stale, and must not trip the banner.
        isStale = now().timeIntervalSince(pushedAt) > WatchTodayWire.staleAfter
    }

    /// The rows to draw: the payload's, with local claims folded in, then the
    /// receipts at the foot.
    var rows: [Row] {
        var out = (summary?.rows ?? []).map { row -> Row in
            Row(id: row.id, lead: row.lead, section: row.section, state: state(for: row))
        }
        out += receipts.map {
            Row(id: $0.id, lead: $0.lead, section: $0.section, state: .confirmed)
        }
        return out
    }

    /// Open work in the day that did not make the trip — the footer's number.
    ///
    /// Computed from the SERVER's counts and the SERVER's rows, never from the local
    /// claims: a footer that flickered on every tap would be reporting the watch's
    /// optimism back to the user as if it were the day.
    var moreOnPhone: Int {
        guard let summary else { return 0 }
        return max(0, summary.openCount - summary.rows.filter { !$0.checked }.count)
    }

    /// Ticked items across the whole day.
    var doneCount: Int { summary?.doneCount ?? 0 }

    /// Whether a local claim for this id is still outstanding.
    func isPending(_ id: String) -> Bool { claims[id] != nil }

    private func state(for row: WatchTodayRow) -> RowState {
        if let claim = claims[row.id] { return claim.queued ? .queued : .pending }
        return row.checked ? .done : .open
    }

    // MARK: - Checking off

    /// Tick or untick one row from the wrist.
    ///
    /// No evidence, by design: a note is a phone and Mac affordance, and an
    /// evidence-less check is fully valid downstream. What the watch owes the user is
    /// the fastest possible "done" and an honest account of whether it went.
    ///
    /// Rows that are already settled receipts are inert — re-checking something the
    /// phone has already accounted for would send an intent about a row that is no
    /// longer in the day's open work.
    func toggle(_ id: String) {
        guard let row = summary?.rows.first(where: { $0.id == id }) else { return }
        let current = claims[id]?.checked ?? row.checked
        let desired = !current
        let queued = !sender.isReachable
        claims[id] = Claim(checked: desired, queued: queued)
        sender.send(WatchTodayCheck(intentId: UUID(), itemId: id, checked: desired))
    }

    // MARK: - The phone's answer

    /// Adopt a pushed context and settle every claim it accounts for.
    ///
    /// A claim ends in exactly one of three ways, and getting these apart is the
    /// whole reducer:
    ///
    ///  * **Agreed** — the row is still on the wrist and now reads the way the user
    ///    left it. The claim retires and the row renders from the payload.
    ///  * **Confirmed by absence** — the row is gone, which for a ticked item is what
    ///    success looks like (a done item is no longer open Do Now work). It becomes
    ///    a receipt at the foot rather than vanishing under the finger.
    ///  * **Still disagreeing** — the row is there and still reads the old way,
    ///    because this context was fetched before the write landed. The claim STAYS,
    ///    so the box does not spring back open and then tick itself a second later.
    private func receive(_ next: WatchTodaySummary) {
        let previous = summary

        // A new day is a new list. Yesterday's receipts are not today's business,
        // and the day file is rewritten in full each morning, so nothing local
        // survives the boundary.
        if let previous, previous.date != next.date {
            receipts.removeAll()
        }

        let byId = Dictionary(next.rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, claim) in claims {
            if let row = byId[id] {
                if row.checked == claim.checked { claims.removeValue(forKey: id) }
                continue
            }
            claims.removeValue(forKey: id)
            // Only a CHECK leaves a receipt. An uncheck whose row also left has
            // nothing to show for itself — there is no "I re-opened this" state
            // worth a line on a watch face.
            if claim.checked, let row = previous?.rows.first(where: { $0.id == id }) {
                receipts.append(row)
            }
        }

        // A receipt whose row is back in the payload is a duplicate, not a receipt:
        // someone re-opened the item, and one item must never occupy two rows.
        receipts.removeAll { byId[$0.id] != nil }

        summary = next
        updateFreshness()
    }
}
