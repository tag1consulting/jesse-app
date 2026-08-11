import Foundation

// The Today-on-the-wrist wire: a COMPACT summary of the day file that the phone
// pushes to the watch, and the check intent the watch sends back.
//
// Compiled into both the phone target and the watch target (and into the watch's
// widget extension), so the three ends share one definition. Foundation-only, for
// the same reason `WatchMessage.swift` is: **the watch never talks to the bridge
// and never holds the auth token**. Nothing from JesseNetworking may appear here —
// not `TodaySnapshot`, not `JesseBridgeClient`, not a URL. What crosses is a value
// the phone already fetched, shrunk to what a 45mm screen can show.
//
// ## Why this is not part of `WatchMessage`
//
// `WatchMessage` is the CHAT wire, and every one of its cases is keyed by a
// `requestId` — its decoder demands one before it even looks at the type. A pushed
// day has no request behind it, so bolting it on would mean either a fake id or
// restructuring the chat codec's guard. It is also a different TRANSPORT with
// different semantics: the summary rides `updateApplicationContext`, whose
// latest-wins overwrite is exactly what a "here is the day now" push wants and
// exactly what a chat turn must never get.
//
// Both wires do share `transferUserInfo` for the watch-to-phone direction, so each
// decoder must reject the other's dictionaries. That is what `type` is for, and
// `WatchTodayWireTests.testTheCodecsRejectEachOther` is what keeps it true.
//
// ## The one non-obvious encoding choice
//
// `pushedAt` travels as a `Double` of seconds, never an `Int` of milliseconds.
// `Int` is 32 BITS on arm64_32 — Apple Watch Series 4 through 8 — where a
// milliseconds-since-epoch stamp overflows and the stale guard starts answering
// nonsense. Seconds-as-Double is exact past the year 2100 on every architecture.

/// The version-and-limits namespace for this wire. Separate from
/// `WatchMessage.version` on purpose: the two protocols evolve independently, and a
/// chat-wire bump has no business invalidating a pushed day.
public nonisolated enum WatchTodayWire {
    /// Bumped only on an incompatible change; both decoders reject anything else.
    public nonisolated static let version = 1

    /// How much of an item's lead survives the trip. A watch row is one or two
    /// lines; past this the words are noise that costs battery to render and bytes
    /// to carry. Enforced by `WatchTodayRow.init`, so no call site can bypass it.
    public nonisolated static let maxLeadCharacters = 80

    /// The most rows a decoder will accept from one payload. The producer ships far
    /// fewer (see `TodayWatchSummary.maxDoNowRows`); this is the defensive bound on
    /// a payload the watch did not write, and it CLAMPS rather than rejects — a
    /// too-long list is still a usable list once it is cut down.
    public nonisolated static let maxDecodedRows = 32

    /// Cap on any single text field, so a corrupt dictionary cannot force a
    /// pathological allocation before the clamps above get a chance to run.
    public nonisolated static let maxFieldBytes = 4096

    /// How old a pushed context may be before the watch stops presenting it as
    /// today. Eighteen hours: long enough to cover a night with the phone in another
    /// room, short enough that yesterday's list can never quietly pass for today's.
    public nonisolated static let staleAfter: TimeInterval = 18 * 3600

    // Wire keys — one definition, shared by encode and decode so they cannot drift.
    nonisolated static let versionKey = "v"
    nonisolated static let typeKey = "type"
    nonisolated static let contextType = "todayContext"
    nonisolated static let checkType = "todayCheck"

    /// A string field bounded by `maxFieldBytes`. nil when absent, not a string, or
    /// over-long — the caller decides whether that is fatal.
    nonisolated static func boundedText(_ value: Any?) -> String? {
        guard let s = value as? String, s.utf8.count <= maxFieldBytes else { return nil }
        return s
    }

    /// `s` cut to `maxLeadCharacters`, with an ellipsis standing in for what was
    /// dropped. Counts CHARACTERS (grapheme clusters), not bytes or scalars: the day
    /// file is full of accented names, and a byte-wise cut would split one.
    nonisolated static func truncatedLead(_ s: String) -> String {
        guard s.count > maxLeadCharacters else { return s }
        return String(s.prefix(maxLeadCharacters - 1)) + "…"
    }
}

// MARK: - The summary

/// One glanceable row: an item id, the words, whether it is ticked, and the section
/// it came from.
///
/// `lead` is truncated BY THE INITIALIZER rather than by the sender, so there is no
/// path — a new call site, a decoded payload, a test fixture — that can produce a
/// row too long for the screen.
public nonisolated struct WatchTodayRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let lead: String
    public let checked: Bool
    /// The day file's section heading, or `""` for the standing lead item that sits
    /// above every heading. Carried so the watch can tell the two apart without a
    /// second flag meaning the same thing.
    public let section: String

    public nonisolated init(id: String, lead: String, checked: Bool, section: String) {
        self.id = id
        self.lead = WatchTodayWire.truncatedLead(lead)
        self.checked = checked
        self.section = section
    }

    /// Whether this is the standing top-priority item.
    public var isLead: Bool { section.isEmpty }
}

/// The whole day, as the wrist needs it: a handful of rows plus the numbers for
/// everything that did not fit.
///
/// `pushedAt` is the PHONE's clock at the moment of the push, and it is what the
/// stale guard reads. `date` is the day file's own date, and it is what the stale
/// banner shows — the two answer different questions and both are needed.
public nonisolated struct WatchTodaySummary: Equatable, Sendable {
    public let date: String?
    public let etag: String?
    public let pushedAt: Date
    public let rows: [WatchTodayRow]
    /// Actionable items in the WHOLE day — not done, not postponed. The footer's
    /// "n more on your phone" is this minus the open rows that made the trip.
    public let openCount: Int
    /// Ticked items in the whole day.
    public let doneCount: Int
    /// Open `Do Now` work plus open lead items — the number the phone's tab badge
    /// means, and the number the complication shows.
    ///
    /// Carried rather than counted from `rows`, because `rows` is CAPPED: a Do Now
    /// section with fourteen open items would make a complication that says ten, and
    /// a complication that undercounts is worse than none.
    public let doNowOpenCount: Int

    public nonisolated init(date: String?, etag: String?, pushedAt: Date,
                            rows: [WatchTodayRow], openCount: Int, doneCount: Int,
                            doNowOpenCount: Int = 0) {
        self.date = date
        self.etag = etag
        self.pushedAt = pushedAt
        self.rows = rows
        self.openCount = max(0, openCount)
        self.doneCount = max(0, doneCount)
        self.doNowOpenCount = max(0, doNowOpenCount)
    }

    private enum Key {
        nonisolated static let date = "date"
        nonisolated static let etag = "etag"
        nonisolated static let pushedAt = "pushedAt"
        nonisolated static let rows = "rows"
        nonisolated static let open = "open"
        nonisolated static let done = "done"
        nonisolated static let doNowOpen = "doNowOpen"
        nonisolated static let id = "id"
        nonisolated static let lead = "lead"
        nonisolated static let checked = "checked"
        nonisolated static let section = "section"
    }

    /// Serialize to the `[String: Any]` WatchConnectivity carries. Property-list
    /// types only (String / Bool / Double / Array / Dictionary), which is what
    /// `updateApplicationContext` requires and what it throws about at RUNTIME if you
    /// get it wrong.
    public nonisolated func encode() -> [String: Any] {
        var dict: [String: Any] = [
            WatchTodayWire.versionKey: WatchTodayWire.version,
            WatchTodayWire.typeKey: WatchTodayWire.contextType,
            Key.pushedAt: pushedAt.timeIntervalSince1970,
            Key.open: openCount,
            Key.done: doneCount,
            Key.doNowOpen: doNowOpenCount,
            Key.rows: rows.map { row in
                [Key.id: row.id, Key.lead: row.lead,
                 Key.checked: row.checked, Key.section: row.section] as [String: Any]
            },
        ]
        if let date { dict[Key.date] = date }
        if let etag { dict[Key.etag] = etag }
        return dict
    }

    /// Parse a pushed context. Returns nil for a wrong version, a wrong type, or a
    /// missing timestamp — the three things that make the payload unreadable rather
    /// than merely untidy. Everything else is CLAMPED: an over-long row list is cut,
    /// an over-long lead is truncated, a negative count becomes zero. A day the watch
    /// can partly render beats a blank screen.
    public nonisolated static func decode(_ dict: [String: Any]) -> WatchTodaySummary? {
        guard let version = dict[WatchTodayWire.versionKey] as? Int,
              version == WatchTodayWire.version,
              dict[WatchTodayWire.typeKey] as? String == WatchTodayWire.contextType,
              let seconds = dict[Key.pushedAt] as? Double, seconds.isFinite
        else { return nil }

        let rawRows = (dict[Key.rows] as? [[String: Any]]) ?? []
        var rows: [WatchTodayRow] = []
        rows.reserveCapacity(min(rawRows.count, WatchTodayWire.maxDecodedRows))
        for raw in rawRows.prefix(WatchTodayWire.maxDecodedRows) {
            // An id is how every piece of watch state is keyed, so a row without one
            // is not a row. One bad row fails the whole payload rather than being
            // skipped: a list that silently lost an entry is a list the user will
            // act on believing it is complete.
            guard let id = WatchTodayWire.boundedText(raw[Key.id]), !id.isEmpty
            else { return nil }
            rows.append(WatchTodayRow(id: id,
                                      lead: WatchTodayWire.boundedText(raw[Key.lead]) ?? "",
                                      checked: (raw[Key.checked] as? Bool) ?? false,
                                      section: WatchTodayWire.boundedText(raw[Key.section]) ?? ""))
        }

        return WatchTodaySummary(date: WatchTodayWire.boundedText(dict[Key.date]),
                                 etag: WatchTodayWire.boundedText(dict[Key.etag]),
                                 pushedAt: Date(timeIntervalSince1970: seconds),
                                 rows: rows,
                                 openCount: (dict[Key.open] as? Int) ?? 0,
                                 doneCount: (dict[Key.done] as? Int) ?? 0,
                                 doNowOpenCount: (dict[Key.doNowOpen] as? Int) ?? 0)
    }
}

// MARK: - The check intent

/// One check-off (or un-check) made on the wrist, on its way to the phone.
///
/// `intentId` exists for exactly one reason: `transferUserInfo` REDELIVERS. Without
/// it, a queued intent that arrives twice would re-tick an item the user had since
/// unticked — the wrist's equivalent of the chat wire's `requestId` dedup, and
/// needed for the same reason.
///
/// There is no evidence field, and that is deliberate rather than unfinished: typing
/// a note is a phone and Mac affordance, and an evidence-less check is fully valid
/// downstream — the bridge writes no sub-line for one.
public nonisolated struct WatchTodayCheck: Equatable, Sendable {
    public let intentId: UUID
    public let itemId: String
    public let checked: Bool

    public nonisolated init(intentId: UUID, itemId: String, checked: Bool) {
        self.intentId = intentId
        self.itemId = itemId
        self.checked = checked
    }

    private enum Key {
        nonisolated static let intentId = "intentId"
        nonisolated static let itemId = "itemId"
        nonisolated static let checked = "checked"
    }

    public nonisolated func encode() -> [String: Any] {
        [WatchTodayWire.versionKey: WatchTodayWire.version,
         WatchTodayWire.typeKey: WatchTodayWire.checkType,
         Key.intentId: intentId.uuidString,
         Key.itemId: itemId,
         Key.checked: checked]
    }

    /// Parse an intent. Every field is required: an intent with no item names nothing
    /// to check, and one with no id cannot be de-duplicated, which is worse than
    /// dropping it.
    public nonisolated static func decode(_ dict: [String: Any]) -> WatchTodayCheck? {
        guard let version = dict[WatchTodayWire.versionKey] as? Int,
              version == WatchTodayWire.version,
              dict[WatchTodayWire.typeKey] as? String == WatchTodayWire.checkType,
              let idString = WatchTodayWire.boundedText(dict[Key.intentId]),
              let intentId = UUID(uuidString: idString),
              let itemId = WatchTodayWire.boundedText(dict[Key.itemId]), !itemId.isEmpty,
              let checked = dict[Key.checked] as? Bool
        else { return nil }
        return WatchTodayCheck(intentId: intentId, itemId: itemId, checked: checked)
    }
}
