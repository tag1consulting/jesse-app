import Foundation

// The single capability the Health dashboard needs from a bridge client: fetch a
// `DietSnapshot` for a day (nil = today). Pulling it behind its own tiny protocol lets
// the shared dashboard model (`HealthDashboardModel`, in JesseDietDisplay) depend on
// just this one method instead of a platform's full client type. Both concrete clients
// satisfy it: the Mac drives it with `JesseBridgeClient`; the iOS app conforms its own
// `JesseClient` (which layers per-turn health context on top) in a one-line extension.
// Tests and previews inject a fake that returns a canned snapshot.
public protocol DietSnapshotProviding: Sendable {
    /// Fetch the diet snapshot for `date` (an ISO `yyyy-MM-dd` day), or today when nil.
    func fetchDietSnapshot(date: String?) async throws -> DietSnapshot
}

// The full shared bridge client already implements `fetchDietSnapshot`, so it satisfies
// the narrow seam directly. Refining `BridgeClientProtocol` here means every conformer
// (today just `JesseBridgeClient`) is a `DietSnapshotProviding` with no extra work.
extension JesseBridgeClient: DietSnapshotProviding {}
