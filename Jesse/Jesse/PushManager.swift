import Combine
import SwiftUI
import UIKit
import UserNotifications

// Push notifications: capture the APNs device token, register it with the bridge,
// ask for authorization at a sensible moment (after a turn succeeds, not on cold
// launch), and route a notification tap back to the right thread. Everything here
// is additive and degrades cleanly: with no bridge configured, or push denied, or
// the bridge's APNs unconfigured, the app behaves exactly as it did before — the
// foreground `resume` still re-attaches a backgrounded turn.

/// The routing keys a tapped notification carries.
///
/// TWO of them, because `job_id` alone cannot answer the question. The app resolves a job
/// id through `RunCoordinator.inFlight` — the turns THIS DEVICE started and has not yet
/// settled — and two whole classes of notification are not in that map:
///
/// * a **scheduled job**, which the phone never started, so it never had an entry;
/// * an **already-settled turn**, whose entry background delivery removed the moment it
///   wrote the reply — so tapping the banner afterwards found nothing.
///
/// `conversationId` names the conversation itself, which the app can fetch locally or
/// adopt from the bridge if it has never seen it. Either id may be absent: an older
/// bridge sends no conversation, and a skipped scheduled run has no turn and so no job.
nonisolated struct PushTap: Equatable, Sendable {
    let jobId: String?
    let conversationId: String?

    init(jobId: String?, conversationId: String?) {
        self.jobId = jobId
        self.conversationId = conversationId
    }

    /// Parse a tapped notification's payload, or `nil` when it carries neither id — an
    /// alert with nothing to route on is an ordinary push, not an error.
    ///
    /// Trimmed and emptiness-checked, matching `BackgroundDelivery.Payload`: this reads
    /// the least trustworthy dictionary the app ever sees, and a whitespace-only id is
    /// no id at all.
    init?(userInfo: [AnyHashable: Any]) {
        let job = PushTap.id(userInfo[BackgroundDelivery.PayloadKey.jobId])
        let conversation = PushTap.id(userInfo[BackgroundDelivery.PayloadKey.conversationId])
        guard job != nil || conversation != nil else { return nil }
        self.init(jobId: job, conversationId: conversation)
    }

    private static func id(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }
}

/// Carries a tapped notification's routing keys from the AppDelegate (UIKit world)
/// into SwiftUI, where `ContentView` opens the matching thread and re-attaches.
@MainActor
final class PushRouter: ObservableObject {
    static let shared = PushRouter()
    /// Set when the user taps a "Jesse finished" notification; consumed (cleared)
    /// by `ContentView` ONCE ROUTING HAS RESOLVED — not before, or a tap that arrives
    /// during launch is dropped while the fallback chain is still awaiting. Nil at rest.
    @Published var pendingTap: PushTap?
    private init() {}
}

/// Whether a device-token registration needs to go to the bridge, or is a redundant
/// repeat of one that just happened.
///
/// `refreshRegistration()` runs on EVERY `scenePhase == .active`, and each one ends in a
/// `POST /jesse/device`. That is deliberate — it is how a bridge restart, a rotated APNs
/// token, or a host change gets covered — but it means a rapid background/foreground
/// toggle multiplies it: measured 8 identical `POST /jesse/device` writes for 8 toggles
/// in 36 seconds, same token, same bridge, every one after the first a no-op server-side.
///
/// So: repeat the write when anything could have changed (a different token, a different
/// bridge) or when enough time has passed that the bridge may have restarted, and skip it
/// when the *same* registration was accepted moments ago. Pure, so the rule is testable
/// without UIApplication, the Keychain, or the network.
enum PushRegistrationDedupe {
    /// How long an accepted registration is treated as still current. Short enough that a
    /// genuine return to the app re-registers, long enough that flipping in and out of the
    /// app does not write once per flip.
    nonisolated static let window: TimeInterval = 60

    /// One registration attempt's identity: the token plus the bridge it was sent to.
    nonisolated struct Key: Equatable, Sendable {
        let token: String
        let host: String
        let port: Int
    }

    /// Whether to send this registration. `last` is the previously accepted registration
    /// and when it was accepted; `nil` means none yet (always send).
    nonisolated static func shouldRegister(_ key: Key, last: (key: Key, at: Date)?, now: Date) -> Bool {
        guard let last else { return true }
        if last.key != key { return true }
        return now.timeIntervalSince(last.at) >= window
    }
}

/// The registration the bridge last ACCEPTED, remembered ACROSS LAUNCHES.
///
/// The in-memory dedupe above answers "did we just write this?"; this answers "has this
/// bridge ever been told this token?", which is a different question with a different
/// failure. A restore from backup, or a reinstall, gives the device a NEW APNs token while
/// the paired bridge is unchanged — and an app that only remembered the last registration
/// in memory would re-register it on the next foreground anyway, so the gap was never
/// visible. It becomes visible the moment registration is allowed to FAIL and retry:
/// without a persisted record there is nothing to compare a retry against, and "we already
/// did this" would reset on every launch.
nonisolated enum PushRegistrationStore {
    static let key = "jesse.push.registration.v1"
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// The last accepted `(token, host, port)`, or nil if there has never been one.
    static func load() -> PushRegistrationDedupe.Key? {
        guard let raw = defaults.dictionary(forKey: key),
              let token = raw["token"] as? String,
              let host = raw["host"] as? String,
              let port = raw["port"] as? Int, !token.isEmpty else { return nil }
        return PushRegistrationDedupe.Key(token: token, host: host, port: port)
    }

    static func save(_ registration: PushRegistrationDedupe.Key) {
        defaults.set(["token": registration.token,
                      "host": registration.host,
                      "port": registration.port], forKey: key)
    }

    static func clear() { defaults.removeObject(forKey: key) }
}

/// How long to wait before retrying a device-token registration that failed.
///
/// Registration used to be a single `try?`: one attempt, and if the laptop happened to be
/// asleep at that moment the bridge had no token until the next foreground. Every push
/// this app can send depends on that one write having landed, which makes it the single
/// worst place in the app to swallow a failure.
///
/// 1s, 10s, 60s, then hourly. Short at the start because the overwhelming case is a laptop
/// that is waking up; hourly after that because everything past a minute is a laptop that
/// is off, and there is no benefit to asking a closed lid more than once an hour.
nonisolated enum PushRegistrationBackoff {
    static let delays: [TimeInterval] = [1, 10, 60]
    static let steadyState: TimeInterval = 3600

    /// The wait before attempt `attempt` (1-based; `1` is the first retry after the
    /// original failed).
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return delays[0] }
        return attempt <= delays.count ? delays[attempt - 1] : steadyState
    }
}

/// Owns the device-token lifecycle and authorization request. A single shared
/// instance; the AppDelegate forwards system callbacks here.
@MainActor
final class PushManager {
    static let shared = PushManager()

    /// Injected in tests so the retry loop runs without the network, the Keychain, or real
    /// waiting. Production is the real client and a real sleep.
    private let register: @MainActor (JesseConfig, String) async throws -> Void
    private let sleep: @MainActor (TimeInterval) async -> Void
    private let now: @MainActor () -> Date
    /// The bridge this device is paired with. Injected alongside the writer so a test can
    /// drive the retry loop without the Keychain — an unpaired app registers nothing, which
    /// would otherwise make every one of those tests pass vacuously.
    private let configProvider: @MainActor () -> JesseConfig

    init(register: @escaping @MainActor (JesseConfig, String) async throws -> Void = {
             try await JesseClient(config: $0).registerDevice(token: $1)
         },
         sleep: @escaping @MainActor (TimeInterval) async -> Void = {
             try? await Task.sleep(for: .seconds($0))
         },
         now: @escaping @MainActor () -> Date = { Date() },
         config: @escaping @MainActor () -> JesseConfig = { ConfigStore.load() }) {
        self.register = register
        self.sleep = sleep
        self.now = now
        self.configProvider = config
        self.lastRegistration = PushRegistrationStore.load().map { ($0, .distantPast) }
    }

    /// The most recent APNs device token (hex), kept so a foreground refresh can
    /// re-register it if the bridge restarted or the host changed.
    private var lastToken: String?
    /// The last registration actually written to the bridge, and when — so an identical
    /// repeat inside `PushRegistrationDedupe.window` is skipped instead of re-POSTed on
    /// every foreground (see `PushRegistrationDedupe`).
    private var lastRegistration: (key: PushRegistrationDedupe.Key, at: Date)?
    /// We only ever surface the system authorization prompt once.
    private var hasRequestedAuth = false
    /// The registration currently being retried, and the key it is for. At most one — a
    /// new token or a re-pairing cancels and replaces it.
    private var registering: (key: PushRegistrationDedupe.Key, task: Task<Void, Never>)?

    /// Called after the first successful turn — the "sensible moment" to ask for
    /// notification permission. A no-op until Jesse is paired (don't ask before
    /// there's anything to be notified about) and after the first ask. On grant,
    /// registers for remote notifications so the device token arrives.
    func noteSuccessfulTurn() {
        guard configProvider().isConfigured, !hasRequestedAuth else { return }
        hasRequestedAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Called on foreground: if authorization is already granted, re-register for
    /// remote notifications. iOS hands back the current token via the AppDelegate,
    /// which re-registers it with the bridge — covering a token change, a bridge
    /// restart, or a host change since last launch. A no-op when unpaired or not
    /// yet authorized.
    func refreshRegistration() {
        guard configProvider().isConfigured else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
            default:
                break
            }
        }
    }

    /// The APNs device token arrived (or was refreshed). Hex-encode it and push it
    /// to the bridge. Re-registration is idempotent server-side.
    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        lastToken = hex
        registerWithBridge(token: hex)
    }

    private func registerWithBridge(token: String) {
        let cfg = configProvider()
        guard cfg.isConfigured else { return }
        // Skip a registration that is byte-for-byte the one the bridge accepted moments
        // ago — every foreground calls in here, and re-POSTing the same token to the same
        // bridge on each one is a network write that cannot change anything.
        let key = PushRegistrationDedupe.Key(token: token,
                                             host: cfg.normalizedHost,
                                             port: cfg.effectivePort)
        let stamp = now()
        guard PushRegistrationDedupe.shouldRegister(key, last: lastRegistration, now: stamp) else {
            return
        }
        // A registration already retrying for this exact key is left alone; anything else
        // (a new token, a re-pairing) supersedes it, because the in-flight one is now
        // trying to tell the wrong bridge about the wrong token.
        if let inFlight = registering, inFlight.key == key { return }
        registering?.task.cancel()
        let task = Task { [weak self] () -> Void in
            await self?.registerUntilAccepted(config: cfg, token: token, key: key)
        }
        registering = (key, task)
    }

    /// Write the token, retrying on `PushRegistrationBackoff` until the bridge accepts it.
    ///
    /// Only a THROW is retried. A throw means the write did not land — an asleep laptop, a
    /// dropped network — and until it does, this device cannot be pushed at all. Anything
    /// the bridge answers is an answer, and re-POSTing a request it understood and refused
    /// (a wrong token: `401`) would be an hourly write for the life of the pairing.
    ///
    /// The loop is unbounded on purpose, and safe because it is bounded by everything
    /// around it: it is cancelled the moment a different token or a different bridge
    /// supersedes it, it only ever runs while the app is alive, and after the first minute
    /// it costs one request an hour.
    private func registerUntilAccepted(config: JesseConfig, token: String,
                                       key: PushRegistrationDedupe.Key) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await register(config, token)
                lastRegistration = (key, now())
                // Persisted only on ACCEPTANCE, so a restored device with a new token
                // re-registers rather than trusting a record of a write that never landed.
                PushRegistrationStore.save(key)
                registering = nil
                return
            } catch {
                attempt += 1
                let wait = PushRegistrationBackoff.delay(forAttempt: attempt)
                Log.push.error("device registration failed (attempt \(attempt)): " +
                               "\(error.localizedDescription) — retrying in \(Int(wait))s")
                await sleep(wait)
            }
        }
    }

    /// Whether a registration is currently being retried, for tests and for the
    /// supersede check.
    var isRegistering: Bool { registering != nil }
}

/// App delegate, attached via `@UIApplicationDelegateAdaptor` in `JesseApp`. Owns
/// the remote-notification callbacks and the notification-center delegate so taps
/// route into the app. Kept thin: real work lives in `PushManager`/`PushRouter` and,
/// for a wake-up with no app on screen, `BackgroundDelivery`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The one background worker, shared by the push path and the periodic task.
    @MainActor static let delivery = BackgroundDelivery()

    /// The periodic backstop. Registered at launch (iOS insists on before-launch-finishes)
    /// and re-armed after every run.
    @MainActor private lazy var refresh = BackgroundRefreshCoordinator(
        work: { await AppDelegate.delivery.periodicRefresh() })

    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Become the notification-center delegate so foreground presentation and
        // taps reach us. Authorization is requested later (after a turn succeeds),
        // not here on cold launch.
        UNUserNotificationCenter.current().delegate = self
        // Start listening for spoken turns relayed from the Apple Watch. No-ops on a
        // device without WatchConnectivity support (e.g. iPad).
        PhoneWatchConnectivity.shared.activate()
        // Register the refresh task BEFORE launch finishes — iOS treats a later
        // registration as a fatal programmer error, not a warning — and ask for the first
        // one. Both are idempotent.
        MainActor.assumeIsolated {
            refresh.register()
            refresh.schedule()
        }
        return true
    }

    /// A push arrived, and the app may be nowhere on screen.
    ///
    /// This is the whole point of the background-modes work. Before it, a reply that
    /// finished while the phone was in a pocket sat on the laptop until the app was
    /// opened; the push carried the `job_id` and nothing was allowed to act on it.
    ///
    /// The completion handler MUST be called, and within the window iOS grants (~30s) —
    /// an app that fails to is given fewer wake-ups, which degrades the feature into
    /// unreliability rather than switching it off honestly. So the work races a 25s
    /// deadline and reports whichever finishes first.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Parsed HERE, synchronously, so the only thing that crosses into the background
        // work is a checked `Sendable` value — a push's `userInfo` is `[AnyHashable: Any]`
        // and has no business travelling any further than this line.
        let payload = BackgroundDelivery.Payload(userInfo: userInfo)
        Task { @MainActor in
            let outcome = await AppDelegate.withDeadline(AppDelegate.backgroundWindow) {
                await AppDelegate.delivery.handle(payload)
            }
            completionHandler(outcome.fetchResult)
        }
    }

    /// The self-imposed ceiling on a push wake-up. iOS allows roughly 30 seconds; finishing
    /// inside 25 leaves room for the completion handler to actually be delivered rather
    /// than the process being killed a moment before it is.
    static let backgroundWindow: TimeInterval = 25

    /// Run `work`, giving up with `.failed` if it has not finished within `seconds`.
    ///
    /// `.failed` rather than `.noData` on the timeout, deliberately: iOS budgets future
    /// wake-ups on what it is told, and a wake-up that ran out of time is not the same
    /// statement as one that found nothing to do.
    static func withDeadline(_ seconds: TimeInterval,
                             work: @escaping @Sendable () async -> BackgroundWorkOutcome)
        async -> BackgroundWorkOutcome {
        await withTaskGroup(of: BackgroundWorkOutcome.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .failed
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }

    func application(_ application: UIApplication,
                    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                    didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.push.error("remote notification registration failed: \(error.localizedDescription)")
    }

    // Show the banner (and play the sound) even when the app is foregrounded, so a
    // push that lands while you're on another thread is still visible.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // A tap: hand BOTH routing keys to the router so ContentView opens the thread and
    // re-attaches to fetch the finished reply. Parsed through `PushTap`, which reads the
    // keys `BackgroundDelivery.PayloadKey` names rather than spelling them again here.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tap = PushTap(userInfo: response.notification.request.content.userInfo) {
            PushRouter.shared.pendingTap = tap
        }
        completionHandler()
    }
}
