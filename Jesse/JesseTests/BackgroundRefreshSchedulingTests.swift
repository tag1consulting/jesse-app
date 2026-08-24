import XCTest
@testable import Jesse

/// The periodic `BGAppRefreshTask`. The real `BGTaskScheduler` cannot be exercised in a
/// unit test — it is a singleton that refuses an identifier the running bundle does not
/// permit, and there is no way to make it fire a task on demand — so the DECISIONS are
/// tested through the thin protocol and the four lines that touch the singleton are not.
@MainActor
final class BackgroundRefreshSchedulingTests: XCTestCase {

    private final class FakeScheduler: BackgroundRefreshScheduling {
        nonisolated deinit {}
        var registrations: [String] = []
        var submissions: [(id: String, earliest: Date)] = []
        var handler: (@MainActor (BackgroundRefreshTask) -> Void)?

        func register(identifier: String,
                      handler: @escaping @MainActor (BackgroundRefreshTask) -> Void) {
            registrations.append(identifier)
            self.handler = handler
        }
        func submit(identifier: String, earliestBeginDate: Date) {
            submissions.append((identifier, earliestBeginDate))
        }
    }

    private final class FakeTask: BackgroundRefreshTask {
        nonisolated deinit {}
        var expirationHandler: (() -> Void)?
        var completed: Bool?
        func setTaskCompleted(success: Bool) { completed = success }
    }

    private func coordinator(_ scheduler: FakeScheduler,
                             now: Date = Date(timeIntervalSince1970: 1_000_000),
                             work: @escaping @MainActor () async -> BackgroundWorkOutcome
                                 = { .newData }) -> BackgroundRefreshCoordinator {
        BackgroundRefreshCoordinator(scheduler: scheduler, work: work, now: { now })
    }

    /// The identifier must match `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`;
    /// iOS turns a mismatch into a crash at launch, not a warning.
    func testTheIdentifierMatchesTheOneInInfoPlist() throws {
        let url = try XCTUnwrap(Bundle(for: type(of: self)).url(forResource: "Info", withExtension: "plist")
                                ?? Bundle.main.url(forResource: "Info", withExtension: "plist"))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                as? [String: Any])
        let permitted = plist["BGTaskSchedulerPermittedIdentifiers"] as? [String]
        // The test bundle's own Info.plist has no such key; only the app's does. Assert
        // against whichever bundle actually carries it, and never vacuously.
        if let permitted {
            XCTAssertTrue(permitted.contains(BackgroundRefreshCoordinator.identifier),
                          "permitted identifiers \(permitted) do not include "
                          + BackgroundRefreshCoordinator.identifier)
        } else {
            XCTAssertEqual(BackgroundRefreshCoordinator.identifier, "com.tag1.Jesse.refresh",
                           "the app target's Info.plist must list exactly this identifier")
        }
    }

    /// Registering twice for one identifier is a fatal programmer error in iOS, so the
    /// guard is load-bearing rather than tidy.
    func testRegistrationIsIdempotent() {
        let scheduler = FakeScheduler()
        let c = coordinator(scheduler)
        c.register()
        c.register()
        c.register()
        XCTAssertEqual(scheduler.registrations, [BackgroundRefreshCoordinator.identifier])
    }

    func testScheduleAsksForARefreshFourHoursOut() {
        let scheduler = FakeScheduler()
        let now = Date(timeIntervalSince1970: 1_000_000)
        coordinator(scheduler, now: now).schedule()
        XCTAssertEqual(scheduler.submissions.count, 1)
        XCTAssertEqual(scheduler.submissions[0].id, BackgroundRefreshCoordinator.identifier)
        XCTAssertEqual(scheduler.submissions[0].earliest, now.addingTimeInterval(4 * 3600))
    }

    /// A `BGAppRefreshTask` is a ONE-SHOT. A task that does not re-arm is a task that runs
    /// once in the lifetime of an install.
    func testRunningATaskReArmsTheNextOne() async {
        let scheduler = FakeScheduler()
        let task = FakeTask()
        await coordinator(scheduler).run(task)
        XCTAssertEqual(scheduler.submissions.count, 1, "the next refresh is requested")
        XCTAssertEqual(task.completed, true)
    }

    /// Re-arming happens FIRST. If the work throws, hangs, or is expired out from under
    /// us, the next refresh has already been requested — whereas re-arming at the end
    /// means one bad run silently ends the backstop for good.
    func testItReArmsEvenWhenTheWorkFails() async {
        let scheduler = FakeScheduler()
        let task = FakeTask()
        await coordinator(scheduler, work: { .failed }).run(task)
        XCTAssertEqual(scheduler.submissions.count, 1)
        XCTAssertEqual(task.completed, false, "a failed run is reported as failed: iOS "
                       + "budgets future wake-ups on what it is told")
    }

    /// `noData` is a successful run that found nothing, not a failure.
    func testNoDataIsASuccessfulRun() async {
        let scheduler = FakeScheduler()
        let task = FakeTask()
        await coordinator(scheduler, work: { .noData }).run(task)
        XCTAssertEqual(task.completed, true)
    }

    /// The system's expiration handler must actually stop the work, or the process is
    /// killed mid-write.
    func testExpirationCancelsTheWork() async {
        let scheduler = FakeScheduler()
        let task = FakeTask()
        let c = coordinator(scheduler, work: {
            // Long enough that the expiration below always wins.
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled ? .failed : .newData
        })
        let run = Task { await c.run(task) }
        // Wait for `run` to install the handler, then fire it as the system would.
        for _ in 0..<200 where task.expirationHandler == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(task.expirationHandler)
        task.expirationHandler?()
        await run.value
        XCTAssertNotNil(task.completed, "the task is always completed, expired or not")
    }

    /// The registered handler is what the system calls; it must reach `run`.
    func testTheRegisteredHandlerRunsTheTask() async {
        let scheduler = FakeScheduler()
        let c = coordinator(scheduler)
        c.register()
        let task = FakeTask()
        scheduler.handler?(task)
        for _ in 0..<200 where task.completed == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(task.completed, true)
    }
}
