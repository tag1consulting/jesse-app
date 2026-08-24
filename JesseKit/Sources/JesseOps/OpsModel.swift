import Foundation
import Observation
import JesseNetworking

// The Ops screen's view model: the status document, the deploy card, and the outcome of the
// last verb.
//
// Two invariants, each with a test:
//
//  * A FAILED REFRESH NEVER BLANKS A LOADED SCREEN. The status page is read at the moment
//    something is wrong, and the moment something is wrong is the moment a probe times out.
//    A loaded document stays on screen behind an error line rather than being replaced by an
//    empty state that says less than the stale one did.
//  * A VERB'S OUTCOME IS SHOWN, NOT INFERRED. Every verb's reply is kept verbatim — for the
//    bridge restart that means `healthy` and `version`, which is the answer to the question
//    that was actually asked ("is it back, and is it the build I wanted"). A green toast on
//    a 200 would say the request was accepted, which is not the same thing.

@MainActor
@Observable
public final class OpsModel {
    // A @MainActor class's synthesized deinit is MainActor-isolated; a unit-test host releases
    // the model off the main actor, which would route through the isolated-deinit executor hop
    // and abort. Same pattern as the two display targets' models.
    nonisolated deinit {}

    public var configuration: OpsConfiguration

    public private(set) var status: SentinelStatusDocument?
    public private(set) var deploy: DeployStatusDocument?
    /// The last refresh's failure, or nil. Shown BESIDE whatever is already loaded.
    public private(set) var refreshError: String?
    public private(set) var isRefreshing = false

    /// The last verb's outcome, shown inline under the actions until the next one replaces it.
    public private(set) var lastVerb: VerbOutcome?
    /// A verb is in flight — every action button is disabled, because the sentinel single-
    /// flights verbs anyway and a second press would earn a 409 that means nothing to a user.
    public private(set) var isRunningVerb = false

    /// How often the deploy poll ticks while a deploy is in flight.
    public static let deployPollInterval: Duration = .seconds(3)

    public init(configuration: OpsConfiguration) {
        self.configuration = configuration
    }

    public var isSentinelPaired: Bool { configuration.sentinel.isConfigured }

    // MARK: - Reading

    /// Pull the status document and the deploy card together. Both are reads, both are cheap
    /// for the caller and neither depends on the other, so they run concurrently and one
    /// failing does not cost the other.
    public func refresh() async {
        guard let client = configuration.sentinelClient else {
            status = nil
            deploy = nil
            refreshError = nil
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        async let statusBytes = client.status()
        async let deployBytes = client.deployStatus()

        var failures: [String] = []
        do {
            status = try SentinelStatusDocument.decode(await statusBytes)
        } catch {
            failures.append(Self.describe(error))
        }
        do {
            deploy = try DeployStatusDocument.decode(await deployBytes)
        } catch {
            failures.append(Self.describe(error))
        }
        // Note what is NOT here: `status = nil` on failure. See the invariant at the top.
        refreshError = failures.isEmpty ? nil : failures.joined(separator: " · ")
    }

    /// Poll the deploy card while a deploy is running, and stop as soon as one is not.
    ///
    /// Driven by the view's `.task`, so SwiftUI cancels it when the screen goes away — there
    /// is deliberately no timer that outlives the view. The first tick is the sleep, not the
    /// fetch: the caller has just refreshed.
    public func pollDeployWhileRunning() async {
        while !Task.isCancelled {
            guard deploy?.deploy?.inFlight == true else { return }
            try? await Task.sleep(for: Self.deployPollInterval)
            guard !Task.isCancelled, let client = configuration.sentinelClient else { return }
            if let fresh = try? DeployStatusDocument.decode(await client.deployStatus()) {
                deploy = fresh
            }
        }
    }

    // MARK: - The verbs

    /// What one verb did, kept whole so the screen can print the fields that matter for the
    /// verb that was pressed rather than a generic "done".
    public struct VerbOutcome: Sendable, Equatable {
        /// What the confirmation dialog named — the exact verb and label, repeated back.
        public var verb: String
        public var succeeded: Bool
        /// The one line under the action. For a bridge restart this carries `healthy` and
        /// `version`; for a prune, the bytes freed; for a refusal, the sentinel's reason.
        public var detail: String

        public init(verb: String, succeeded: Bool, detail: String) {
            self.verb = verb
            self.succeeded = succeeded
            self.detail = detail
        }
    }

    /// Every action goes through here: run it, keep the outcome, and refresh, because each of
    /// these verbs changes something the status document reports and a screen still showing
    /// the pre-verb state is how a restart gets pressed twice.
    private func run(_ verb: String, _ body: @Sendable @escaping () async throws -> Data,
                     summarize: @escaping (Data) -> String) async {
        guard !isRunningVerb else { return }
        isRunningVerb = true
        defer { isRunningVerb = false }
        do {
            let data = try await body()
            lastVerb = VerbOutcome(verb: verb, succeeded: true, detail: summarize(data))
        } catch {
            lastVerb = VerbOutcome(verb: verb, succeeded: false, detail: Self.describe(error))
        }
        await refresh()
    }

    public func restart(_ service: SentinelClient.Service) async {
        guard let client = configuration.sentinelClient else { return }
        await run("restart \(service.label)", { try await client.restart(service) }) { data in
            // The bridge's restart carries the two fields the press was really asking about.
            guard service == .bridge else { return "restarted" }
            let r = Self.object(data)
            let healthy = r["healthy"] as? Bool
            let version = r["version"] as? String
            switch (healthy, version) {
            case (true, let v?): return "back up, healthy, running \(v)"
            case (true, nil): return "back up and healthy"
            case (false, _): return "restarted, but it did not come back healthy"
            default: return "restarted"
            }
        }
    }

    public func reloadBridgeEnv() async {
        guard let client = configuration.sentinelClient else { return }
        await run("reload the bridge's environment", { try await client.reloadBridgeEnv() }) { data in
            let r = Self.object(data)
            let healthy = r["healthy"] as? Bool ?? false
            let version = r["version"] as? String
            return healthy
                ? "bootstrapped and healthy\(version.map { ", running \($0)" } ?? "")"
                : "bootstrapped, but it did not come back healthy"
        }
    }

    public func unlockGit() async {
        guard let client = configuration.sentinelClient else { return }
        await run("unlock git", { try await client.gitUnlock() }) { data in
            let r = Self.object(data)
            let age = r["age_secs"] as? UInt64
            return "removed the index lock\(age.map { " (\($0)s old)" } ?? "")"
        }
    }

    public func pruneArtifacts() async {
        guard let client = configuration.sentinelClient else { return }
        await run("prune artifacts", { try await client.pruneArtifacts() }) { data in
            let r = Self.object(data)
            let freed = (r["bytes_freed"] as? NSNumber)?.uint64Value
            let removed = r["removed"] as? Int ?? 0
            return "\(removed) removed, \(OpsFormat.bytes(freed)) freed"
        }
    }

    /// Start a deploy of one commit. The sha is named in the confirmation, and it is the
    /// resolved sha rather than `main`: a ref would let the commit change between reading the
    /// card and pressing the button.
    public func deploy(sha: String) async {
        guard let client = configuration.sentinelClient else { return }
        await run("deploy \(OpsFormat.shortSha(sha))",
                  { try await client.deploy(ref: sha, force: false) }) { data in
            let id = (try? DeployStatusDocument.Accepted.decode(data))?.deployId
            return "accepted\(id.map { " (\($0))" } ?? "") — it builds, swaps and restarts, "
                + "and rolls back on any failure"
        }
    }

    // MARK: - Reading a reply

    static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// A failure as one sentence. `JesseError` already names the host it tried and carries the
    /// server's own reason, so this is mostly about not printing "The operation couldn't be
    /// completed" at somebody trying to fix a machine.
    static func describe(_ error: any Error) -> String {
        (error as? JesseError)?.errorDescription
            ?? (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }
}
