import Foundation

// `GET /sentinel/deploy/status` — the Deploy card — and the ONE decision on it that is worth
// a test of its own: whether the button may be pressed.
//
// A deploy builds a commit on the Studio, swaps three binaries, restarts the bridge and rolls
// back on any failure. It is the most consequential button in the app, so the card refuses it
// unless BOTH conditions hold: the commit differs from what is running, and CI vouched for
// that commit. `pending` is not `green` and `none` is not `green` — a card that treated
// "CI has not answered yet" as permission would be the one shape in which pressing Deploy
// looks safe and is not.

public struct DeployStatusDocument: Decodable, Sendable {
    /// The last (or in-flight) deploy, or nil when nothing has ever been deployed.
    public var deploy: DeployRecord?
    public var running: RunningBuild
    public var originMain: OriginMain

    /// What each commit actually changed: the running release, and everything a deploy would
    /// bring in. Derived by the sentinel from commit subjects and the `CHANGELOG.md` bullets
    /// each commit added, never written by hand and never generated.
    ///
    /// **Absent from an older sentinel**, and that is the ordinary case rather than an error:
    /// a deploy replaces the bridge, not the sentinel, so a phone on a new build routinely
    /// talks to a sentinel that predates this block. The card renders exactly as it did
    /// before when it is missing.
    public var releases: Releases?

    /// The release-notes block. `deployed` is nil when there is no running commit or it is not
    /// readable; `undeployed` is newest first and is EMPTY rather than a guess whenever the
    /// range could not be computed, with `reason` saying which case that was.
    public struct Releases: Decodable, Sendable, Equatable {
        public var deployed: Release?
        public var undeployed: [Release]
        /// Undeployed releases the sentinel dropped past its own cap. Zero means the list is
        /// complete — a count, not a flag, because the card says how many it is not showing.
        public var truncated: Int
        /// Why `undeployed` is empty when emptiness is not simply "already current": no
        /// recorded deploy yet, a running commit that is not on `origin/main`, or one that is
        /// not in the deploy clone at all.
        public var reason: String?

        public init(deployed: Release?, undeployed: [Release], truncated: Int, reason: String?) {
            self.deployed = deployed
            self.undeployed = undeployed
            self.truncated = truncated
            self.reason = reason
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            deployed = try? c.decodeIfPresent(Release.self, forKey: .deployed)
            undeployed = (try? c.decodeIfPresent([Release].self, forKey: .undeployed)) ?? []
            truncated = (try? c.decodeIfPresent(Int.self, forKey: .truncated)) ?? 0
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
            // Positional identity, assigned here: two releases can carry the same version
            // string (a re-tag, an app-only pair), so nothing in the payload is an identity.
            for i in undeployed.indices { undeployed[i].id = i }
        }

        enum CodingKeys: String, CodingKey { case deployed, undeployed, truncated, reason }
    }

    /// One release: a title, and up to a handful of one-sentence claims. The bullet BODIES the
    /// changelog carries under each claim are dropped by the sentinel on purpose — this card
    /// is read in ten seconds to decide whether a deploy is worth running.
    public struct Release: Decodable, Sendable, Equatable, Identifiable {
        public var sha: String
        /// Component-qualified (`bridge 0.106.0`, `App 1.0 (121)`), because the list mixes
        /// components. Nil when neither the changelog heading nor the subject stated one.
        public var version: String?
        public var title: String
        public var dateMs: UInt64
        /// The bold lead sentence of each changelog bullet the commit added. Empty when it
        /// added none, in which case the title alone is the summary.
        public var lines: [String]
        /// Lines beyond the sentinel's per-release cap. Shown, never swallowed.
        public var more: Int

        /// Positional, assigned by the enclosing document — see `LedgerRow.id` for the same
        /// reasoning: two releases can share every visible field.
        public var id: Int = 0

        enum CodingKeys: String, CodingKey {
            case sha, version, title, lines, more
            case dateMs = "date_ms"
        }

        public init(sha: String, version: String?, title: String, dateMs: UInt64,
                    lines: [String], more: Int, id: Int = 0) {
            self.sha = sha
            self.version = version
            self.title = title
            self.dateMs = dateMs
            self.lines = lines
            self.more = more
            self.id = id
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sha = (try? c.decodeIfPresent(String.self, forKey: .sha)) ?? ""
            version = try? c.decodeIfPresent(String.self, forKey: .version)
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            dateMs = (try? c.decodeIfPresent(UInt64.self, forKey: .dateMs)) ?? 0
            lines = (try? c.decodeIfPresent([String].self, forKey: .lines)) ?? []
            more = (try? c.decodeIfPresent(Int.self, forKey: .more)) ?? 0
        }

        /// `bridge 0.106.0 · 23f03ce`, or just the short sha when no version was stated.
        public var subtitle: String {
            let short = String(sha.prefix(7))
            guard let version, !version.isEmpty else { return short }
            return "\(version) · \(short)"
        }
    }

    enum CodingKeys: String, CodingKey {
        case deploy, running, releases
        case originMain = "origin_main"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deploy = try? c.decodeIfPresent(DeployRecord.self, forKey: .deploy)
        running = (try? c.decode(RunningBuild.self, forKey: .running))
            ?? RunningBuild(version: nil, sha: nil)
        originMain = (try? c.decode(OriginMain.self, forKey: .originMain))
            ?? OriginMain(sha: nil, version: nil, ci: "none", ciDetail: nil, checkedMs: 0,
                          stale: true, staleReason: "the sentinel sent no origin/main view")
        // Absent on any sentinel older than the release-summaries change, which a deploy does
        // NOT update — so nil here is routine, not a decode failure.
        releases = try? c.decodeIfPresent(Releases.self, forKey: .releases)
    }

    public static func decode(_ data: Data) throws -> DeployStatusDocument {
        try JSONDecoder().decode(DeployStatusDocument.self, from: data)
    }

    /// What is actually up, which is not the same as what was last deployed: the version is
    /// read from the live bridge's `/health`, the sha from the sentinel's own state.
    public struct RunningBuild: Decodable, Sendable, Equatable {
        public var version: String?
        public var sha: String?
    }

    /// The cached view of `origin/main` behind the card.
    public struct OriginMain: Decodable, Sendable, Equatable {
        public var sha: String?
        /// The `[package] version` declared at that commit, so the card can say
        /// "0.93.0 → 0.94.0" without a second call.
        public var version: String?
        /// `green` | `red` | `pending` | `none`.
        public var ci: String
        /// Why, in one line. `green` carries the run that vouched for it.
        public var ciDetail: String?
        public var checkedMs: UInt64
        /// Present ONLY when the view could not be refreshed — a fresh read omits both of
        /// these, so absent means current.
        public var stale: Bool?
        public var staleReason: String?

        enum CodingKeys: String, CodingKey {
            case sha, version, ci, stale
            case ciDetail = "ci_detail"
            case checkedMs = "checked_ms"
            case staleReason = "stale_reason"
        }

        public init(sha: String?, version: String?, ci: String, ciDetail: String?,
                    checkedMs: UInt64, stale: Bool?, staleReason: String?) {
            self.sha = sha
            self.version = version
            self.ci = ci
            self.ciDetail = ciDetail
            self.checkedMs = checkedMs
            self.stale = stale
            self.staleReason = staleReason
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sha = try? c.decodeIfPresent(String.self, forKey: .sha)
            version = try? c.decodeIfPresent(String.self, forKey: .version)
            ci = (try? c.decodeIfPresent(String.self, forKey: .ci)) ?? "none"
            ciDetail = try? c.decodeIfPresent(String.self, forKey: .ciDetail)
            checkedMs = (try? c.decodeIfPresent(UInt64.self, forKey: .checkedMs)) ?? 0
            stale = try? c.decodeIfPresent(Bool.self, forKey: .stale)
            staleReason = try? c.decodeIfPresent(String.self, forKey: .staleReason)
        }

        public var isStale: Bool { stale ?? false }
        public var ciIsGreen: Bool { ci == "green" }

        public var ciHealth: OpsHealth {
            switch ci {
            case "green": return .green
            case "red": return .red
            case "pending": return .amber
            default: return .grey
            }
        }
    }

    /// One deploy, present from the moment the verb is accepted — so a phone that polls
    /// immediately sees `phase: "resolve"` rather than an absent field it has to guess at.
    public struct DeployRecord: Decodable, Sendable, Equatable {
        public var deployId: String
        /// `resolve` → `ci` → `build` → `stage` → `restart` → (`rollback`) → `finish`.
        public var phase: String
        /// What the caller asked for: `main` or a 40-hex sha.
        public var gitRef: String
        /// The commit that ref resolved to. Absent until `resolve` succeeds.
        public var sha: String?
        public var startedMs: UInt64
        public var finishedMs: UInt64?
        /// `ok` | `failed` | `rolled_back` | `rolled_back_unhealthy`. Absent WHILE RUNNING,
        /// which is exactly how "still going" is told from "finished".
        public var result: String?
        public var reason: String?
        public var logTail: [String]

        enum CodingKeys: String, CodingKey {
            case phase, sha, result, reason
            case deployId = "deploy_id"
            case gitRef = "ref"
            case startedMs = "started_ms"
            case finishedMs = "finished_ms"
            case logTail = "log_tail"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            deployId = (try? c.decodeIfPresent(String.self, forKey: .deployId)) ?? ""
            phase = (try? c.decodeIfPresent(String.self, forKey: .phase)) ?? ""
            gitRef = (try? c.decodeIfPresent(String.self, forKey: .gitRef)) ?? ""
            sha = try? c.decodeIfPresent(String.self, forKey: .sha)
            startedMs = (try? c.decodeIfPresent(UInt64.self, forKey: .startedMs)) ?? 0
            finishedMs = try? c.decodeIfPresent(UInt64.self, forKey: .finishedMs)
            result = try? c.decodeIfPresent(String.self, forKey: .result)
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
            logTail = (try? c.decodeIfPresent([String].self, forKey: .logTail)) ?? []
        }

        /// Still running. The bridge's own rule: a record with no `result` is in flight.
        public var inFlight: Bool { result == nil }

        public var resultHealth: OpsHealth {
            switch result {
            case "ok": return .green
            case nil: return .grey
            default: return .red
            }
        }
    }

    /// `POST /sentinel/deploy`'s 202 body.
    public struct Accepted: Decodable, Sendable {
        public var deployId: String
        enum CodingKeys: String, CodingKey { case deployId = "deploy_id" }

        public static func decode(_ data: Data) throws -> Accepted {
            try JSONDecoder().decode(Accepted.self, from: data)
        }
    }
}

// MARK: - May the button be pressed?

/// Whether Deploy is offered, and when it is not, why not — in one sentence the card prints
/// under the button. A disabled control with no explanation is the thing an operator retries
/// by force.
public enum DeployAvailability: Sendable, Equatable {
    case ready(sha: String)
    case blocked(String)

    public var isReady: Bool { if case .ready = self { return true }; return false }

    public var reason: String? {
        if case .blocked(let why) = self { return why }
        return nil
    }

    /// THE MATRIX, in one place:
    ///   * a deploy already running → blocked, whatever else is true;
    ///   * no origin/main sha at all → blocked ("nothing to deploy");
    ///   * the same sha as the running build → blocked ("already running");
    ///   * CI red / pending / none → blocked, naming which;
    ///   * different sha AND `ci == green` → ready.
    ///
    /// The running sha being UNKNOWN does not block: a sentinel that has never deployed has
    /// no `running.sha`, and refusing the first deploy for want of a record of a deploy would
    /// be a deadlock. It is the SAME-sha case that blocks, not the unknown one.
    public static func decide(_ doc: DeployStatusDocument) -> DeployAvailability {
        if let d = doc.deploy, d.inFlight {
            return .blocked("a deploy is already running (\(d.phase))")
        }
        guard let target = doc.originMain.sha, !target.isEmpty else {
            return .blocked("the sentinel has not read origin/main yet")
        }
        if let running = doc.running.sha, running == target {
            return .blocked("origin/main is already what is running")
        }
        switch doc.originMain.ci {
        case "green":
            return .ready(sha: target)
        case "red":
            return .blocked("CI is red on that commit")
        case "pending":
            return .blocked("CI has not finished on that commit yet")
        default:
            return .blocked("no CI run vouches for that commit")
        }
    }
}
