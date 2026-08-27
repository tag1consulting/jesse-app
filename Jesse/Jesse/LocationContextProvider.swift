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
// WHAT IT DELIBERATELY DOES NOT DO, and this is the security posture rather than a
// to-do list:
//
//   * NO always authorization. `requestWhenInUseAuthorization` only. There is no code
//     path here that can ask for `.authorizedAlways`.
//   * NO background location, NO significant-change monitoring, NO region monitoring,
//     NO visit monitoring, NO heading. The app declares no location background mode,
//     so none of it would run anyway — but the absence is also structural: this file
//     starts and stops updates inside one awaited call and holds no manager between
//     turns.
//   * NO persistence. A reading is returned, rendered into one request, and dropped.
//     Nothing is written to the vault, to SwiftData, or to UserDefaults, and the only
//     thing kept in memory is the single cached fix below.
//   * NO logging of coordinates. The log lines here name failures and statuses, never
//     a latitude.

/// Reads one location fix (and optionally its placemark) for the `location_context`
/// block. Read-only, when-in-use only, and bounded: every degrade path — services off,
/// unauthorized, denied, restricted, timed out, no fix available, a simulator with no
/// location set — yields `.empty`, so a turn is never blocked or broken by location.
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
    /// Hard bound on one fix. The send path waits at most this long, then proceeds with
    /// no block. Two seconds is generous for a warm fix and short enough that a cold
    /// one (indoors, airplane mode) does not visibly delay the turn — it degrades to
    /// the unavailable path instead, which still produces an answer.
    private let fixTimeout: Duration
    /// Hard bound on the reverse geocode, which is a network round trip. Separate from
    /// the fix bound because a device can have a perfectly good fix and no network, and
    /// in that case the coordinates should still ride out.
    private let geocodeTimeout: Duration
    /// The last fix, kept in memory ONLY, so a `max_age_seconds` the directive is happy
    /// with can be served without waking the GPS. Dropped on process exit like anything
    /// else in memory; never written anywhere.
    private let cache = CachedFix()

    init(fixTimeout: Duration = .seconds(2), geocodeTimeout: Duration = .milliseconds(1500)) {
        self.fixTimeout = fixTimeout
        self.geocodeTimeout = geocodeTimeout
    }

    // MARK: - Authorization

    /// The live status, read fresh. True ONLY for `.authorizedWhenInUse`.
    ///
    /// `.notDetermined` is false on purpose: the app has never asked, and asking here —
    /// inside a turn, because of a message he typed — is exactly the mid-turn ambush
    /// the gate exists to prevent. The first ask happens from the Settings row, where
    /// he chose it.
    func isAuthorized() async -> Bool {
        guard CLLocationManager.locationServicesEnabled() else { return false }
        return CLLocationManager().authorizationStatus == .authorizedWhenInUse
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
                 wantsPlacemark: Bool) async -> LocationReading {
        guard await isAuthorized() else { return .empty }

        // A cached fix young enough for what was asked, and precise enough. A fix taken
        // at reduced accuracy cannot answer a `precise` request, so precision is part
        // of the cache key rather than only the age.
        let location: CLLocation
        if let cached = cache.load(maxAge: TimeInterval(maxAgeSeconds), precision: precision) {
            location = cached
        } else if let fresh = await bounded(fixTimeout, { await self.oneFix(precision: precision) }) {
            cache.store(fresh, precision: precision)
            location = fresh
        } else {
            return .empty
        }

        var out = LocationReading(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            placemark: nil,
            timestamp: location.timestamp)
        if wantsPlacemark {
            out.placemark = await bounded(geocodeTimeout, { await Self.placemark(for: location) })
                .flatMap { $0 }
        }
        return out
    }

    /// One fix, via a manager that lives only for the duration of this call.
    ///
    /// `precision == .coarse` never touches `requestTemporaryFullAccuracyAuthorization`,
    /// so a coarse request cannot produce a prompt. A `precise` request on a device that
    /// granted reduced accuracy asks for temporary full accuracy — the one prompt this
    /// channel can raise, and only because the model explicitly stated `"precise"`.
    ///
    /// TWO THINGS HERE ARE LOAD-BEARING, and the first was the bug.
    ///
    /// **The waiter is a `let` in THIS frame.** `CLLocationManager.delegate` is a WEAK
    /// reference, so the waiter's only strong owner is whoever holds it — and the
    /// manager's only strong owner is the waiter. When both were locals inside the inner
    /// `Task { @MainActor in … }`, they died the instant that Task body finished, which
    /// is immediately after `requestLocation()` returns. A deallocated manager delivers
    /// neither `didUpdateLocations` nor `didFailWithError`, so the continuation was
    /// never resumed at all. Declared out here, the async frame keeps the waiter alive
    /// for the whole suspension, and the waiter keeps the manager alive with it.
    ///
    /// **The cancellation handler is what makes the caller's timeout real.** `bounded`
    /// races this against a sleep inside a `withTaskGroup`, and a task group cannot
    /// return until every child finishes — `cancelAll()` only *requests* cancellation. A
    /// plain non-throwing `withCheckedContinuation` ignores that request entirely, so a
    /// fix that never arrives (airplane mode, no GPS, a simulator with no location set)
    /// left the group unable to return and hung the whole turn rather than degrading to
    /// `.empty`. Resuming with `nil` on cancel is what lets the group close.
    private func oneFix(precision: LocationPrecision) async -> CLLocation? {
        // Owned by this frame, NOT by the Task below — see above.
        let waiter = FixWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
                Task { @MainActor in
                    waiter.begin(precision: precision) { cont.resume(returning: $0) }
                }
            }
        } onCancel: {
            // Hop to the main actor rather than isolating the waiter to it: this type is
            // held by `JesseClient` and released off the main actor, and a main-actor
            // class gets an isolated deinit that aborts the process on such a release.
            // The hop keeps every resume/teardown on the actor the manager delivers on,
            // which is what makes the single-resume guard sufficient against this race.
            Task { @MainActor in waiter.cancel() }
        }
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
    private nonisolated static func placemark(for location: CLLocation) async -> String? {
        // Run in a DETACHED task, not merely a nonisolated function. A nonisolated async
        // function inherits its caller's isolation, so awaiting `mapItems` from it still
        // counts as sending a non-Sendable MapKit value across a boundary. A detached
        // task has an isolation of its own: the request is built, awaited and consumed
        // entirely inside it, and the only thing that comes back out is the `String?`.
        await Task.detached { () -> String? in
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

/// The queryable side of the permission, for the Settings row. Unlike HealthKit's read
/// status — which Apple hides by design, so a denial is invisible — CoreLocation reports
/// its status honestly, so the row can say "this is off in Settings" instead of leaving
/// a toggle on that can never attach anything.
nonisolated enum LocationPermissionStatus {
    /// The owner has said no, or the device is restricted (Screen Time, MDM). NOT true
    /// for `.notDetermined`: nobody has been asked yet, which is a different row.
    static func isDenied() -> Bool {
        guard CLLocationManager.locationServicesEnabled() else { return true }
        switch CLLocationManager().authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }
}

// MARK: - Delegates (the only stateful CoreLocation surface)

/// Owns one location request end to end: it creates the `CLLocationManager`, holds the
/// only strong reference to it (`delegate` is weak, so nothing else does), and resumes
/// its caller EXACTLY ONCE — with the first fix, with nil on failure, or with nil on
/// cancellation.
///
/// One-shot by design, and the guard in `finish` is what enforces it. Three things can
/// race to finish a request: `didUpdateLocations`, `didFailWithError` (iOS can deliver
/// both for one request), and the caller's timeout cancelling. Resuming a
/// `CheckedContinuation` twice traps, so a second arrival must be a silent no-op rather
/// than a second resume.
///
/// `begin`, `cancel` and both delegate callbacks all run on the main actor — the manager
/// is created there and delivers there, and `cancel` hops there — so the guard is
/// checked and cleared on one actor and needs no further locking.
///
/// `nonisolated`/`@unchecked Sendable` deliberately: an instance is reachable from
/// `LocationContextProvider`, which `JesseClient` holds and releases off the main actor.
/// A main-actor-isolated class gets an isolated deinit and aborts the process on such a
/// release, which is a crash this file has already had once.
private nonisolated final class FixWaiter: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private var resume: ((CLLocation?) -> Void)?
    private var manager: CLLocationManager?

    /// Arm the request: configure accuracy for `precision`, take the one strong
    /// reference to the manager, and ask for a single fix. `requestLocation()` delivers
    /// exactly one callback, so the `resume` stored here is called once and then cleared.
    ///
    /// `precision == .coarse` never touches full accuracy, so a coarse request cannot
    /// raise a prompt.
    @MainActor
    func begin(precision: LocationPrecision, resume: @escaping (CLLocation?) -> Void) {
        // A request that was cancelled before it could be armed: resume immediately
        // rather than starting a manager nobody is waiting on.
        guard !isFinished else {
            resume(nil)
            return
        }
        self.resume = resume
        let manager = CLLocationManager()
        if precision == .precise, manager.accuracyAuthorization == .reducedAccuracy {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PreciseDistance")
        }
        manager.desiredAccuracy = precision == .precise
            ? kCLLocationAccuracyBest
            : kCLLocationAccuracyReduced
        manager.delegate = self
        // The ONLY strong reference to the manager. `delegate` is weak, so without this
        // the manager deallocates and never calls back.
        self.manager = manager
        manager.requestLocation()
    }

    /// The caller's timeout fired. Resume with nil and tear the manager down, so the
    /// awaiting task group can close instead of waiting on a fix that is not coming.
    @MainActor
    func cancel() {
        finish(nil)
    }

    /// Whether a resume has already happened — including a cancel that landed before
    /// `begin` ran, which is why this is a stored flag rather than `resume == nil`
    /// (that is also nil before arming).
    private var isFinished = false

    @MainActor
    private func finish(_ location: CLLocation?) {
        guard !isFinished else { return }
        isFinished = true
        let resume = self.resume
        self.resume = nil
        manager?.delegate = nil
        manager = nil
        resume?(location)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { finish(locations.last) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Never log the request, only that it failed — a failure reason can name a
        // region and this file logs no place data at all.
        Log.location.notice("location: fix failed (\(error.localizedDescription))")
        MainActor.assumeIsolated { finish(nil) }
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

/// The single in-memory cached fix. Lock-guarded because `reading` may be called from
/// concurrent turns. Holds one `CLLocation` and the precision it was taken at, and
/// nothing else — no history, no disk.
private nonisolated final class CachedFix: @unchecked Sendable {
    private let lock = NSLock()
    private var location: CLLocation?
    private var precision: LocationPrecision?

    /// The cached fix if it is young enough AND was taken at a precision that can
    /// answer `precision`. A reduced-accuracy fix can never answer a `precise` request;
    /// a full-accuracy one can always answer a `coarse` one.
    func load(maxAge: TimeInterval, precision wanted: LocationPrecision) -> CLLocation? {
        lock.lock()
        defer { lock.unlock() }
        guard let location, let precision else { return nil }
        guard wanted == .coarse || precision == .precise else { return nil }
        guard Date().timeIntervalSince(location.timestamp) <= maxAge else { return nil }
        return location
    }

    func store(_ location: CLLocation, precision: LocationPrecision) {
        lock.lock()
        defer { lock.unlock() }
        self.location = location
        self.precision = precision
    }
}
