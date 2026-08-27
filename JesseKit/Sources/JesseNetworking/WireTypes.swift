import Foundation
import JesseCore

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
/// ONE file a turn returned, as the reply carries it: identity, display metadata, and a
/// content hash. Matches the bridge's `Artifact` exactly.
///
/// **It never carries the bytes.** The bridge deliberately keeps binary content out of
/// the job JSON, the persisted job file, the SSE frame and the conversation store, so
/// the content is fetched separately from `GET /jesse/artifact/{id}` — see
/// `BridgeClientProtocol.artifact(id:)`. `sha256` doubles as that route's `ETag`.
public struct JesseArtifact: Decodable, Equatable, Sendable, Identifiable {
    /// Opaque, unguessable, and the fetch key. Also the cache filename on the device.
    public let id: String
    /// The model's own filename, for DISPLAY only — the bridge never used it as a path
    /// component and neither does the app.
    public let filename: String
    /// The mime the bridge sniffed FROM THE BYTES (never from the extension).
    public let mime: String
    public let bytes: UInt64
    /// Hex SHA-256 of the content, so a cached copy can be validated and a re-fetch is
    /// one `304`.
    public let sha256: String

    public init(id: String, filename: String, mime: String, bytes: UInt64, sha256: String) {
        self.id = id
        self.filename = filename
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
    }

    /// Whether this renders inline as a picture. SVG is INCLUDED, having previously been
    /// excluded as "markup and a rendering surface"; `ArtifactFileType.isInlineImage`
    /// holds the one rule and the reasoning that changed it.
    public var isInlineImage: Bool {
        ArtifactFileType.isInlineImage(mime)
    }

    /// A short human size for the chip ("18 KB", "2.4 MB").
    public var displaySize: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB]
        return f.string(fromByteCount: Int64(bytes))
    }
}

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
    // The files this turn returned — METADATA ONLY (see `JesseArtifact`). Empty for the
    // overwhelming majority of turns, and empty against any bridge that predates the
    // field, which is the same thing: there is nothing for a reader to distinguish.
    public var artifacts: [JesseArtifact]

    public init(text: String, sessionId: String?,
                directives: JesseDirectives? = nil, provenance: JesseProvenance? = nil,
                artifacts: [JesseArtifact] = []) {
        self.text = text
        self.sessionId = sessionId
        self.directives = directives
        self.provenance = provenance
        self.artifacts = artifacts
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

/// The device context an outgoing retry turn should carry — the result of fulfilling
/// one channel's directive. Either a `block` with `requested == true` (fulfilled), or
/// `block == nil` with `unavailable == true` (toggle off / denied / no data). Never
/// both flags, and never neither: a retry always tells the bridge which of the two
/// happened, because "no block and no flag" is the ordinary-turn shape and would put
/// the agent back on the request instruction — which is the loop.
///
/// One type for every channel. The health and location halves of a retry differ only
/// in which field the block lands in on the wire.
public struct OutgoingDeviceContext: Sendable, Equatable {
    public var block: String?
    public var requested: Bool
    public var unavailable: Bool
    public init(block: String?, requested: Bool, unavailable: Bool) {
        self.block = block
        self.requested = requested
        self.unavailable = unavailable
    }

    /// The channel could not be fulfilled: no block, and the flag that makes the
    /// bridge append its "answer without it, don't re-request" note. The terminator
    /// on every failure path.
    public static let unavailable = OutgoingDeviceContext(
        block: nil, requested: false, unavailable: true)

    /// A fulfilled channel carrying `block`.
    public static func fulfilled(_ block: String) -> OutgoingDeviceContext {
        OutgoingDeviceContext(block: block, requested: true, unavailable: false)
    }
}

/// The name this carried when health was the only channel. Kept so nothing that
/// already spells it has to change to say the same thing.
public typealias OutgoingHealthContext = OutgoingDeviceContext

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
///
/// Both cases carry the AUTHORITATIVE `conversationId` the bridge registered for this
/// turn, which the caller writes back onto its thread. Optional so a pre-0.33 bridge that
/// omits the field decodes cleanly to nil rather than throwing.
public enum JesseSendResult: Sendable {
    case reply(JesseReply, jobId: String?, conversationId: String?)
    case running(jobId: String, conversationId: String?)

    /// The conversation the bridge named, whichever shape came back.
    public var conversationId: String? {
        switch self {
        case let .reply(_, _, cid): return cid
        case let .running(_, cid): return cid
        }
    }
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

/// One coarse tool-activity hint: WHICH tool, and whether the containment boundary
/// REFUSED the call.
///
/// `refused` is a separate field rather than a word inside `name` because `name` is a
/// VOCABULARY the bridge and both clients share — `RunCoordinator.activityLabel`
/// switches on it — and folding a display word in would make every reader parse a string
/// grammar to get one bit back out. A refused `Write` is still a `Write`.
///
/// It carries a bit rather than the child's own error text ON PURPOSE: that text names the
/// path or the command the model tried, and this value is rendered on screen.
///
/// COUPLED WITH `ToolActivity` in `bridge/src/jobstore/streams.rs`, the same pair on the
/// bridge side. The wire OMITS `refused` when false, so this defaults to false and a
/// bridge that predates the field decodes exactly as it always did.
public struct ToolActivity: Equatable, Sendable {
    public let name: String
    public let refused: Bool

    public init(name: String, refused: Bool = false) {
        self.name = name
        self.refused = refused
    }

    /// The human line for this activity, ellipsis included — ONE mapping, in JesseKit,
    /// because both clients render it and a whole-answer turn has nothing else to show.
    ///
    /// Two cases carry weight, and neither is cosmetic:
    ///
    /// A REFUSED call gets its own phrasing, because the two are opposite facts about the
    /// turn: "Writing a file…" while the sandbox is refusing every write tells the user
    /// something that did not happen. It reads as a statement about the boundary rather than
    /// an error, because it is not one — the model routinely tries something, is refused, and
    /// answers anyway. It is deliberately NOT rendered as a failed turn.
    ///
    /// An MCP tool arrives as `mcp__<server>__<tool>`, which is a routing key and not
    /// something to show anyone; the server is the useful half. This case needs handling
    /// because a Read-level Codex turn's visible work is mostly qmd calls — without it, most
    /// of the turn would read `Using mcp__qmd__query…`.
    public var displayLabel: String {
        if refused {
            switch name {
            case "Write", "Edit", "NotebookEdit": return "Blocked from writing a file…"
            case "Bash": return "Blocked from running a command…"
            default: return "Blocked from using \(Self.showable(name))…"
            }
        }
        switch name {
        case "Read", "Glob", "Grep": return "Reading the vault…"
        case "Write", "Edit", "NotebookEdit": return "Writing a file…"
        case "Bash": return "Running a command…"
        case "WebFetch", "WebSearch": return "Searching the web…"
        case "Task": return "Working on it…"
        default: return "Using \(Self.showable(name))…"
        }
    }

    /// The showable half of a tool name: `mcp__qmd__query` → `qmd`, anything else verbatim.
    static func showable(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let server = tool.dropFirst("mcp__".count).components(separatedBy: "__").first ?? ""
        return server.isEmpty ? tool : server
    }
}

/// One decoded frame from the live SSE stream (`GET /jesse/stream/{job_id}`).
/// `reset` carries the full text-so-far and REPLACES the partial buffer; `delta`
/// APPENDS. The three terminal frames mirror `JesseResultState`.
///
/// `activity` is the ONLY mid-turn frame a whole-answer model produces — see
/// `ModelInfo.streamsText`. On a streaming model it is a garnish beside the deltas; on a
/// whole-answer one it is the entire difference between a turn the user can see working
/// and one indistinguishable from a turn that has silently hung.
public enum JesseStreamEvent: Equatable, Sendable {
    case reset(String)
    case delta(String)
    case activity(ToolActivity)
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
    /// The bridge's stable per-turn key, `"<session_id>:<byte offset of its jsonl line>"`.
    /// Unique within a conversation and byte-identical across repeated hydrates, which is
    /// what `TranscriptMerge` keys on. Empty only against the deprecated single-session
    /// route, which predates the field; the merge treats an empty key as "unkeyed".
    public let turnKey: String
    /// The files this turn returned, re-attached by the bridge from its artifact store.
    /// A reloaded transcript therefore still shows an older turn's chart or PDF instead
    /// of silently losing it. Empty on a user turn, on a turn that returned nothing, and
    /// against a bridge that predates the field.
    public let artifacts: [JesseArtifact]
    public init(role: String, text: String, timestamp: String?, turnKey: String = "",
                artifacts: [JesseArtifact] = []) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.turnKey = turnKey
        self.artifacts = artifacts
    }
    enum CodingKeys: String, CodingKey {
        case role, text, timestamp
        case turnKey = "turn_key"
        case artifacts
    }
    // Custom decode so `turn_key` DEFAULTS rather than failing the whole hydrate against
    // the deprecated route (which omits it), the same additive-forward-compatible pattern
    // `SessionSummary` uses for the flag fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
        turnKey = try c.decodeIfPresent(String.self, forKey: .turnKey) ?? ""
        artifacts = try c.decodeIfPresent([JesseArtifact].self, forKey: .artifacts) ?? []
    }
}

/// One deletion tombstone on `GET /jesse/sessions` (bridge 0.26.0): the id of a session
/// an explicit delete removed, and the unix-millis time it was deleted. It rides the
/// `deleted` array alongside `sessions` so a delete made on one device converges to the
/// others (they remove the matching local thread). Against a pre-0.26.0 bridge the array
/// is absent and decodes to empty, so cross-device delete propagation is simply inert.
public struct SessionTombstone: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let deletedMs: UInt64
    public init(sessionId: String, deletedMs: UInt64) {
        self.sessionId = sessionId
        self.deletedMs = deletedMs
    }
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case deletedMs = "deleted_ms"
    }
}

/// Result of listing sessions: either fresh data (the sessions, the cross-device deletion
/// tombstones, and the ETag to send back next time) or a 304 telling the caller its cache
/// is current. `deleted` is empty against a pre-0.26.0 bridge that omits the field.
public enum SessionsResult: Sendable, Equatable {
    case notModified
    case sessions([SessionSummary], deleted: [SessionTombstone], etag: String?)
}

// MARK: - Conversations

/// One conversation in `GET /jesse/conversations` (bridge 0.33.0). Matches the bridge's
/// `ConversationSummary`.
///
/// `conversationId` is the sync key. `sessionId` is the conversation's CURRENT Claude
/// session, nil for a conversation registered but not yet run (including one whose first
/// turn is still in flight). `sessionIds` is the full ordered alias list, oldest first: a
/// client needs it to bind a pre-upgrade thread, whose only identity is a session id, to
/// its conversation exactly once.
public struct ConversationSummary: Decodable, Sendable, Equatable {
    public let conversationId: String
    public let sessionId: String?
    public let sessionIds: [String]
    public let lastModified: UInt64
    public let firstMessage: String?
    public let title: String?
    public let favorite: Bool
    public let favoriteUpdatedMs: UInt64
    public let archived: Bool
    public let archivedUpdatedMs: UInt64
    public let registeredMs: UInt64

    public init(conversationId: String, sessionId: String? = nil, sessionIds: [String] = [],
                lastModified: UInt64 = 0, firstMessage: String? = nil, title: String? = nil,
                favorite: Bool = false, favoriteUpdatedMs: UInt64 = 0,
                archived: Bool = false, archivedUpdatedMs: UInt64 = 0,
                registeredMs: UInt64 = 0) {
        self.conversationId = conversationId
        self.sessionId = sessionId
        self.sessionIds = sessionIds
        self.lastModified = lastModified
        self.firstMessage = firstMessage
        self.title = title
        self.favorite = favorite
        self.favoriteUpdatedMs = favoriteUpdatedMs
        self.archived = archived
        self.archivedUpdatedMs = archivedUpdatedMs
        self.registeredMs = registeredMs
    }

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case sessionId = "session_id"
        case sessionIds = "session_ids"
        case lastModified = "last_modified"
        case firstMessage = "first_message"
        case title, favorite
        case favoriteUpdatedMs = "favorite_updated_ms"
        case archived
        case archivedUpdatedMs = "archived_updated_ms"
        case registeredMs = "registered_ms"
    }

    // Only `conversation_id` is required; every other field defaults, so an added or
    // omitted field never fails the whole list decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        sessionIds = try c.decodeIfPresent([String].self, forKey: .sessionIds) ?? []
        lastModified = try c.decodeIfPresent(UInt64.self, forKey: .lastModified) ?? 0
        firstMessage = try c.decodeIfPresent(String.self, forKey: .firstMessage)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        favoriteUpdatedMs = try c.decodeIfPresent(UInt64.self, forKey: .favoriteUpdatedMs) ?? 0
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        archivedUpdatedMs = try c.decodeIfPresent(UInt64.self, forKey: .archivedUpdatedMs) ?? 0
        registeredMs = try c.decodeIfPresent(UInt64.self, forKey: .registeredMs) ?? 0
    }
}

/// One deletion tombstone on `GET /jesse/conversations`: the id of a conversation an
/// explicit delete removed, and the unix-millis time it was deleted. It rides the
/// `deleted` array so a delete made on one device converges to the others.
public struct ConversationTombstone: Decodable, Sendable, Equatable {
    public let conversationId: String
    public let deletedMs: UInt64
    public init(conversationId: String, deletedMs: UInt64) {
        self.conversationId = conversationId
        self.deletedMs = deletedMs
    }
    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case deletedMs = "deleted_ms"
    }
}

/// Result of listing conversations: either fresh data (the conversations, the cross-device
/// deletion tombstones, and the ETag to send back next time) or a 304 telling the caller
/// its cache is current.
public enum ConversationsResult: Sendable, Equatable {
    case notModified
    case conversations([ConversationSummary], deleted: [ConversationTombstone], etag: String?)
}

/// Decoded `GET /jesse/conversations` body.
struct JesseConversationsBody: Decodable {
    let conversations: [ConversationSummary]
    let deleted: [ConversationTombstone]
    enum CodingKeys: String, CodingKey {
        case conversations, deleted
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decodeIfPresent([ConversationSummary].self, forKey: .conversations) ?? []
        deleted = try c.decodeIfPresent([ConversationTombstone].self, forKey: .deleted) ?? []
    }
}

// MARK: - Wire contract (Codable)

/// The `POST /jesse` request body. A nil field omits its key, reproducing the old
/// conditionally-built dictionary byte-for-byte and matching the bridge's
/// `#[serde(default)]` shape.
public struct JesseRequest: Encodable, Equatable, Sendable {
    public let mode: String
    public let text: String
    public let sessionId: String?
    /// The stable client-minted conversation identity, sent on EVERY turn (first and
    /// follow-up alike). The bridge registers it before returning its 202 and echoes the
    /// authoritative id back, which is what closes the window where the server knew a
    /// thread identifier the client did not.
    public let conversationId: String?
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
    // Compact device location block from CoreLocation. Nil omits the field, so an app
    // build that predates the channel produces byte-for-byte the old request.
    public let locationContext: String?
    // This turn is a retry answering a prior `JESSE_NEEDS_LOCATION` directive.
    public let locationContextRequested: Bool?
    // The app could NOT fulfill a location request this turn (toggle off, permission
    // denied, Location Services off, timed out, no fix).
    public let locationContextUnavailable: Bool?
    // Meal-corrections ack (JESSE_MEAL_LOG v2): the highest `corrections_seq` the app
    // has taken responsibility for.
    public let mealCorrectionsAck: Int?
    // Idempotency key (the send outbox's `OutboxItem.id`, as a string): the bridge
    // dedups a `POST /jesse` carrying a `request_id` it has already seen.
    public let requestId: String?
    // Per-turn model selection (retire the global switch): a registry id (`opus`,
    // `glm-5.2`, `local`, …) that backs THIS turn only. The apps remember it per thread
    // and per device and send it on every turn; a nil field omits the key, so the bridge
    // uses its stored default (byte-for-byte today's behavior for an older client).
    public let model: String?
    // The IANA zone the DEVICE is standing in ("Europe/London"), stamped onto every turn by
    // `JesseBridgeClient.sendPrepared` rather than by each caller — see `stamped(clientTz:sentAt:)`.
    // The bridge lets it outrank the away profile for that one request, because the phone's own
    // zone is a more specific claim than a fortnight-long declaration. `private(set)` so the
    // stamp is the only way it is set.
    public private(set) var clientTz: String?
    // When the PHONE says it sent this turn: RFC3339 with the device's offset
    // ("2026-09-03T13:10:00+01:00"). Stamped in the same one place as `clientTz`, and for
    // a related reason — the bridge dates an entry the message gave no time for from when
    // it was SENT, so a turn that was queued, retried, or slowly delivered must not be
    // dated from whenever it happened to arrive. Omitted (nil) is the bridge's own clock,
    // which is byte-for-byte what every build before this one did.
    public private(set) var sentAt: String?

    public init(mode: String, text: String, sessionId: String?, conversationId: String? = nil,
                voice: Bool?,
                instructions: String?, floorOverride: String?, attachments: [Attachment]?,
                healthContext: String?, healthContextRequested: Bool?,
                healthContextUnavailable: Bool?,
                locationContext: String? = nil, locationContextRequested: Bool? = nil,
                locationContextUnavailable: Bool? = nil,
                mealCorrectionsAck: Int?, requestId: String?,
                model: String? = nil) {
        self.mode = mode
        self.text = text
        self.sessionId = sessionId
        self.conversationId = conversationId
        self.voice = voice
        self.instructions = instructions
        self.floorOverride = floorOverride
        self.attachments = attachments
        self.healthContext = healthContext
        self.healthContextRequested = healthContextRequested
        self.healthContextUnavailable = healthContextUnavailable
        self.locationContext = locationContext
        self.locationContextRequested = locationContextRequested
        self.locationContextUnavailable = locationContextUnavailable
        self.mealCorrectionsAck = mealCorrectionsAck
        self.requestId = requestId
        self.model = model
        self.clientTz = nil
        self.sentAt = nil
    }

    /// The same request, carrying the two facts only the DEVICE knows: the zone it is
    /// standing in and the instant it says it sent this turn.
    ///
    /// The ONE place either is set. Every caller (the Mac's plain send, the iOS layer's
    /// health-laden one) goes through `JesseBridgeClient.sendPrepared`, and that stamps
    /// here, so there is no path that can build a turn body without them. A blank value
    /// omits its field rather than sending an empty string, which the bridge would have to
    /// parse and reject.
    public func stamped(clientTz: String, sentAt: String) -> JesseRequest {
        var copy = self
        copy.clientTz = clientTz.isEmpty ? nil : clientTz
        copy.sentAt = sentAt.isEmpty ? nil : sentAt
        return copy
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
        case conversationId = "conversation_id"
        case voice, instructions
        case floorOverride = "floor_override"
        case attachments
        case healthContext = "health_context"
        case healthContextRequested = "health_context_requested"
        case healthContextUnavailable = "health_context_unavailable"
        case locationContext = "location_context"
        case locationContextRequested = "location_context_requested"
        case locationContextUnavailable = "location_context_unavailable"
        case mealCorrectionsAck = "meal_corrections_ack"
        case requestId = "request_id"
        case model
        case clientTz = "client_tz"
        case sentAt = "sent_at"
    }
}

/// Decoded `POST /jesse` response. The 200 carries `response` (+`session_id`,
/// +`job_id`); the 202 carries `job_id`+`status`. One all-optional shape covers both.
struct JesseSendResponse: Decodable {
    let jobId: String?
    let status: String?
    let response: String?
    let sessionId: String?
    /// The authoritative conversation the bridge registered for this turn. Optional so a
    /// pre-0.33 bridge that omits it decodes cleanly.
    let conversationId: String?
    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status, response
        case sessionId = "session_id"
        case conversationId = "conversation_id"
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
    /// Absent or `null` against a bridge with no artifact channel, and on every turn that
    /// returned no file — both decode to nil and are read as "none".
    public let artifacts: [JesseArtifact]?
    public let error: String?
    enum CodingKeys: String, CodingKey {
        case status, response
        case sessionId = "session_id"
        case directives, provenance, artifacts, error
    }
}

/// The `directives` object a terminal result (poll + SSE `done`) may carry. Only known
/// directive types are modeled; absent/`null` decodes to nil (the common case).
public struct JesseDirectives: Decodable, Equatable, Sendable {
    public let needsHealth: JesseNeedsHealth?
    public let needsLocation: JesseNeedsLocation?
    public var mealLog: JesseMealLog?
    public init(needsHealth: JesseNeedsHealth?,
                needsLocation: JesseNeedsLocation? = nil,
                mealLog: JesseMealLog? = nil) {
        self.needsHealth = needsHealth
        self.needsLocation = needsLocation
        self.mealLog = mealLog
    }
    enum CodingKeys: String, CodingKey {
        case needsHealth = "needs_health"
        case needsLocation = "needs_location"
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
    // Only the nutrients with a real HealthKit type ride this wire: trans fat, added sugar,
    // purines and mercury are gauge-only (no clean type — `dietarySugar` is TOTAL sugar,
    // which added sugar is not) and are deliberately absent here.
    public let sodiumMg: Double?
    public let satFatGrams: Double?
    public let sugarGrams: Double?
    public let potassiumMg: Double?
    public let calciumMg: Double?
    public let magnesiumMg: Double?
    public let cholesterolMg: Double?
    public let seleniumUg: Double?
    public let vitaminDUg: Double?
    public init(id: String, consumedAt: String, name: String, kcal: Double?,
                proteinGrams: Double?, carbGrams: Double?, fatGrams: Double?,
                fiberGrams: Double?, sodiumMg: Double? = nil, satFatGrams: Double? = nil,
                sugarGrams: Double? = nil, potassiumMg: Double? = nil,
                calciumMg: Double? = nil, magnesiumMg: Double? = nil,
                cholesterolMg: Double? = nil, seleniumUg: Double? = nil,
                vitaminDUg: Double? = nil) {
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
        self.cholesterolMg = cholesterolMg
        self.seleniumUg = seleniumUg
        self.vitaminDUg = vitaminDUg
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
        case cholesterolMg = "cholesterol_mg"
        case seleniumUg = "selenium_ug"
        case vitaminDUg = "vitamin_d_ug"
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

/// The decoded (not yet validated) `needs_location` request. Every key is optional
/// HERE and required by the CONTRACT: the decode has to survive a malformed payload so
/// the app can reject it deliberately (`NeedsLocationRequest.validated` → nil) rather
/// than throwing inside a reply decode and losing the whole turn.
public struct JesseNeedsLocation: Decodable, Equatable, Sendable {
    public let fields: [String]?
    public let precision: String?
    public let maxAgeSeconds: Int?
    public init(fields: [String]?, precision: String?, maxAgeSeconds: Int?) {
        self.fields = fields
        self.precision = precision
        self.maxAgeSeconds = maxAgeSeconds
    }
    enum CodingKeys: String, CodingKey {
        case fields, precision
        case maxAgeSeconds = "max_age_seconds"
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
    /// Absent on every frame but a REFUSED activity, and absent from a bridge that predates
    /// the field — so it decodes to nil and means false.
    public let refused: Bool?
    public let response: String?
    public let sessionId: String?
    public let directives: JesseDirectives?
    public let provenance: JesseProvenance?
    /// Present only on a `done` frame for a turn that returned a file; `null` otherwise
    /// and absent from any bridge that predates the field.
    public let artifacts: [JesseArtifact]?
    public let error: String?
    enum CodingKeys: String, CodingKey {
        case text, name, refused, response
        case sessionId = "session_id"
        case directives, provenance, artifacts, error
    }
}

/// The `POST /jesse/device` body — register this phone's APNs token.
public struct JesseDeviceRegistration: Encodable {
    public let token: String
    public init(token: String) { self.token = token }
}

// MARK: - Global model switch (GET /jesse/models, POST /jesse/model)

/// One selectable model in the bridge's global model switch. Ids and booleans only — never
/// a token or base url (those live solely in the bridge launch env), so this is safe to hold
/// and display. Shared so the iPhone and the Mac render one switcher and converge on one
/// active selection (the bridge is the source of truth). Lives in JesseNetworking alongside
/// the other wire types so its `Decodable` conformance stays nonisolated (JesseCore defaults
/// to MainActor isolation, which a nonisolated client decode cannot use).
public struct ModelInfo: Decodable, Equatable, Sendable, Identifiable {
    /// The stable id the switch keys on (`opus`, `glm-5.2`, `kimi-k3`, `local`, or a
    /// declarative id like `fireworks` / `codex`).
    public let id: String
    /// The human label shown in the switcher.
    public let label: String
    /// `ambient` | `hosted` | `local` — kept as the raw string so an unknown future kind
    /// still decodes and renders rather than failing.
    public let kind: String
    /// Whether this model may be selected RIGHT NOW: the bridge's `available` = `configured`
    /// AND `healthy`. The switcher renders an unavailable model disabled with `unavailableReason`.
    public let available: Bool
    /// Whether the model's backend/token RESOLVED (an unconfigured model is `kimi-k3` until a
    /// live slug is armed, or a declarative entry whose token env var is unset). Defaults to
    /// `available` against a pre-health bridge that omits it.
    public let configured: Bool
    /// Whether the model's last health probe PASSED. Ambient `opus` is always healthy.
    /// Defaults to `available` against a pre-health bridge that omits it.
    public let healthy: Bool
    /// Unix-millis of the model's last health probe, or `nil` (opus / before the first probe /
    /// older bridge).
    public let lastCheckedMs: UInt64?
    /// The last probe's round-trip latency in millis, or `nil` when not reported.
    public let latencyMs: UInt64?
    /// Whether this model may change the vault. It is `level == "write"` and comes from the
    /// bridge CONFIG — there is no longer any way for a client to change it (the per-model
    /// writes toggle was removed).
    public let writesAllowed: Bool
    /// The most this model may be granted: `basic` | `read` | `write`. Kept as the raw string
    /// so an unknown future level still decodes and renders. Defaults to `write` when a
    /// pre-level bridge omits it, which is what `writesAllowed` alone used to imply for the
    /// ambient default; every model below Write is shown as able to answer but not to change
    /// the vault. Models are NEVER hidden from the picker by level — being able to talk to
    /// all of them is the point.
    public let level: String
    /// Whether this model's HARNESS delivers its answer as token-level deltas (true) or whole,
    /// in one terminal event (false). A whole-answer harness must render tool activity and a
    /// spinner rather than an empty bubble, so the client needs to be told. Defaults to `true`
    /// — the streaming assumption every client already made — against a bridge that omits it.
    public let streamsText: Bool

    public init(id: String, label: String, kind: String, available: Bool, writesAllowed: Bool,
                level: String? = nil, streamsText: Bool? = nil,
                configured: Bool? = nil, healthy: Bool? = nil,
                lastCheckedMs: UInt64? = nil, latencyMs: UInt64? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.available = available
        // Default the health fields to `available` so a construction (or an older bridge that
        // omits them) behaves exactly as the pre-health `configured ⇒ available` model.
        self.configured = configured ?? available
        self.healthy = healthy ?? available
        self.lastCheckedMs = lastCheckedMs
        self.latencyMs = latencyMs
        self.writesAllowed = writesAllowed
        self.level = level ?? (writesAllowed ? "write" : "read")
        self.streamsText = streamsText ?? true
    }

    enum CodingKeys: String, CodingKey {
        case id, label, kind, available, configured, healthy, level
        case lastCheckedMs = "last_checked_ms"
        case latencyMs = "latency_ms"
        case writesAllowed = "writes_allowed"
        case streamsText = "streams_text"
    }

    // Custom decode so the health fields DEFAULT (a pre-health bridge omits them) rather than
    // fail the whole list decode — the same additive-forward-compatible pattern SessionSummary
    // uses. `configured`/`healthy` fall back to `available`; the timestamps are optional.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(String.self, forKey: .kind)
        available = try c.decode(Bool.self, forKey: .available)
        writesAllowed = try c.decode(Bool.self, forKey: .writesAllowed)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? available
        healthy = try c.decodeIfPresent(Bool.self, forKey: .healthy) ?? available
        lastCheckedMs = try c.decodeIfPresent(UInt64.self, forKey: .lastCheckedMs)
        latencyMs = try c.decodeIfPresent(UInt64.self, forKey: .latencyMs)
        // Additive-forward-compatible, the same pattern as the health fields: a bridge that
        // predates levels omits both, and the defaults reproduce what the client assumed.
        level = try c.decodeIfPresent(String.self, forKey: .level) ?? (writesAllowed ? "write" : "read")
        streamsText = try c.decodeIfPresent(Bool.self, forKey: .streamsText) ?? true
    }

    /// What this model may touch, for the switcher subtitle. `nil` for a Write model (the
    /// unremarkable case); a short phrase for anything below it, so a user who picks a
    /// read-only model learns it can answer but not change the vault BEFORE they ask it to.
    public var levelCaveat: String? {
        switch level {
        case "write": return nil
        case "read": return "can answer, but can't change the vault"
        case "basic": return "can answer only — no vault access"
        default: return nil
        }
    }

    /// The ambient default (`opus`) — never applies overrides and is always writes-on.
    public var isDefault: Bool { kind == "ambient" }

    /// A short reason this model is NOT selectable, or `nil` when it is. Distinguishes the two
    /// disabled states the switcher explains: `not configured` (no token/triple armed) vs
    /// `unreachable` (configured, but the last health probe failed).
    public var unavailableReason: String? {
        if available { return nil }
        if !configured { return "not configured" }
        return "unreachable"
    }
}

/// The `GET /jesse/models` payload: the active model id plus the selectable models. The
/// active id may name a model that is currently unavailable (a stale selection); the app
/// shows it checked and the switcher's disabled state guides the user to a live choice.
public struct ModelSwitchState: Decodable, Equatable, Sendable {
    public let active: String
    public let models: [ModelInfo]

    public init(active: String, models: [ModelInfo]) {
        self.active = active
        self.models = models
    }

    /// The active model's info, if present in the list.
    public var activeModel: ModelInfo? { models.first { $0.id == active } }
}

/// The `POST /jesse/model` body: the id of the model to make active.
public struct SetModelBody: Encodable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
}

/// The `POST /jesse/conversation/{id}/flags` body: any subset of the four flag fields. Only
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
    /// A non-nil conversation also persists the minted title server-side, keyed on the
    /// conversation (the bridge's title store is conversation-keyed).
    public let conversationId: String?
    public init(digest: String, conversationId: String? = nil) {
        self.digest = digest
        self.conversationId = conversationId
    }
    enum CodingKeys: String, CodingKey {
        case digest = "text"
        case conversationId = "conversation_id"
    }
}

/// Decoded `POST /jesse/title` body — a single short title string.
struct JesseTitleResponse: Decodable {
    let title: String?
}

/// Decoded `GET /jesse/sessions` body. `deleted` (bridge 0.26.0) is the cross-device
/// deletion tombstones; it decodes to empty against a pre-0.26.0 bridge that omits the
/// field (so a delete never propagates but nothing breaks, exactly today's behavior).
struct JesseSessionsBody: Decodable {
    let sessions: [SessionSummary]
    let deleted: [SessionTombstone]
    enum CodingKeys: String, CodingKey {
        case sessions, deleted
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decode([SessionSummary].self, forKey: .sessions)
        deleted = try c.decodeIfPresent([SessionTombstone].self, forKey: .deleted) ?? []
    }
}

/// Decoded `GET /jesse/conversations/{id}/transcript` body. `nextCursor` is OPAQUE: a
/// conversation can span several transcript files, so a bare byte offset is not a
/// sufficient position. The client only ever echoes it back.
struct JesseConversationHydrateBody: Decodable {
    let conversationId: String
    let turns: [HydratedTurn]
    let nextCursor: String
    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case turns
        case nextCursor = "next_cursor"
    }
}
