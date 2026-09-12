import Foundation
import SwiftData
import JesseCore
import JesseDietDisplay
import JesseNetworking

// **The Health tab's two turns, fired when the data lands rather than when someone asks.**
//
// New health data only reached the logs when Jeremy asked for it. The rest of the morning is
// automated server-side, and the health path structurally cannot be: the data lives in
// HealthKit on this phone and is attached to a turn at send time, so a turn the Studio's
// scheduler fires carries none of it. The trigger has to live here, and it has to be the
// arrival of the data itself — a weigh-in at 06:15 or 09:30, a run at 08:35, a treadmill walk
// at 16:43.
//
// Three layers, and only the middle one is new machinery:
//
//  * `HealthDataObserver` (the HealthKit file) notices that something arrived and reduces it
//    to dates and identifiers.
//  * `HealthAutoTrigger` (below) decides, through the pure rules in JesseCore
//    (`HealthAutoFire`, `WorkoutAutoLog`), whether that means a turn — and remembers what it
//    already fired for.
//  * `HealthTurn` (below) sends it, and it is the SAME function the Start-new-day button
//    calls, so there is no second copy of the morning routine and no second copy of the
//    offline-capture path.
//
// iOS only. HealthKit does not exist on the Mac, whose Health view keeps its manual button.

// MARK: - The one send path

/// **Sends a Health turn the one way, whoever asks for it**: the Start-new-day button, the
/// body-mass observer, or the workout observer.
///
/// Fire and forget. The routine runs on the Studio for minutes; this opens a fresh Tell
/// thread, stages the send through `RunCoordinator` (the same user turn, outbox row and Retry
/// as a typed message) and returns. Offline, it holds the turn in the capture queue exactly as
/// the button always has, and the replayer decides what a held turn still means when the
/// bridge comes back.
@MainActor
enum HealthTurn {
    enum Outcome: Equatable {
        /// A fresh thread was opened and the send staged.
        case sent
        /// Held in the offline capture queue.
        case queued
        /// Neither: nothing to capture it with, or the staging save failed.
        case refused
        /// This device already ran the new-day refresh for this diet day. Nothing happened.
        case alreadyRan
    }

    /// **Start-new-day.** The button's path and the automatic weigh-in's, in one function.
    ///
    /// `dietDay` is the diet day this run is FOR, and it is what `HealthNewDay.lastFiredDayKey`
    /// records once the run is sent or held, so a second request for the same day — by either
    /// path — is `.alreadyRan` rather than a second rollover. `capturedDay` is the day a HELD
    /// run is dated against: the automatic path passes the weigh-in's own day, and the button
    /// passes nil and keeps the bridge's `captureDay`, as it always has.
    @discardableResult
    static func startNewDay(model: HealthDashboardModel, coordinator: RunCoordinator,
                            context: ModelContext, origin: ThreadOrigin, dietDay: String,
                            capturedDay: String? = nil,
                            defaults: UserDefaults = .standard) -> Outcome {
        let ranToday = defaults.string(forKey: HealthNewDay.lastFiredDayKey) == dietDay
        let outcome: Outcome
        switch HealthTurnRoute.decide(alreadyRanToday: ranToday, isReadOnly: model.isReadOnly) {
        case .alreadyRan:
            return .alreadyRan
        case .capture:
            outcome = model.captureStartNewDay(dayDate: capturedDay, origin: origin)
                ? .queued : .refused
        case .send:
            outcome = send(.morningRefresh, origin: origin, coordinator: coordinator,
                           context: context) ? .sent : .refused
        }
        if outcome != .refused { defaults.set(dietDay, forKey: HealthNewDay.lastFiredDayKey) }
        return outcome
    }

    /// **The automatic workout log.** No day guard here: the caller has already decided,
    /// by workout identity, that there is something new to log.
    @discardableResult
    static func logWorkouts(model: HealthDashboardModel, coordinator: RunCoordinator,
                            context: ModelContext, dietDay: String) -> Outcome {
        switch HealthTurnRoute.decide(alreadyRanToday: false, isReadOnly: model.isReadOnly) {
        case .alreadyRan:
            return .alreadyRan
        case .capture:
            return model.captureWorkoutLog(dayDate: dietDay) ? .queued : .refused
        case .send:
            return send(.workoutLog, origin: .automatic, coordinator: coordinator,
                        context: context) ? .sent : .refused
        }
    }

    /// Open a fresh Tell thread carrying `origin` and stage the turn. Always a NEW thread:
    /// an automatic turn never appends to an existing conversation, and it is an ordinary,
    /// visible, searchable thread that is titled like any other.
    private static func send(_ turn: HealthAutoTurn, origin: ThreadOrigin,
                             coordinator: RunCoordinator, context: ModelContext) -> Bool {
        let thread = JesseThread(mode: .tell)
        thread.origin = origin.rawValue
        context.insert(thread)
        return coordinator.send(thread: thread, text: turn.prompt, voice: false, context: context)
    }
}

// MARK: - The trigger

/// **Decides when new health data means a turn, and remembers what it already fired for.**
///
/// One per process, because HealthKit relaunches the app into the BACKGROUND to deliver, where
/// no view exists: the coordinator and the Health model are handed over from `JesseApp.init`,
/// and the observers are started from `application(_:didFinishLaunchingWithOptions:)`, which
/// is where HealthKit's documentation requires them to be set up.
///
/// Nothing here waits on a view, shows a modal, or needs the app in the foreground.
@MainActor
final class HealthAutoTrigger {
    // A MainActor class's synthesized deinit aborts when a test host releases it off the
    // main actor — the same guard every app-scoped object here carries.
    nonisolated deinit {}

    static let shared = HealthAutoTrigger()

    /// `UserDefaults` key for the workout ledger (`WorkoutLedger`, JSON). A per-device record
    /// of dates and identifiers, beside `HealthNewDay.lastFiredDayKey` in the same store.
    static let ledgerKey = "healthWorkoutLedger"

    private weak var coordinator: RunCoordinator?
    private var model: HealthDashboardModel?
    private var observer: HealthDataObserver?
    private let defaults: UserDefaults
    private let now: () -> Date

    /// Asks iOS for a background refresh no earlier than a moment — set by the app delegate,
    /// which owns the refresh task. Used when a workout burst is waiting out its settle.
    var requestWake: ((Date) -> Void)?

    /// The diet day a morning-refresh fire is in progress for. The fire awaits a network
    /// round trip before it records the day, and body-mass notifications arrive in bursts;
    /// without this, two of them could both pass the guard in that gap.
    private var firingDay: String?
    /// Whether a workout-log fire is in progress, for the same reason.
    private var firingWorkouts = false
    /// The in-process wake-up for a settling burst. It only helps while the process is alive
    /// (foreground, or the seconds a background wake grants); the persisted ledger and the
    /// other triggers cover every other case.
    private var settleTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// Hand over the app-scoped coordinator and the one Health model. Called from
    /// `JesseApp.init`, which runs on every launch — including a background one.
    func attach(coordinator: RunCoordinator, model: HealthDashboardModel) {
        self.coordinator = coordinator
        self.model = model
    }

    // MARK: Registration

    /// Register the two observers, once, if the user has connected Apple Health.
    ///
    /// "Connected" is the attach-health-context toggle, which the app turns on only after the
    /// HealthKit authorization prompt has been answered. It is also the right gate for a
    /// second reason: with it off, no health block attaches to any turn, so an automatic
    /// turn would arrive with nothing to log.
    func startIfEnabled() {
        guard HealthContextSettings.isEnabled, HealthDataObserver.isAvailable else {
            stop()
            return
        }
        guard observer == nil else { return }
        let observer = HealthDataObserver(
            defaults: defaults,
            onBodyMass: { [weak self] in self?.receiveBodyMass($0) },
            onWorkouts: { [weak self] in self?.receiveWorkouts($0) })
        self.observer = observer
        observer.start()
    }

    /// Stop both observers and background delivery — the toggle went off.
    func stop() {
        observer?.stop()
        observer = nil
        settleTask?.cancel()
        settleTask = nil
    }

    // MARK: Body mass → the morning refresh

    /// New body-mass samples arrived. Fire the morning refresh if the newest belongs to today's
    /// diet day and it has not already run for that day. Returns at once; the fire runs on.
    func receiveBodyMass(_ arrivals: HealthArrivals<Date>) {
        // The first observation ever is a baseline of what was already there, not news.
        guard !arrivals.isBaseline, let newest = arrivals.items.max() else { return }
        let current = now()
        let day = DietDay.stamp(for: current)
        guard firingDay != day,
              HealthAutoFire.shouldFireMorningRefresh(
                newestSampleDate: newest,
                lastFiredDay: defaults.string(forKey: HealthNewDay.lastFiredDayKey),
                now: current)
        else { return }
        firingDay = day
        Task {
            await fireMorningRefresh(day: day)
            firingDay = nil
        }
    }

    private func fireMorningRefresh(day: String) async {
        guard let (coordinator, model) = ready() else { return }
        // One live fetch first, for what it proves: whether the bridge can be reached (so a
        // held run goes to the capture queue, where a rolled day refuses it, rather than to
        // the chat outbox, where nothing would), and a fresh dashboard for the tab.
        await model.load()
        let outcome = HealthTurn.startNewDay(
            model: model, coordinator: coordinator,
            context: AppModelContainer.shared.container.mainContext,
            origin: .automatic, dietDay: day, capturedDay: day, defaults: defaults)
        Log.health.notice("automatic new-day refresh for \(day): \(String(describing: outcome))")
    }

    // MARK: Workouts → the workout log

    /// New workouts arrived. Record them, and fire for whatever has settled. Returns at once.
    func receiveWorkouts(_ arrivals: HealthArrivals<ObservedWorkout>) {
        if arrivals.isBaseline {
            ledger = WorkoutAutoLog.baseline(arrivals.items, in: ledger, now: now())
            return
        }
        let decision = evaluate(adding: arrivals.items)
        guard !decision.due.isEmpty else { return }
        Task { await fireWorkoutLog(decision.due) }
    }

    /// Fire for any burst that has settled since it was noticed — from the foreground, the
    /// background refresh task, and the in-process settle timer. Waits for the fire, so the
    /// refresh task does not report completion while it is still running.
    func settleWorkouts() async {
        let decision = evaluate(adding: [])
        guard !decision.due.isEmpty else { return }
        await fireWorkoutLog(decision.due)
    }

    private func evaluate(adding observed: [ObservedWorkout]) -> WorkoutFireDecision {
        let decision = WorkoutAutoLog.workoutsToFire(observed: observed, ledger: ledger, now: now())
        ledger = decision.ledger
        if let next = decision.nextCheck { armSettle(at: next) }
        return decision
    }

    private func fireWorkoutLog(_ due: [ObservedWorkout]) async {
        guard !firingWorkouts, let (coordinator, model) = ready() else { return }
        firingWorkouts = true
        defer { firingWorkouts = false }
        await model.load()
        let outcome = HealthTurn.logWorkouts(
            model: model, coordinator: coordinator,
            context: AppModelContainer.shared.container.mainContext,
            dietDay: DietDay.stamp(for: now()))
        Log.health.notice("automatic workout log for \(due.count) workout(s): \(String(describing: outcome))")
        // Only a turn that was sent or held marks its workouts fired. A refused one leaves
        // them pending, already settled, for the next trigger to try again.
        guard outcome == .sent || outcome == .queued else { return }
        ledger = WorkoutAutoLog.markFired(due, in: ledger, now: now())
        // Anything that landed while this was in flight starts its own settle now.
        if !ledger.pending.isEmpty { _ = evaluate(adding: []) }
    }

    private func armSettle(at date: Date) {
        requestWake?(date)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.settleWorkouts()
        }
    }

    // MARK: Shared

    /// The coordinator and model, or nil — with the reason logged — when a turn cannot be
    /// sent from here: the app is not paired, or launch has not handed them over.
    private func ready() -> (RunCoordinator, HealthDashboardModel)? {
        guard ConfigStore.load().isConfigured else {
            Log.health.notice("automatic health turn skipped: the app is not paired")
            return nil
        }
        guard let coordinator, let model else {
            Log.health.error("automatic health turn skipped: no coordinator attached")
            return nil
        }
        return (coordinator, model)
    }

    /// The persisted workout ledger. An unreadable value reads as empty, which costs at most
    /// one turn whose CSV diff finds nothing new.
    private var ledger: WorkoutLedger {
        get {
            guard let data = defaults.data(forKey: Self.ledgerKey),
                  let ledger = try? JSONDecoder().decode(WorkoutLedger.self, from: data)
            else { return WorkoutLedger() }
            return ledger
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.ledgerKey)
            }
        }
    }
}
