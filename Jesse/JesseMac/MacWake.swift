import SwiftUI
import AppKit

// The Mac's "we might be back" signal.
//
// The iPhone gets this for free: iOS suspends the app and `scenePhase` swings through
// `.background` and back to `.active`, and every screen already refreshes on that. A Mac
// left open on a desk never leaves `.active` — the LID CLOSES, the machine sleeps, every
// socket in the process dies, and when it opens again nothing in SwiftUI has changed.
// The bounded client makes that worse rather than better: `waitsForConnectivity = false`
// means the first request after a wake fails immediately, and with nothing re-probing,
// the window keeps that verdict until the user notices and hits ⌘R.
//
// So the Mac needs both halves — the scene-phase transition AND `NSWorkspace`'s wake
// notification — and it needs them on every screen that reads from the bridge. One
// modifier, so a screen added later cannot quietly ship without it.

/// The pure half, so the transition rule is asserted rather than assumed.
enum MacReconnect {
    /// Whether a `scenePhase` change is a RETURN to the foreground, as opposed to the
    /// no-op re-delivery of a phase the view was already in.
    ///
    /// Without the `old` check this fires on every unrelated re-evaluation that happens
    /// to carry `.active`, which on a Mac is a refetch per window focus change.
    static func isReturnToActive(from old: ScenePhase, to new: ScenePhase) -> Bool {
        new == .active && old != .active
    }
}

extension View {
    /// Run `action` when this window comes back to the foreground, and when the Mac
    /// wakes from sleep.
    ///
    /// Both, not either: waking with the window already frontmost produces no scene-phase
    /// change at all, and switching back to a window on a machine that never slept
    /// produces no wake notification. Each covers the case the other misses.
    func onReconnect(perform action: @escaping () -> Void) -> some View {
        modifier(MacReconnectModifier(action: action))
    }
}

private struct MacReconnectModifier: ViewModifier {
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { old, new in
                guard MacReconnect.isReturnToActive(from: old, to: new) else { return }
                action()
            }
            // `NSWorkspace`'s own center, NOT `NotificationCenter.default` — the wake and
            // sleep notifications are posted only there, and subscribing to the default
            // center is the silent way to get none of them.
            .onReceive(NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    action()
                }
    }
}
