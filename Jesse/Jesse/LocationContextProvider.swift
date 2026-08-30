import CoreLocation
import MapKit
import Foundation

// The ONE file that imports CoreLocation. It conforms to `LocationContextProviding`
// (declared in the Foundation-only `LocationContext.swift`) and does nothing but read:
// take one bounded fix, optionally reverse-geocode it, and reduce both to a pure value.
// All formatting/policy/gating logic lives in the pure files with full unit tests; this
// file is deliberately thin so the untestable CoreLocation surface is as small as
// possible.
//
// The fix-ACQUISITION policy — which arrivals count, which one wins, when to stop
// waiting, what to report when nothing usable came — used to live in here too, behind
// the seam rather than in front of it, which is why the defect it contained could not be
// tested for. It now lives in `LocationFixPolicy.swift` over plain values, and what is
// left in this file is `CLFixSource`: start, stop, two callbacks.
//
// WHAT IT DELIBERATELY DOES NOT DO, and this is the security posture rather than a
// to-do list:
//
//   * NO always authorization. `requestWhenInUseAuthorization` only. There is no code
//     path here that can ask for `.authorizedAlways`.
//   * NO background location, NO significant-change monitoring, NO region monitoring,
//     NO visit monitoring, NO heading. The app declares no location background mode,
//     so none of it would run anyway — but the absence is also structural: this file
//     starts and stops updates inside one awaited call and holds no manager between
//     turns. `startUpdatingLocation` is now used in place of `requestLocation`, which
//     makes STOPPING it on every exit path load-bearing rather than tidy — see
//     `CLFixSource.stopUpdating` and `FixAcquisition.finish`.
//   * NO persistence. A reading is returned, rendered into one request, and dropped.
//     Nothing is written to the vault, to SwiftData, or to UserDefaults, and the only
//     things kept in memory are the single cached fix below and the last-attempt
//     diagnostic, which holds no place data at all.
//   * NO logging of coordinates. The log lines here name statuses, failures, elapsed
//     times and accuracy radii — never a latitude and never a place name.

/// Reads one location fix (and optionally its placemark) for the `location_context`
/// block. Read-only, when-in-use only, and bounded: every degrade path — services off,
/// unauthorized, denied, restricted, timed out, no fix available, a simulator with no
/// location set — yields an empty reading AND the reason it was empty, so a turn is
/// never blocked or broken by location and the agent is told what actually happened.
///
/// `@unchecked Sendable`: the type holds only immutable configuration plus a lock-
/// guarded cache box; `CLLocationManager` is created and destroyed inside a single call
/// and never crosses an isolation boundary.
///
/// `nonisolated` is not decoration. This module defaults to `@MainActor` isolation, and
/// a main-actor-isolated CLASS gets an actor-isolated `deinit`. `JesseClient` holds one
/// of these as a stored property, so every `JesseClient` released off the main actor —
/// which is most of them, since the send path is nonisolated — tears one down through
/// that isolated deinit and aborts the process with `pointer being freed was not
/// allocated`. It took the test host down on two `JesseIntegrationTests` cases that do
/// nothing but construct a client and read its URLSession config. The provider is a
/// `Sendable` value that must be usable from any context; saying so here is both the
/// fix and the accurate description. Same for the delegate and cache classes below.
nonisolated final class LocationContextProvider: LocationContextProviding, @unchecked Sendable {
    /// The last fix, kept in memory ONLY, so a `max_age_seconds` the directive is happy
    /// with can be served without waking the GPS. Dropped on process exit like anything
    /// else in memory; never written anywhere.
    ///
    /// A channel that ALWAYS FAILS never populates this at all, which is why repeated
    /// attempts never got easier: three failed precise requests left the cache exactly as
    /// empty as they found it, so the fourth started from cold too. Taking interim fixes
    /// is what makes the cache start doing its job.
    private let cache = CachedFix()
    /// Where the last attempt is recorded for the Settings diagnostic. Injected so the
    /// tests do not write to the shared one.
    private let attempts: LocationAttemptLog
    /// The source of each acquisition. A factory rather than a stored instance: a
    /// `CLLocationManager` is created and destroyed inside one call and never held
    /// between turns.
    private let makeSource: @Sendable () -> any FixSourcing
    /// How the live authorization state is read. Injected for the same reason
    /// `makeSource` is: the cache, the degrade paths and the achieved-precision
    /// bookkeeping are policy, and a simulator is permanently unauthorized, so without
    /// this seam every one of them would be untestable behind a `guard` that always
    /// fails.
    private let authorization: @Sendable () -> LocationAuthorizationState

    init(attempts: LocationAttemptLog = .shared,
         makeSource: @escaping @Sendable () -> any FixSourcing = { CLFixSource() },
         authorization: @escaping @Sendable () -> LocationAuthorizationState = {
             LocationPermissionStatus.state()
         }) {
        self.attempts = attempts
        self.makeSource = makeSource
        self.authorization = authorization
    }

    // MARK: - Authorization

    /// The live state, read fresh, split three ways so "off for the whole device" and
    /// "off for this app" are different answers — they need different things from the
    /// owner, and telling him the wrong one is what cost an hour.
    ///
    /// `.notDetermined` reports `.unauthorized` on purpose: the app has never asked, and
    /// asking here — inside a turn, because of a message he typed — is exactly the
    /// mid-turn ambush the gate exists to prevent. The first ask happens from the
    /// Settings row, where he chose it.
    func authorizationState() async -> LocationAuthorizationState {
        authorization()
    }

    /// Ask for when-in-use authorization. Called from the Settings row and from
    /// nowhere else, so the system prompt only ever appears at a moment the owner
    /// chose. Returns the status after the ask settles.
    ///
    /// There is deliberately no `requestAlwaysAuthorization` anywhere in this app.
    @MainActor
    static func requestAuthorization() async -> Bool {
        guard CLLocationManager.locationServicesEnabled() else {
            Log.location.notice("location: services are off — not requesting authorization")
            return false
        }
        let manager = CLLocationManager()
        guard manager.authorizationStatus == .notDetermined else {
            // Already answered, one way or the other. Re-asking does nothing (iOS
            // shows no second prompt), so report what we have.
            return manager.authorizationStatus == .authorizedWhenInUse
        }
        let delegate = AuthorizationWaiter()
        manager.delegate = delegate
        manager.requestWhenInUseAuthorization()
        let status = await delegate.settled()
        return status == .authorizedWhenInUse
    }

    // MARK: - Reading

    func reading(precision: LocationPrecision,
                 maxAgeSeconds: Int,
                 wantsPlacemark: Bool,
                 budget: LocationFixBudget) async -> LocationReadingResult {
        let state = await authorizationState()
        guard state == .authorized else {
            let reason = state.unavailableReason ?? .unauthorized
            record(requested: precision, achieved: nil, accuracy: nil,
                   elapsed: 0, reason: reason, fromCache: false)
            return .unavailable(reason)
        }

        let fix: FixCandidate
        // The precision the fix ACHIEVED, which is what it is cached and rendered under
        // — never the precision that was asked for.
        let achieved: LocationPrecision
        var cachedPlace: String?
        var servedFromCache = false
        var elapsed: TimeInterval = 0

        if let hit = cache.load(maxAge: TimeInterval(maxAgeSeconds), precision: precision) {
            fix = hit.fix
            achieved = hit.precision
            cachedPlace = hit.placemark
            servedFromCache = true
        } else {
            let attempt = await oneFix(precision: precision,
                                       maxAgeSeconds: maxAgeSeconds,
                                       budget: budget)
            elapsed = attempt.elapsed
            guard let got = attempt.fix else {
                let reason = attempt.reason ?? .timedOut
                Log.location.notice(
                    "location: fix failed (reason=\(reason.rawValue) "
                    + "requested=\(precision.rawValue) elapsed_ms=\(Self.ms(elapsed)))")
                record(requested: precision, achieved: nil, accuracy: nil,
                       elapsed: elapsed, reason: reason, fromCache: false)
                return .unavailable(reason)
            }
            fix = got
            achieved = Self.achievedPrecision(of: got)
            cache.store(got, precision: achieved)
            // A placemark already resolved for a fix close enough to share it. A repeat
            // request inside the cache window used to pay the geocode round trip again
            // for an answer that cannot have changed.
            cachedPlace = cache.placemark(near: got)
        }

        Log.location.notice(
            "location: fix ok (requested=\(precision.rawValue) achieved=\(achieved.rawValue) "
            + "accuracy_m=\(Int(fix.horizontalAccuracy.rounded())) "
            + "elapsed_ms=\(Self.ms(elapsed)) cached=\(servedFromCache))")
        record(requested: precision, achieved: achieved, accuracy: fix.horizontalAccuracy,
               elapsed: elapsed, reason: nil, fromCache: servedFromCache)

        var out = LocationReading(
            latitude: fix.latitude,
            longitude: fix.longitude,
            accuracyMeters: fix.horizontalAccuracy > 0 ? fix.horizontalAccuracy : nil,
            placemark: nil,
            timestamp: fix.timestamp)
        if wantsPlacemark {
            if let cachedPlace {
                out.placemark = cachedPlace
            } else if let resolved = await bounded(budget.geocodeTimeout, {
                await Self.placemark(for: fix)
            }).flatMap({ $0 }) {
                out.placemark = resolved
                cache.storePlacemark(resolved, for: fix)
            }
        }
        return .got(out)
    }

    /// One fix, through a source that lives only for the duration of this call.
    ///
    /// `precision == .coarse` never touches `requestTemporaryFullAccuracyAuthorization`,
    /// so a coarse request cannot produce a prompt. A `precise` request on a device that
    /// granted reduced accuracy asks for temporary full accuracy — the one prompt this
    /// channel can raise, and only because the model explicitly stated `"precise"` — and
    /// **waits for the answer before the deadline clock starts**, which the old code did
    /// not. It fired the prompt and started the fix in the same breath, so the budget
    /// burned down while the sheet was still on screen.
    ///
    /// THREE THINGS HERE ARE LOAD-BEARING.
    ///
    /// **The acquisition is a `let` in THIS frame.** `CLLocationManager.delegate` is a
    /// WEAK reference, so the source's only strong owner is whoever holds it — and the
    /// manager's only strong owner is the source. When both were locals inside the inner
    /// `Task { @MainActor in … }`, they died the instant that Task body finished, which
    /// is immediately after the request was started. A deallocated manager delivers
    /// neither `didUpdateLocations` nor `didFailWithError`, so the continuation was never
    /// resumed at all. Declared out here, the async frame keeps it alive for the whole
    /// suspension.
    ///
    /// **The cancellation handler is what lets the caller's task group close.**
    /// `bounded` races this against a sleep inside a `withTaskGroup`, and a task group
    /// cannot return until every child finishes — `cancelAll()` only *requests*
    /// cancellation. A plain non-throwing `withCheckedContinuation` ignores that request
    /// entirely, so a fix that never arrives left the group unable to return and hung the
    /// whole turn. Resuming on cancel is what makes the bound real.
    ///
    /// **The outer bound is NOT the fix deadline.** `FixAcquisition` owns the deadline
    /// itself, and starts it only after the accuracy prompt settles. The bound here is
    /// that deadline plus `authorizationGrace`, and exists for exactly one case: a prompt
    /// nobody ever answers. Making it the fix bound would put the prompt-reading seconds
    /// back on the budget, which is the bug.
    private func oneFix(precision: LocationPrecision,
                        maxAgeSeconds: Int,
                        budget: LocationFixBudget) async -> LocationFixAttempt {
        // Owned by this frame, NOT by the Task below — see above.
        let acquisition = FixAcquisition(source: makeSource(),
                                         precision: precision,
                                         budget: budget,
                                         maxAgeSeconds: maxAgeSeconds)
        let interval = Log.locationFix.begin("location-fix")
        let attempt = await bounded(budget.deadline + LocationFixBudget.authorizationGrace, {
            () -> LocationFixAttempt? in
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    (cont: CheckedContinuation<LocationFixAttempt, Never>) in
                    Task { @MainActor in
                        await acquisition.begin { cont.resume(returning: $0) }
                    }
                }
            } onCancel: {
                // Hop to the main actor rather than isolating the acquisition to it:
                // this type is held by `JesseClient` and released off the main actor,
                // and a main-actor class gets an isolated deinit that aborts the process
                // on such a release. The hop keeps every resume/teardown on the actor
                // the manager delivers on, which is what makes the single-resume guard
                // sufficient against this race.
                Task { @MainActor in acquisition.cancel() }
            }
        })
        // The prompt was never answered: the outer net fired and there is no attempt to
        // report. Charged as a timeout, which is what it is.
        let result = attempt ?? .failure(.timedOut, elapsed: 0)
        // Instrumentation, and the reason the deadlines in `LocationFixBudget` can be
        // chosen from measurement rather than guessed the way the old 2 seconds was.
        // Elapsed, achieved accuracy, outcome — and NO coordinate and NO place name.
        Log.locationFix.end("location-fix", interval,
                            Self.signpostSummary(result, precision: precision))
        return result
    }

    /// The one-line summary of an attempt, for the signpost and nothing else. Carries
    /// numbers about the fix, never the fix.
    private static func signpostSummary(_ attempt: LocationFixAttempt,
                                        precision: LocationPrecision) -> String {
        let elapsed = "elapsed_ms=\(ms(attempt.elapsed))"
        guard let fix = attempt.fix else {
            return "requested=\(precision.rawValue) outcome=\(attempt.reason?.rawValue ?? "none") "
                + elapsed
        }
        return "requested=\(precision.rawValue) outcome=fix "
            + "accuracy_m=\(Int(fix.horizontalAccuracy.rounded())) "
            + "met_target=\(attempt.metTarget) " + elapsed
    }

    private static func ms(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }

    /// What a fix actually achieved, which is what it is cached and rendered under. The
    /// same ceiling the block rendering uses, so a fix cached as `precise` is exactly a
    /// fix that would print five decimal places.
    private static func achievedPrecision(of fix: FixCandidate) -> LocationPrecision {
        fix.horizontalAccuracy > 0
            && fix.horizontalAccuracy <= LocationRequestFulfiller.preciseRenderingCeilingMeters
            ? .precise : .coarse
    }

    private func record(requested: LocationPrecision,
                        achieved: LocationPrecision?,
                        accuracy: Double?,
                        elapsed: TimeInterval,
                        reason: LocationUnavailableReason?,
                        fromCache: Bool) {
        attempts.record(LocationAttemptRecord(
            requested: requested, achieved: achieved,
            accuracyMeters: accuracy.flatMap { $0 > 0 ? $0 : nil },
            elapsed: elapsed, reason: reason, servedFromCache: fromCache, at: Date()))
    }

    /// Reverse-geocode one fix into a human place line, or nil. Network-bound and
    /// entirely best-effort: a failure just means the block carries coordinates without
    /// a name.
    ///
    /// `MKReverseGeocodingRequest` rather than `CLGeocoder`, which iOS 26 deprecates.
    ///
    /// `nonisolated`, and that is load-bearing rather than incidental: `mapItems` is a
    /// nonisolated async property, and neither `MKReverseGeocodingRequest` nor
    /// `MKMapItem` is `Sendable`. Awaiting it FROM the main actor would send the request
    /// out and the results back across an isolation boundary, which does not compile.
    /// Keeping the whole geocode off the actor means no MapKit value crosses anything —
    /// only the assembled `String` leaves, and a String may.
    private nonisolated static func placemark(for fix: FixCandidate) async -> String? {
        let location = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        // Run in a DETACHED task, not merely a nonisolated function. A nonisolated async
        // function inherits its caller's isolation, so awaiting `mapItems` from it still
        // counts as sending a non-Sendable MapKit value across a boundary. A detached
        // task has an isolation of its own: the request is built, awaited and consumed
        // entirely inside it, and the only thing that comes back out is the `String?`.
        return await Task.detached { () -> String? in
            guard let request = MKReverseGeocodingRequest(location: location),
                  let items = try? await request.mapItems,
                  let item = items.first else {
                return nil
            }
            return placemarkLine(from: item.address)
        }.value
    }

    /// The place line assembled from a resolved address. Sub-locality through country,
    /// skipping the parts that are absent, with adjacent repeats collapsed (a city whose
    /// admin area shares its name).
    ///
    /// Deliberately NOT the street address: a thoroughfare and a house number are a home
    /// address, and nothing this channel answers — "what's near me", "how far is X",
    /// "is it open" — needs one. That is a data-minimisation decision, not an oversight.
    private nonisolated static func placemarkLine(from address: MKAddress?) -> String? {
        guard let address else { return nil }
        // `shortAddress` is the locality-level rendering; `fullAddress` carries the
        // street. Prefer the short form, and fall back to the full one ONLY when there
        // is no short form at all — which is the one path that can put a thoroughfare in
        // the block, and is why it is the fallback rather than the default.
        let line = address.shortAddress ?? address.fullAddress
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var seen: [String] = []
        for part in line.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
        where !part.isEmpty && seen.last != part {
            seen.append(part)
        }
        return seen.isEmpty ? nil : seen.joined(separator: ", ")
    }

    /// Run `operation` under a hard bound; nil when it does not finish in time. The
    /// same shape as `HealthContextTimeout.orEmpty`, specialized to an optional.
    private func bounded<T: Sendable>(_ limit: Duration,
                                      _ operation: @escaping @Sendable () async -> T?)
        async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// The queryable side of the permission, for the Settings row and the gate. Unlike
/// HealthKit's read status — which Apple hides by design, so a denial is invisible —
/// CoreLocation reports its status honestly, so the row can say "this is off in
/// Settings" instead of leaving a toggle on that can never attach anything.
nonisolated enum LocationPermissionStatus {
    /// The live three-way state. `.notDetermined` is `.unauthorized`: nobody has been
    /// asked yet, which is a different row but the same answer to "can this read now".
    static func state() -> LocationAuthorizationState {
        guard CLLocationManager.locationServicesEnabled() else { return .servicesOff }
        return CLLocationManager().authorizationStatus == .authorizedWhenInUse
            ? .authorized : .unauthorized
    }

    /// The owner has said no, or the device is restricted (Screen Time, MDM). NOT true
    /// for `.notDetermined`: nobody has been asked yet, which is a different row.
    static func isDenied() -> Bool {
        guard CLLocationManager.locationServicesEnabled() else { return true }
        switch CLLocationManager().authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// Whether FULL accuracy is granted, as distinct from when-in-use authorization.
    /// A device can be authorized and still only ever hand back a 1–3 km circle, which
    /// is the single most confusing state this channel has and is why the Settings row
    /// now says it out loud.
    static func isFullAccuracyGranted() -> Bool {
        guard CLLocationManager.locationServicesEnabled() else { return false }
        return CLLocationManager().accuracyAuthorization == .fullAccuracy
    }

    /// The authorization status as one short owner-facing phrase.
    static func statusText() -> String {
        guard CLLocationManager.locationServicesEnabled() else {
            return "Location Services off (device-wide)"
        }
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse: return "While Using the App"
        case .authorizedAlways: return "Always (this app never asks for this)"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - The CoreLocation source (the only stateful CoreLocation surface)

/// `FixSourcing` over a real `CLLocationManager`. Owns the manager — the ONLY strong
/// reference to it, because `delegate` is weak and a manager with no owner deallocates
/// and never calls back — and forwards arrivals and failures as plain values.
///
/// **`startUpdatingLocation`, not `requestLocation`, and that is the whole fix.**
/// `requestLocation()` delivers exactly one callback and only once CoreLocation is
/// satisfied it has met `desiredAccuracy`; at `kCLLocationAccuracyBest`, taken cold or
/// indoors, that regularly takes longer than any budget this channel can afford, and
/// every progressively-improving interim fix computed on the way was thrown away
/// unseen. Updates deliver those interim fixes, and `FixAcquisition` keeps the best one.
///
/// The cost of that change is that stopping is now mandatory: a `startUpdatingLocation`
/// left running holds the GPS on and drains the battery in the background, which is a
/// worse bug than the one being fixed. `stopUpdating` is called on every exit path
/// including cancellation and error, and there is a test that proves it.
///
/// `nonisolated`/`@unchecked Sendable` deliberately: an instance is reachable from
/// `LocationContextProvider`, which `JesseClient` holds and releases off the main actor.
/// A main-actor-isolated class gets an isolated deinit and aborts the process on such a
/// release, which is a crash this file has already had once.
nonisolated final class CLFixSource: NSObject, CLLocationManagerDelegate, FixSourcing,
                                     @unchecked Sendable {
    private var manager: CLLocationManager?
    private var onUpdate: ((FixCandidate) -> Void)?
    private var onFailure: ((LocationFixFailure) -> Void)?

    /// Settle the temporary-full-accuracy prompt BEFORE the caller starts its clock.
    ///
    /// A coarse request never reaches the prompt at all — that is what "a coarse request
    /// cannot raise any prompt" means structurally rather than by convention. A precise
    /// request on a device that already granted full accuracy does not reach it either.
    ///
    /// The completion handler is awaited, which the old code did not do: it fired the
    /// prompt and started the fix immediately, so on a reduced-accuracy device the sheet
    /// was still on screen while the two-second budget expired, and the first precise
    /// request was close to guaranteed to fail.
    ///
    /// A refusal is not an error here. The handler's error is deliberately ignored:
    /// declining means the request carries on at reduced accuracy and returns the coarse
    /// fix, which is a real answer and much better than nothing.
    @MainActor
    func prepareAccuracy(precision: LocationPrecision) async {
        guard precision == .precise else { return }
        let manager = self.manager ?? CLLocationManager()
        self.manager = manager
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            manager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: "PreciseDistance") { _ in
                cont.resume()
            }
        }
    }

    @MainActor
    func startUpdating(precision: LocationPrecision,
                       onUpdate: @escaping (FixCandidate) -> Void,
                       onFailure: @escaping (LocationFixFailure) -> Void) {
        self.onUpdate = onUpdate
        self.onFailure = onFailure
        let manager = self.manager ?? CLLocationManager()
        self.manager = manager
        manager.desiredAccuracy = precision == .precise
            ? kCLLocationAccuracyBest
            : kCLLocationAccuracyReduced
        manager.delegate = self
        manager.startUpdatingLocation()
    }

    @MainActor
    func stopUpdating() {
        onUpdate = nil
        onFailure = nil
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let onUpdate else { return }
            for location in locations {
                onUpdate(FixCandidate(latitude: location.coordinate.latitude,
                                      longitude: location.coordinate.longitude,
                                      horizontalAccuracy: location.horizontalAccuracy,
                                      timestamp: location.timestamp))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Never log the request, only that it failed — a failure reason can name a
        // region and this file logs no place data at all.
        Log.location.notice("location: update failed (\(error.localizedDescription))")
        // `kCLErrorLocationUnknown` means "not right now", and updates keep trying after
        // it; ending the acquisition there would throw away exactly the case interim
        // fixes exist to rescue. Only a denial is terminal.
        let failure: LocationFixFailure =
            (error as? CLError)?.code == .denied ? .denied : .unableToDetermine
        MainActor.assumeIsolated { onFailure?(failure) }
    }
}

/// Resumes once the authorization prompt has settled into a definite status.
private nonisolated final class AuthorizationWaiter: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private var cont: CheckedContinuation<CLAuthorizationStatus, Never>?

    func settled() async -> CLAuthorizationStatus {
        await withCheckedContinuation { c in
            self.cont = c
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined, let cont else { return }
        self.cont = nil
        cont.resume(returning: status)
    }
}

/// The single in-memory cached fix and its placemark. Lock-guarded because `reading` may
/// be called from concurrent turns. Holds one fix, the precision it ACHIEVED, and the
/// place line resolved for it — no history, no disk.
private nonisolated final class CachedFix: @unchecked Sendable {
    struct Hit {
        let fix: FixCandidate
        let precision: LocationPrecision
        let placemark: String?
    }

    /// How far a cached placemark may be reused. A locality-level place line does not
    /// change over a hundred metres, and re-resolving it costs a network round trip
    /// stacked on top of the fix budget for an answer that cannot have changed.
    static let placemarkReuseRadiusMeters: CLLocationDistance = 100

    private let lock = NSLock()
    private var fix: FixCandidate?
    /// The precision the stored fix ACHIEVED — never the precision that was requested.
    ///
    /// Storing the requested one was wrong in both directions: a precise request that
    /// degraded to a 3 km fix cached that fix as `precise`, so a LATER precise request
    /// was served a coarse answer as though it had been fulfilled; and the same
    /// degraded fix was rejected for later COARSE requests it could have answered
    /// instantly, because nothing recorded that it was, in fact, coarse.
    private var precision: LocationPrecision?
    private var placemark: String?
    /// The fix the placemark was resolved for, so it is only reused near it.
    private var placemarkFix: FixCandidate?

    /// The cached fix if it is young enough AND was taken at a precision that can
    /// answer `precision`. A reduced-accuracy fix can never answer a `precise` request;
    /// a full-accuracy one can always answer a `coarse` one.
    func load(maxAge: TimeInterval, precision wanted: LocationPrecision) -> Hit? {
        lock.lock()
        defer { lock.unlock() }
        guard let fix, let precision else { return nil }
        guard wanted == .coarse || precision == .precise else { return nil }
        guard Date().timeIntervalSince(fix.timestamp) <= maxAge else { return nil }
        return Hit(fix: fix, precision: precision,
                   placemark: Self.placemark(placemark, at: placemarkFix, near: fix))
    }

    func store(_ fix: FixCandidate, precision: LocationPrecision) {
        lock.lock()
        defer { lock.unlock() }
        self.fix = fix
        self.precision = precision
    }

    func storePlacemark(_ line: String, for fix: FixCandidate) {
        lock.lock()
        defer { lock.unlock() }
        self.placemark = line
        self.placemarkFix = fix
    }

    /// A cached placemark close enough to `fix` to describe it too.
    func placemark(near fix: FixCandidate) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return Self.placemark(placemark, at: placemarkFix, near: fix)
    }

    private static func placemark(_ line: String?, at resolvedFor: FixCandidate?,
                                  near fix: FixCandidate) -> String? {
        guard let line, let resolvedFor else { return nil }
        let a = CLLocation(latitude: resolvedFor.latitude, longitude: resolvedFor.longitude)
        let b = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        return a.distance(from: b) <= placemarkReuseRadiusMeters ? line : nil
    }
}
