import Foundation

// `GET /sentinel/status`, as a value.
//
// The document is ONE object assembled from eight independent probes, and the property that
// shapes every type here is that any of them may be `unknown`: a probe that overran its
// ceiling reports a stated absence of knowledge rather than a cheerful default. So no field
// below is non-optional unless the sentinel emits it unconditionally, and a probe whose
// `detail` arrives in a shape this build does not recognise degrades to "no detail" instead
// of failing the whole decode. A status screen that renders nothing because one probe changed
// shape is worse than one that renders seven cards and a grey dot.

// MARK: - The probe envelope

/// What one probe learned. THREE states, not two — `unknown` is what a timeout produces and
/// it must never be shown as `failed`: "the disk is not full" and "I could not find out
/// whether the disk is full" lead to different actions.
public enum ProbeState: String, Sendable, Codable {
    case ok, failed, unknown

    /// An unrecognised `state` string reads as `unknown` rather than throwing: a newer
    /// sentinel adding a fourth word must not blank the screen.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProbeState(rawValue: raw) ?? .unknown
    }
}

/// One probe's report, over whatever `detail` that probe carries.
public struct Probe<Detail: Decodable & Sendable>: Decodable, Sendable {
    public var state: ProbeState
    /// Nil when the probe timed out (there is nothing to describe), and ALSO nil when the
    /// detail arrived in a shape this build cannot read — see `init(from:)`.
    public var detail: Detail?
    /// Present on a failure, and also on an `ok` that has something worth saying anyway (an
    /// artifact store that does not exist yet, a ledger the scheduler has not written).
    public var error: String?

    enum CodingKeys: String, CodingKey { case state, detail, error }

    public init(state: ProbeState, detail: Detail?, error: String?) {
        self.state = state
        self.detail = detail
        self.error = error
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? c.decode(ProbeState.self, forKey: .state)) ?? .unknown
        // `try?`, deliberately: the envelope is the contract and the detail is not. A probe
        // whose detail this build cannot parse still has a colour and an error line, which is
        // most of what the card is for.
        detail = try? c.decodeIfPresent(Detail.self, forKey: .detail)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }

    /// The dot. `ok` with a note is AMBER: it is not a fault, but it is not silence either,
    /// and painting it green would read as "checked and fine" for something that was not
    /// fully checked.
    public var health: OpsHealth {
        switch state {
        case .failed: return .red
        case .unknown: return .grey
        case .ok: return (error?.isEmpty == false) ? .amber : .green
        }
    }
}

/// The four dots an Ops card can wear.
public enum OpsHealth: Sendable, Equatable {
    case green, amber, red, grey
}

// MARK: - The per-probe details

/// `sentinel` — the supervisor talking about itself.
public struct SentinelSelf: Decodable, Sendable {
    public var version: String?
    public var uptimeSecs: UInt64?
    public var nowMs: UInt64?
    public var watchdog: WatchdogReport?

    enum CodingKeys: String, CodingKey {
        case version
        case uptimeSecs = "uptime_secs"
        case nowMs = "now_ms"
        case watchdog
    }
}

/// The watchdog's own report. `gaveUpMs` is the field that matters most when it is set: it is
/// the difference between "the bridge is down" and "the bridge is down AND nothing is trying
/// to fix it any more".
public struct WatchdogReport: Decodable, Sendable {
    public var lastTickMs: UInt64?
    public var bridgeMisses: Int?
    public var kickstartsLastHour: Int?
    public var gaveUpMs: UInt64?
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case lastTickMs = "last_tick_ms"
        case bridgeMisses = "bridge_misses"
        case kickstartsLastHour = "kickstarts_last_hour"
        case gaveUpMs = "gave_up_ms"
        case lastError = "last_error"
    }
}

public struct BridgeProbeDetail: Decodable, Sendable {
    public var reachable: Bool?
    public var status: Int?
    public var latencyMs: UInt64?
    public var health: BridgeHealthDetail?

    enum CodingKeys: String, CodingKey {
        case reachable, status, health
        case latencyMs = "latency_ms"
    }
}

/// The bridge's own `/health` body, reduced to what the card shows. Everything is optional:
/// this is another service's document quoted verbatim, and quoting one is exactly where a
/// strict decode turns a version skew into a blank screen.
public struct BridgeHealthDetail: Decodable, Sendable {
    public var version: String?
    public var profile: String?
    public var tz: String?
    /// The scheduler's own drift report, when the bridge carries one. Only its COUNT is
    /// shown, so it is decoded as an opaque array of strings and anything else is dropped.
    public var drift: [String]?

    enum CodingKeys: String, CodingKey { case version, profile, tz, drift }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        tz = try? c.decodeIfPresent(String.self, forKey: .tz)
        // `profile` is a bare name on some builds and an object on others; take the name
        // either way rather than picking one and failing on the other.
        if let name = try? c.decodeIfPresent(String.self, forKey: .profile) {
            profile = name
        } else if let obj = try? c.decodeIfPresent(ProfileNameOnly.self, forKey: .profile) {
            profile = obj.name
        }
        drift = (try? c.decodeIfPresent([String].self, forKey: .drift)) ?? nil
    }

    private struct ProfileNameOnly: Decodable { var name: String? }
}

/// One launchd job, as `launchctl print` reports it.
public struct ServiceRow: Decodable, Sendable, Identifiable {
    /// The sentinel's slug for the slot (`bridge`, `autocommit`, …) — the map key, filled in
    /// by `SentinelStatusDocument`.
    public var id: String = ""
    /// launchd's own word: `running`, `waiting`, `not running`, or the sentinel's
    /// `not-loaded`.
    public var state: String?
    public var pid: Int?
    /// Nil when launchd says `(never exited)`, which is NOT the same as 0 — reporting it as
    /// zero would tell an operator a KeepAlive job had exited cleanly when it never exited.
    public var lastExitCode: Int?
    public var runs: Int?
    /// What an operator would type into `launchctl` themselves.
    public var label: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case state, pid, runs, label, error
        case lastExitCode = "last_exit_code"
    }

    /// Green while it is running, red when it is not loaded or exited non-zero, grey when
    /// launchd said nothing usable about it.
    public var health: OpsHealth {
        guard let state else { return .grey }
        if state == "running" { return (lastExitCode ?? 0) == 0 ? .green : .amber }
        if state == "not-loaded" { return .red }
        return .amber
    }
}

public struct TailscaleDetail: Decodable, Sendable {
    public var online: Bool?
    public var ips: [String]?
    /// Trailing dot and all, exactly as tailscale reports it.
    public var dnsName: String?

    enum CodingKeys: String, CodingKey {
        case online, ips
        case dnsName = "dns_name"
    }
}

public struct DiskDetail: Decodable, Sendable {
    public struct Volume: Decodable, Sendable, Identifiable {
        public var path: String
        public var freeBytes: UInt64?
        public var totalBytes: UInt64?
        public var id: String { path }

        enum CodingKeys: String, CodingKey {
            case path
            case freeBytes = "free_bytes"
            case totalBytes = "total_bytes"
        }
    }

    public var volumes: [Volume]?
    public var freeBytesMin: UInt64?
    public var floorBytes: UInt64?
    public var artifactsBytes: UInt64?
    public var artifactsFiles: Int?
    /// False when the walk hit its entry ceiling — a partial walk must say so rather than
    /// under-report the store as small.
    public var artifactsComplete: Bool?

    enum CodingKeys: String, CodingKey {
        case volumes
        case freeBytesMin = "free_bytes_min"
        case floorBytes = "floor_bytes"
        case artifactsBytes = "artifacts_bytes"
        case artifactsFiles = "artifacts_files"
        case artifactsComplete = "artifacts_complete"
    }
}

public struct GitDetail: Decodable, Sendable {
    public struct AutocommitLine: Decodable, Sendable {
        public var line: String?
        public var published: Bool?
        public var error: String?
    }

    public var repo: String?
    public var branch: String?
    public var ahead: Int?
    public var behind: Int?
    public var dirty: Bool?
    public var indexLockAgeSecs: UInt64?
    public var conflicts: [String]?
    public var lastAutocommitLine: AutocommitLine?

    enum CodingKeys: String, CodingKey {
        case repo, branch, ahead, behind, dirty, conflicts
        case indexLockAgeSecs = "index_lock_age_secs"
        case lastAutocommitLine = "last_autocommit_line"
    }
}

public struct QmdDetail: Decodable, Sendable {
    public var exitCode: Int?
    public var firstStderrLine: String?
    public var childPathSet: Bool?
    public var nodeVersion: String?

    enum CodingKeys: String, CodingKey {
        case exitCode = "exit_code"
        case firstStderrLine = "first_stderr_line"
        case childPathSet = "child_path_set"
        case nodeVersion = "node_version"
    }
}

/// One fire-ledger line. A line that was not JSON arrives as `{"raw": "…"}` rather than being
/// dropped — a ledger that has started emitting garbage is a thing to see, not to hide.
public struct LedgerRow: Decodable, Sendable, Identifiable, Equatable {
    public var at: String?
    public var atMs: UInt64?
    public var job: String?
    public var outcome: String?
    public var reason: String?
    public var firedAtMs: UInt64?
    public var durationMs: UInt64?
    public var jobId: String?
    public var raw: String?

    /// Positional, assigned by the document: two lines can legitimately share every field
    /// (the same job, the same outcome, the same millisecond on a fast skip), so nothing in
    /// the payload is a usable identity.
    public var id: Int = 0

    enum CodingKeys: String, CodingKey {
        case at, job, outcome, reason, raw
        case atMs = "at_ms"
        case firedAtMs = "fired_at_ms"
        case durationMs = "duration_ms"
        case jobId = "job_id"
    }
}

// MARK: - The whole document

/// `GET /sentinel/status`.
public struct SentinelStatusDocument: Decodable, Sendable {
    public var sentinel: SentinelSelf?
    public var bridge: Probe<BridgeProbeDetail>
    /// Keyed by the sentinel's slug for the slot. Rendered in `SERVICE_SLOTS` order via
    /// `serviceRows`, so a card's row order does not depend on dictionary iteration.
    public var services: Probe<[String: ServiceRow]>
    public var tailscale: Probe<TailscaleDetail>
    public var disk: Probe<DiskDetail>
    public var git: Probe<GitDetail>
    public var qmd: Probe<QmdDetail>
    public var ledgerTail: Probe<[LedgerRow]>
    /// The bridge's `GET /jesse/schedule`, quoted. The Ops screen shows only its shape here;
    /// the Schedule screen fetches it itself so a wedged sentinel never hides the schedule.
    public var schedule: Probe<ScheduleDocument>

    enum CodingKeys: String, CodingKey {
        case sentinel, bridge, services, tailscale, disk, git, qmd, schedule
        case ledgerTail = "ledger_tail"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sentinel = try? c.decodeIfPresent(SentinelSelf.self, forKey: .sentinel)
        // Each probe envelope is required — an answer that carries none of them is not this
        // document, and pretending otherwise would show eight grey cards for what is really a
        // wrong URL or a proxy's error page.
        bridge = try c.decode(Probe<BridgeProbeDetail>.self, forKey: .bridge)
        services = try c.decode(Probe<[String: ServiceRow]>.self, forKey: .services)
        tailscale = try c.decode(Probe<TailscaleDetail>.self, forKey: .tailscale)
        disk = try c.decode(Probe<DiskDetail>.self, forKey: .disk)
        git = try c.decode(Probe<GitDetail>.self, forKey: .git)
        qmd = try c.decode(Probe<QmdDetail>.self, forKey: .qmd)
        ledgerTail = try c.decode(Probe<[LedgerRow]>.self, forKey: .ledgerTail)
        schedule = try c.decode(Probe<ScheduleDocument>.self, forKey: .schedule)

        services.detail = services.detail.map { rows in
            rows.reduce(into: [String: ServiceRow]()) { out, pair in
                var row = pair.value
                row.id = pair.key
                out[pair.key] = row
            }
        }
        ledgerTail.detail = ledgerTail.detail.map { rows in
            rows.enumerated().map { i, row in
                var r = row
                r.id = i
                return r
            }
        }
    }

    public static func decode(_ data: Data) throws -> SentinelStatusDocument {
        try JSONDecoder().decode(SentinelStatusDocument.self, from: data)
    }

    /// The five service slots in the order the sentinel declares them, so the card reads the
    /// same every refresh. Anything the sentinel adds later lands after them, sorted, rather
    /// than being dropped.
    public static let serviceOrder = ["bridge", "autocommit", "lock-reaper", "qmd-update",
                                      "miniserve"]

    public var serviceRows: [ServiceRow] {
        guard let rows = services.detail else { return [] }
        let known = Self.serviceOrder.compactMap { rows[$0] }
        let extra = rows.keys.filter { !Self.serviceOrder.contains($0) }.sorted()
            .compactMap { rows[$0] }
        return known + extra
    }

    /// The ledger newest-first, which is the order the question is asked in.
    public var ledgerRows: [LedgerRow] {
        (ledgerTail.detail ?? []).reversed()
    }
}
