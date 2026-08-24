import Foundation
import JesseNetworking

/// The persisted half of frugal mode: the "Frugal on cellular" toggle, plus the one call
/// that combines it with the live network path into a `FrugalPolicy`.
///
/// The split is deliberate. `FrugalPolicy` is pure and lives in JesseNetworking, so the
/// whole decision table is a unit test; this is the two lines of `UserDefaults` and the
/// one read of `ConnectivityMonitor.shared` that a test must never have to stand up.
///
/// The toggle only ever turns frugal mode ON. There is no "full quality on cellular"
/// setting, because every decision the policy makes is cheap-and-still-correct, and the
/// one a person might genuinely want to override — a full-resolution photo over cell — is
/// a thing to want rarely and pay for knowingly, not a default to leave armed.
nonisolated enum FrugalSettings {
    static let forcedKey = "frugalOnCellular"
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Whether the user has forced frugal mode on. Off by default, so an app that has
    /// never seen the toggle behaves entirely off the network's own signals.
    static var isForced: Bool { defaults.bool(forKey: forcedKey) }
    static func setForced(_ on: Bool) { defaults.set(on, forKey: forcedKey) }

    /// The policy in force right now: the live path plus the toggle.
    ///
    /// Reads the off-main mirror (`CurrentNetworkPath`) rather than the `@Observable`
    /// monitor, so the send path and the attachment downscaler can ask without hopping to
    /// the main actor mid-turn. A VIEW that wants to re-render when the answer changes
    /// must read `ConnectivityMonitor.shared.path` itself and call
    /// `FrugalPolicy.decide` — the mirror is a value, and a value cannot be observed.
    static func current() -> FrugalPolicy {
        FrugalPolicy.decide(path: CurrentNetworkPath.current, forcedOn: isForced)
    }
}
