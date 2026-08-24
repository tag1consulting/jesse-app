import Foundation

// `GET /jesse/schedule`, as a value — plus the one thing the document does not carry and the
// screen needs: the CHAINS.
//
// The bridge answers with a flat list of jobs, each link naming its predecessor in `after`.
// A chain is therefore a client-side derivation, and it is derived here rather than in the
// view so it can be tested against the shapes that actually break it: a link whose `after`
// names a job that is not in the list, two links hanging off the same predecessor, and a
// cycle. All three are config mistakes a person can make, and none of them may cost the
// screen a job — an entry that cannot be placed under a head is shown on its own rather than
// silently dropped.

// MARK: - The row

/// One job's row, exactly as `schedule_row` in `bridge/src/scheduler.rs` emits it.
public struct ScheduleRow: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    /// The EFFECTIVE state — the runtime override while it is live, else the config's.
    public var enabled: Bool
    /// The config file's own answer, kept beside it so "why is this off" never needs the
    /// file to be read.
    public var enabledConfig: Bool?
    /// `head` | `link`.
    public var kind: String
    /// The predecessor a link hangs off.
    public var after: String?
    /// `success` | `completion` — what "after" means for this link.
    public var afterOn: String?
    /// `"HH:MM"` for a head; nil for a link, which has no clock of its own.
    public var at: String?
    public var days: [String]?
    /// The profiles this job is in scope for. Always both unless the entry says otherwise.
    public var profiles: [String]?
    public var mode: String?
    public var prompt: String?
    public var notify: Bool?
    public var timeoutSecs: UInt64?
    public var catchUpSecs: UInt64?
    public var running: Bool?
    public var nextFireMs: UInt64?
    /// An occurrence skipped because the bridge was busy and STILL ELIGIBLE — the next tick
    /// retries it while it is inside `catch_up_secs`.
    public var retryDueMs: UInt64?
    public var lastFireMs: UInt64?
    public var lastCompletionMs: UInt64?
    public var lastOutcome: String?
    public var lastReason: String?
    public var lastDurationMs: UInt64?
    public var lastJobId: String?
    /// How many times in a row it has not delivered. `lastOutcome` says last night failed;
    /// only this says it was the sixth night running.
    public var consecutiveFailures: Int?
    public var expectOutput: String?
    public var lastOutputPath: String?
    public var model: String?
    /// Set when this entry was promoted into a missing head's clock slot.
    public var promotedFrom: String?
    public var override: EnableOverride?

    public struct EnableOverride: Decodable, Sendable, Equatable {
        public var enabled: Bool
        public var untilMs: UInt64?
        public var setMs: UInt64?
        /// Whether the override is the one in force RIGHT NOW. An EXPIRED override is still
        /// reported, because "it was disabled until Sunday and Sunday has passed" is a thing
        /// someone asks.
        public var active: Bool?

        enum CodingKeys: String, CodingKey {
            case enabled, active
            case untilMs = "until_ms"
            case setMs = "set_ms"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, enabled, kind, after, at, days, profiles, mode, prompt, notify, running, model
        case override
        case enabledConfig = "enabled_config"
        case afterOn = "after_on"
        case timeoutSecs = "timeout_secs"
        case catchUpSecs = "catch_up_secs"
        case nextFireMs = "next_fire_ms"
        case retryDueMs = "retry_due_ms"
        case lastFireMs = "last_fire_ms"
        case lastCompletionMs = "last_completion_ms"
        case lastOutcome = "last_outcome"
        case lastReason = "last_reason"
        case lastDurationMs = "last_duration_ms"
        case lastJobId = "last_job_id"
        case consecutiveFailures = "consecutive_failures"
        case expectOutput = "expect_output"
        case lastOutputPath = "last_output_path"
        case promotedFrom = "promoted_from"
    }

    /// Whether this row heads a chain. Read from `kind` when the bridge sent one and from the
    /// absence of `after` otherwise, because that is what `kind` MEANS and a row is not worth
    /// losing to a missing string.
    public var isHead: Bool { kind.isEmpty ? (after == nil) : kind == "head" }

    /// The days, resolved to something a person reads. The bridge already sends names; an
    /// empty or absent list is "every day", which is what an entry with no `days` key means.
    public var resolvedDays: String {
        guard let days, !days.isEmpty else { return "every day" }
        return days.joined(separator: ", ")
    }

    /// The clock line: a head's `at`, or what a link hangs off.
    public var whenLabel: String {
        if let at, !at.isEmpty { return at }
        if let after { return "after \(after)\(afterOn.map { " (\($0))" } ?? "")" }
        return "—"
    }

    /// Nil when the job declares no output contract, which is a real and ordinary state — the
    /// screen says "no output contract" rather than leaving a blank.
    public var outputLabel: String {
        if let p = lastOutputPath, !p.isEmpty { return p }
        if let e = expectOutput, !e.isEmpty { return "expects \(e) — nothing matched yet" }
        return "no output contract"
    }
}

// MARK: - The document

/// `GET /jesse/schedule`, and the identical body the enable verb and the reload answer with.
public struct ScheduleDocument: Decodable, Sendable {
    public var nowMs: UInt64?
    /// THE ACTIVE PROFILE, at the top level because it reinterprets every `tz`, every
    /// `nextFireMs` and every `profiles` below it.
    public var profile: ActiveProfile?
    /// The job whose chain runs once when an away period ends, or nil when none is declared.
    public var onReturn: String?
    /// THE ZONE, BY NAME. Every "HH:MM" and every `days` is resolved in it, and a UTC offset
    /// alone cannot answer that: "+02:00" is Rome in August and something else in January.
    public var tz: String?
    public var utcOffset: String?
    public var persistent: Bool?
    public var jobs: [ScheduleRow]
    /// Entries disabled individually by validation, so a typo is VISIBLE rather than merely
    /// absent from the list above.
    public var invalid: [InvalidEntry]

    public struct ActiveProfile: Decodable, Sendable {
        public var name: String?
        public var tz: String?
        public var untilMs: UInt64?
        public var note: String?

        enum CodingKeys: String, CodingKey {
            case name, tz, note
            case untilMs = "until_ms"
        }
    }

    public struct InvalidEntry: Decodable, Sendable, Identifiable, Equatable {
        public var id: String
        public var reason: String
    }

    enum CodingKeys: String, CodingKey {
        case profile, tz, persistent, jobs, invalid
        case nowMs = "now_ms"
        case onReturn = "on_return"
        case utcOffset = "utc_offset"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nowMs = try? c.decodeIfPresent(UInt64.self, forKey: .nowMs)
        profile = try? c.decodeIfPresent(ActiveProfile.self, forKey: .profile)
        onReturn = try? c.decodeIfPresent(String.self, forKey: .onReturn)
        tz = try? c.decodeIfPresent(String.self, forKey: .tz)
        utcOffset = try? c.decodeIfPresent(String.self, forKey: .utcOffset)
        persistent = try? c.decodeIfPresent(Bool.self, forKey: .persistent)
        // `jobs` is the document. Its absence is not a schedule with no jobs, it is not this
        // document at all, so it is the one required key.
        jobs = try c.decode([ScheduleRow].self, forKey: .jobs)
        invalid = (try? c.decodeIfPresent([InvalidEntry].self, forKey: .invalid)) ?? []
    }

    public static func decode(_ data: Data) throws -> ScheduleDocument {
        try JSONDecoder().decode(ScheduleDocument.self, from: data)
    }

    /// The reload verb answers `{reloaded, errors, schedule}` — the same document, one level
    /// down, beside what the reload itself did.
    public struct ReloadResult: Decodable, Sendable {
        public var reloaded: Bool
        public var errors: [String]
        public var schedule: ScheduleDocument?

        public static func decode(_ data: Data) throws -> ReloadResult {
            try JSONDecoder().decode(ReloadResult.self, from: data)
        }
    }

    /// The chains, in the order the screen shows them.
    public var chains: [ScheduleChain] { ScheduleChain.group(jobs) }
}

// MARK: - Chains

/// One chain: a head and everything hanging off it, in fire order.
public struct ScheduleChain: Sendable, Identifiable, Equatable {
    /// The head's id — or, for an orphan, the orphan's own.
    public var id: String
    public var members: [Member]

    public struct Member: Sendable, Identifiable, Equatable {
        public var row: ScheduleRow
        /// 0 for the head, 1 for its link, 2 for the link's link. Drives the indent.
        public var depth: Int
        public var id: String { row.id }
    }

    public var head: ScheduleRow? { members.first?.row }

    /// Group a flat job list into chains.
    ///
    /// Heads keep the order the config declared them in — that is the order the day happens
    /// in, and re-sorting by clock would put a 03:30 job above an 06:00 one only until
    /// somebody moved a job across midnight. Links follow their predecessor.
    ///
    /// THREE SHAPES THAT MUST NOT LOSE A JOB, all of them things a person can write:
    ///   * a link whose `after` names a job that is not in the list (a typo, or an entry
    ///     that failed validation and is in `invalid` instead) — shown as its own group;
    ///   * two links hanging off the same predecessor — both are placed, in list order;
    ///   * a cycle — the `placed` set stops the walk and whatever it could not reach is
    ///     emitted as its own group.
    public static func group(_ jobs: [ScheduleRow]) -> [ScheduleChain] {
        var followers: [String: [ScheduleRow]] = [:]
        for job in jobs where !job.isHead {
            guard let after = job.after else { continue }
            followers[after, default: []].append(job)
        }
        var placed = Set<String>()

        func walk(_ row: ScheduleRow, depth: Int) -> [Member] {
            guard placed.insert(row.id).inserted else { return [] }
            var out = [Member(row: row, depth: depth)]
            for next in followers[row.id] ?? [] {
                out += walk(next, depth: depth + 1)
            }
            return out
        }

        var chains: [ScheduleChain] = []
        for head in jobs where head.isHead {
            let members = walk(head, depth: 0)
            if !members.isEmpty { chains.append(ScheduleChain(id: head.id, members: members)) }
        }
        // Anything a head could not reach — an orphaned link, a cycle's members. Placed at the
        // bottom, each on its own, because they ARE the shape someone needs to see.
        for row in jobs where !placed.contains(row.id) {
            let members = walk(row, depth: 0)
            if !members.isEmpty { chains.append(ScheduleChain(id: row.id, members: members)) }
        }
        return chains
    }
}
