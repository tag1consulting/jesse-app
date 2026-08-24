import Foundation
import SwiftData

// The OFFLINE CAPTURE QUEUE's storage layer: one change the user made while the bridge
// was out of reach, held until it can be replayed — and refused, out loud, when it no
// longer can be.
//
// ## Why this exists at all, when the day file argues against it
//
// `Today.md` is rewritten in full every morning and edited by the agent all day, so for
// a long time this app refused every offline change and queued nothing. The reasoning
// was written down in `TodayDashboardModel.readOnlyNotice`: a held tap would replay
// against a document that has since moved on.
//
// That is true of BLIND replay and false as a reason to drop the capture. A checked box
// and a logged lunch are facts about the day they happened. They can be replayed safely
// if the replay carries two things the old design never captured — **the day** the
// change was made against, and **the identity** of the thing it was made about — and
// refuses when either no longer matches. Everything in this file exists to carry those
// two facts across an outage.
//
// ## Why the currency is a value type
//
// `PendingIntent` is the `@Model`; `PendingIntentRecord` is what every other layer
// actually holds. The queue's consumers are a `@MainActor` display model and its unit
// tests, and neither should need a `ModelContainer` to answer "what is queued". A value
// type crossing the `PendingIntentStoring` seam is what lets the replay logic be tested
// against an array, exactly as `TodayProviding` lets the fetch logic be tested against a
// script.

/// Which change a queued intent stands for.
///
/// The four Today verbs are separate cases rather than one case with a boolean because
/// they are separate USER ACTS: "I did this" and "I had not actually done this" are
/// different claims about the day, and the pending list names them differently.
public nonisolated enum PendingIntentKind: String, Codable, CaseIterable, Sendable {
    case check
    case uncheck
    case `defer`
    case undefer
    case move
    case quickLog
    case startNewDay
    /// **Never written.** Process-updates fires a long Tell that rewrites every named
    /// project file, the Dashboard and the day file, off a set of ticked rows chosen at
    /// the moment of the tap. Replaying that hours later would run it against a
    /// different set, so it keeps the offline refusal it always had.
    ///
    /// The case exists so the stored `kind` string has one closed vocabulary — a store
    /// row is decoded by name, and a name the enum does not know would have to be
    /// silently dropped.
    case processUpdates

    /// Whether replaying this intent writes to the DAY FILE (as opposed to opening a
    /// conversation). The two families have completely different replay rules — one
    /// needs an item id that still resolves, the other needs only a thread — so the
    /// distinction is named once here.
    public var isDayFileWrite: Bool {
        switch self {
        case .check, .uncheck, .defer, .undefer, .move: return true
        case .quickLog, .startNewDay, .processUpdates: return false
        }
    }

    /// The checkbox/postponement state this kind asserts, for the two pairs that have
    /// one. `nil` for the kinds that are not a boolean claim.
    public var asserts: Bool? {
        switch self {
        case .check, .defer: return true
        case .uncheck, .undefer: return false
        default: return nil
        }
    }

    /// How the pending list names this row.
    public var label: String {
        switch self {
        case .check: return "Checked off"
        case .uncheck: return "Un-checked"
        case .defer: return "Not today"
        case .undefer: return "Brought back"
        case .move: return "Moved"
        case .quickLog: return "Quick log"
        case .startNewDay: return "Start new day"
        case .processUpdates: return "Process updates"
        }
    }
}

/// Where one queued intent has got to.
public nonisolated enum PendingIntentState: String, Codable, Sendable {
    /// Captured and waiting. The state every intent starts in.
    case queued
    /// A replay is in flight for it right now. Persisted (rather than held in memory)
    /// so a kill mid-replay is visible as what it was, instead of looking like a row
    /// that was never attempted.
    case replaying
    /// Replayed and accepted by the bridge. Kept briefly as a receipt, then swept.
    case applied
    /// **Replayed and refused**, with a reason. Never swept: a change the app took from
    /// the user and could not deliver is exactly the thing that must not disappear
    /// quietly, so it stays on the pending list until the user dismisses it.
    case refused
}

/// The extra fields one kind or another needs, as one JSON object.
///
/// A single payload type rather than a per-kind one, and every field optional, for the
/// same reason the wire types decode tolerantly: a stored row written by an older build
/// must still decode under a newer one. Nothing here is required, and a payload that
/// fails to decode reads as an empty one rather than losing the intent.
public nonisolated struct PendingIntentPayload: Codable, Equatable, Sendable {
    /// The note typed alongside a check.
    public var evidence: String?
    /// A move's op, spelled as the bridge parses it (`top_of_section`, `to_do_now`, …).
    public var moveOp: String?
    /// A `to_section` move's destination heading.
    public var moveSection: String?
    /// The sentence a quick log will send.
    public var text: String?

    public init(evidence: String? = nil, moveOp: String? = nil,
                moveSection: String? = nil, text: String? = nil) {
        self.evidence = evidence
        self.moveOp = moveOp
        self.moveSection = moveSection
        self.text = text
    }

    /// Serialized for storage. An encode failure yields `"{}"` rather than throwing: a
    /// payload is detail, and losing the detail is better than losing the intent.
    public var json: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Parse a stored payload. Anything undecodable reads as empty.
    public static func decode(_ json: String) -> PendingIntentPayload {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PendingIntentPayload.self, from: data)
        else { return PendingIntentPayload() }
        return payload
    }
}

/// One captured change, as a value.
///
/// `dayDate` and (`itemId`, `leadText`, `sectionName`) are the whole safety story. The
/// day says which document this was a fact about; the id is how the bridge is addressed
/// when the document has not moved; the lead is how the change is RE-FOUND when it has,
/// because an item id is a content hash over `(section, lead, added date)` and a rebuild
/// that re-words nothing keeps it while a rebuild that re-words anything does not.
public nonisolated struct PendingIntentRecord: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: PendingIntentKind
    /// The `date` of the Today snapshot (or the diet `dietDay`) this was made against.
    public var dayDate: String
    /// The item the change was about, for the day-file kinds. `nil` for a quick log.
    public var itemId: String?
    /// The item's one-line lead, kept so a rebuilt day can be searched for it.
    public var leadText: String?
    /// The section the item sat in when the change was made.
    public var sectionName: String?
    public var payload: PendingIntentPayload
    /// When the user acted. This — never the moment of replay — is the `at` the bridge
    /// is sent and the instant a quick log's `(eaten at …)` stamp carries.
    public var createdAt: Date
    /// The IANA zone the device was standing in. Carried because a quick log's stamp
    /// must be RFC3339 **with an offset**, and the offset that means anything is the one
    /// the person was living in when they ate.
    public var tz: String
    public var state: PendingIntentState
    public var refusalReason: String?
    public var attempts: Int

    public init(id: UUID = UUID(), kind: PendingIntentKind, dayDate: String,
                itemId: String? = nil, leadText: String? = nil, sectionName: String? = nil,
                payload: PendingIntentPayload = PendingIntentPayload(),
                createdAt: Date = Date(),
                tz: String = TimeZone.current.identifier,
                state: PendingIntentState = .queued,
                refusalReason: String? = nil, attempts: Int = 0) {
        self.id = id
        self.kind = kind
        self.dayDate = dayDate
        self.itemId = itemId
        self.leadText = leadText
        self.sectionName = sectionName
        self.payload = payload
        self.createdAt = createdAt
        self.tz = tz
        self.state = state
        self.refusalReason = refusalReason
        self.attempts = attempts
    }

    /// Whether this row still wants the user's attention: it has not been delivered, or
    /// it could not be. `applied` rows are receipts and drop out on their own.
    public var isOutstanding: Bool { state != .applied }

    /// `createdAt` as RFC3339 **carrying `tz`'s offset**, which is the one spelling the
    /// diet pipeline's `(eaten at …)` stamp accepts (`eaten_at_stamp` in the bridge
    /// parses it with `DateTime::parse_from_rfc3339`, and a value with no offset is
    /// simply not a stamp).
    ///
    /// An unknown zone identifier falls back to the device's current one rather than to
    /// UTC: a stored row whose zone no longer exists in this tz database is still a row
    /// about a person, and the nearest true offset beats a confident wrong one.
    public var createdAtStamp: String {
        let zone = TimeZone(identifier: tz) ?? TimeZone.current
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: createdAt)
    }

    /// `createdAt` as the UTC instant the two Today file mutations take. The peer of
    /// `createdAtStamp`, and deliberately a different spelling: the bridge derives the
    /// wall clock it writes from the request's `client_tz`, so `at` names an instant and
    /// only the diet stamp needs to carry a zone of its own.
    public var createdAtInstant: String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: createdAt)
    }

    /// The wall clock this was captured at, in its own zone — what the pending row and
    /// the "Tell Jesse" fallback sentence show.
    public var createdAtClock: String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: tz) ?? TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: createdAt)
    }
}

/// One captured change, as stored.
///
/// Every property carries a default and the entity is new, which is what makes the V3 →
/// V4 step a LIGHTWEIGHT migration with no migration code — see the long note at the top
/// of `JesseSchema.swift` for why this app must never reintroduce a staged plan for an
/// additive change.
///
/// The enums are stored as their raw strings, like `OutboxItem.stateRaw` and
/// `JesseThread.origin`, so a row written by a build that knew a case this one does not
/// still loads.
@Model
public final class PendingIntent {
    /// The queue's identity, and — for a check-off made on the WRIST — the watch's own
    /// `intentId`. Reusing it is what makes the watch's redelivery safe across a phone
    /// relaunch: `TodayWatchLink`'s in-memory de-duper is emptied by a kill, and this is
    /// not.
    public var id: UUID = UUID()
    /// `PendingIntentKind` raw value.
    public var kind: String = PendingIntentKind.check.rawValue
    /// The day the change was made against, `YYYY-MM-DD`.
    public var dayDate: String = ""
    public var itemId: String?
    public var leadText: String?
    public var sectionName: String?
    public var payloadJSON: String = "{}"
    public var createdAt: Date = Date()
    /// IANA zone identifier.
    public var tz: String = TimeZone.current.identifier
    /// `PendingIntentState` raw value.
    public var state: String = PendingIntentState.queued.rawValue
    public var refusalReason: String?
    public var attempts: Int = 0

    public nonisolated init(record: PendingIntentRecord) {
        apply(record)
    }

    /// Overwrite every field from a record. One function rather than per-field setters
    /// scattered across the store, so a field added to the record cannot be forgotten on
    /// the way back to disk.
    public nonisolated func apply(_ record: PendingIntentRecord) {
        id = record.id
        kind = record.kind.rawValue
        dayDate = record.dayDate
        itemId = record.itemId
        leadText = record.leadText
        sectionName = record.sectionName
        payloadJSON = record.payload.json
        createdAt = record.createdAt
        tz = record.tz
        state = record.state.rawValue
        refusalReason = record.refusalReason
        attempts = record.attempts
    }

    /// The stored row as a value. An unknown `kind` or `state` — a row written by a
    /// newer build — reads as the safest interpretation rather than being dropped: a
    /// check, and queued.
    public nonisolated var record: PendingIntentRecord {
        PendingIntentRecord(id: id,
                            kind: PendingIntentKind(rawValue: kind) ?? .check,
                            dayDate: dayDate,
                            itemId: itemId,
                            leadText: leadText,
                            sectionName: sectionName,
                            payload: PendingIntentPayload.decode(payloadJSON),
                            createdAt: createdAt,
                            tz: tz,
                            state: PendingIntentState(rawValue: state) ?? .queued,
                            refusalReason: refusalReason,
                            attempts: attempts)
    }
}

// MARK: - The seam

/// The narrow store the replayer and the two dashboards talk to.
///
/// A seam rather than a `ModelContext` for the same reason `TodayProviding` is a seam
/// rather than `JesseBridgeClient`: the interesting behaviour is the REPLAY RULES, and a
/// test that has to stand up a `ModelContainer` to exercise "a day change with no lead
/// match refuses" is a test about SwiftData.
@MainActor
public protocol PendingIntentStoring: AnyObject {
    /// Everything held, oldest first. Creation order is load-bearing for quick logs —
    /// a day's meals must arrive in the order they were eaten.
    func all() -> [PendingIntentRecord]
    /// Add one. A record whose `id` is already held is IGNORED, which is what makes a
    /// redelivered watch intent land once.
    func append(_ record: PendingIntentRecord)
    /// Overwrite one by id. A no-op for an id that is not held.
    func update(_ record: PendingIntentRecord)
    /// Forget one — what Discard does, and what the sweep does to a spent receipt.
    func delete(id: UUID)
}

public extension PendingIntentStoring {
    /// The rows still wanting attention: queued, replaying, or refused.
    func outstanding() -> [PendingIntentRecord] { all().filter(\.isOutstanding) }

    /// The rows a replay should attempt, oldest first. `replaying` is included because a
    /// process killed mid-replay leaves one there and nothing else would ever pick it
    /// up; the bridge's own `If-Match` and day guard make a second attempt safe.
    func replayable() -> [PendingIntentRecord] {
        all().filter { $0.state == .queued || $0.state == .replaying }
    }

    /// Drop `applied` receipts older than `ttl`. `refused` rows are never swept — see
    /// `PendingIntentState.refused`.
    func prune(now: Date, ttl: TimeInterval = PendingIntentSweep.appliedTTL) {
        for record in all()
        where record.state == .applied && now.timeIntervalSince(record.createdAt) > ttl {
            delete(id: record.id)
        }
    }
}

/// The one number behind the receipt sweep, named so the store and its test agree.
public nonisolated enum PendingIntentSweep {
    /// How long a delivered intent stays visible as a receipt. A day: long enough that
    /// someone who queued a check on a boat in the morning can see it landed when they
    /// pick the phone up that evening, short enough that the list is not a log.
    public static let appliedTTL: TimeInterval = 24 * 3600
}

/// The SwiftData-backed store the app runs on.
///
/// It holds a `ModelContext` and nothing else. Every decision — what replays, in what
/// order, what refuses — lives above the seam; this is the part that talks to disk.
@MainActor
public final class PendingIntentStore: PendingIntentStoring {
    nonisolated deinit {}

    private let context: ModelContext
    private let save: (ModelContext) throws -> Void

    /// `save` is injected for the same reason `RunCoordinator` injects one: a failed
    /// save must be visible to a test, not swallowed by a `try?` nobody can observe.
    public init(context: ModelContext,
                save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        self.save = save
    }

    public func all() -> [PendingIntentRecord] {
        let descriptor = FetchDescriptor<PendingIntent>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.map(\.record)
    }

    public func append(_ record: PendingIntentRecord) {
        guard row(id: record.id) == nil else { return }
        context.insert(PendingIntent(record: record))
        persist("append")
    }

    public func update(_ record: PendingIntentRecord) {
        guard let row = row(id: record.id) else { return }
        row.apply(record)
        persist("update")
    }

    public func delete(id: UUID) {
        guard let row = row(id: id) else { return }
        context.delete(row)
        persist("delete")
    }

    private func row(id: UUID) -> PendingIntent? {
        var descriptor = FetchDescriptor<PendingIntent>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Save, or leave the change in the context.
    ///
    /// A throw here is not fatal and must not be: the in-memory context still holds the
    /// row, so the queue is correct for this session and only its durability is lost.
    /// Reported through `lastSaveError` so a caller that cares can say so rather than
    /// having to guess.
    private func persist(_ what: String) {
        do {
            try save(context)
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }

    /// The last save failure, or nil. Readable so a screen can tell the user their
    /// offline capture is held in memory only.
    public private(set) var lastSaveError: (any Error)?
}
