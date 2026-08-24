import Foundation
import BackgroundTasks

/// The `BGTaskScheduler` surface this app uses, behind a protocol.
///
/// The real scheduler cannot be exercised in a unit test: `BGTaskScheduler.shared` is a
/// singleton that refuses a registration for an identifier the running bundle's
/// `BGTaskSchedulerPermittedIdentifiers` does not list, and there is no way to make it
/// fire a task on demand. So the DECISION — what identifier, how far ahead, and that
/// completing a task re-arms the next one — is tested through this seam, and the four
/// lines that talk to the real singleton are not.
///
/// The same shape as `BackgroundTasking`, for the same reason.
@MainActor
protocol BackgroundRefreshScheduling: AnyObject {
    /// Register the launch handler. Must be called before the app finishes launching;
    /// iOS treats a later registration as a programmer error.
    func register(identifier: String, handler: @escaping @MainActor (BackgroundRefreshTask) -> Void)
    /// Ask for a refresh no earlier than `earliestBeginDate`. iOS decides when, or
    /// whether — this is a request, never a schedule.
    func submit(identifier: String, earliestBeginDate: Date)
}

/// The half of `BGTask` this app touches, so a test can hand the handler a task it
/// controls. `BGAppRefreshTask` is `final` and cannot be constructed outside the system.
@MainActor
protocol BackgroundRefreshTask: AnyObject {
    /// Called by the system shortly before the task is killed. The work must stop here.
    var expirationHandler: (() -> Void)? { get set }
    /// Report the outcome. Failing to call it is what makes iOS stop scheduling the task.
    func setTaskCompleted(success: Bool)
}

extension BGAppRefreshTask: BackgroundRefreshTask {}

/// Carries the main-actor handler across `BGTaskScheduler`'s `@Sendable` registration
/// closure. Unchecked because the guarantee is the SCHEDULER's, not the type system's:
/// the task is registered against the MAIN queue below, so the only thread that ever
/// reads this box is the one its contents are isolated to.
private struct MainActorHandlerBox: @unchecked Sendable {
    let handler: @MainActor (BackgroundRefreshTask) -> Void
}

/// The production conformer, backed by `BGTaskScheduler.shared`.
final class SystemBackgroundRefreshScheduler: BackgroundRefreshScheduling {
    func register(identifier: String,
                  handler: @escaping @MainActor (BackgroundRefreshTask) -> Void) {
        let box = MainActorHandlerBox(handler: handler)
        // `.main` and not `nil`: the launch handler must run where `assumeIsolated` below
        // says it does, and the default queue is not a promise this file can make.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let refresh = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                box.handler(refresh)
            }
        }
    }

    func submit(identifier: String, earliestBeginDate: Date) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // A submit failure is never fatal: the push path still delivers replies, and
            // this task is the backstop for when no push arrived. Logged so a
            // misconfigured `BGTaskSchedulerPermittedIdentifiers` is visible rather than
            // silently costing the backstop.
            Log.push.error("background refresh submit failed: \(error.localizedDescription)")
        }
    }
}

/// Owns the periodic background refresh: registering the handler at launch, asking for
/// the next one, and re-arming after each run.
///
/// # Why a periodic task at all, when there are pushes
///
/// Because a push is not guaranteed. APNs drops them under load, a phone that was off the
/// network when one was sent never gets it, and `content-available` wake-ups are budgeted
/// by iOS against how useful the app has been with them. The task is the backstop: every
/// four hours or so, refresh the two cached documents and re-attach to anything still in
/// flight, so the worst case is a stale day file rather than a lost reply.
@MainActor
final class BackgroundRefreshCoordinator {
    // Under this target's MainActor default isolation a class's synthesized deinit is
    // MainActor-isolated, and a unit-test host releases objects OFF the main actor — which
    // routes through the isolated-deinit executor hop and aborts the process. Same
    // `nonisolated deinit` the display models carry, for the same reason.
    nonisolated deinit {}

    /// The one identifier, which must also appear in `BGTaskSchedulerPermittedIdentifiers`
    /// in `Info.plist` — iOS refuses the registration otherwise, and the refusal is a
    /// crash at launch, not a warning.
    static let identifier = "com.tag1.Jesse.refresh"

    /// How far ahead the next refresh is requested. Four hours: often enough that a day
    /// file rewritten in the morning is not read stale all afternoon, rare enough that iOS
    /// keeps granting them.
    static let interval: TimeInterval = 4 * 3600

    private let scheduler: any BackgroundRefreshScheduling
    private let work: @MainActor () async -> BackgroundWorkOutcome
    private let now: @MainActor () -> Date
    private var registered = false

    init(scheduler: any BackgroundRefreshScheduling = SystemBackgroundRefreshScheduler(),
         work: @escaping @MainActor () async -> BackgroundWorkOutcome,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.scheduler = scheduler
        self.work = work
        self.now = now
    }

    /// Register the handler. Idempotent; iOS treats a second registration for the same
    /// identifier as a fatal programmer error, so the guard is load-bearing rather than
    /// tidy.
    func register() {
        guard !registered else { return }
        registered = true
        scheduler.register(identifier: Self.identifier) { [weak self] task in
            Task { @MainActor [weak self] in await self?.run(task) }
        }
    }

    /// Request the next refresh. Called at launch and again after each run — a
    /// `BGAppRefreshTask` is a ONE-SHOT, so a task that does not re-arm is a task that
    /// runs once in the lifetime of an install.
    func schedule() {
        scheduler.submit(identifier: Self.identifier,
                         earliestBeginDate: now().addingTimeInterval(Self.interval))
    }

    /// Run one task: re-arm FIRST, then do the work, then report.
    ///
    /// Re-arming first is deliberate. If the work throws, hangs, or the task is expired
    /// out from under us, the next refresh has already been requested — whereas re-arming
    /// at the end means one bad run silently ends the backstop for good.
    func run(_ task: BackgroundRefreshTask) async {
        schedule()
        let job = Task { @MainActor in await work() }
        task.expirationHandler = { job.cancel() }
        let outcome = await job.value
        task.setTaskCompleted(success: outcome != .failed)
    }
}
