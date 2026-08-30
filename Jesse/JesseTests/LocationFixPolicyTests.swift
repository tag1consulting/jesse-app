import XCTest
@testable import Jesse

/// The layer the defect actually lived in: how ONE fix is acquired.
///
/// The old code asked for a single `requestLocation()` fix and raced it against a
/// two-second bound. That bound sat above the `LocationContextProviding` seam, so every
/// existing location test could pass while the channel failed on nearly every precise
/// request on a real phone — there was nothing below the seam to write a test against.
/// `FixSourcing` is that seam, and everything here is driven through a scripted source:
/// no device, no simulator location, no network, no timing luck.
@MainActor
final class LocationFixPolicyTests: XCTestCase {

    // MARK: - A scripted CoreLocation

    /// A `FixSourcing` the test drives by hand. Records starts, stops and prepare calls,
    /// which is how "updates stopped on every exit path" is asserted — a
    /// `startUpdatingLocation` left running holds the GPS on and drains the battery, and
    /// that is a worse bug than the one being fixed.
    ///
    /// `nonisolated` class with `@MainActor` methods, mirroring the production
    /// conformer: a main-actor-isolated CLASS gets an isolated `deinit`, which has taken
    /// this test host down before.
    nonisolated final class ScriptedSource: FixSourcing, @unchecked Sendable {
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var preparedFor: [LocationPrecision] = []
        private(set) var startedAt: [LocationPrecision] = []
        /// Held only while updates are running, so a leaked stream is observable.
        private(set) var isRunning = false
        /// How long the (simulated) full-accuracy prompt sits on screen before the
        /// person answers it.
        var promptDuration: Duration?

        private var onUpdate: ((FixCandidate) -> Void)?
        private var onFailure: ((LocationFixFailure) -> Void)?

        @MainActor
        func prepareAccuracy(precision: LocationPrecision) async {
            preparedFor.append(precision)
            if let promptDuration {
                try? await Task.sleep(for: promptDuration)
            }
        }

        @MainActor
        func startUpdating(precision: LocationPrecision,
                           onUpdate: @escaping (FixCandidate) -> Void,
                           onFailure: @escaping (LocationFixFailure) -> Void) {
            starts += 1
            startedAt.append(precision)
            isRunning = true
            self.onUpdate = onUpdate
            self.onFailure = onFailure
        }

        @MainActor
        func stopUpdating() {
            stops += 1
            isRunning = false
            onUpdate = nil
            onFailure = nil
        }

        /// Deliver one arrival, exactly as `didUpdateLocations` would.
        @MainActor
        func deliver(_ candidate: FixCandidate) { onUpdate?(candidate) }

        @MainActor
        func fail(_ failure: LocationFixFailure) { onFailure?(failure) }
    }

    /// Run one acquisition and return its attempt. `drive` runs AFTER updates have
    /// started, so it can deliver arrivals the way CoreLocation would.
    @MainActor
    private func acquire(source: ScriptedSource,
                         precision: LocationPrecision = .precise,
                         budget: LocationFixBudget,
                         maxAgeSeconds: Int = 0,
                         drive: @escaping @MainActor (ScriptedSource) async -> Void = { _ in }
    ) async -> LocationFixAttempt {
        let acquisition = FixAcquisition(source: source, precision: precision,
                                         budget: budget, maxAgeSeconds: maxAgeSeconds)
        return await withCheckedContinuation {
            (cont: CheckedContinuation<LocationFixAttempt, Never>) in
            Task { @MainActor in
                await acquisition.begin { cont.resume(returning: $0) }
                await drive(source)
            }
        }
    }

    /// A budget whose deadline is short enough to test against without making the suite
    /// slow, and whose target is the real one.
    private func budget(deadlineMs: Int, target: Double = 65) -> LocationFixBudget {
        LocationFixBudget(deadline: .milliseconds(deadlineMs),
                          targetAccuracyMeters: target,
                          geocodeTimeout: .milliseconds(50))
    }

    private func fix(_ accuracy: Double, ageSeconds: TimeInterval = 0,
                     lat: Double = 55.94, lon: Double = -3.21) -> FixCandidate {
        FixCandidate(latitude: lat, longitude: lon, horizontalAccuracy: accuracy,
                     timestamp: Date().addingTimeInterval(-ageSeconds))
    }

    // MARK: - THE DEFECT: interim fixes are taken

    /// THE BUG, INVERTED. A stream of improving fixes, none of which reaches the target
    /// before the deadline. The old all-or-nothing shape returned nothing at all here —
    /// which is exactly what three consecutive precise requests did on a real phone,
    /// indoors, while a coarse attach was answering the same question. The best usable
    /// interim fix must come back instead.
    func testTheDeadlineReturnsTheBestInterimFixRatherThanNothing() async {
        let source = ScriptedSource()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 250)) { s in
            s.deliver(self.fix(3200))
            s.deliver(self.fix(850))
            s.deliver(self.fix(410))
            // …and then nothing more. The target (65 m) is never met.
        }
        XCTAssertEqual(attempt.fix?.horizontalAccuracy, 410,
                       "the deadline must return the TIGHTEST usable fix seen, not nil")
        XCTAssertNil(attempt.reason)
        XCTAssertFalse(attempt.metTarget, "it ended at the deadline, not on the target")
        XCTAssertEqual(source.stops, 1, "updates stopped exactly once")
        XCTAssertFalse(source.isRunning)
    }

    /// The other half: when a fix good enough arrives, the request ends IMMEDIATELY
    /// rather than sitting out the rest of its deadline. This is what keeps a longer
    /// deadline from costing anything on a warm device — the 6-second fulfilment budget
    /// is a ceiling, not an expectation.
    func testMeetingTheTargetReturnsEarlyAndStopsUpdating() async {
        let source = ScriptedSource()
        let started = Date()
        // A deliberately long deadline: if the target did not end the request, this test
        // would take five seconds instead of milliseconds.
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 5000)) { s in
            s.deliver(self.fix(900))
            s.deliver(self.fix(40))
        }
        XCTAssertEqual(attempt.fix?.horizontalAccuracy, 40)
        XCTAssertTrue(attempt.metTarget)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "it must return on the target, not sit out the deadline")
        XCTAssertEqual(source.stops, 1, "the GPS is released the moment the answer is in")
        XCTAssertFalse(source.isRunning)
    }

    // MARK: - THE TRAP: staleness

    /// THE TRAP IN THIS WHOLE CHANGE. `startUpdatingLocation()` typically opens with a
    /// CACHED fix, and that fix can be hours old and from another city — the
    /// `requestLocation()` code this replaces was accidentally shielded from it.
    /// Adopting interim fixes without an explicit timestamp test would let the channel
    /// confidently report the wrong town, which is worse than reporting nothing.
    func testAStaleFirstArrivalIsRejectedAndNothingIsReturned() async {
        let source = ScriptedSource()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 200),
                                    maxAgeSeconds: 60) { s in
            // A tight, beautiful, four-hour-old fix from another city.
            s.deliver(self.fix(12, ageSeconds: 4 * 3600, lat: 51.50, lon: -0.12))
        }
        XCTAssertNil(attempt.fix, "a stale fix must never be served as a current one")
        XCTAssertEqual(attempt.reason, .timedOut)
        XCTAssertEqual(source.stops, 1)
    }

    /// `max_age_seconds: 0` means literally "taken after this request began", not
    /// "whatever CoreLocation had lying around".
    func testMaxAgeZeroAcceptsOnlyAFixTakenAfterTheRequestBegan() async {
        let source = ScriptedSource()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 200),
                                    maxAgeSeconds: 0) { s in
            // One second old: fine for max_age 60, disqualified at 0.
            s.deliver(self.fix(30, ageSeconds: 1))
            // Taken now, i.e. after the request began.
            s.deliver(self.fix(300))
        }
        XCTAssertEqual(attempt.fix?.horizontalAccuracy, 300,
                       "the tighter fix predates the request, so it does not qualify")
    }

    /// …and the same stream with a window that admits it takes the tighter one, which is
    /// what proves the rejection above was the AGE and not something else.
    func testAWindowThatAdmitsTheOlderFixTakesIt() async {
        let source = ScriptedSource()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 200),
                                    maxAgeSeconds: 60) { s in
            s.deliver(self.fix(30, ageSeconds: 1))
            s.deliver(self.fix(300))
        }
        XCTAssertEqual(attempt.fix?.horizontalAccuracy, 30)
    }

    /// CoreLocation reports a NEGATIVE horizontal accuracy for a fix whose position is
    /// invalid. `LocationReading` already knew this; now the selection does too, rather
    /// than only the rendering.
    func testANegativeAccuracyFixIsUnusable() async {
        let source = ScriptedSource()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 200)) { s in
            s.deliver(self.fix(-1))
        }
        XCTAssertNil(attempt.fix)
        XCTAssertEqual(attempt.reason, .timedOut)
    }

    // MARK: - Nothing arrives

    /// Nothing ever arrives: nil, promptly, and the awaiting task closes rather than
    /// hanging the turn. (A `withCheckedContinuation` that is never resumed would hang
    /// this test, which is the assertion.)
    func testNothingArrivingTimesOutCleanly() async {
        let source = ScriptedSource()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 120))
        XCTAssertNil(attempt.fix)
        XCTAssertEqual(attempt.reason, .timedOut)
        XCTAssertEqual(source.stops, 1, "the deadline path stops updates too")
        XCTAssertFalse(source.isRunning)
    }

    /// A transient "cannot determine a position" does NOT end the request: CoreLocation
    /// keeps trying after one, and a fix commonly arrives a moment later. Ending there
    /// would throw away exactly the case interim fixes exist to rescue.
    func testATransientFailureDoesNotEndTheRequest() async {
        let source = ScriptedSource()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 400)) { s in
            s.fail(.unableToDetermine)
            try? await Task.sleep(for: .milliseconds(30))
            s.deliver(self.fix(50))
        }
        XCTAssertEqual(attempt.fix?.horizontalAccuracy, 50,
                       "a transient failure must not cancel a request that then succeeds")
    }

    /// …but when nothing ever arrives after one, the reason is `no_fix` rather than
    /// `timed_out`. They are different conversations with the owner.
    func testAFailureWithNoFixReportsNoFixRatherThanTimedOut() async {
        let source = ScriptedSource()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 150)) { s in
            s.fail(.unableToDetermine)
        }
        XCTAssertNil(attempt.fix)
        XCTAssertEqual(attempt.reason, .noFix)
    }

    /// A denial is terminal — waiting cannot produce authorization — and it stops
    /// updates on the way out.
    func testADenialEndsTheRequestImmediatelyAsUnauthorized() async {
        let source = ScriptedSource()
        let started = Date()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 5000)) { s in
            s.fail(.denied)
        }
        XCTAssertEqual(attempt.reason, .unauthorized)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "terminal means terminal")
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(source.isRunning)
    }

    // MARK: - Coarse

    /// A coarse request finishes on its FIRST usable fix, whatever the budget's target
    /// says. Asking for reduced accuracy and then waiting for a tight radius would be
    /// waiting for something the request declined.
    func testACoarseRequestReturnsOnItsFirstUsableFix() async {
        let source = ScriptedSource()
        let started = Date()
        let attempt = await acquire(source: source, precision: .coarse,
                                    budget: budget(deadlineMs: 5000)) { s in
            s.deliver(self.fix(2800))
        }
        XCTAssertEqual(attempt.fix?.horizontalAccuracy, 2800)
        XCTAssertTrue(attempt.metTarget)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// …and a coarse request never touches the accuracy prompt at all, which is what
    /// "a coarse request cannot raise any prompt" means structurally.
    func testACoarseRequestNeverPreparesFullAccuracy() async {
        let source = ScriptedSource()
        _ = await acquire(source: source, precision: .coarse,
                          budget: budget(deadlineMs: 100))
        XCTAssertEqual(source.preparedFor, [.coarse],
                       "prepare is called, and CLFixSource returns immediately for coarse")
        XCTAssertEqual(source.startedAt, [.coarse])
    }

    // MARK: - The accuracy prompt is not charged to the fix budget

    /// A device on reduced accuracy shows a system sheet for a precise request. The old
    /// code fired that sheet and started the fix in the same breath, so the two-second
    /// budget burned down while the sheet was still on screen — which made the FIRST
    /// precise request on such a device close to guaranteed to fail.
    ///
    /// The prompt is awaited, and the deadline clock starts after it: a 300 ms sheet in
    /// front of a 200 ms deadline must still leave the full 200 ms to find a fix.
    func testTheAccuracyPromptIsNotChargedAgainstTheFixDeadline() async {
        let source = ScriptedSource()
        source.promptDuration = .milliseconds(300)
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 200)) { s in
            // Arrives 100 ms after updates start — which is only reachable at all if the
            // deadline did not begin ticking during the prompt.
            try? await Task.sleep(for: .milliseconds(100))
            s.deliver(self.fix(30))
        }
        XCTAssertEqual(attempt.fix?.horizontalAccuracy, 30)
        XCTAssertEqual(source.preparedFor, [.precise])
        XCTAssertLessThan(attempt.elapsed, 0.2,
                          "elapsed is measured from after the prompt, not before it")
    }

    // MARK: - Cancellation

    /// The caller's outer bound firing must stop updates and release the source, exactly
    /// as every other exit path does.
    func testCancellationStopsUpdatesAndReleasesTheSource() async {
        let source = ScriptedSource()
        let acquisition = FixAcquisition(source: source, precision: .precise,
                                         budget: budget(deadlineMs: 5000), maxAgeSeconds: 0)
        let attempt = await withCheckedContinuation {
            (cont: CheckedContinuation<LocationFixAttempt, Never>) in
            Task { @MainActor in
                await acquisition.begin { cont.resume(returning: $0) }
                acquisition.cancel()
            }
        }
        XCTAssertNil(attempt.fix)
        XCTAssertEqual(attempt.reason, .timedOut)
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(source.isRunning, "a leaked stream holds the GPS on in the background")
    }

    /// Every exit path stops exactly once, and a second arrival after the resume is a
    /// silent no-op rather than a second resume (which would trap on the continuation).
    func testASecondArrivalAfterFinishingIsASilentNoOp() async {
        let source = ScriptedSource()
        let attempt = await acquire(source: source, budget: budget(deadlineMs: 5000)) { s in
            s.deliver(self.fix(20))
            // Racing arrivals: iOS can deliver an update and a failure for one request.
            s.deliver(self.fix(5))
            s.fail(.denied)
        }
        XCTAssertEqual(attempt.fix?.horizontalAccuracy, 20,
                       "the request finished on the first satisfying fix")
        XCTAssertEqual(source.stops, 1, "and stopped exactly once")
    }

    // MARK: - The selector, on its own

    func testTheSelectorKeepsTheTightestUsableFix() {
        var selector = FixSelector(startedAt: Date(timeIntervalSince1970: 1_000),
                                   maxAgeSeconds: 900, targetAccuracyMeters: 65)
        let base = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(selector.offer(FixCandidate(latitude: 0, longitude: 0,
                                                   horizontalAccuracy: 900, timestamp: base)),
                       .accepted)
        XCTAssertEqual(selector.offer(FixCandidate(latitude: 0, longitude: 0,
                                                   horizontalAccuracy: 1200, timestamp: base)),
                       .accepted, "a worse fix is kept but does not displace the best")
        XCTAssertEqual(selector.best?.horizontalAccuracy, 900)
        XCTAssertEqual(selector.offer(FixCandidate(latitude: 0, longitude: 0,
                                                   horizontalAccuracy: 60, timestamp: base)),
                       .satisfied)
        XCTAssertEqual(selector.best?.horizontalAccuracy, 60)
    }

    func testTheSelectorRejectsInvalidAndStaleFixes() {
        let started = Date(timeIntervalSince1970: 10_000)
        var selector = FixSelector(startedAt: started, maxAgeSeconds: 0,
                                   targetAccuracyMeters: 65)
        // Invalid: CoreLocation's negative sentinel.
        XCTAssertEqual(selector.offer(FixCandidate(latitude: 0, longitude: 0,
                                                   horizontalAccuracy: -1,
                                                   timestamp: started)), .rejected)
        // Stale: one second before the request began, with max_age 0.
        XCTAssertEqual(selector.offer(FixCandidate(latitude: 0, longitude: 0,
                                                   horizontalAccuracy: 5,
                                                   timestamp: started.addingTimeInterval(-1))),
                       .rejected)
        XCTAssertNil(selector.best)
        XCTAssertEqual(selector.rejectedCount, 2)
    }

    /// A coarse request's effective target is "the first usable fix", however the budget
    /// is configured.
    func testACoarseRequestsTargetIsAlwaysTheFirstUsableFix() {
        XCTAssertEqual(LocationFixBudget.fulfilment.targetAccuracy(for: .coarse), .infinity)
        XCTAssertEqual(LocationFixBudget.fulfilment.targetAccuracy(for: .precise), 65)
    }

    // MARK: - The two call sites spend different budgets

    /// A provider that records what each call site asked for.
    private final class RecordingProvider: LocationContextProviding, @unchecked Sendable {
        var readingToReturn: LocationReading
        private(set) var budgets: [LocationFixBudget] = []
        private(set) var precisions: [LocationPrecision] = []

        init(reading: LocationReading) { self.readingToReturn = reading }

        func authorizationState() async -> LocationAuthorizationState { .authorized }

        func reading(precision: LocationPrecision, maxAgeSeconds: Int,
                     wantsPlacemark: Bool,
                     budget: LocationFixBudget) async -> LocationReadingResult {
            budgets.append(budget)
            precisions.append(precision)
            return .got(readingToReturn)
        }
    }

    private var somewhere: LocationReading {
        LocationReading(latitude: 55.94, longitude: -3.21, accuracyMeters: 900,
                        placemark: "Fountainbridge, Edinburgh EH3",
                        timestamp: Date())
    }

    /// THE TWO BUDGETS ARE DIFFERENT, AND EACH CALL SITE USES ITS OWN.
    ///
    /// One shared timeout used to serve both, and it was reasoned about for the send
    /// path — "generous for a warm fix, short enough not to visibly delay the turn" —
    /// and then inherited by the fulfilment path, where the owner is already watching a
    /// spinner and the reasoning does not apply. That inheritance is the second half of
    /// the bug.
    func testTheProactiveAttachAndTheFulfilmentSpendDifferentBudgets() async {
        XCTAssertNotEqual(LocationFixBudget.proactive, LocationFixBudget.fulfilment,
                          "collapsing these back into one constant is the bug")
        XCTAssertLessThan(LocationFixBudget.proactive.deadline,
                          LocationFixBudget.fulfilment.deadline,
                          "the send path delays the owner's message; the retry does not")
        XCTAssertLessThan(LocationFixBudget.proactive.geocodeTimeout,
                          LocationFixBudget.fulfilment.geocodeTimeout)

        let proactive = RecordingProvider(reading: somewhere)
        _ = await LocationContextResolver.resolve(enabled: true, relevant: true,
                                                  provider: proactive)
        XCTAssertEqual(proactive.budgets, [.proactive],
                       "the send path spends the tight budget")

        let fulfilment = RecordingProvider(reading: somewhere)
        let channel = LocationChannel(provider: fulfilment, enabled: { true })
        _ = await channel.block(for: NeedsLocationRequest(fields: [.placemark],
                                                          precision: .precise,
                                                          maxAgeSeconds: 0))
        XCTAssertEqual(fulfilment.budgets, [.fulfilment],
                       "the directive retry spends the longer one")
    }

    // MARK: - Reasons reach the wire, one per cause

    /// A provider stuck in one state, for the reason matrix.
    private final class StuckProvider: LocationContextProviding, @unchecked Sendable {
        let state: LocationAuthorizationState
        let reason: LocationUnavailableReason?
        init(state: LocationAuthorizationState, reason: LocationUnavailableReason? = nil) {
            self.state = state
            self.reason = reason
        }
        func authorizationState() async -> LocationAuthorizationState { state }
        func reading(precision: LocationPrecision, maxAgeSeconds: Int,
                     wantsPlacemark: Bool,
                     budget: LocationFixBudget) async -> LocationReadingResult {
            reason.map { .unavailable($0) } ?? .got(LocationReading())
        }
    }

    /// EACH CAUSE ARRIVES AS ITS OWN REASON. The bridge renders a different line for
    /// each; the app's job is to tell them apart in the first place, which the old
    /// single Bool could not.
    func testEachFailureCauseProducesItsOwnWireReason() async {
        let request = NeedsLocationRequest(fields: [.placemark], precision: .precise,
                                           maxAgeSeconds: 0)
        // The owner's own switch, checked before anything touches CoreLocation.
        let off = LocationChannel(provider: StuckProvider(state: .authorized),
                                  enabled: { false })
        var outcome = await fulfillDeviceContext(request, through: off)
        XCTAssertEqual(outcome.unavailableReason, "feature_off")
        XCTAssertTrue(outcome.unavailable, "and it still terminates the channel")

        // The device-wide switch.
        let services = LocationChannel(provider: StuckProvider(state: .servicesOff),
                                       enabled: { true })
        outcome = await fulfillDeviceContext(request, through: services)
        XCTAssertEqual(outcome.unavailableReason, "services_off")

        // This app's permission.
        let denied = LocationChannel(provider: StuckProvider(state: .unauthorized),
                                     enabled: { true })
        outcome = await fulfillDeviceContext(request, through: denied)
        XCTAssertEqual(outcome.unavailableReason, "unauthorized")

        // Authorized, but the fix ran out of time — the one that needs no setting
        // changed, and the one the old conflated message got wrong.
        let slow = LocationChannel(
            provider: StuckProvider(state: .authorized, reason: .timedOut),
            enabled: { true })
        outcome = await fulfillDeviceContext(request, through: slow)
        XCTAssertEqual(outcome.unavailableReason, "timed_out")

        // Authorized, but the phone cannot place itself at all.
        let lost = LocationChannel(
            provider: StuckProvider(state: .authorized, reason: .noFix),
            enabled: { true })
        outcome = await fulfillDeviceContext(request, through: lost)
        XCTAssertEqual(outcome.unavailableReason, "no_fix")
    }

    /// Every reason the app can emit is one the bridge whitelists. A reason with no
    /// matching bridge token would silently fall back to the generic four-causes line,
    /// which is the failure this whole item is about. (`scripts/ci-guards.sh` checks the
    /// same thing against the Rust source; this checks it in the app's own terms.)
    func testEveryReasonIsANonEmptySnakeCaseToken() {
        for reason in LocationUnavailableReason.allCases {
            XCTAssertFalse(reason.rawValue.isEmpty)
            XCTAssertEqual(reason.rawValue, reason.rawValue.lowercased())
            XCTAssertNil(reason.rawValue.rangeOfCharacter(from: .whitespacesAndNewlines))
        }
        XCTAssertEqual(LocationUnavailableReason.allCases.count, 5)
    }

    // MARK: - Rendering and caching the precision ACHIEVED

    /// FALSE PRECISION. A `precise` request answered by a 3 km fix used to print five
    /// decimal places — about a metre — of a position known only to within a town,
    /// because the rounding was chosen from what was ASKED FOR. The agent reads this
    /// block to decide whether it can name a street, so that is not a cosmetic problem.
    func testAPreciseRequestAnsweredByACoarseFixRendersAsCoarse() {
        let request = NeedsLocationRequest(fields: [.coordinates, .accuracy],
                                           precision: .precise, maxAgeSeconds: 0)
        let coarseReading = LocationReading(latitude: 55.9412345, longitude: -3.2112345,
                                            accuracyMeters: 3200, placemark: nil,
                                            timestamp: Date())
        let block = LocationRequestFulfiller.block(request: request, reading: coarseReading)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("Coordinates (coarse)"),
                      "a precise request answered by a coarse fix must READ as coarse")
        XCTAssertTrue(block!.contains("55.941, -3.211"), "three decimals, not five")

        // …and the same request answered by a real precise fix still renders precise.
        let preciseReading = LocationReading(latitude: 55.9412345, longitude: -3.2112345,
                                             accuracyMeters: 12, placemark: nil,
                                             timestamp: Date())
        let precise = LocationRequestFulfiller.block(request: request, reading: preciseReading)
        XCTAssertTrue(precise!.contains("Coordinates (precise)"))
        XCTAssertTrue(precise!.contains("55.94123, -3.21123"))
    }

    /// A coarse request is never quietly upgraded, however good the fix turned out to
    /// be: the request declined that precision.
    func testACoarseRequestNeverRendersPrecise() {
        let request = NeedsLocationRequest(fields: [.coordinates], precision: .coarse,
                                           maxAgeSeconds: 300)
        let reading = LocationReading(latitude: 55.9412345, longitude: -3.2112345,
                                      accuracyMeters: 5, placemark: nil, timestamp: Date())
        let block = LocationRequestFulfiller.block(request: request, reading: reading)
        XCTAssertTrue(block!.contains("Coordinates (coarse)"))
    }

    /// A reading with no accuracy figure at all counts as coarse — an unquantified fix
    /// is one whose precision nothing vouches for.
    func testAnUnquantifiedFixRendersCoarse() {
        let reading = LocationReading(latitude: 1, longitude: 2, accuracyMeters: nil,
                                      placemark: nil, timestamp: Date())
        XCTAssertEqual(LocationRequestFulfiller.achievedPrecision(reading, requested: .precise),
                       .coarse)
    }

    // MARK: - The provider's cache, end to end

    /// A provider wired to a scripted source and a forced authorization, so the cache
    /// and the achieved-precision bookkeeping are testable on a simulator that has no
    /// fix and is permanently unauthorized.
    @MainActor
    private func provider(_ source: ScriptedSource) -> LocationContextProvider {
        LocationContextProvider(attempts: LocationAttemptLog(),
                                makeSource: { source },
                                authorization: { .authorized })
    }

    /// A PRECISE REQUEST THAT DEGRADES IS CACHED AS WHAT IT IS. Storing a fix under the
    /// precision that was REQUESTED was wrong in both directions: a degraded fix was
    /// later served as though it had answered a precise request, and the same fix was
    /// refused for the coarse requests it could have answered instantly.
    func testADegradedPreciseFixIsCachedAsCoarseAndServesLaterCoarseRequests() async {
        let source = ScriptedSource()
        let provider = provider(source)

        // A precise request that only ever gets a 3 km fix, ending at the deadline.
        // The budget is hoisted into a local because `async let` runs the call off this
        // main-actor test, and reading it from `self` there would be a data race.
        let quarterSecond = budget(deadlineMs: 250)
        async let first = provider.reading(precision: .precise, maxAgeSeconds: 0,
                                           wantsPlacemark: false, budget: quarterSecond)
        try? await Task.sleep(for: .milliseconds(40))
        source.deliver(fix(3000))
        let degraded = await first
        XCTAssertNil(degraded.reason)
        XCTAssertEqual(degraded.reading.accuracyMeters, 3000)
        XCTAssertEqual(source.starts, 1)

        // A LATER COARSE request inside the window is served from that cache — the GPS
        // is never woken a second time.
        let cached = await provider.reading(precision: .coarse, maxAgeSeconds: 300,
                                            wantsPlacemark: false,
                                            budget: budget(deadlineMs: 250))
        XCTAssertEqual(cached.reading.accuracyMeters, 3000)
        XCTAssertEqual(source.starts, 1, "a cache hit must not start updates again")

        // …and a later PRECISE request is NOT served from it, because the cached fix is
        // coarse and cannot answer one.
        let fifthSecond = budget(deadlineMs: 200)
        async let third = provider.reading(precision: .precise, maxAgeSeconds: 300,
                                           wantsPlacemark: false, budget: fifthSecond)
        try? await Task.sleep(for: .milliseconds(40))
        source.deliver(fix(20))
        let fresh = await third
        XCTAssertEqual(fresh.reading.accuracyMeters, 20)
        XCTAssertEqual(source.starts, 2, "a coarse cache entry cannot answer a precise ask")
    }

    /// The failure reasons the provider itself produces, and the fact that a failing
    /// channel records a diagnosable attempt rather than nothing.
    func testTheProviderReportsItsDegradePathsWithReasons() async {
        let log = LocationAttemptLog()
        let servicesOff = LocationContextProvider(attempts: log,
                                                  makeSource: { ScriptedSource() },
                                                  authorization: { .servicesOff })
        var result = await servicesOff.reading(precision: .coarse, maxAgeSeconds: 0,
                                               wantsPlacemark: false, budget: .proactive)
        XCTAssertEqual(result.reason, .servicesOff)
        XCTAssertTrue(result.reading.isEmpty)
        XCTAssertEqual(log.last?.reason, .servicesOff)

        let unauthorized = LocationContextProvider(attempts: log,
                                                   makeSource: { ScriptedSource() },
                                                   authorization: { .unauthorized })
        result = await unauthorized.reading(precision: .precise, maxAgeSeconds: 0,
                                            wantsPlacemark: false, budget: .proactive)
        XCTAssertEqual(result.reason, .unauthorized)

        // Authorized, nothing ever arrives: timed out, with the attempt recorded so the
        // Settings row can say so.
        let source = ScriptedSource()
        let timingOut = LocationContextProvider(attempts: log, makeSource: { source },
                                                authorization: { .authorized })
        result = await timingOut.reading(precision: .precise, maxAgeSeconds: 0,
                                         wantsPlacemark: false,
                                         budget: budget(deadlineMs: 120))
        XCTAssertEqual(result.reason, .timedOut)
        XCTAssertEqual(log.last?.reason, .timedOut)
        XCTAssertFalse(log.last!.succeeded)
        XCTAssertEqual(source.stops, 1, "even the failing path releases the GPS")
    }

    /// The Settings diagnostic holds an outcome, an accuracy and an elapsed time — and
    /// NO place data. It is the one thing in this channel that outlives the turn, so
    /// what it may hold is a security question rather than a cosmetic one.
    func testTheDiagnosticSummaryCarriesNoPlaceData() async {
        let log = LocationAttemptLog()
        let source = ScriptedSource()
        let provider = LocationContextProvider(attempts: log, makeSource: { source },
                                               authorization: { .authorized })
        let quarterSecond = budget(deadlineMs: 250)
        async let reading = provider.reading(precision: .precise, maxAgeSeconds: 0,
                                             wantsPlacemark: false, budget: quarterSecond)
        try? await Task.sleep(for: .milliseconds(40))
        source.deliver(fix(42, lat: 55.9412345, lon: -3.2112345))
        _ = await reading

        let record = try? XCTUnwrap(log.last)
        XCTAssertEqual(record?.achieved, .precise)
        XCTAssertEqual(record?.accuracyMeters, 42)
        let summary = LocationAttemptLog.summary(record!)
        XCTAssertTrue(summary.contains("precise"))
        XCTAssertTrue(summary.contains("42 m"))
        for leak in ["55.9", "-3.2", "Edinburgh", "Fountainbridge"] {
            XCTAssertFalse(summary.contains(leak), "the diagnostic must not name a place")
        }
    }
}
