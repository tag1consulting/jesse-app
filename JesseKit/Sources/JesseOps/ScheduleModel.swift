import Foundation
import Observation
import JesseNetworking

// The Schedule screen's view model.
//
// It reads the schedule from the BRIDGE, always — the document is the bridge's own and the
// sentinel only quotes it inside `GET /sentinel/status`, one refresh behind. It WRITES through
// whichever process `OpsConfiguration.scheduleControl` picks, which is the sentinel when one
// is paired. Read one way, write the other, deliberately: the read has to be current and the
// write has to survive a wedged bridge.
//
// The invariants, each with a test:
//
//  * A FAILED REFRESH NEVER BLANKS A LOADED SCHEDULE — same rule as the Ops screen, same
//    reason.
//  * A `409` IS NOT AN ERROR, IT IS AN ANSWER. "the chain headed by X is already running" is
//    what the person needed to know; it is shown as the row's own conflict line rather than a
//    generic failure banner.
//  * AN ENABLE APPLIES THE ROW THE BRIDGE ANSWERS WITH, not the one the toggle assumed. The
//    verb returns the job's row, and taking it is what makes an override's `until` and
//    `active` correct on screen without a second round trip.

@MainActor
@Observable
public final class ScheduleModel {
    nonisolated deinit {}

    public var configuration: OpsConfiguration

    public private(set) var document: ScheduleDocument?
    public private(set) var isLoading = false
    /// The last refresh's failure, shown beside whatever is already loaded.
    public private(set) var loadError: String?
    /// The reload verb's own report: what it said and what it complained about. Kept separate
    /// from `loadError` because a reload that REFUSED a bad file is a success of the reload
    /// and a failure of the file, and collapsing the two hides which.
    public private(set) var reloadReport: ReloadReport?
    /// Keyed by job id: the one-line refusal that row's last action earned.
    public private(set) var rowMessages: [String: String] = [:]
    /// The job whose verb is in flight, so exactly that row's controls disable.
    public private(set) var busyJob: String?

    public struct ReloadReport: Sendable, Equatable {
        public var reloaded: Bool
        public var errors: [String]
    }

    public init(configuration: OpsConfiguration) {
        self.configuration = configuration
    }

    /// Which process the two verbs go to — printed under the list so an outage is
    /// attributable.
    public var route: OpsConfiguration.Route { configuration.scheduleControlRoute }

    public var chains: [ScheduleChain] { document?.chains ?? [] }
    public var invalid: [ScheduleDocument.InvalidEntry] { document?.invalid ?? [] }
    /// The zone every "HH:MM" in the document is resolved in.
    public var bridgeTz: String? { document?.tz }

    // MARK: - Reading

    public func refresh() async {
        guard configuration.bridge.isConfigured else {
            loadError = "Pair the bridge in Settings first."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            document = try ScheduleDocument.decode(await configuration.bridgeClient.scheduleDocument())
            loadError = nil
        } catch {
            loadError = OpsModel.describe(error)
        }
    }

    /// `POST /jesse/schedule/reload` — the same swap the tick performs when it notices an
    /// mtime change, but one you can watch the result of. Always the BRIDGE: the sentinel
    /// proxies fire and enable and nothing else.
    public func reloadConfig() async {
        guard configuration.bridge.isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try ScheduleDocument.ReloadResult
                .decode(await configuration.bridgeClient.reloadSchedule())
            reloadReport = ReloadReport(reloaded: result.reloaded, errors: result.errors)
            // The reload answers with the whole fresh document, so taking it is both cheaper
            // and more honest than a follow-up GET that could race another change.
            if let fresh = result.schedule { document = fresh }
            loadError = nil
        } catch {
            reloadReport = nil
            loadError = OpsModel.describe(error)
        }
    }

    // MARK: - The two verbs

    /// Run the chain from `id` now. A `409` lands on the row as its conflict line; the chain
    /// it names is already running, which is the whole answer.
    public func fire(id: String, force: Bool = false) async {
        guard busyJob == nil else { return }
        busyJob = id
        defer { busyJob = nil }
        rowMessages[id] = nil
        do {
            _ = try await configuration.scheduleControl.fireJob(id: id, force: force)
            rowMessages[id] = "started"
        } catch {
            rowMessages[id] = OpsModel.describe(error)
        }
        await refresh()
    }

    /// Turn one job on or off, optionally until a deadline.
    ///
    /// `until` nil means "until it is changed" — allowed, and deliberately not the default the
    /// screen offers: a disabled job is silent by design, so an override nobody remembers is a
    /// job that never runs again.
    public func setEnabled(id: String, enabled: Bool, until: Date?) async {
        guard busyJob == nil else { return }
        busyJob = id
        defer { busyJob = nil }
        rowMessages[id] = nil
        do {
            let data = try await configuration.scheduleControl
                .enableJob(id: id, enabled: enabled, until: until)
            rowMessages[id] = enabled ? "on" : (until == nil ? "off" : "off until the deadline")
            // The verb answers the job's ROW, so splicing it in is what makes the override's
            // `until` and `active` correct on screen without a second round trip. If it could
            // not be spliced — an older bridge, an unrecognised wrapper — re-read, because the
            // toggle has already moved and a screen that disagrees with the bridge about which
            // jobs are on is worse than a slow one.
            if !apply(rowFrom: data, id: id) { await refresh() }
        } catch {
            rowMessages[id] = OpsModel.describe(error)
            // The toggle moved optimistically in SwiftUI; a refresh is what puts it back where
            // the bridge says it belongs.
            await refresh()
        }
    }

    /// Splice the row the enable verb answered with into the loaded document.
    ///
    /// The bridge answers with the bare row; the sentinel's proxy wraps it as
    /// `{bridge_status, bridge_body}`. Both are read, because which one arrives depends on
    /// configuration and a screen that only understood one would silently stop updating for
    /// half of its users.
    @discardableResult
    func apply(rowFrom data: Data, id: String) -> Bool {
        let row = (try? JSONDecoder().decode(ScheduleRow.self, from: data))
            ?? (try? JSONDecoder().decode(ProxiedRow.self, from: data))?.bridgeBody
        guard let row, var doc = document,
              let i = doc.jobs.firstIndex(where: { $0.id == row.id || $0.id == id }) else {
            return false
        }
        doc.jobs[i] = row
        document = doc
        return true
    }

    struct ProxiedRow: Decodable {
        var bridgeBody: ScheduleRow?
        enum CodingKeys: String, CodingKey { case bridgeBody = "bridge_body" }
    }
}
