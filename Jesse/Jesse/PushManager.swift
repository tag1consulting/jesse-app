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

/// Carries a tapped notification's `job_id` from the AppDelegate (UIKit world)
/// into SwiftUI, where `ContentView` opens the matching thread and re-attaches.
@MainActor
final class PushRouter: ObservableObject {
    static let shared = PushRouter()
    /// Set when the user taps a "Jesse finished" notification; consumed (cleared)
    /// by `ContentView`. Nil at rest.
    @Published var pendingJobId: String?
    private init() {}
}

/// Owns the device-token lifecycle and authorization request. A single shared
/// instance; the AppDelegate forwards system callbacks here.
@MainActor
final class PushManager {
    static let shared = PushManager()
    private init() {}

    /// The most recent APNs device token (hex), kept so a foreground refresh can
    /// re-register it if the bridge restarted or the host changed.
    private var lastToken: String?
    /// We only ever surface the system authorization prompt once.
    private var hasRequestedAuth = false

    /// Called after the first successful turn — the "sensible moment" to ask for
    /// notification permission. A no-op until Jesse is paired (don't ask before
    /// there's anything to be notified about) and after the first ask. On grant,
    /// registers for remote notifications so the device token arrives.
    func noteSuccessfulTurn() {
        guard ConfigStore.load().isConfigured, !hasRequestedAuth else { return }
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
        guard ConfigStore.load().isConfigured else { return }
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
        let cfg = ConfigStore.load()
        guard cfg.isConfigured else { return }
        let client = JesseClient(config: cfg)
        Task { try? await client.registerDevice(token: token) }
    }
}

/// App delegate, attached via `@UIApplicationDelegateAdaptor` in `JesseApp`. Owns
/// the remote-notification callbacks and the notification-center delegate so taps
/// route into the app. Kept thin: real work lives in `PushManager`/`PushRouter`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Become the notification-center delegate so foreground presentation and
        // taps reach us. Authorization is requested later (after a turn succeeds),
        // not here on cold launch.
        UNUserNotificationCenter.current().delegate = self
        // Start listening for spoken turns relayed from the Apple Watch. No-ops on a
        // device without WatchConnectivity support (e.g. iPad).
        PhoneWatchConnectivity.shared.activate()
        return true
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

    // A tap: hand the job_id to the router so ContentView opens the thread and
    // re-attaches to fetch the finished reply.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let jobId = response.notification.request.content.userInfo["job_id"] as? String {
            PushRouter.shared.pendingJobId = jobId
        }
        completionHandler()
    }
}
