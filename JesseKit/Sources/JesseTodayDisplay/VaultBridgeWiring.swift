import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import JesseNetworking
import JesseVault

// THE BRIDGE CLIENT AS THE THING NOTES ARE OPENED FROM AND WRITTEN THROUGH, AND THE ONE
// CALL EACH APP SHELL MAKES TO SAY SO.
//
// Here rather than in either half because this target is the one that already knows both:
// JesseVault owns the opener and the outbox and must not learn about HTTP, and
// JesseNetworking owns the calls and must not learn about notes.

extension JesseBridgeClient: VaultBridgeNoteFetching {
    public func fetchVaultNote(path: String?, target: String?,
                               ifNoneMatch: String?) async throws -> (status: Int, body: Data) {
        try await getVaultNote(path: path, target: target, ifNoneMatch: ifNoneMatch)
    }
}

extension JesseBridgeClient: VaultWriteSending {
    public func sendVaultWrites(_ body: Data) async throws -> (status: Int, body: Data) {
        try await postVaultWrites(body)
    }
}

public enum VaultBridgeWiring {

    /// Hand the shared opener and outbox a way to reach the bridge, and send whatever is
    /// waiting on the schedule the outbox needs: now, whenever the bridge becomes reachable
    /// again, and whenever the app comes to the foreground. (After every write, the writers
    /// send it themselves.)
    ///
    /// `client` is called per use, so a re-pair is picked up without a relaunch.
    @MainActor
    public static func install(client: @escaping @Sendable @MainActor () -> JesseBridgeClient) {
        Task {
            await VaultNoteOpener.shared.configure(
                client: { await client() },
                reachability: { await reachabilityState() })
            await VaultWriteOutbox.shared.configure(sender: { await client() })
            await VaultWriteOutbox.shared.flush()
        }
        ReachabilityFlush.shared.start()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: foregroundNotification, object: nil, queue: .main) { _ in
            Task { await VaultWriteOutbox.shared.flush() }
        }
    }

    @MainActor private static var foregroundObserver: NSObjectProtocol?

    private static var foregroundNotification: Notification.Name {
        #if canImport(UIKit)
        UIApplication.didBecomeActiveNotification
        #else
        NSApplication.didBecomeActiveNotification
        #endif
    }

    /// The app-wide reachability, in the vault's own three words.
    @MainActor
    static func reachabilityState() -> BridgeReachabilityState {
        switch BridgeReachabilityModel.shared.state {
        case .reachable: return .reachable
        case .unreachable: return .unreachable
        case .unknown: return .unknown
        }
    }
}

/// Sends the outbox each time the bridge comes back. One instance, watching the one
/// reachability model the whole app shares.
@MainActor
final class ReachabilityFlush {
    nonisolated deinit {}

    static let shared = ReachabilityFlush()
    private var last: BridgeReachability = .unknown
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        last = BridgeReachabilityModel.shared.state
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = BridgeReachabilityModel.shared.state
        } onChange: {
            Task { @MainActor in ReachabilityFlush.shared.changed() }
        }
    }

    private func changed() {
        let now = BridgeReachabilityModel.shared.state
        if now == .reachable, last != .reachable {
            Task { await VaultWriteOutbox.shared.flush() }
        }
        last = now
        observe()
    }
}
