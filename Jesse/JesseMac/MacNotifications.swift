import Foundation
import UserNotifications

// Local completion notifications (plan section 4e / 5.5). A Mac app keeps running when
// it isn't frontmost, so the SSE connection stays alive and we can post a local
// `UserNotifications` alert when a turn finishes — no APNs needed. The quit / lid-closed
// case (real APNs-for-Mac work) stays deferred to polish.

@MainActor
final class MacNotifier {
    private var authorized = false
    /// Whether the app is currently the foreground app; a finished turn the user is
    /// already watching doesn't need an alert.
    var isActive = true

    /// Ask for alert/sound authorization once at launch. Best-effort — a denial just
    /// means no banners.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// Post a completion banner for a finished turn, unless the app is frontmost (the
    /// user is already looking at the reply).
    func notifyTurnFinished(title: String, reply: String) {
        guard authorized, !isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Jesse replied" : title
        content.body = Self.snippet(reply)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A one-line preview of the reply for the banner body.
    nonisolated static func snippet(_ text: String, limit: Int = 140) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
