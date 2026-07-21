import Foundation
import SwiftData

// SwiftData store for thread history. A `JesseThread` is one conversation; a
// `Turn` is one message in it. The class is named `JesseThread` rather than
// `Thread` so it can't be confused with `Foundation.Thread`.

enum TurnRole: String {
    case user
    case jesse
}

/// Where a thread's first turn came from. `phone` is everything the app itself
/// starts (typed composer, Siri); `watch` is a turn relayed through the phone
/// from an Apple Watch. Modeled as a small String-backed enum so `JesseThread`
/// can store a stable raw value that lightweight-migrates, mirroring how `mode`
/// maps to `JesseMode`. An unknown/absent raw value reads as `.phone`, so an
/// existing store with no `origin` column migrates without loss.
enum ThreadOrigin: String {
    case phone
    case watch
}

/// Non-observed memo backing `JesseThread.orderedTurns`. A plain reference type so
/// the (read-only-looking) getter can cache the sorted array without writing any
/// *observed* property of the model: the model holds this box in a `@Transient`
/// slot it never reassigns, so reading it registers no SwiftUI re-render dependency
/// and mutating the box's fields can't trigger an observation loop during a body
/// evaluation. Reset to empty whenever a fetched model is materialized.
// `nonisolated` so it matches the isolation of `JesseThread`'s `@Model`-generated
// accessors (which run outside the module's default main-actor isolation). The box
// is reachable only through a single non-Sendable `JesseThread`, never shared
// across isolation domains, so its in-place mutation can't race.
private nonisolated final class OrderedTurnsMemo {
    var cache: [Turn]?
    var count = -1
    var sortCount = 0
}

@Model
final class JesseThread {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    // Drives list ordering — bumped on every new turn.
    var updatedAt: Date = Date()
    // "ask" | "tell", fixed at creation.
    var mode: String = JesseMode.ask.rawValue
    // Bridge session for resume; nil until the first reply lands.
    var sessionId: String?
    // Whether this thread is starred. New property with a default, so SwiftData
    // lightweight-migrates existing stores with no migration code.
    var isFavorite: Bool = false
    // When it was starred; nil whenever `isFavorite` is false. Kept so favorites
    // could later sort by pin time rather than last activity.
    var favoritedAt: Date?
    // The bridge job_id whose reply was last delivered into this thread, used as
    // an idempotency key so a re-entry of `finish` (Re-check / resume re-polling a
    // completed job) can't append the same reply twice. New property with a
    // default, so SwiftData lightweight-migrates existing stores with no migration
    // code (matching `isFavorite`/`favoritedAt`).
    var lastDeliveredJobId: String?
    // A short conversation title minted by the bridge's /jesse/title endpoint,
    // cached so the list row reads better than the derived first-words title. nil
    // until one is generated (and stays nil forever against a bridge that lacks
    // the endpoint — the row falls back to the derived `title`). New property with
    // a default → SwiftData lightweight-migrates existing stores, no migration code.
    var aiTitle: String?
    // The content key (see `threadContentKey`) the current `aiTitle` was minted
    // from. When it no longer equals the thread's live content key, `aiTitle` is
    // stale (a turn was appended or edited) and a regeneration is due. Default nil
    // → lightweight migration, and nil reads as "no cached title yet".
    var titleSourceKey: String?
    // Where this thread originated: "phone" (the default — typed composer, Siri)
    // or "watch" (relayed through the phone from an Apple Watch). Stored as the
    // raw value of `ThreadOrigin`, read back via `originValue`. New property with a
    // default → SwiftData lightweight-migrates existing stores with no migration
    // code (matching `isFavorite`/`aiTitle`), and an old row with no value reads as
    // `.phone`.
    var origin: String = ThreadOrigin.phone.rawValue

    @Relationship(deleteRule: .cascade, inverse: \Turn.thread)
    var turns: [Turn] = []

    init(title: String = "", mode: JesseMode = .ask, createdAt: Date = Date()) {
        self.id = UUID()
        self.title = title
        self.mode = mode.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var modeValue: JesseMode { JesseMode(rawValue: mode) ?? .ask }

    /// The thread's origin, decoded from the stored raw value. An unknown or absent
    /// value (a store migrated from before `origin` existed) reads as `.phone`,
    /// mirroring how `modeValue` defaults an unknown mode to `.ask`.
    var originValue: ThreadOrigin { ThreadOrigin(rawValue: origin) ?? .phone }

    /// Flip the favorite flag, stamping `favoritedAt` when starring and clearing
    /// it when unstarring. `now` is injectable so tests don't read the clock.
    func toggleFavorite(now: Date = Date()) {
        setFavorite(!isFavorite, now: now)
    }

    /// Set the favorite flag explicitly, keeping `favoritedAt` consistent.
    func setFavorite(_ value: Bool, now: Date = Date()) {
        isFavorite = value
        favoritedAt = value ? now : nil
    }

    // Non-observed memo for `orderedTurns` (see `OrderedTurnsMemo`). Never reassigned
    // after init, so it registers no observation dependency; its fields are mutated
    // in place by the getter. @Transient: never persisted, and reset to a fresh empty
    // box each time SwiftData materializes the model.
    @Transient private var orderedMemo = OrderedTurnsMemo()

    /// Turns in chronological order — `turns` itself is an unordered relationship.
    ///
    /// Memoized: this is read in the transcript's hot path, which re-evaluates ~10Hz
    /// during a streaming reply, and re-sorting the whole thread on every read is
    /// wasted work when no turn was appended. The cache is keyed on `turns.count` —
    /// turns are only ever *appended* (never reordered or individually removed;
    /// deleting a thread cascades all its turns), so a change in count is the only
    /// way the ordering can change. Reading `turns` still registers the observation
    /// dependency, so the view re-evaluates (and the cache invalidates) on append.
    var orderedTurns: [Turn] {
        let memo = orderedMemo
        if let cache = memo.cache, memo.count == turns.count {
            return cache
        }
        let sorted = turns.sorted { $0.createdAt < $1.createdAt }
        memo.cache = sorted
        memo.count = turns.count
        memo.sortCount += 1
        return sorted
    }

    /// Instrumentation: the number of real sorts `orderedTurns` has performed. A test
    /// asserts it stays at 1 across repeated reads (the memoization win) and steps to
    /// 2 after a turn is appended (invalidation). Not persisted.
    var orderedSortCount: Int { orderedMemo.sortCount }

    /// The whole conversation as a role-labeled Markdown transcript, for copy /
    /// share. Uses each turn's *raw* text so any links or formatting survive,
    /// with a blank line between turns so it reads cleanly when pasted.
    var sharedTranscript: String {
        orderedTurns
            .map { "**\($0.isUser ? "You" : "Jesse"):** \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Max length of a derived thread title before it's truncated with an ellipsis.
    static let titleCharacterLimit = 60

    /// A short, single-line title derived from the first user message. Used when
    /// a thread is created so the list row reads sensibly before any rename.
    static func deriveTitle(from text: String) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let limit = titleCharacterLimit
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

@Model
final class Turn {
    var id: UUID = UUID()
    // "user" | "jesse".
    var role: String = TurnRole.user.rawValue
    var text: String = ""
    var createdAt: Date = Date()
    var thread: JesseThread?

    // Structured provenance (model-badge v2) for a Jesse reply, stored as the compact
    // JSON the bridge delivered (see `JesseProvenance`). Drives the native provenance
    // chip under the message, and survives relaunch/scroll. Nil for user turns, older
    // replies, and badges-off turns. Additive defaulted property → SwiftData
    // lightweight-migrates existing stores with no migration code (matching how
    // `origin`/`aiTitle`/`lastDeliveredJobId` were added).
    var provenanceJSON: String?

    // Downscaled previews of the files the user attached to this turn (nil bytes
    // are never stored — see `TurnAttachment`). Cascade so deleting a Turn (or, via
    // JesseThread's own cascade, a whole thread) removes its previews. Empty by
    // default, so this additive to-many relationship lightweight-migrates existing
    // stores with no migration code (matching how `origin`/`aiTitle` were added).
    @Relationship(deleteRule: .cascade, inverse: \TurnAttachment.turn)
    var attachments: [TurnAttachment] = []

    init(role: TurnRole, text: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.role = role.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    var roleValue: TurnRole { TurnRole(rawValue: role) ?? .user }
    var isUser: Bool { roleValue == .user }

    /// Attachment previews in a stable order (the relationship itself is unordered).
    var orderedAttachments: [TurnAttachment] {
        attachments.sorted { $0.createdAt < $1.createdAt }
    }
}

/// A storage-optimized preview of one file the user attached to a `Turn`. The
/// full-resolution bytes live only in the composer at send time and are gone from
/// the bridge the instant the turn ends; we persist ONLY a small downscaled JPEG
/// `thumbnail` (a few KB — see `AttachmentThumbnail`), never the original, so
/// history can show what was sent without unbounded growth. Belongs to exactly
/// one `Turn` (cascade-deleted with it).
@Model
final class TurnAttachment {
    var id: UUID = UUID()
    // The original file's display name (e.g. "Photo 1.jpg", "report.pdf").
    var filename: String = ""
    // The original file's MIME (e.g. "image/jpeg", "application/pdf"), kept so the
    // renderer can badge a PDF distinctly from an image.
    var mime: String = ""
    // A downscaled JPEG preview of the original — the ONLY image bytes we retain.
    var thumbnail: Data = Data()
    var createdAt: Date = Date()
    // The owning turn; nil only transiently before insert. `Turn.attachments` is
    // the cascade side.
    var turn: Turn?

    init(filename: String, mime: String, thumbnail: Data, createdAt: Date = Date()) {
        self.id = UUID()
        self.filename = filename
        self.mime = mime
        self.thumbnail = thumbnail
        self.createdAt = createdAt
    }

    var isImage: Bool { mime.hasPrefix("image/") }
    var isPDF: Bool { mime == "application/pdf" }
}

/// The delivery state of an `OutboxItem`. `sending` while its transmit is in
/// flight (the thread reads as running); `failed` once a send threw before the
/// bridge ACKed it — the state the per-message Retry/Discard UI keys off. Stored
/// as a String raw value so the model lightweight-migrates and an unknown/absent
/// value reads as `.sending`, mirroring how `TurnRole`/`ThreadOrigin` map.
enum OutboxState: String {
    case sending
    case failed
}

/// A message that has been staged for send but not yet ACKed by the bridge. It is
/// created (state `.sending`) in the SAME save as its optimistic user `Turn`, and
/// DELETED the instant `client.send` returns any success (a 202 `.running` job id
/// or the legacy inline 200 `.reply`). Before that ACK the outbox owns the message:
/// a timeout, a dead network, a 429/5xx, or the app being suspended/killed mid-POST
/// would otherwise lose it — and the full-resolution attachment bytes with it, since
/// only thumbnails persist on the `Turn` and the composer clears its staged bytes at
/// send. A pre-ACK failure flips this to `.failed` (never auto-retried — a manual
/// per-message Retry re-runs the transmit with the SAME `id`, so the bridge dedups
/// if the original POST actually landed).
///
/// `id` IS the wire `request_id` (the bridge's idempotency key). All properties are
/// defaulted so existing stores lightweight-migrate, matching how `TurnAttachment`
/// was added. Registered in `AppModelContainer` via `JesseSchemaV2`.
@Model
final class OutboxItem {
    // This IS the wire `request_id` sent as `request_id` on `POST /jesse`.
    var id: UUID = UUID()
    // The thread this message belongs to (id, not a relationship — the thread is
    // fetched by id on the recovery paths where no live reference survives a kill).
    var threadID: UUID = UUID()
    // The optimistic user `Turn` this message created (reused verbatim on Retry —
    // never a second user bubble; deleted on Discard).
    var turnID: UUID = UUID()
    var text: String = ""
    // The mode the turn was staged with (`JesseMode` raw value).
    var mode: String = JesseMode.ask.rawValue
    var voice: Bool = false
    // `OutboxState` raw value — "sending" | "failed".
    var stateRaw: String = OutboxState.sending.rawValue
    // The human-readable failure line (a mapped `JesseError` message) once `.failed`.
    var lastError: String?
    // How many times a transmit of this message has failed pre-ACK.
    var attempts: Int = 0
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \OutboxAttachment.item)
    var attachments: [OutboxAttachment] = []

    init(id: UUID = UUID(), threadID: UUID, turnID: UUID, text: String,
         mode: JesseMode, voice: Bool, state: OutboxState = .sending,
         createdAt: Date = Date()) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.text = text
        self.mode = mode.rawValue
        self.voice = voice
        self.stateRaw = state.rawValue
        self.createdAt = createdAt
    }

    /// The delivery state, decoded from the raw value (unknown/absent → `.sending`).
    var state: OutboxState { OutboxState(rawValue: stateRaw) ?? .sending }
    /// The staged mode, decoded from the raw value (unknown/absent → `.ask`).
    var modeValue: JesseMode { JesseMode(rawValue: mode) ?? .ask }
    /// Attachments in a stable order (the relationship itself is unordered).
    var orderedAttachments: [OutboxAttachment] {
        attachments.sorted { $0.createdAt < $1.createdAt }
    }
}

/// The ORIGINAL full-resolution bytes of one file staged with an `OutboxItem` —
/// the always-sendable staged (post-downscale) bytes the composer would otherwise
/// drop at send. Held in `.externalStorage` so a large image doesn't bloat the
/// sqlite row, and cascade-deleted with its item (at ACK, or on Discard). Distinct
/// from `TurnAttachment`, which keeps only a small thumbnail for history.
@Model
final class OutboxAttachment {
    var id: UUID = UUID()
    var filename: String = ""
    var mime: String = ""
    @Attribute(.externalStorage) var data: Data = Data()
    var createdAt: Date = Date()
    // The owning item; nil only transiently before insert. `OutboxItem.attachments`
    // is the cascade side.
    var item: OutboxItem?

    init(filename: String, mime: String, data: Data, createdAt: Date = Date()) {
        self.id = UUID()
        self.filename = filename
        self.mime = mime
        self.data = data
        self.createdAt = createdAt
    }
}

/// A meal already written to Apple Health, keyed by the bridge-provided stable
/// meal `id` (date + slot). Its purpose is idempotency AND correction tracking: before
/// applying a delivered meal we consult this store, so a re-poll, Re-check, re-opened
/// thread, or watch relay never double-writes, and a *changed* meal (v2 upsert) is
/// detected and rewritten exactly once.
///
/// - `contentHash` is `Meal.contentHash` at last write — an empty string means
///   "hash-unknown" (a row migrated from the pre-v2 store, or not yet recorded). On the
///   next sight of that id the hashes differ, triggering exactly one idempotent rewrite.
/// - `tombstoned` marks an id the source retracted: a later *plain* insert of the same
///   content is ignored (stale replay), but an upsert with a DIFFERENT hash clears the
///   tombstone (a re-logged meal wins over a stale deletion).
///
/// Both new fields are **defaulted**, so SwiftData lightweight-migrates existing stores
/// with no migration code (matching how `TurnAttachment` and this entity itself were
/// added). `.unique` collapses a duplicate insert to an upsert, a second guarantee
/// against a double row.
@Model
final class WrittenMeal {
    @Attribute(.unique) var id: String = ""
    var writtenAt: Date = Date()
    var contentHash: String = ""
    var tombstoned: Bool = false

    init(id: String, writtenAt: Date = Date(), contentHash: String = "", tombstoned: Bool = false) {
        self.id = id
        self.writtenAt = writtenAt
        self.contentHash = contentHash
        self.tombstoned = tombstoned
    }
}
