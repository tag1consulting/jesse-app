import Foundation
import JesseNetworking
import JesseVault

// THE BRIDGE CLIENT AS THE THING A STRAND TICK IS REPORTED TO.
//
// Here rather than in either half because this target is the one that already knows both:
// JesseVault owns the report and its outbox and must not learn about HTTP, and
// JesseNetworking owns the call and must not learn about notes.

extension JesseBridgeClient: StrandTickReporting {

    /// Send one report. A `404` is the bridge saying it has no such note or step, which
    /// resending can never change, so it leaves the outbox as `refused`; every other
    /// failure is thrown, and the report stays for the next flush.
    public func reportStrandTick(_ report: StrandTickReport) async throws -> StrandTickDelivery {
        do {
            _ = try await postStrandTick(slug: report.note, id: report.id,
                                         checked: report.checked)
            return .delivered
        } catch JesseError.badResponse(let status, _) where status == 404 {
            return .refused
        }
    }
}
