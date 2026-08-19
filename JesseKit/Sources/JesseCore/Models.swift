import Foundation
import SwiftData

// SwiftData store for thread history. A `JesseThread` is one conversation; a
// `Turn` is one message in it. The class is named `JesseThread` rather than
// `Thread` so it can't be confused with `Foundation.Thread`.

public enum TurnRole: String {
    case user
    case jesse
}

/// Where a submitted turn is between "typed" and "answered".
///
/// `.sending` is the pre-ACK window: the POST is crossing the network and the message could
/// still be lost with it. `.accepted` means the bridge returned its 202, having registered the
/// conversation, so the turn is durably the server's and will be answered even if the app is
/// closed. That distinction had no representation anywhere before, which is why both apps
/// showed the identical spinner for both states.
///
/// Shared (rather than declared per app) so the phone and the Mac cannot drift on what their
/// delivery captions mean. `nonisolated`: this module defaults to MainActor isolation for the
/// `@Model` layer, but this is plain Sendable data.
public nonisolated enum TurnPhase: Equatable, Sendable {
    case sending
    case accepted
}

/// Where a thread's first turn came from. `phone` is everything the app itself
/// starts (typed composer, Siri); `watch` is a turn relayed through the phone
/// from an Apple Watch. Modeled as a small String-backed enum so `JesseThread`
/// can store a stable raw value that lightweight-migrates, mirroring how `mode`
/// maps to `JesseMode`. An unknown/absent raw value reads as `.phone`, so an
/// existing store with no `origin` column migrates without loss.
public enum ThreadOrigin: String {
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
public final class JesseThread {
    public var id: UUID = UUID()
    public var title: String = ""
    public var createdAt: Date = Date()
    // Drives list ordering — bumped on every new turn.
    public var updatedAt: Date = Date()
    // "ask" | "tell", fixed at creation.
    public var mode: String = JesseMode.ask.rawValue
    // Bridge session for resume; nil until the first reply lands.
    public var sessionId: String?
    // The BRIDGE-REGISTERED conversation this thread is, as a canonical lowercase UUID.
    // This is the cross-device SYNC KEY, deliberately not the object identity: `id` above
    // stays the SwiftData identity and the key for the outbox, the in-flight map, the task
    // map, and every view. Retyping `id` would force a real SchemaMigrationPlan with frozen
    // copies of the old model types and buy nothing.
    //
    // Minted here in the initializer (never at a call site, of which there are dozens) so
    // no construction path can forget it, and sent on EVERY turn: the bridge registers it
    // before returning its 202 and echoes back the authoritative id, so there is never a
    // window in which the server knows a thread identifier the client does not. That window
    // was the whole duplicate-conversation bug: a sync landing in it adopted the bridge's
    // freshly-advertised session id as a SECOND thread.
    //
    // Optional so an existing store lightweight-migrates with nil; the first sync binds a
    // pre-upgrade thread to the conversation whose `session_ids` contains its `sessionId`.
    public var conversationId: String?
    // When the bridge first ACKNOWLEDGED a turn on this conversation, set ONCE on the first
    // 202. nil means no turn has ever been accepted, which is what distinguishes "still
    // sending" from "the server has it" for the transcript's delivery caption. Additive
    // optional property, so SwiftData lightweight-migrates existing stores.
    public var registeredAt: Date?
    // The model this conversation sends its turns on (per-turn model selection — the
    // bridge's `model` request field). PER THREAD and PER DEVICE: changing it here affects
    // only this conversation on this device, never another thread or another device. A new
    // conversation is seeded from this device's last-used default (`LastUsedModelStore`),
    // falling back to the ambient `opus` if none. nil means "unset" — an old thread migrated
    // from before this property, or a thread that predates any selection — which the send
    // path resolves to the device default, then `opus`. New optional property with a nil
    // default → SwiftData lightweight-migrates existing stores with no migration code
    // (matching `aiTitle`/`origin`/`lastDeliveredJobId`).
    public var selectedModelID: String?
    // Whether this thread is starred. New property with a default, so SwiftData
    // lightweight-migrates existing stores with no migration code.
    //
    // Local-first, reconciled across devices by the bridge flags (bridge 0.25.0):
    // the local store is the render source and the bridge is the sync source. The
    // favorite bit rides `GET /jesse/sessions` and is settable via
    // `POST /jesse/session/{id}/flags`, converged last-writer-wins by
    // `favoriteUpdatedMs` (see `FlagReconciler`). A purely-local thread (no
    // `sessionId` yet) simply stays local until its first reply lands.
    public var isFavorite: Bool = false
    // When it was starred; nil whenever `isFavorite` is false. Kept so favorites
    // could later sort by pin time rather than last activity. This is a DISPLAY
    // timestamp, not the sync clock: it is deliberately cleared on unstar, so it
    // cannot be the last-writer-wins clock (an unstar would lose its change time).
    // `favoriteUpdatedMs` below is the never-cleared LWW clock instead.
    public var favoritedAt: Date?
    // The last-writer-wins clock for `isFavorite` (unix millis of the last change,
    // set OR cleared), used only by cross-device flag sync. Unlike `favoritedAt` it
    // is never reset to a sentinel on unstar, so an unstar's timestamp survives and
    // can beat a stale server `favorite:true`. Additive defaulted property → SwiftData
    // lightweight-migrates existing stores with no migration code (matching how the
    // favorite/archive fields were added); a pre-sync row reads 0, equal to an
    // unflagged server session's 0, so it reconciles as a no-op.
    public var favoriteUpdatedMs: Int = 0
    // The bridge job_id whose reply was last delivered into this thread, used as
    // an idempotency key so a re-entry of `finish` (Re-check / resume re-polling a
    // completed job) can't append the same reply twice. New property with a
    // default, so SwiftData lightweight-migrates existing stores with no migration
    // code (matching `isFavorite`/`favoritedAt`).
    public var lastDeliveredJobId: String?
    // A short conversation title minted by the bridge's /jesse/title endpoint,
    // cached so the list row reads better than the derived first-words title. nil
    // until one is generated (and stays nil forever against a bridge that lacks
    // the endpoint — the row falls back to the derived `title`). New property with
    // a default → SwiftData lightweight-migrates existing stores, no migration code.
    public var aiTitle: String?
    // The content key (see `threadContentKey`) the current `aiTitle` was minted
    // from. When it no longer equals the thread's live content key, `aiTitle` is
    // stale (a turn was appended or edited) and a regeneration is due. Default nil
    // → lightweight migration, and nil reads as "no cached title yet".
    public var titleSourceKey: String?
    // Where this thread originated: "phone" (the default — typed composer, Siri)
    // or "watch" (relayed through the phone from an Apple Watch). Stored as the
    // raw value of `ThreadOrigin`, read back via `originValue`. New property with a
    // default → SwiftData lightweight-migrates existing stores with no migration
    // code (matching `isFavorite`/`aiTitle`), and an old row with no value reads as
    // `.phone`.
    public var origin: String = ThreadOrigin.phone.rawValue
    // Whether this thread is archived: hidden from the main list (All / Favorites /
    // Watch) and shown only in the dedicated Archived view, from which it can be
    // restored. Distinct from deletion: archiving keeps the thread and its turns and
    // is fully reversible; it just hides the row (for example to get a duplicate out
    // of the way). New property with a default, so SwiftData lightweight-migrates
    // existing stores with no migration code (matching isFavorite/origin).
    //
    // Local-first, reconciled across devices by the bridge flags (bridge 0.25.0):
    // like favorite, archive state renders from the local store and syncs through the
    // bridge, converged last-writer-wins by `archivedUpdatedMs`. It rides
    // `GET /jesse/sessions` and is settable via `POST /jesse/session/{id}/flags`, so
    // archiving a conversation on one device hides it on the others after a sync.
    public var isArchived: Bool = false
    // When it was archived; nil whenever isArchived is false. Stamped on archive and
    // cleared on unarchive, mirroring favoritedAt, so an Archived view could later
    // sort by archive time rather than last activity. DISPLAY timestamp only; the
    // never-cleared `archivedUpdatedMs` below is the last-writer-wins sync clock.
    public var archivedAt: Date?
    // The last-writer-wins clock for `isArchived` (unix millis of the last change, set
    // OR cleared). Mirrors `favoriteUpdatedMs`: never reset on unarchive, so an
    // unarchive's timestamp survives to beat a stale server `archived:true`. Additive
    // defaulted property → lightweight migration; a pre-sync row reads 0.
    public var archivedUpdatedMs: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Turn.thread)
    public var turns: [Turn] = []

    public init(title: String = "", mode: JesseMode = .ask, createdAt: Date = Date()) {
        self.id = UUID()
        self.title = title
        self.mode = mode.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        // Mint the conversation sync key HERE rather than at any call site: there are
        // dozens of construction sites across the app, the Mac, the watch relay, and the
        // tests, and one that forgot would be a thread the bridge could never match. A
        // thread ADOPTED from a remote conversation overwrites this immediately with the
        // remote id (it must not keep a fresh random one).
        self.conversationId = Self.mintConversationId()
    }

    /// A fresh conversation id in exactly the shape the bridge validates: a canonical
    /// LOWERCASE hyphenated UUID. `UUID.uuidString` is uppercase, which the bridge rejects
    /// outright, so the lowercasing is load-bearing rather than cosmetic.
    public static func mintConversationId() -> String {
        UUID().uuidString.lowercased()
    }

    public var modeValue: JesseMode { JesseMode(rawValue: mode) ?? .ask }

    /// The thread's origin, decoded from the stored raw value. An unknown or absent
    /// value (a store migrated from before `origin` existed) reads as `.phone`,
    /// mirroring how `modeValue` defaults an unknown mode to `.ask`.
    public var originValue: ThreadOrigin { ThreadOrigin(rawValue: origin) ?? .phone }

    /// Flip the favorite flag, stamping `favoritedAt` when starring and clearing
    /// it when unstarring. `now` is injectable so tests don't read the clock.
    public func toggleFavorite(now: Date = Date()) {
        setFavorite(!isFavorite, now: now)
    }

    /// Set the favorite flag explicitly (a LOCAL user action), keeping `favoritedAt`
    /// consistent and stamping the never-cleared LWW clock `favoriteUpdatedMs` with
    /// `now` on EVERY change (set or clear), so a later reconcile can push this change
    /// up and win against a stale server value. Adopting a value FROM the server uses
    /// `applyFavoriteFromSync` instead (it carries the server's clock, not `now`).
    public func setFavorite(_ value: Bool, now: Date = Date()) {
        isFavorite = value
        favoritedAt = value ? now : nil
        favoriteUpdatedMs = Self.unixMillis(now)
    }

    /// Flip the archived flag, stamping `archivedAt` when archiving and clearing it
    /// when unarchiving. `now` is injectable so tests don't read the clock. Mirrors
    /// `toggleFavorite`.
    public func toggleArchived(now: Date = Date()) {
        setArchived(!isArchived, now: now)
    }

    /// Set the archived flag explicitly (a LOCAL user action), keeping `archivedAt`
    /// consistent and stamping the never-cleared LWW clock `archivedUpdatedMs` with
    /// `now`. Mirrors `setFavorite`; server adoption uses `applyArchivedFromSync`.
    public func setArchived(_ value: Bool, now: Date = Date()) {
        isArchived = value
        archivedAt = value ? now : nil
        archivedUpdatedMs = Self.unixMillis(now)
    }

    /// Adopt a favorite value that WON last-writer-wins against the local one, carrying
    /// the SERVER's change clock (not `now`) so the local `favoriteUpdatedMs` matches the
    /// server exactly and the next reconcile is a no-op. `favoritedAt` (display only) is
    /// set to that clock when starring and cleared when unstarring, preserving its
    /// nil-when-unstarred invariant. Called only by `FlagReconciler`.
    public func applyFavoriteFromSync(_ value: Bool, updatedMs: Int) {
        isFavorite = value
        favoritedAt = value ? Self.date(fromUnixMillis: updatedMs) : nil
        favoriteUpdatedMs = updatedMs
    }

    /// Adopt an archived value that won last-writer-wins, carrying the server's clock.
    /// Mirrors `applyFavoriteFromSync`. Called only by `FlagReconciler`.
    public func applyArchivedFromSync(_ value: Bool, updatedMs: Int) {
        isArchived = value
        archivedAt = value ? Self.date(fromUnixMillis: updatedMs) : nil
        archivedUpdatedMs = updatedMs
    }

    /// Unix milliseconds of a date, the unit the bridge's LWW flag clocks use. Rounded
    /// to the nearest millisecond so a round-trip through the wire is stable.
    public static func unixMillis(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The date for a unix-millis clock, used to set the display `favoritedAt`/
    /// `archivedAt` when adopting a server flag.
    public static func date(fromUnixMillis ms: Int) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
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
    public var orderedTurns: [Turn] {
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
    public var orderedSortCount: Int { orderedMemo.sortCount }

    /// The whole conversation as a role-labeled Markdown transcript, for copy /
    /// share. Uses each turn's *raw* text so any links or formatting survive,
    /// with a blank line between turns so it reads cleanly when pasted.
    public var sharedTranscript: String {
        orderedTurns
            .map { "**\($0.isUser ? "You" : "Jesse"):** \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Max length of a derived thread title before it's truncated with an ellipsis.
    public static let titleCharacterLimit = 60

    /// A short, single-line title derived from the first user message. Used when
    /// a thread is created so the list row reads sensibly before any rename.
    public static func deriveTitle(from text: String) -> String {
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
public final class Turn {
    public var id: UUID = UUID()
    // "user" | "jesse".
    public var role: String = TurnRole.user.rawValue
    public var text: String = ""
    public var createdAt: Date = Date()
    public var thread: JesseThread?

    // Structured provenance (model-badge v2) for a Jesse reply, stored as the compact
    // JSON the bridge delivered (see `JesseProvenance`). Drives the native provenance
    // chip under the message, and survives relaunch/scroll. Nil for user turns, older
    // replies, and badges-off turns. Additive defaulted property → SwiftData
    // lightweight-migrates existing stores with no migration code (matching how
    // `origin`/`aiTitle`/`lastDeliveredJobId` were added).
    public var provenanceJSON: String?

    // The bridge's `turn_key` for this turn: `"<session_id>:<byte offset of the jsonl line
    // it came from>"`, stable across repeated hydrates and unique within a conversation.
    // It is what lets hydration merge server history into a thread without duplicating a
    // turn already rendered, including two genuinely identical messages that a content hash
    // would wrongly collapse into one.
    //
    // nil for a turn created OPTIMISTICALLY (the local echo of a message being sent, or a
    // reply delivered live) that has not yet been matched to its transcript line. The first
    // hydrate that sees the matching content BINDS the key onto it rather than inserting a
    // second bubble. Additive optional property, so SwiftData lightweight-migrates.
    public var sourceKey: String?

    // Downscaled previews of the files the user attached to this turn (nil bytes
    // are never stored — see `TurnAttachment`). Cascade so deleting a Turn (or, via
    // JesseThread's own cascade, a whole thread) removes its previews. Empty by
    // default, so this additive to-many relationship lightweight-migrates existing
    // stores with no migration code (matching how `origin`/`aiTitle` were added).
    @Relationship(deleteRule: .cascade, inverse: \TurnAttachment.turn)
    public var attachments: [TurnAttachment] = []

    // Files JESSE returned on this turn — the other direction from `attachments`. Cascade
    // for the same reason, empty by default so this additive to-many relationship
    // lightweight-migrates. Metadata plus a cache path only: see `TurnArtifact`.
    @Relationship(deleteRule: .cascade, inverse: \TurnArtifact.turn)
    public var artifacts: [TurnArtifact] = []

    public init(role: TurnRole, text: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.role = role.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    public var roleValue: TurnRole { TurnRole(rawValue: role) ?? .user }
    public var isUser: Bool { roleValue == .user }

    /// Attachment previews in a stable order (the relationship itself is unordered).
    public var orderedAttachments: [TurnAttachment] {
        attachments.sorted { $0.createdAt < $1.createdAt }
    }

    /// Returned files in the order the bridge swept them (`sortIndex`), which is the
    /// order the reply's `artifacts` array named them. The relationship itself is
    /// unordered, and `createdAt` is not enough here: every artifact of one turn is
    /// created in the same save, so their timestamps can tie.
    public var orderedArtifacts: [TurnArtifact] {
        artifacts.sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
    }
}

/// A storage-optimized preview of one file the user attached to a `Turn`. The
/// full-resolution bytes live only in the composer at send time and are gone from
/// the bridge the instant the turn ends; we persist ONLY a small downscaled JPEG
/// `thumbnail` (a few KB — see `AttachmentThumbnail`), never the original, so
/// history can show what was sent without unbounded growth. Belongs to exactly
/// one `Turn` (cascade-deleted with it).
@Model
public final class TurnAttachment {
    public var id: UUID = UUID()
    // The original file's display name (e.g. "Photo 1.jpg", "report.pdf").
    public var filename: String = ""
    // The original file's MIME (e.g. "image/jpeg", "application/pdf"), kept so the
    // renderer can badge a PDF distinctly from an image.
    public var mime: String = ""
    // A downscaled JPEG preview of the original — the ONLY image bytes we retain.
    public var thumbnail: Data = Data()
    public var createdAt: Date = Date()
    // The owning turn; nil only transiently before insert. `Turn.attachments` is
    // the cascade side.
    public var turn: Turn?

    public init(filename: String, mime: String, thumbnail: Data, createdAt: Date = Date()) {
        self.id = UUID()
        self.filename = filename
        self.mime = mime
        self.thumbnail = thumbnail
        self.createdAt = createdAt
    }

    public var isImage: Bool { mime.hasPrefix("image/") }
    public var isPDF: Bool { mime == "application/pdf" }
}

/// One file JESSE returned on a `Turn`, as history holds it.
///
/// The same shape as `TurnAttachment` with ONE deliberate difference: it stores metadata
/// plus a local cache PATH, never the bytes. A 20 MB PDF inside SwiftData would be loaded
/// into memory on every fetch of the turn that owns it — including every scroll that
/// touches the row — which is exactly the cost the bridge's metadata-only wire was
/// designed to avoid, undone one layer down.
///
/// Belongs to exactly one `Turn` and is cascade-deleted with it (and, via `JesseThread`'s
/// own cascade, with a whole thread). Every property is defaulted and the relationship is
/// additive, so existing stores lightweight-migrate with no migration code — matching how
/// `TurnAttachment` and the outbox models were added. Registered in `AppModelContainer`
/// through `JesseSchemaV3`.
@Model
public final class TurnArtifact {
    public var id: UUID = UUID()
    /// The BRIDGE's artifact id — the fetch key for `GET /jesse/artifact/{id}` and the
    /// cache filename. Distinct from `id`, which is this row's local identity.
    public var artifactID: String = ""
    /// The model's own filename, for display. Never used as a path component: the cache
    /// file is named from `artifactID`, which the bridge guarantees is hex.
    public var filename: String = ""
    /// The mime the bridge sniffed from the bytes.
    public var mime: String = ""
    public var byteCount: Int = 0
    /// Hex SHA-256 of the content, so a cached file can be validated against the metadata
    /// rather than trusted because it exists.
    public var sha256: String = ""
    /// Position in the reply's `artifacts` array, so history renders them in the order the
    /// turn produced them even though the relationship is unordered.
    public var sortIndex: Int = 0
    /// Whether the bridge has told us this file is permanently gone (a `404` whose reason
    /// was `expired`). Sticky: once set, the view renders "expired" and NEVER fetches this
    /// id again — otherwise every appearance of the row would re-ask for a dead id, for
    /// the life of the thread.
    public var isExpired: Bool = false
    public var createdAt: Date = Date()
    /// The owning turn; nil only transiently before insert. `Turn.artifacts` is the
    /// cascade side.
    public var turn: Turn?

    public init(artifactID: String, filename: String, mime: String, byteCount: Int,
                sha256: String, sortIndex: Int = 0, createdAt: Date = Date()) {
        self.id = UUID()
        self.artifactID = artifactID
        self.filename = filename
        self.mime = mime
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    /// Renders inline as a picture. SVG used to be excluded here as "markup and a
    /// rendering surface"; `ArtifactFileType.isInlineImage` is now the one rule for both
    /// this and the wire type, and carries the reasoning that changed it.
    ///
    /// Computed from `mime`, never stored. A stored property would need a default and a
    /// backfill for every row already in the store, to hold a fact the row already has.
    public var isInlineImage: Bool { ArtifactFileType.isInlineImage(mime) }
    public var isPDF: Bool { mime == "application/pdf" }

    /// The extension the cached copy of this file carries, or `nil` for a mime this build
    /// does not know. From the mime and NEVER from `filename` — see `ArtifactFileType`.
    public var cacheFileExtension: String? { ArtifactFileType.fileExtension(for: mime) }

    /// A short human size for the chip ("18 KB", "2.4 MB").
    public var displaySize: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB]
        return f.string(fromByteCount: Int64(byteCount))
    }

    /// An SF Symbol for the file's kind, so a chip reads at a glance.
    public var typeIcon: String {
        if isInlineImage { return "photo" }
        if isPDF { return "doc.richtext" }
        switch mime {
        case "text/csv": return "tablecells"
        case "application/json": return "curlybraces"
        case "text/html": return "globe"
        case "text/markdown": return "doc.plaintext"
        default: return "doc"
        }
    }
}

/// The delivery state of an `OutboxItem`. `sending` while its transmit is in
/// flight (the thread reads as running); `failed` once a send threw before the
/// bridge ACKed it — the state the per-message Retry/Discard UI keys off. Stored
/// as a String raw value so the model lightweight-migrates and an unknown/absent
/// value reads as `.sending`, mirroring how `TurnRole`/`ThreadOrigin` map.
public enum OutboxState: String {
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
public final class OutboxItem {
    // This IS the wire `request_id` sent as `request_id` on `POST /jesse`.
    public var id: UUID = UUID()
    // The thread this message belongs to (id, not a relationship — the thread is
    // fetched by id on the recovery paths where no live reference survives a kill).
    public var threadID: UUID = UUID()
    // The optimistic user `Turn` this message created (reused verbatim on Retry —
    // never a second user bubble; deleted on Discard).
    public var turnID: UUID = UUID()
    public var text: String = ""
    // The mode the turn was staged with (`JesseMode` raw value).
    public var mode: String = JesseMode.ask.rawValue
    public var voice: Bool = false
    // `OutboxState` raw value — "sending" | "failed".
    public var stateRaw: String = OutboxState.sending.rawValue
    // The human-readable failure line (a mapped `JesseError` message) once `.failed`.
    public var lastError: String?
    // How many times a transmit of this message has failed pre-ACK.
    public var attempts: Int = 0
    public var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \OutboxAttachment.item)
    public var attachments: [OutboxAttachment] = []

    public init(id: UUID = UUID(), threadID: UUID, turnID: UUID, text: String,
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
    public var state: OutboxState { OutboxState(rawValue: stateRaw) ?? .sending }
    /// The staged mode, decoded from the raw value (unknown/absent → `.ask`).
    public var modeValue: JesseMode { JesseMode(rawValue: mode) ?? .ask }
    /// Attachments in a stable order (the relationship itself is unordered).
    public var orderedAttachments: [OutboxAttachment] {
        attachments.sorted { $0.createdAt < $1.createdAt }
    }
}

/// The ORIGINAL full-resolution bytes of one file staged with an `OutboxItem` —
/// the always-sendable staged (post-downscale) bytes the composer would otherwise
/// drop at send. Held in `.externalStorage` so a large image doesn't bloat the
/// sqlite row, and cascade-deleted with its item (at ACK, or on Discard). Distinct
/// from `TurnAttachment`, which keeps only a small thumbnail for history.
@Model
public final class OutboxAttachment {
    public var id: UUID = UUID()
    public var filename: String = ""
    public var mime: String = ""
    @Attribute(.externalStorage) public var data: Data = Data()
    public var createdAt: Date = Date()
    // The owning item; nil only transiently before insert. `OutboxItem.attachments`
    // is the cascade side.
    public var item: OutboxItem?

    public init(filename: String, mime: String, data: Data, createdAt: Date = Date()) {
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
public final class WrittenMeal {
    @Attribute(.unique) public var id: String = ""
    public var writtenAt: Date = Date()
    public var contentHash: String = ""
    public var tombstoned: Bool = false

    public init(id: String, writtenAt: Date = Date(), contentHash: String = "", tombstoned: Bool = false) {
        self.id = id
        self.writtenAt = writtenAt
        self.contentHash = contentHash
        self.tombstoned = tombstoned
    }
}
