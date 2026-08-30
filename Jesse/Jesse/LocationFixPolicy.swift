import Foundation

// The fix-acquisition POLICY, with no CoreLocation in it.
//
// `LocationContextProviding` already hides CoreLocation from the resolver and the
// channel, but the seam sat above the thing that was actually broken: how one fix is
// acquired. Everything in this file is the part of that acquisition that can be wrong —
// which fixes count, which one is best, when to stop waiting, and what to say when
// nothing usable arrived — expressed over plain values so it is unit-tested without a
// device, a simulator location, or a network.
//
// The CoreLocation half is reduced to `FixSourcing`: start, stop, and two callbacks.
// `LocationContextProvider` conforms it to a `CLLocationManager`; the tests conform it
// to a script of arrivals.
//
// WHAT WAS WRONG. The old code asked for ONE fix with `requestLocation()` and raced it
// against a two-second bound. `requestLocation()` calls back exactly once, and only
// once CoreLocation is satisfied it has met `desiredAccuracy` — Apple budgets roughly
// ten seconds for that. At `kCLLocationAccuracyBest`, taken cold or indoors, it needs
// more than two seconds far more often than not, so the bound won the race and the
// whole reading came back empty. Every interim fix CoreLocation had already computed
// was discarded, because nothing ever asked for one.
//
// The fix is not a bigger number. It is to take the interim fixes: hold the best one
// seen so far, return early the moment it is good enough, and return the best held when
// the deadline expires. Then a deadline is a QUALITY bound rather than an all-or-
// nothing one, and the "town, not street" answer that was always available arrives
// instead of nothing.

// MARK: - The reasons a reading can be unavailable

/// Why the location channel produced nothing this turn.
///
/// This exists because the bridge used to tell the agent four things at once —
/// "permission was denied, Location Services are off, the fix timed out, or the feature
/// is off" — and those need telling apart. One of them means the owner has to change a
/// setting; another means nothing is wrong and a retry in a moment will work. Conflated,
/// the agent sends him to Settings to check toggles that are already on.
///
/// **A reason is not a place.** It says what happened, never where: no coordinate, no
/// accuracy figure, no place name, nothing that narrows down where the phone is. That
/// is what makes it safe to put on the wire and in a log line, and it must stay that
/// way — see `Log.location` and `LocationAttemptLog`.
///
/// The raw values are the wire strings. **Kept in exact sync with the bridge's
/// `NEEDS_LOCATION_UNAVAILABLE_REASONS`**, checked by `scripts/ci-guards.sh` the same
/// way the field and precision whitelists are.
nonisolated enum LocationUnavailableReason: String, CaseIterable, Sendable, Equatable {
    /// The owner's own "Attach location context" switch is off. Nothing was read and
    /// no system permission is involved.
    case featureOff = "feature_off"
    /// Location Services are off for the whole device, in Settings › Privacy.
    case servicesOff = "services_off"
    /// The app is not authorized when-in-use (denied, restricted, or never asked).
    case unauthorized = "unauthorized"
    /// The deadline expired and nothing usable had arrived. **Nothing is misconfigured
    /// —** this is the one reason whose remedy is "try again in a moment".
    case timedOut = "timed_out"
    /// CoreLocation reported it could not determine a position at all (no GPS, no
    /// usable network signal, airplane mode, a simulator with no location set).
    case noFix = "no_fix"
}

// MARK: - One fix, as a plain value

/// One location fix reduced to the four things this channel uses. Deliberately not a
/// `CLLocation`: keeping the policy over a Foundation value is what lets the selection
/// rules be tested on any machine, and there is nothing else on a `CLLocation` this
/// channel reads.
nonisolated struct FixCandidate: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    /// The horizontal accuracy radius in metres, exactly as CoreLocation reports it —
    /// **including its negative sentinel for an invalid fix**, which is why the
    /// usability test below is not decoration.
    var horizontalAccuracy: Double
    /// When the fix was taken, which is NOT when it was delivered. A
    /// `startUpdatingLocation` stream commonly opens with a cached fix that is hours
    /// old and from another city.
    var timestamp: Date

    init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }
}

// MARK: - The per-call budget

/// What ONE fix request is allowed to spend, and how good a fix ends it early.
///
/// A per-CALL value, not a property of the provider, and that is the point of the type.
/// One shared timeout used to serve two call sites whose latency situations have
/// nothing in common, and it was reasoned about for the wrong one of them. See
/// `proactive` and `fulfilment` below, whose comments are the reasoning that must not
/// be collapsed back into a single constant.
nonisolated struct LocationFixBudget: Sendable, Equatable {
    /// How long the acquisition may run before it returns the best fix it holds.
    /// **Not an all-or-nothing bound** — when it expires with a usable interim fix in
    /// hand, that fix is the answer.
    var deadline: Duration
    /// Good enough to stop early: the first usable fix at or under this radius ends the
    /// request immediately and stops the GPS. `.infinity` means "the first usable fix
    /// wins", which is what a coarse request wants.
    var targetAccuracyMeters: Double
    /// Hard bound on the reverse geocode, a separate network round trip stacked on top
    /// of the fix. Separate because a device can have a perfect fix and no network, and
    /// in that case the coordinates should still ride out.
    var geocodeTimeout: Duration

    init(deadline: Duration, targetAccuracyMeters: Double, geocodeTimeout: Duration) {
        self.deadline = deadline
        self.targetAccuracyMeters = targetAccuracyMeters
        self.geocodeTimeout = geocodeTimeout
    }

    /// THE PROACTIVE ATTACH, spent inside `JesseClient.send`.
    ///
    /// This sits between the owner pressing send and the message leaving the phone, so
    /// every millisecond here is dead air he is watching. It is also the cheapest
    /// request the channel makes — coarse, placemark-led, happy with a five-minute-old
    /// cached fix — so it is usually served from the cache or by a fast reduced-accuracy
    /// fix and never reaches the deadline at all. A tight bound is correct HERE and
    /// only here.
    ///
    /// `targetAccuracyMeters` is infinite deliberately: a proactive attach wants *a*
    /// fix, not a good one, and the first usable arrival should end it.
    static let proactive = LocationFixBudget(deadline: .seconds(2),
                                             targetAccuracyMeters: .infinity,
                                             geocodeTimeout: .milliseconds(1500))

    /// THE DIRECTIVE FULFILMENT, spent between two turns.
    ///
    /// `LocationChannel.block` runs as a retry AFTER the agent has asked for a location
    /// and BEFORE it answers. The owner is already watching a spinner waiting for a
    /// reply that is several seconds away regardless, so a few more seconds here are
    /// invisible — and this is the path that asks for precise fixes, and the path that
    /// was failing on every single one.
    ///
    /// **Do not collapse this into `proactive`.** They differ because the two call sites
    /// differ; sharing one constant is the bug this file exists to fix, and the shared
    /// value was reasoned about for the proactive case and then inherited by this one,
    /// where the reasoning does not apply.
    ///
    /// The numbers: `targetAccuracy` at 65 m is a street-level answer, which is what
    /// "how far is it" and "where am I" actually need — waiting past it for the 5 m fix
    /// buys nothing this channel renders. The 6-second deadline is the ceiling, not the
    /// expectation; a warm device satisfies the target well inside it and returns early.
    static let fulfilment = LocationFixBudget(deadline: .seconds(6),
                                              targetAccuracyMeters: 65,
                                              geocodeTimeout: .seconds(3))

    /// Extra head-room the acquisition gets ON TOP of `deadline`, covering the seconds a
    /// person spends reading the temporary-full-accuracy prompt. That wait is charged to
    /// nobody: the deadline clock starts once the prompt is answered. This bound exists
    /// only so a prompt that is never answered at all cannot wedge the awaiting task
    /// group forever.
    static let authorizationGrace: Duration = .seconds(30)

    /// The target a REQUEST of this precision actually gets. A coarse request finishes
    /// on its first usable fix whatever the budget says: asking for reduced accuracy and
    /// then waiting for a tight radius is asking for something the request declined.
    func targetAccuracy(for precision: LocationPrecision) -> Double {
        precision == .coarse ? .infinity : targetAccuracyMeters
    }
}

// MARK: - Which fix wins

/// Picks the best usable fix out of a stream of arrivals, and says when one is good
/// enough to stop.
///
/// **The staleness test is the trap in this whole change and is not optional.**
/// `startUpdatingLocation()` typically delivers a cached fix as its very first callback,
/// and that fix can be hours old and from a different city. The `requestLocation()` code
/// this replaces was accidentally shielded from that. Adopting interim fixes without an
/// explicit timestamp test would let the channel confidently report the wrong town,
/// which is worse than reporting nothing — a wrong answer is acted on and an absent one
/// is not.
nonisolated struct FixSelector: Sendable, Equatable {
    /// What each arrival was judged to be.
    enum Verdict: Sendable, Equatable {
        /// Not usable at all — invalid, or older than the request allows.
        case rejected
        /// Usable and kept (possibly as the new best), but not yet good enough to stop.
        case accepted
        /// Usable, and the best held fix now meets the target: stop.
        case satisfied
    }

    /// The oldest timestamp a fix may carry. Derived from the request's own
    /// `max_age_seconds` measured against when the request STARTED, so a
    /// `max_age_seconds` of 0 means literally "taken after this request began" rather
    /// than the unbounded "whatever CoreLocation had lying around".
    let earliestAcceptable: Date
    let targetAccuracyMeters: Double

    /// The smallest-radius usable fix seen so far, or nil if none has been.
    private(set) var best: FixCandidate?
    /// Whether anything at all was offered and rejected. Distinguishes "the stream was
    /// silent" from "the stream only ever produced stale or invalid fixes", which read
    /// the same from the outside and are diagnosed differently.
    private(set) var rejectedCount = 0

    init(startedAt: Date, maxAgeSeconds: Int, targetAccuracyMeters: Double) {
        self.earliestAcceptable = startedAt.addingTimeInterval(-Double(max(0, maxAgeSeconds)))
        self.targetAccuracyMeters = targetAccuracyMeters
    }

    /// Whether a fix may be used at all. BOTH tests are load-bearing:
    ///
    ///  * a `horizontalAccuracy` at or below zero is CoreLocation's sentinel for a fix
    ///    whose position is invalid — `LocationReading` already knows this, and now the
    ///    selection knows it too rather than only the rendering;
    ///  * a timestamp older than the request allows is the stale-cached-fix trap above.
    func isUsable(_ candidate: FixCandidate) -> Bool {
        candidate.horizontalAccuracy > 0 && candidate.timestamp >= earliestAcceptable
    }

    /// Offer one arrival. Keeps it if it is usable and tighter than what is held, and
    /// says whether the request can stop now.
    ///
    /// Ties break toward the NEWER fix: two readings of the same radius describe the
    /// same circle, and the later one describes it later.
    @discardableResult
    mutating func offer(_ candidate: FixCandidate) -> Verdict {
        guard isUsable(candidate) else {
            rejectedCount += 1
            return .rejected
        }
        if let held = best {
            if candidate.horizontalAccuracy < held.horizontalAccuracy
                || (candidate.horizontalAccuracy == held.horizontalAccuracy
                    && candidate.timestamp > held.timestamp) {
                best = candidate
            }
        } else {
            best = candidate
        }
        // `best!` is non-nil here: the branch above either kept the arrival or already
        // held something at least as good.
        return best!.horizontalAccuracy <= targetAccuracyMeters ? .satisfied : .accepted
    }
}

// MARK: - The outcome of one acquisition

/// What one fix acquisition produced, and what it cost. `fix` and `reason` are mutually
/// exclusive: a fix means success, a reason means there is nothing to render.
nonisolated struct LocationFixAttempt: Sendable, Equatable {
    var fix: FixCandidate?
    /// Why there is no fix. Nil exactly when `fix` is non-nil.
    var reason: LocationUnavailableReason?
    /// Wall-clock seconds from the moment the deadline clock started (i.e. AFTER any
    /// full-accuracy prompt was answered) to the moment the request finished.
    var elapsed: TimeInterval
    /// The request ended early because the target accuracy was met, rather than at the
    /// deadline. Instrumentation only — it is the single number that says whether the
    /// chosen deadline is doing anything.
    var metTarget: Bool

    static func success(_ fix: FixCandidate, elapsed: TimeInterval, metTarget: Bool) -> Self {
        LocationFixAttempt(fix: fix, reason: nil, elapsed: elapsed, metTarget: metTarget)
    }

    static func failure(_ reason: LocationUnavailableReason, elapsed: TimeInterval) -> Self {
        LocationFixAttempt(fix: nil, reason: reason, elapsed: elapsed, metTarget: false)
    }
}

// MARK: - The CoreLocation seam

/// Why a location source gave up. Deliberately two cases rather than a `CLError`: the
/// only distinction the policy makes is "this is terminal, stop" versus "CoreLocation is
/// still trying, keep waiting", and passing a full error through would put a
/// CoreLocation type in the Foundation-only half of the channel.
nonisolated enum LocationFixFailure: Sendable, Equatable {
    /// Authorization was refused. Terminal — no amount of waiting fixes it.
    case denied
    /// Could not determine a position right now. NOT terminal: `startUpdatingLocation`
    /// keeps trying after one of these, and a fix often arrives a second later, so the
    /// acquisition keeps waiting and lets the deadline decide.
    case unableToDetermine
}

/// The whole of CoreLocation, as this channel uses it: prepare, start, stop.
///
/// Main-actor by module default, matching where a `CLLocationManager` is created and
/// where it delivers. The production conformer is `CLFixSource`; tests conform a
/// scripted fake and drive every path — including the ones a device cannot be made to
/// produce on demand, like "a stale cached fix arrives first and nothing else ever
/// does".
///
/// `nonisolated` on the protocol with `@MainActor` on each requirement, rather than a
/// `@MainActor` protocol: the conformers are held by types `JesseClient` releases off
/// the main actor, and a main-actor-isolated class gets an isolated `deinit` that aborts
/// the process on such a release. Same reasoning as `FixAcquisition` above.
nonisolated protocol FixSourcing: AnyObject, Sendable {
    /// Settle any accuracy authorization the request needs BEFORE the clock starts.
    ///
    /// A `precise` request on a device that granted reduced accuracy raises the
    /// temporary-full-accuracy prompt here, and this call does not return until the
    /// person has answered it. The old code fired that prompt and started the fix in the
    /// same breath, so the budget burned down while the sheet was still on screen and
    /// the first precise request on such a device was close to guaranteed to fail.
    ///
    /// Declining is not a failure: the request carries on at reduced accuracy and
    /// returns the coarse fix, which is a real answer.
    @MainActor
    func prepareAccuracy(precision: LocationPrecision) async

    /// Begin delivering fixes. Every arrival goes to `onUpdate`, including the interim
    /// ones — taking those is the entire point.
    @MainActor
    func startUpdating(precision: LocationPrecision,
                       onUpdate: @escaping (FixCandidate) -> Void,
                       onFailure: @escaping (LocationFixFailure) -> Void)

    /// Stop delivering and release everything. Called on EVERY exit path — success,
    /// timeout, error, cancellation — because a `startUpdatingLocation` left running
    /// holds the GPS on and drains the battery in the background, which is a worse bug
    /// than the one this file fixes.
    @MainActor
    func stopUpdating()
}

// MARK: - The acquisition itself

/// Runs one fix acquisition end to end: prepare accuracy, start updates, feed arrivals
/// to a `FixSelector`, and resume EXACTLY ONCE with the best usable fix or a reason.
///
/// This is the class the defect lived in, lifted out from behind `CLLocationManager` so
/// it can be driven by a test. What it inherited from the `FixWaiter` it replaces, and
/// what must survive any future edit:
///
///  * **The single-resume guard.** Three things race to finish: an arrival meeting the
///    target, the deadline, and the caller cancelling. Resuming a `CheckedContinuation`
///    twice traps, so a second arrival must be a silent no-op.
///  * **Main-actor discipline.** `begin`, `cancel`, the deadline task and both callbacks
///    all run on the main actor — the manager is created there and delivers there — so
///    the guard is checked and cleared on one actor and needs no further locking.
///  * **`nonisolated` on the class.** A main-actor-isolated CLASS gets an actor-isolated
///    `deinit`; `JesseClient` holds this channel and is released off the main actor,
///    which aborts the process with `pointer being freed was not allocated`. That has
///    already taken the test host down once. The class is nonisolated and its methods
///    are annotated, never the other way round.
///  * **The source is owned here.** `CLLocationManager.delegate` is weak, so the source
///    holds the manager and this holds the source. A manager with no strong owner
///    deallocates and never calls back — the request then simply never returns, which
///    was a previous bug on this path.
nonisolated final class FixAcquisition: @unchecked Sendable {
    private let source: any FixSourcing
    private let precision: LocationPrecision
    private let budget: LocationFixBudget
    private let maxAgeSeconds: Int
    private let now: @Sendable () -> Date

    private var selector: FixSelector
    private var resume: ((LocationFixAttempt) -> Void)?
    private var deadlineTask: Task<Void, Never>?
    private var startedAt: Date
    private var isFinished = false
    /// A terminal reason observed before the deadline (a denial), or the sticky record
    /// that CoreLocation said it could not determine a position — which turns a
    /// fruitless wait from "timed out" into "no fix", a different thing to tell the
    /// owner.
    private var terminal: LocationUnavailableReason?
    private var sawUnableToDetermine = false

    init(source: any FixSourcing,
         precision: LocationPrecision,
         budget: LocationFixBudget,
         maxAgeSeconds: Int,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.precision = precision
        self.budget = budget
        self.maxAgeSeconds = maxAgeSeconds
        self.now = now
        let started = now()
        self.startedAt = started
        self.selector = FixSelector(startedAt: started,
                                    maxAgeSeconds: maxAgeSeconds,
                                    targetAccuracyMeters: budget.targetAccuracy(for: precision))
    }

    /// Arm the request and resume `resume` exactly once when it finishes.
    ///
    /// The accuracy prompt is awaited FIRST and the deadline clock is (re)started
    /// afterwards, so the seconds a person spends reading that sheet are charged to
    /// nobody. The staleness window moves with it: a fix taken while the prompt was on
    /// screen is genuinely older than "after this request began".
    @MainActor
    func begin(resume: @escaping (LocationFixAttempt) -> Void) async {
        // Cancelled before it could be armed: resume rather than starting a stream
        // nobody is waiting on.
        guard !isFinished else {
            resume(.failure(.timedOut, elapsed: 0))
            return
        }
        self.resume = resume
        await source.prepareAccuracy(precision: precision)
        // The caller may have cancelled while the prompt was up; `cancel` has already
        // resumed and stopped the source, so there is nothing left to do.
        guard !isFinished else { return }

        startedAt = now()
        selector = FixSelector(startedAt: startedAt,
                               maxAgeSeconds: maxAgeSeconds,
                               targetAccuracyMeters: budget.targetAccuracy(for: precision))
        source.startUpdating(precision: precision,
                             onUpdate: { [weak self] in self?.offer($0) },
                             onFailure: { [weak self] in self?.fail($0) })
        let deadline = budget.deadline
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            // The deadline is a QUALITY bound: whatever usable fix is held wins.
            self?.finish()
        }
    }

    /// The caller's outer bound fired, or its task was cancelled. Resume so the awaiting
    /// task group can close instead of waiting on a fix that is not coming.
    @MainActor
    func cancel() {
        if terminal == nil { terminal = .timedOut }
        finish()
    }

    @MainActor
    private func offer(_ candidate: FixCandidate) {
        guard !isFinished else { return }
        if selector.offer(candidate) == .satisfied {
            finish()
        }
    }

    @MainActor
    private func fail(_ failure: LocationFixFailure) {
        guard !isFinished else { return }
        switch failure {
        case .denied:
            // Terminal: waiting longer cannot produce authorization.
            terminal = .unauthorized
            finish()
        case .unableToDetermine:
            // NOT terminal. CoreLocation keeps trying after this and a fix often
            // arrives moments later; ending here would throw away the exact case the
            // interim-fix change exists to rescue. Remembered only so a request that
            // ends up with nothing is reported as "no fix" rather than "timed out".
            sawUnableToDetermine = true
        }
    }

    /// The single exit. Stops the source, cancels the deadline, and resumes once.
    @MainActor
    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        deadlineTask?.cancel()
        deadlineTask = nil
        // On EVERY path, including cancellation and error — see `stopUpdating`.
        source.stopUpdating()
        let resume = self.resume
        self.resume = nil
        resume?(attempt())
    }

    @MainActor
    private func attempt() -> LocationFixAttempt {
        let elapsed = max(0, now().timeIntervalSince(startedAt))
        if let best = selector.best {
            return .success(best, elapsed: elapsed,
                            metTarget: best.horizontalAccuracy <= selector.targetAccuracyMeters)
        }
        if let terminal {
            return .failure(terminal, elapsed: elapsed)
        }
        // Nothing usable, and nothing terminal. If CoreLocation actually said it could
        // not place the device, say so — that is a different conversation with the owner
        // from "we ran out of time".
        return .failure(sawUnableToDetermine ? .noFix : .timedOut, elapsed: elapsed)
    }
}

// MARK: - Diagnostics (in memory, no place data)

/// One attempt, as the Settings row reports it. Outcome, accuracy and elapsed time —
/// and deliberately NOT where the phone was. A diagnostic that carried a coordinate
/// would be the one place in this channel where a reading outlives the turn.
nonisolated struct LocationAttemptRecord: Sendable, Equatable {
    /// The precision the request asked for.
    var requested: LocationPrecision
    /// The precision the fix actually achieved, or nil when there was no fix.
    var achieved: LocationPrecision?
    /// Accuracy radius in metres, or nil when there was no fix.
    var accuracyMeters: Double?
    var elapsed: TimeInterval
    /// Nil on success; the reason otherwise.
    var reason: LocationUnavailableReason?
    /// This attempt was answered out of the in-memory cache without waking the GPS.
    var servedFromCache: Bool
    var at: Date

    var succeeded: Bool { reason == nil }
}

/// The last attempt made in THIS RUN of the app, for the Settings diagnostic.
///
/// In memory only, exactly like the fix cache: nothing here is written to disk, to
/// SwiftData or to `UserDefaults`, and it is gone when the process is. The point is that
/// the next failure is diagnosable from the phone in ten seconds rather than by reading
/// this file on another machine — which is what the failure that prompted this change
/// cost.
nonisolated final class LocationAttemptLog: @unchecked Sendable {
    static let shared = LocationAttemptLog()

    private let lock = NSLock()
    private var record: LocationAttemptRecord?

    func record(_ attempt: LocationAttemptRecord) {
        lock.lock()
        defer { lock.unlock() }
        self.record = attempt
    }

    var last: LocationAttemptRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    /// A one-line human rendering for the Settings row. Names the outcome, the accuracy
    /// and the elapsed time; never a place.
    static func summary(_ r: LocationAttemptRecord, now: Date = Date()) -> String {
        let ms = Int((r.elapsed * 1000).rounded())
        if let reason = r.reason {
            return "\(reasonText(reason)) after \(ms) ms"
        }
        let accuracy = r.accuracyMeters.map { LocationRequestFulfiller.metres($0) } ?? "unknown"
        let how = r.servedFromCache ? "from cache" : "in \(ms) ms"
        let achieved = r.achieved?.rawValue ?? "unknown"
        return "\(achieved) fix, within about \(accuracy), \(how)"
    }

    /// The owner-facing wording for a reason. Plain about which ones need him to change
    /// something and which need nothing.
    static func reasonText(_ reason: LocationUnavailableReason) -> String {
        switch reason {
        case .featureOff: return "not attempted — the switch above is off"
        case .servicesOff: return "Location Services are off for this device"
        case .unauthorized: return "Jesse is not allowed to use your location"
        case .timedOut: return "timed out with no usable fix — nothing is misconfigured"
        case .noFix: return "the phone could not determine a position"
        }
    }
}
