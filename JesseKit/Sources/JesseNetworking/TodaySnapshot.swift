import Foundation

// The Decodable models for the day-file endpoints (`bridge/src/today.rs` and
// `bridge/src/todaywrite.rs`), mirroring the bridge's serialization exactly:
// camelCase keys, every may-be-absent field optional. Swift's synthesized Decodable
// ignores unknown keys and decodes an absent optional to nil, so a bridge that
// grows a field and one that predates a field both decode cleanly.
//
// These are PURE DATA. Every derived judgement — open counts, the tab badge, what
// an optimistic tap looks like before the server answers — lives in
// `TodaySemantics` (JesseTodayDisplay), never here and never in a view. The one
// thing worth internalizing before reading further is the ITEM IDENTITY CONTRACT,
// because it is what makes the whole screen work and it is also its sharpest edge:
//
//   id = first 12 hex of sha256(sectionName + "|" + normalizedLead + "|" + addedDate)
//
// The day file is REWRITTEN IN FULL every morning, so nothing in it is stable
// across a rebuild except the words. Hashing (section, lead, Added date) means an
// item re-emitted with the same lead in the same section keeps its id, and every
// piece of client state keyed on that id (a local check, a seen flag) survives the
// night. The edge: the SECTION NAME is part of the hash, so an item that moves
// between sections COMES BACK UNDER A DIFFERENT ID. `to_do_now` is the only op that
// crosses sections, and the client must re-key its state when it does — see
// `TodaySemantics.rekeyed(_:in:excluding:)`.

// MARK: - Nodes

/// The half-open byte range `[start, end)` of the source the node was parsed from.
/// The bridge's write path splices by re-parsing, never by a remembered offset, so
/// these are carried for provenance and diffing only — a client must not treat them
/// as addresses.
public struct TodaySourceRange: Decodable, Equatable, Hashable, Sendable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// One link found in a node: a `[[wiki-style]]` vault target, or an http(s) URL.
///
/// `kind` stays a `String` rather than an enum on purpose: the bridge emits it as a
/// `&'static str` it may extend, and an unknown kind must render as a plain chip
/// rather than fail the whole snapshot's decode.
public struct TodayLink: Decodable, Equatable, Hashable, Sendable {
    public var target: String
    public var kind: String

    public init(target: String, kind: String) {
        self.target = target
        self.kind = kind
    }

    /// Whether this link addresses a vault note (as opposed to the open web).
    public var isWiki: Bool { kind == "wiki" }

    /// The short label a chip shows: a wiki target's last path component, or a
    /// URL's host. Never the whole target — a vault path is too long for a chip.
    public var chipLabel: String {
        if isWiki {
            let leaf = target.split(separator: "/").last.map(String.init) ?? target
            return leaf.split(separator: "#").first.map(String.init) ?? leaf
        }
        return URL(string: target)?.host ?? target
    }
}

/// The app's own completion sub-line, lifted out of an item's continuation block:
/// when the phone checked it off and what note it recorded. Both halves are
/// optional — the bridge parses the sub-line leniently because a human and an agent
/// also write it.
public struct TodayAppCompleted: Decodable, Equatable, Hashable, Sendable {
    public var at: String?
    public var evidence: String?
    public init(at: String? = nil, evidence: String? = nil) {
        self.at = at
        self.evidence = evidence
    }
}

/// One task line plus its continuation block.
///
/// `text` is the RAW markdown (the line and every continuation, joined by `\n`) —
/// the client renders that, never a reconstruction, and it is also exactly what the
/// discuss/propagate prompt builders embed. `lead` is the one-line display string:
/// the bold segment when the line has one, otherwise the first sentence, markdown
/// stripped either way.
public struct TodayItem: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var checked: Bool
    public var lead: String
    public var text: String
    public var links: [TodayLink]
    public var addedDate: String?
    public var updatedDate: String?
    public var appCompleted: TodayAppCompleted?
    public var sectionName: String
    /// The topic this item rolls up to, as the bridge derived it from the item's links,
    /// its section heading and the five Dashboard pages. `.unfiled` is the honest
    /// answer for an item that declares no lineage, and is common — see `TodayProject`.
    public var project: TodayProject
    public var range: TodaySourceRange

    public init(id: String, checked: Bool = false, lead: String = "", text: String = "",
                links: [TodayLink] = [], addedDate: String? = nil, updatedDate: String? = nil,
                appCompleted: TodayAppCompleted? = nil, sectionName: String = "",
                project: TodayProject = .unfiled,
                range: TodaySourceRange = TodaySourceRange(start: 0, end: 0)) {
        self.id = id
        self.checked = checked
        self.lead = lead
        self.text = text
        self.links = links
        self.addedDate = addedDate
        self.updatedDate = updatedDate
        self.appCompleted = appCompleted
        self.sectionName = sectionName
        self.project = project
        self.range = range
    }

    /// A tolerant decode, for the same reason `TodaySnapshot` has one: a bridge that
    /// predates a field and one that grows a field must both decode. `project` is the
    /// live case — every bridge before 0.72.0 sends no such key, and an item with no
    /// declared topic is exactly what `.unfiled` means, so its absence is not an error.
    /// Only `id` is required, because an item the client cannot key state by is not an
    /// item it can render.
    private enum CodingKeys: String, CodingKey {
        case id, checked, lead, text, links, addedDate, updatedDate
        case appCompleted, sectionName, project, range
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        lead = try c.decodeIfPresent(String.self, forKey: .lead) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        links = try c.decodeIfPresent([TodayLink].self, forKey: .links) ?? []
        addedDate = try c.decodeIfPresent(String.self, forKey: .addedDate)
        updatedDate = try c.decodeIfPresent(String.self, forKey: .updatedDate)
        appCompleted = try c.decodeIfPresent(TodayAppCompleted.self, forKey: .appCompleted)
        sectionName = try c.decodeIfPresent(String.self, forKey: .sectionName) ?? ""
        project = try c.decodeIfPresent(TodayProject.self, forKey: .project) ?? .unfiled
        range = try c.decodeIfPresent(TodaySourceRange.self, forKey: .range)
            ?? TodaySourceRange(start: 0, end: 0)
    }

    /// Whether this item sits in the lead block above every heading — the standing
    /// top-priority item, which the bridge refuses to move (`409`). The UI hides the
    /// move menu for it rather than offering a button that always fails.
    public var isLeadItem: Bool { sectionName.isEmpty }
}

/// A glanceable row: a briefing-section line that carries a link and is worth
/// surfacing on its own. `seen` / `seenMs` come from the bridge's glance store,
/// which is keyed by DAY as well as by id — "seen" means "seen today", because a
/// briefing line re-emitted tomorrow is a new thing to read even when worded
/// identically.
public struct TodayReport: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var links: [TodayLink]
    public var kind: String
    public var sectionName: String
    public var seen: Bool
    public var seenMs: UInt64
    public var range: TodaySourceRange

    public init(id: String, title: String = "", links: [TodayLink] = [], kind: String = "general",
                sectionName: String = "", seen: Bool = false, seenMs: UInt64 = 0,
                range: TodaySourceRange = TodaySourceRange(start: 0, end: 0)) {
        self.id = id
        self.title = title
        self.links = links
        self.kind = kind
        self.sectionName = sectionName
        self.seen = seen
        self.seenMs = seenMs
        self.range = range
    }
}

/// A body-text line of a section: every non-task line that did not become a report
/// row, carried raw so the client can render it rather than silently drop content.
public struct TodayProse: Decodable, Equatable, Hashable, Sendable {
    public var text: String
    public var range: TodaySourceRange
    public init(text: String, range: TodaySourceRange = TodaySourceRange(start: 0, end: 0)) {
        self.text = text
        self.range = range
    }
}

/// One `## ` section.
///
/// `kind` (`schedule` / `briefing` / `tasks`) is a RENDERING HINT and nothing more:
/// the bridge parses task lines wherever they appear, including inside briefing
/// sections, and the only thing `kind` gates server-side is whether a linked bold
/// line becomes a report row. An unrecognized section name arrives as `tasks`.
public struct TodaySection: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var kind: String
    public var prose: [TodayProse]
    public var items: [TodayItem]
    public var reports: [TodayReport]
    public var range: TodaySourceRange

    /// Sections are addressed by name (which is also part of every contained item's
    /// id), and one parse never emits two `## ` headings the client must tell apart
    /// by anything else.
    public var id: String { name }

    public init(name: String, kind: String = "tasks", prose: [TodayProse] = [],
                items: [TodayItem] = [], reports: [TodayReport] = [],
                range: TodaySourceRange = TodaySourceRange(start: 0, end: 0)) {
        self.name = name
        self.kind = kind
        self.prose = prose
        self.items = items
        self.reports = reports
        self.range = range
    }

    public var isSchedule: Bool { kind == "schedule" }
    public var isBriefing: Bool { kind == "briefing" }
}

/// The document's tallies, as the bridge counted them. Recomputed client-side by
/// `TodaySemantics.counts(_:)` whenever optimistic state is overlaid, so a checkbox
/// tap moves the badge before the round trip completes.
public struct TodayCounts: Decodable, Equatable, Hashable, Sendable {
    public var open: Int
    public var done: Int
    public var reportsUnseen: Int
    public init(open: Int = 0, done: Int = 0, reportsUnseen: Int = 0) {
        self.open = open
        self.done = done
        self.reportsUnseen = reportsUnseen
    }
}

// MARK: - The snapshot

/// The whole day, as `GET /jesse/today` and every mutation return it.
///
/// `missing` is the only field that is not a function of the document: it says the
/// day file was not there at all, which the bridge answers `200` for (before the
/// morning routine has run there is legitimately no file, and the screen should
/// render an empty day rather than an error).
///
/// `generatedAt`, `etag` and `pending` are added by the ENDPOINT, not by the
/// parser, which is why they are optional here: `etag` is echoed inside the body so
/// a client that stored the payload need not also keep headers; `pending` appears
/// only on a mutation response and means "journaled and visible here, but not in
/// the file yet — a turn is mid-write and replay will land it".
public struct TodaySnapshot: Decodable, Equatable, Sendable {
    public var title: String?
    public var date: String?
    public var narrative: String?
    public var leadItems: [TodayItem]
    public var sections: [TodaySection]
    public var counts: TodayCounts
    public var missing: Bool
    public var generatedAt: String?
    public var etag: String?
    public var pending: Bool?

    public init(title: String? = nil, date: String? = nil, narrative: String? = nil,
                leadItems: [TodayItem] = [], sections: [TodaySection] = [],
                counts: TodayCounts = TodayCounts(), missing: Bool = false,
                generatedAt: String? = nil, etag: String? = nil, pending: Bool? = nil) {
        self.title = title
        self.date = date
        self.narrative = narrative
        self.leadItems = leadItems
        self.sections = sections
        self.counts = counts
        self.missing = missing
        self.generatedAt = generatedAt
        self.etag = etag
        self.pending = pending
    }

    /// A tolerant decode: `leadItems`, `sections`, `counts` and `missing` all fall
    /// back to empty/false rather than failing the whole snapshot, so one field the
    /// bridge stops emitting cannot blank the screen.
    private enum CodingKeys: String, CodingKey {
        case title, date, narrative, leadItems, sections, counts, missing
        case generatedAt, etag, pending
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        narrative = try c.decodeIfPresent(String.self, forKey: .narrative)
        leadItems = try c.decodeIfPresent([TodayItem].self, forKey: .leadItems) ?? []
        sections = try c.decodeIfPresent([TodaySection].self, forKey: .sections) ?? []
        counts = try c.decodeIfPresent(TodayCounts.self, forKey: .counts) ?? TodayCounts()
        missing = try c.decodeIfPresent(Bool.self, forKey: .missing) ?? false
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        pending = try c.decodeIfPresent(Bool.self, forKey: .pending)
    }

    /// Decode a snapshot from a response body.
    public static func decode(from data: Data) throws -> TodaySnapshot {
        try JSONDecoder().decode(TodaySnapshot.self, from: data)
    }

    /// Every item in the document, lead items first, then each section in file
    /// order — the same traversal the bridge counts over.
    public var allItems: [TodayItem] {
        leadItems + sections.flatMap(\.items)
    }

    /// Every report row, in file order.
    public var allReports: [TodayReport] {
        sections.flatMap(\.reports)
    }

    /// The item with `id`, wherever it sits.
    public func item(id: String) -> TodayItem? {
        allItems.first { $0.id == id }
    }
}

// MARK: - The move op

/// The four reorderings the app may request, spelled exactly as the bridge parses
/// them. `toDoNow` is the ONLY one that can cross a section boundary, and therefore
/// the only one that can change an item's id.
public enum TodayMoveOp: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Above every other item of the item's own section.
    case topOfSection = "top_of_section"
    /// Above every other item of the first section named `Do Now…`.
    case toDoNow = "to_do_now"
    /// Swap with the item above it, within its section.
    case up
    /// Swap with the item below it, within its section.
    case down

    /// Whether this op can move an item into a different section — and so whether
    /// the response may carry the item under a new id.
    public var crossesSections: Bool { self == .toDoNow }
}
