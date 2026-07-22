import Foundation

// The bridge HTTP contract, modeled once. Every wire key ("job_id"/"session_id"/
// "response"/"status"/…) is a single CodingKey shared by encode and decode — not a
// magic string duplicated between a hand-built dictionary and `obj["…"] as? T` casts.
// Optional fields encode only when present (synthesized `encodeIfPresent`), so the bytes
// on the wire match the old conditionally-built dictionaries byte-for-byte. This is the
// ONE canonical set: it replaces both the iOS-private wire types and the Mac-private
// `Mac*` duplicates.

// MARK: - Reply value

/// A delivered reply: the raw text, the session id to carry forward, and the optional
/// structured sidecars (directives + provenance) a terminal frame/result may carry.
/// The iOS-only accessors that validate directives into HealthKit/meal actions live in
/// an app-side extension; the Mac app reads only `text`/`sessionId`.
public struct JesseReply: Equatable, Sendable {
    public let text: String         // raw response from the bridge
    public let sessionId: String?   // carry into the next call to continue the thread
    // Structured directives the agent emitted (bridge-extracted, stripped from
    // `text`). Nil for the overwhelming majority of turns.
    public var directives: JesseDirectives?
    // Structured, display-only provenance (model-badge v2). When present, `displayText`
    // strips the trailing badge (and the emergency citations-unverified warning) so the
    // bubble shows a clean body and a native chip renders it instead. Nil on an older
    // bridge / badges-off turn → the text is shown verbatim.
    public var provenance: JesseProvenance?

    public init(text: String, sessionId: String?,
                directives: JesseDirectives? = nil, provenance: JesseProvenance? = nil) {
        self.text = text
        self.sessionId = sessionId
        self.directives = directives
        self.provenance = provenance
    }

    private static let marker = "SPOKEN:"

    /// Full answer for the screen, with the model-badge (and any emergency
    /// citations-unverified warning) stripped when structured provenance is present,
    /// then the SPOKEN: line removed. With no provenance the text is shown verbatim
    /// (the older-bridge fallback), badge included, exactly as before.
    public var displayText: String {
        let base = provenance?.strip(from: text) ?? text
        return base.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix(Self.marker) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to read aloud: the SPOKEN: line if present, else a short fallback.
    public var spokenText: String {
        if let line = text.split(separator: "\n")
            .first(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix(Self.marker) }) {
            let s = line.trimmingCharacters(in: .whitespaces)
            return String(s.dropFirst(Self.marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
    }
}

/// The health context an outgoing retry turn should carry — the result of
/// fulfilling a `JESSE_NEEDS_HEALTH` directive. Either a `block` with
/// `requested == true` (fulfilled), or `block == nil` with `unavailable == true`
/// (toggle off / no data). Never both flags.
public struct OutgoingHealthContext: Sendable, Equatable {
    public var block: String?
    public var requested: Bool
    public var unavailable: Bool
    public init(block: String?, requested: Bool, unavailable: Bool) {
        self.block = block
        self.requested = requested
        self.unavailable = unavailable
    }
}

/// Parsed `GET /health` result. Only the bridge `version` is modeled — the
/// liveness `ok` flag and the auth-gated operator paths aren't needed by the app.
/// `version` is nil for a bridge too old to report one.
public struct BridgeHealth: Equatable, Sendable {
    public let version: String?
    public init(version: String?) { self.version = version }
}

/// What `GET /jesse/prompts` returns: the two editable wrapper defaults plus the two
/// fixed safety floors. The floors are display-only.
public struct PromptDefaults: Equatable, Sendable {
    public let ask: String
    public let tell: String
    public let askFloor: String
    public let tellFloor: String
    public init(ask: String, tell: String, askFloor: String, tellFloor: String) {
        self.ask = ask
        self.tell = tell
        self.askFloor = askFloor
        self.tellFloor = tellFloor
    }
}

// MARK: - Result / job / stream states

/// Outcome of a `POST /jesse`. The bridge either finishes within its grace
/// window (inline reply, 200) or hands back a job id to poll (202).
public enum JesseSendResult: Sendable {
    case reply(JesseReply, jobId: String?)
    case running(jobId: String)
}

/// State of a job fetched via `GET /jesse/result/{job_id}`.
public enum JesseResultState: Sendable {
    case running
    case done(JesseReply)
    case failed(String)
    /// The bridge no longer has this job (404 — evicted past its TTL). Terminal
    /// and distinct from `.failed`: there is nothing left to re-check, so the
    /// coordinator drops the retained job_id and shows the one genuinely-final
    /// "expired" state.
    case expired
    /// The turn was cancelled server-side — a clean terminal state, NOT a failure.
    case cancelled
}

/// One decoded frame from the live SSE stream (`GET /jesse/stream/{job_id}`).
/// `reset` carries the full text-so-far and REPLACES the partial buffer; `delta`
/// APPENDS. The three terminal frames mirror `JesseResultState`.
public enum JesseStreamEvent: Equatable, Sendable {
    case reset(String)
    case delta(String)
    case activity(String)   // coarse tool name, e.g. "Read" / "Write"
    case done(JesseReply)
    case failed(String)
    case cancelled
}

// MARK: - Sessions / hydration

/// One session in `GET /jesse/sessions`. Matches the bridge `SessionSummary`.
///
/// The four flag fields (`favorite`, `favoriteUpdatedMs`, `archived`,
/// `archivedUpdatedMs`, bridge 0.25.0) are the server-authoritative favorite/archive
/// state plus their last-writer-wins millis clocks. They are decoded with
/// `decodeIfPresent` and default to `false` / `0`, so against a pre-0.25.0 bridge that
/// omits them the app behaves exactly as before (local-only flags): a missing flag reads
/// as unset with a zero clock, which reconciles as a no-op against an unflagged local
/// thread.
public struct SessionSummary: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let lastModified: UInt64
    public let firstMessage: String?
    public let title: String?
    public let favorite: Bool
    public let favoriteUpdatedMs: UInt64
    public let archived: Bool
    public let archivedUpdatedMs: UInt64
    public init(sessionId: String, lastModified: UInt64, firstMessage: String?, title: String?,
                favorite: Bool = false, favoriteUpdatedMs: UInt64 = 0,
                archived: Bool = false, archivedUpdatedMs: UInt64 = 0) {
        self.sessionId = sessionId
        self.lastModified = lastModified
        self.firstMessage = firstMessage
        self.title = title
        self.favorite = favorite
        self.favoriteUpdatedMs = favoriteUpdatedMs
        self.archived = archived
        self.archivedUpdatedMs = archivedUpdatedMs
    }
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case lastModified = "last_modified"
        case firstMessage = "first_message"
        case title
        case favorite
        case favoriteUpdatedMs = "favorite_updated_ms"
        case archived
        case archivedUpdatedMs = "archived_updated_ms"
    }
    // Custom decode so the flag fields default (a pre-0.25.0 bridge omits them) rather
    // than fail the whole list decode. The required fields stay required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        lastModified = try c.decode(UInt64.self, forKey: .lastModified)
        firstMessage = try c.decodeIfPresent(String.self, forKey: .firstMessage)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        favoriteUpdatedMs = try c.decodeIfPresent(UInt64.self, forKey: .favoriteUpdatedMs) ?? 0
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        archivedUpdatedMs = try c.decodeIfPresent(UInt64.self, forKey: .archivedUpdatedMs) ?? 0
    }
}

/// One hydrated transcript turn. Matches the bridge `HydratedTurn`. `role` is
/// "user" | "assistant".
public struct HydratedTurn: Decodable, Sendable, Equatable {
    public let role: String
    public let text: String
    public let timestamp: String?
    public init(role: String, text: String, timestamp: String?) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

/// Result of listing sessions: either fresh data (with the ETag to send back next
/// time) or a 304 telling the caller its cache is current.
public enum SessionsResult: Sendable, Equatable {
    case notModified
    case sessions([SessionSummary], etag: String?)
}

// MARK: - Wire contract (Codable)

/// The `POST /jesse` request body. A nil field omits its key, reproducing the old
/// conditionally-built dictionary byte-for-byte and matching the bridge's
/// `#[serde(default)]` shape.
public struct JesseRequest: Encodable, Equatable, Sendable {
    public let mode: String
    public let text: String
    public let sessionId: String?
    public let voice: Bool?
    public let instructions: String?
    public let floorOverride: String?
    public let attachments: [Attachment]?
    // Compact device health-context block from Apple Health. Nil omits the field.
    public let healthContext: String?
    // This turn is a retry answering a prior `JESSE_NEEDS_HEALTH` directive.
    public let healthContextRequested: Bool?
    // The app could NOT fulfill a health request this turn (toggle off, denied, etc.).
    public let healthContextUnavailable: Bool?
    // Meal-corrections ack (JESSE_MEAL_LOG v2): the highest `corrections_seq` the app
    // has taken responsibility for.
    public let mealCorrectionsAck: Int?
    // Idempotency key (the send outbox's `OutboxItem.id`, as a string): the bridge
    // dedups a `POST /jesse` carrying a `request_id` it has already seen.
    public let requestId: String?

    public init(mode: String, text: String, sessionId: String?, voice: Bool?,
                instructions: String?, floorOverride: String?, attachments: [Attachment]?,
                healthContext: String?, healthContextRequested: Bool?,
                healthContextUnavailable: Bool?, mealCorrectionsAck: Int?, requestId: String?) {
        self.mode = mode
        self.text = text
        self.sessionId = sessionId
        self.voice = voice
        self.instructions = instructions
        self.floorOverride = floorOverride
        self.attachments = attachments
        self.healthContext = healthContext
        self.healthContextRequested = healthContextRequested
        self.healthContextUnavailable = healthContextUnavailable
        self.mealCorrectionsAck = mealCorrectionsAck
        self.requestId = requestId
    }

    public struct Attachment: Encodable, Equatable, Sendable {
        public let filename: String
        public let mime: String
        public let dataBase64: String
        public init(filename: String, mime: String, dataBase64: String) {
            self.filename = filename
            self.mime = mime
            self.dataBase64 = dataBase64
        }
        enum CodingKeys: String, CodingKey {
            case filename, mime
            case dataBase64 = "data_base64"
        }
    }

    enum CodingKeys: String, CodingKey {
        case mode, text
        case sessionId = "session_id"
        case voice, instructions
        case floorOverride = "floor_override"
        case attachments
        case healthContext = "health_context"
        case healthContextRequested = "health_context_requested"
        case healthContextUnavailable = "health_context_unavailable"
        case mealCorrectionsAck = "meal_corrections_ack"
        case requestId = "request_id"
    }
}

/// Decoded `POST /jesse` response. The 200 carries `response` (+`session_id`,
/// +`job_id`); the 202 carries `job_id`+`status`. One all-optional shape covers both.
struct JesseSendResponse: Decodable {
    let jobId: String?
    let status: String?
    let response: String?
    let sessionId: String?
    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status, response
        case sessionId = "session_id"
    }
}

/// Decoded `GET /jesse/result/{id}` body: `status` plus the fields that status implies.
/// Public so the wire-contract tests can decode it directly and assert the directive
/// shapes the terminal result carries.
public struct JesseResultResponse: Decodable {
    public let status: String
    public let response: String?
    public let sessionId: String?
    public let directives: JesseDirectives?
    public let provenance: JesseProvenance?
    public let error: String?
    enum CodingKeys: String, CodingKey {
        case status, response
        case sessionId = "session_id"
        case directives, provenance, error
    }
}

/// The `directives` object a terminal result (poll + SSE `done`) may carry. Only known
/// directive types are modeled; absent/`null` decodes to nil (the common case).
public struct JesseDirectives: Decodable, Equatable, Sendable {
    public let needsHealth: JesseNeedsHealth?
    public var mealLog: JesseMealLog?
    public init(needsHealth: JesseNeedsHealth?, mealLog: JesseMealLog? = nil) {
        self.needsHealth = needsHealth
        self.mealLog = mealLog
    }
    enum CodingKeys: String, CodingKey {
        case needsHealth = "needs_health"
        case mealLog = "meal_log"
    }
}

/// The decoded (not yet validated) `meal_log` directive. v1 is just `meals`; v2 adds
/// `retract` and `corrections_seq`. Both v2 fields are absent on a v1 delivery.
public struct JesseMealLog: Decodable, Equatable, Sendable {
    public let meals: [JesseMeal]
    public var retract: [String]?
    public var correctionsSeq: Int?
    public init(meals: [JesseMeal], retract: [String]? = nil, correctionsSeq: Int? = nil) {
        self.meals = meals
        self.retract = retract
        self.correctionsSeq = correctionsSeq
    }
    enum CodingKeys: String, CodingKey {
        case meals, retract
        case correctionsSeq = "corrections_seq"
    }
}

/// One decoded meal. Wire field names match the bridge contract exactly.
public struct JesseMeal: Decodable, Equatable, Sendable {
    public let id: String
    public let consumedAt: String
    public let name: String
    public let kcal: Double?
    public let proteinGrams: Double?
    public let carbGrams: Double?
    public let fatGrams: Double?
    public let fiberGrams: Double?
    // The HealthKit-bound micronutrients, each pre-summed by the bridge over only the
    // meal's items that carried a known value (absent when none did — never a summed 0).
    public let sodiumMg: Double?
    public let satFatGrams: Double?
    public let sugarGrams: Double?
    public let potassiumMg: Double?
    public let calciumMg: Double?
    public let magnesiumMg: Double?
    public init(id: String, consumedAt: String, name: String, kcal: Double?,
                proteinGrams: Double?, carbGrams: Double?, fatGrams: Double?,
                fiberGrams: Double?, sodiumMg: Double? = nil, satFatGrams: Double? = nil,
                sugarGrams: Double? = nil, potassiumMg: Double? = nil,
                calciumMg: Double? = nil, magnesiumMg: Double? = nil) {
        self.id = id
        self.consumedAt = consumedAt
        self.name = name
        self.kcal = kcal
        self.proteinGrams = proteinGrams
        self.carbGrams = carbGrams
        self.fatGrams = fatGrams
        self.fiberGrams = fiberGrams
        self.sodiumMg = sodiumMg
        self.satFatGrams = satFatGrams
        self.sugarGrams = sugarGrams
        self.potassiumMg = potassiumMg
        self.calciumMg = calciumMg
        self.magnesiumMg = magnesiumMg
    }
    enum CodingKeys: String, CodingKey {
        case id, consumedAt, name, kcal
        case proteinGrams = "protein_g"
        case carbGrams = "carbs_g"
        case fatGrams = "fat_g"
        case fiberGrams = "fiber_g"
        case sodiumMg = "sodium_mg"
        case satFatGrams = "satfat_g"
        case sugarGrams = "sugar_g"
        case potassiumMg = "potassium_mg"
        case calciumMg = "calcium_mg"
        case magnesiumMg = "magnesium_mg"
    }
}

/// The decoded (not yet validated) `needs_health` request.
public struct JesseNeedsHealth: Decodable, Equatable, Sendable {
    public let sections: [String]?
    public let metrics: [Metric]?
    public init(sections: [String]?, metrics: [Metric]?) {
        self.sections = sections
        self.metrics = metrics
    }
    public struct Metric: Decodable, Equatable, Sendable {
        public let metric: String
        public let windowDays: Int
        public init(metric: String, windowDays: Int) {
            self.metric = metric
            self.windowDays = windowDays
        }
        enum CodingKeys: String, CodingKey {
            case metric
            case windowDays = "window_days"
        }
    }
}

/// Decoded `GET /health` body. `version` is optional so a bridge too old to report one
/// still decodes cleanly to `version == nil`.
struct JesseHealthResponse: Decodable {
    let ok: Bool?
    let version: String?
}

/// Decoded `GET /jesse/prompts` body — all four fields required.
struct JessePromptsResponse: Decodable {
    let ask: String
    let tell: String
    let askFloor: String
    let tellFloor: String
    enum CodingKeys: String, CodingKey {
        case ask, tell
        case askFloor = "ask_floor"
        case tellFloor = "tell_floor"
    }
}

/// Decoded `data:` payload of one SSE frame. Every field is optional — which one is
/// meaningful depends on the frame's `event:` name (see `decodeStreamFrame`). Public so
/// the wire-contract tests can decode a `done` frame's directives directly.
public struct JesseStreamFrameData: Decodable {
    public let text: String?
    public let name: String?
    public let response: String?
    public let sessionId: String?
    public let directives: JesseDirectives?
    public let provenance: JesseProvenance?
    public let error: String?
    enum CodingKeys: String, CodingKey {
        case text, name, response
        case sessionId = "session_id"
        case directives, provenance, error
    }
}

/// The `POST /jesse/device` body — register this phone's APNs token.
public struct JesseDeviceRegistration: Encodable {
    public let token: String
    public init(token: String) { self.token = token }
}

/// The `POST /jesse/session/{id}/flags` body: any subset of the four flag fields. Only
/// the flag(s) that changed are sent, each paired with its unix-millis change clock, so
/// the bridge applies each last-writer-wins by that timestamp. A nil field omits its key
/// (synthesized `encodeIfPresent`), so a favorite-only change carries no `archived` keys
/// and leaves the server's archived register untouched, matching the bridge's partial
/// `FlagUpdate`.
public struct JesseFlagsRequest: Encodable, Equatable {
    public let favorite: Bool?
    public let favoriteUpdatedMs: UInt64?
    public let archived: Bool?
    public let archivedUpdatedMs: UInt64?
    public init(favorite: Bool? = nil, favoriteUpdatedMs: UInt64? = nil,
                archived: Bool? = nil, archivedUpdatedMs: UInt64? = nil) {
        self.favorite = favorite
        self.favoriteUpdatedMs = favoriteUpdatedMs
        self.archived = archived
        self.archivedUpdatedMs = archivedUpdatedMs
    }
    enum CodingKeys: String, CodingKey {
        case favorite
        case favoriteUpdatedMs = "favorite_updated_ms"
        case archived
        case archivedUpdatedMs = "archived_updated_ms"
    }
}

/// The `POST /jesse/title` request body: a bounded, whitespace-collapsed digest of the
/// conversation the bridge summarizes into a short title. The bridge's field is `text`;
/// a non-nil `sessionId` also persists the minted title server-side.
public struct JesseTitleRequest: Encodable, Equatable {
    public let digest: String
    public let sessionId: String?
    public init(digest: String, sessionId: String? = nil) {
        self.digest = digest
        self.sessionId = sessionId
    }
    enum CodingKeys: String, CodingKey {
        case digest = "text"
        case sessionId = "session_id"
    }
}

/// Decoded `POST /jesse/title` body — a single short title string.
struct JesseTitleResponse: Decodable {
    let title: String?
}

/// Decoded `GET /jesse/sessions` body.
struct JesseSessionsBody: Decodable {
    let sessions: [SessionSummary]
}

/// Decoded `GET /jesse/sessions/{id}` body.
struct JesseHydrateBody: Decodable {
    let sessionId: String
    let turns: [HydratedTurn]
    let nextOffset: UInt64
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case turns
        case nextOffset = "next_offset"
    }
}
