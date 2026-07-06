import Foundation
import Observation

/// Whether the phone can currently reach the Jesse bridge. `unknown` is the
/// pre-probe state (cold launch, or unconfigured) — deliberately distinct from
/// `unreachable` so the offline banner never flashes before the first probe.
enum BridgeReachability: Equatable {
    case unknown
    case reachable
    case unreachable
}

/// The pure gate for the list-level offline banner: show it only when the app is
/// paired AND a probe has actually come back unreachable. Kept pure so the
/// decision is unit-tested without standing up the view or the network.
func shouldShowOfflineBanner(isConfigured: Bool, reachability: BridgeReachability) -> Bool {
    isConfigured && reachability == .unreachable
}

/// Probes the bridge's `GET /health` to drive the offline banner, mirroring the
/// watch's `.queued` signal — so the phone tells you the bridge is unreachable
/// *before* you compose and send, instead of only erroring after. The probe uses
/// a short-timeout session (not the 30s send session) so the banner appears
/// promptly; an unconfigured app stays `.unknown` (the pairing CTA covers that).
@MainActor
@Observable
final class BridgeReachabilityModel {
    private(set) var state: BridgeReachability = .unknown

    @ObservationIgnored private var task: Task<Void, Never>?

    /// A dedicated short-timeout session so an unreachable host fails fast (≈5s)
    /// rather than after the send path's 30s ceiling.
    private static let probeSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Re-probe reachability for the current config. Unconfigured → `.unknown`
    /// (no banner). Success → `.reachable`; any transport/HTTP failure →
    /// `.unreachable`. Supersedes any in-flight probe so the latest config wins.
    func refresh(config: JesseConfig) {
        task?.cancel()
        guard config.isConfigured else {
            state = .unknown
            return
        }
        task = Task { [weak self] in
            do {
                _ = try await JesseClient(config: config, session: Self.probeSession).health()
                guard !Task.isCancelled else { return }
                self?.state = .reachable
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .unreachable
            }
        }
    }
}
