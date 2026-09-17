import Foundation

// `GET /jesse/today/items/{id}/detail` — the "more information" note behind one
// day-file item (`bridge/src/todaydetail.rs`).
//
// ## The one thing to know about this endpoint
//
// It is keyed by ITEM ID, never by a path. The bridge re-parses `Today.md` at request
// time and reads the first wiki link of that item that resolves to a readable file
// under the vault root, so the reachable set is "notes linked from today's day file"
// by construction. There is deliberately no `?path=` reader on the wire and this
// client must never grow one: a path parameter would turn a fixed, file-derived set of
// notes into a general vault reader with a token in front of it.
//
// ## Why the outcomes are a result and not thrown errors
//
// Three of the four answers are ORDINARY, exactly as with `TodayProviding`:
//
//   * `304` — the note has not changed since our ETag. The common answer when a detail
//     view is re-opened; the client re-renders what it already has.
//   * `410` — the item is gone from the day file (a rebuild dropped it, or its lead was
//     re-worded into a different id). The detail sheet closes and the row goes away.
//   * `200 {"status":"no-detail"}` — the item links nothing, or its links resolve to
//     nothing. An item with no note is an ORDINARY item; the bridge types this rather
//     than answering `500` precisely so the app does not render a failure for a
//     perfectly healthy day file, and a client that mapped it onto an error would undo
//     that.
//
// Only transport, auth, 5xx and an undecodable body throw.

// MARK: - The note

/// One resolved detail note.
public struct TodayItemDetail: Decodable, Equatable, Hashable, Sendable {
    /// The item this note was resolved for.
    public var id: String
    /// The note's path RELATIVE to the vault's notes root (`Projects/Demo/Widget.md`).
    /// Never absolute: the bridge's own vault location is not the app's business, and
    /// the bridge strips it before serializing.
    public var path: String
    /// The wiki target this was resolved from, verbatim, so a view can show which of an
    /// item's links it got.
    public var target: String
    /// The note's markdown, capped bridge-side at 64 KB on a UTF-8 char boundary.
    public var markdown: String
    /// The note was longer than that cap and `markdown` is a prefix. Worth saying out
    /// loud in the UI — silently showing two thirds of a note is the kind of quiet lie
    /// that costs a reader an afternoon.
    public var truncated: Bool
    /// The strong ETag over `(path, bytes)`, echoed in the body so a client that stored
    /// the payload need not also keep headers. Editing the note OR re-pointing the
    /// item's link both move it.
    public var etag: String?
    public var generatedAt: String?
    /// The seven answers about THIS ITEM, which is what the page leads with — the note
    /// above is the source, one disclosure below it.
    public var brief: TodayBriefEnvelope?

    public init(id: String, path: String = "", target: String = "", markdown: String = "",
                truncated: Bool = false, etag: String? = nil, generatedAt: String? = nil,
                brief: TodayBriefEnvelope? = nil) {
        self.id = id
        self.path = path
        self.target = target
        self.markdown = markdown
        self.truncated = truncated
        self.etag = etag
        self.generatedAt = generatedAt
        self.brief = brief
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, target, markdown, truncated, etag, generatedAt, brief
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        // A bridge before 0.143.0 sends no brief, and the page falls back to showing the
        // note exactly as it always did.
        brief = try c.decodeIfPresent(TodayBriefEnvelope.self, forKey: .brief)
    }

    /// The note's file name, for a title. The full path is shown as a caption, not as a
    /// heading — a vault path is too long to be one.
    public var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

// MARK: - No note

/// Why an item has no detail to show. The bridge's own two reasons, plus the honest
/// answer for a spelling this build does not know.
public enum TodayNoDetailReason: String, Decodable, Equatable, Hashable, Sendable {
    /// The item carries no wiki link at all — most items, in practice.
    case noTarget = "no-target"
    /// It carries wiki links, but none resolved to a readable file under the vault root:
    /// a note not written yet, or a target the sandbox refused.
    case unresolvedTarget = "unresolved-target"
    /// A reason this build has not heard of. Rendered as the general "no note" case, the
    /// same as the two above — the reason refines the wording, never the outcome.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TodayNoDetailReason(rawValue: raw) ?? .unknown
    }
}

/// The typed "there is no note here" answer. It carries an ETag of its own, so an item
/// that will never have a note still costs one `304` per re-open rather than a body.
public struct TodayNoDetail: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var reason: TodayNoDetailReason
    public var etag: String?
    public var generatedAt: String?
    /// **An item with no note still gets a brief.** That is the whole point of writing
    /// one from the item line and a search rather than from a linked document: the items
    /// that link nothing are exactly the ones a reader could previously learn nothing
    /// about.
    public var brief: TodayBriefEnvelope?

    public init(id: String, reason: TodayNoDetailReason = .noTarget,
                etag: String? = nil, generatedAt: String? = nil,
                brief: TodayBriefEnvelope? = nil) {
        self.id = id
        self.reason = reason
        self.etag = etag
        self.generatedAt = generatedAt
        self.brief = brief
    }

    private enum CodingKeys: String, CodingKey { case id, reason, etag, generatedAt, brief }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        reason = try c.decodeIfPresent(TodayNoDetailReason.self, forKey: .reason) ?? .unknown
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        brief = try c.decodeIfPresent(TodayBriefEnvelope.self, forKey: .brief)
    }
}

// MARK: - The brief

// The seven answers about one item (`bridge/src/todaybrief.rs`), served alongside the
// note on the same endpoint.
//
// ## Why this exists at all
//
// The note above is almost never ABOUT the item. It is a person's journal, a project
// file or an area overview, and several unrelated items routinely share one — so an item
// used to open a long document with the answer somewhere inside it, or nowhere. The
// brief is the answer; the note stays, one disclosure away, as the source.

/// One of the seven answers.
///
/// `known == false` is a real state, not an empty string: the bridge's contract is that
/// an answer the notes cannot support SAYS SO ("No due date is recorded.") rather than
/// being omitted or guessed. Render those in a secondary style — the difference between
/// "the vault does not say" and "nobody asked" is worth a reader's eye.
public struct TodayBriefAnswer: Decodable, Equatable, Hashable, Sendable {
    public var text: String
    public var known: Bool

    public init(text: String, known: Bool = true) {
        self.text = text
        self.known = known
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        known = try c.decodeIfPresent(Bool.self, forKey: .known) ?? true
    }

    private enum CodingKeys: String, CodingKey { case text, known }
}

/// How urgent the item is. `unknown` is a real level, for the same reason
/// `TodayBriefAnswer.known` exists.
public enum TodayBriefPriority: String, Decodable, Equatable, Hashable, Sendable {
    case urgent
    case thisWeek = "this-week"
    case whenTimeAllows = "when-time-allows"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TodayBriefPriority(rawValue: raw) ?? .unknown
    }
}

/// Whether the item is still the user's to do.
public enum TodayBriefVerdict: String, Decodable, Equatable, Hashable, Sendable {
    /// Still theirs to do — the common case, and the one that shows no marker.
    case open
    /// The action has happened.
    case done
    /// No longer their action, or no longer needed.
    case moot
    /// A stated deadline passed and nothing shows it was met. NEVER auto-closed by the
    /// bridge: a missed deadline is the case that most needs a person to look.
    case overdue
    /// A verdict this build has not heard of — read as `open`, the safe direction.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TodayBriefVerdict(rawValue: raw) ?? .unknown
    }
}

public enum TodayBriefConfidence: String, Decodable, Equatable, Hashable, Sendable {
    case high, low, unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TodayBriefConfidence(rawValue: raw) ?? .unknown
    }
}

/// A named person who knows more.
public struct TodayBriefContact: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var role: String
    public var knows: String

    /// Names are unique enough within a three-person list to key a `ForEach`.
    public var id: String { name }

    public init(name: String, role: String = "", knows: String = "") {
        self.name = name
        self.role = role
        self.knows = knows
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        knows = try c.decodeIfPresent(String.self, forKey: .knows) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case name, role, knows }
}

/// The judgement, with the evidence it rests on.
public struct TodayBriefRelevance: Decodable, Equatable, Hashable, Sendable {
    public var verdict: TodayBriefVerdict
    public var reason: String
    /// Where the evidence came from: a note path, or a channel and sender.
    public var evidenceSource: String?
    /// The evidence's own date, `YYYY-MM-DD`.
    public var evidenceDate: String?
    public var confidence: TodayBriefConfidence

    public init(verdict: TodayBriefVerdict = .open, reason: String = "",
                evidenceSource: String? = nil, evidenceDate: String? = nil,
                confidence: TodayBriefConfidence = .low) {
        self.verdict = verdict
        self.reason = reason
        self.evidenceSource = evidenceSource
        self.evidenceDate = evidenceDate
        self.confidence = confidence
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decodeIfPresent(TodayBriefVerdict.self, forKey: .verdict) ?? .open
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        evidenceSource = try c.decodeIfPresent(String.self, forKey: .evidenceSource)
        evidenceDate = try c.decodeIfPresent(String.self, forKey: .evidenceDate)
        confidence = try c.decodeIfPresent(TodayBriefConfidence.self, forKey: .confidence) ?? .low
    }

    private enum CodingKeys: String, CodingKey {
        case verdict, reason, evidenceSource, evidenceDate, confidence
    }
}

/// A channel the brief can search for the owner's own sent replies.
///
/// Tolerant like every other enum here: a spelling this build does not know decodes as
/// `.unknown` rather than throwing, so a bridge that grows a seventh channel does not
/// break a phone that has not been updated.
public enum TodayMessageChannel: String, Decodable, Equatable, Hashable, Sendable, CaseIterable {
    case workMail = "work-mail"
    case personalMail = "personal-mail"
    case fastmail
    case slack
    case whatsapp
    case imessage
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TodayMessageChannel(rawValue: raw) ?? .unknown
    }

    /// The six the brief actually searches — `.unknown` is a decoding outcome, not a channel.
    public static var searchable: [TodayMessageChannel] {
        allCases.filter { $0 != .unknown }
    }

    public var label: String {
        switch self {
        case .workMail: "Work mail"
        case .personalMail: "Personal mail"
        case .fastmail: "Fastmail"
        case .slack: "Slack"
        case .whatsapp: "WhatsApp"
        case .imessage: "iMessage"
        case .unknown: "Other"
        }
    }
}

/// ONE MESSAGE THE OWNER SENT, cited as evidence that an item is finished.
///
/// Every field here was checked bridge-side before it arrived: the date parses, the id and
/// account are present, and the sender matched the owner's own identity on that channel. A
/// citation that failed any of those was dropped before this type ever saw it.
///
/// **`summary` is at most one sentence, and the page does not show it.** The body is the
/// owner's private correspondence; the detail page shows where the evidence is, not what it
/// says, so a shoulder-surfer reading a to-do list does not read a mailbox.
public struct TodayMessageCitation: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var channel: TodayMessageChannel
    /// The mailbox, workspace channel or chat it sits in.
    public var account: String
    public var messageId: String
    /// `YYYY-MM-DD`.
    public var date: String
    public var sender: String
    public var summary: String

    /// Stable within one brief: a provider's own message id.
    public var id: String { messageId }

    public init(channel: TodayMessageChannel = .unknown, account: String = "",
                messageId: String = "", date: String = "", sender: String = "",
                summary: String = "") {
        self.channel = channel
        self.account = account
        self.messageId = messageId
        self.date = date
        self.sender = sender
        self.summary = summary
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decodeIfPresent(TodayMessageChannel.self, forKey: .channel) ?? .unknown
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        messageId = try c.decodeIfPresent(String.self, forKey: .messageId) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        sender = try c.decodeIfPresent(String.self, forKey: .sender) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case channel, account, messageId, date, sender, summary
    }
}

/// Seven answers about one item, plus the judgement and the provenance.
public struct TodayItemBrief: Decodable, Equatable, Hashable, Sendable {
    public var about: TodayBriefAnswer
    public var origin: TodayBriefAnswer
    public var due: TodayBriefAnswer
    public var priority: TodayBriefAnswer
    public var priorityLevel: TodayBriefPriority
    public var progress: TodayBriefAnswer
    public var done: TodayBriefAnswer
    public var contacts: TodayBriefAnswer
    public var people: [TodayBriefContact]
    public var relevance: TodayBriefRelevance
    /// Anything useful that did not fit one of the seven.
    public var more: String?
    /// The note paths the answers rest on, each proven bridge-side to resolve under the
    /// notes root — a citation that escaped the vault is dropped before it reaches here.
    public var sources: [String]
    /// Messages the OWNER sent that bear on the item, each already checked bridge-side.
    public var messageCitations: [TodayMessageCitation]
    /// Which channels this brief actually searched. Empty means none were — either the
    /// switch is off or the harness has no containment row for the message servers — and
    /// the page says so rather than letting a reader take silence for an answer.
    public var channelsSearched: [TodayMessageChannel]
    /// When the sent-message search ran. `nil` for a brief written without one.
    public var messagesSearchedAt: String?
    public var generatedAt: String?
    /// Which harness and model wrote it, so a doubtful brief can be traced.
    public var harness: String?
    public var model: String?

    /// The seven, in the order the page shows them, paired with their headings.
    public var sections: [(heading: String, answer: TodayBriefAnswer)] {
        [("What it is", about),
         ("Where it came from", origin),
         ("Due", due),
         ("Priority", priority),
         ("Done so far", progress),
         ("Done means", done),
         ("Who knows more", contacts)]
    }

    public init(about: TodayBriefAnswer, origin: TodayBriefAnswer, due: TodayBriefAnswer,
                priority: TodayBriefAnswer, priorityLevel: TodayBriefPriority = .unknown,
                progress: TodayBriefAnswer, done: TodayBriefAnswer,
                contacts: TodayBriefAnswer, people: [TodayBriefContact] = [],
                relevance: TodayBriefRelevance = TodayBriefRelevance(),
                more: String? = nil, sources: [String] = [],
                messageCitations: [TodayMessageCitation] = [],
                channelsSearched: [TodayMessageChannel] = [],
                messagesSearchedAt: String? = nil, generatedAt: String? = nil,
                harness: String? = nil, model: String? = nil) {
        self.about = about
        self.origin = origin
        self.due = due
        self.priority = priority
        self.priorityLevel = priorityLevel
        self.progress = progress
        self.done = done
        self.contacts = contacts
        self.people = people
        self.relevance = relevance
        self.more = more
        self.sources = sources
        self.messageCitations = messageCitations
        self.channelsSearched = channelsSearched
        self.messagesSearchedAt = messagesSearchedAt
        self.generatedAt = generatedAt
        self.harness = harness
        self.model = model
    }

    /// Tolerant like every other type here: a missing answer decodes as an explicit
    /// unknown rather than throwing, because a brief with six good answers is still
    /// worth showing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func answer(_ key: CodingKeys) throws -> TodayBriefAnswer {
            try c.decodeIfPresent(TodayBriefAnswer.self, forKey: key)
                ?? TodayBriefAnswer(text: "Not recorded.", known: false)
        }
        about = try answer(.about)
        origin = try answer(.origin)
        due = try answer(.due)
        priority = try answer(.priority)
        priorityLevel = try c.decodeIfPresent(TodayBriefPriority.self,
                                              forKey: .priorityLevel) ?? .unknown
        progress = try answer(.progress)
        done = try answer(.done)
        contacts = try answer(.contacts)
        people = try c.decodeIfPresent([TodayBriefContact].self, forKey: .people) ?? []
        relevance = try c.decodeIfPresent(TodayBriefRelevance.self,
                                          forKey: .relevance) ?? TodayBriefRelevance()
        more = try c.decodeIfPresent(String.self, forKey: .more)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        messageCitations = try c.decodeIfPresent([TodayMessageCitation].self,
                                                 forKey: .messageCitations) ?? []
        channelsSearched = try c.decodeIfPresent([TodayMessageChannel].self,
                                                 forKey: .channelsSearched) ?? []
        messagesSearchedAt = try c.decodeIfPresent(String.self, forKey: .messagesSearchedAt)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        harness = try c.decodeIfPresent(String.self, forKey: .harness)
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }

    private enum CodingKeys: String, CodingKey {
        case about, origin, due, priority, priorityLevel, progress, done, contacts
        case people, relevance, more, sources, generatedAt, harness, model
        case messageCitations, channelsSearched, messagesSearchedAt
    }
}

/// How the brief for this item turned out.
///
/// `pending` is a first-class answer, not an absence: generation is background work, and
/// an item opened before its brief exists gets an honest "being written" — the seven
/// headings with a spinner — rather than a blank card or a spinner over the whole page.
public enum TodayBriefStatus: String, Decodable, Equatable, Hashable, Sendable {
    case ok, pending, failed, unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TodayBriefStatus(rawValue: raw) ?? .unknown
    }
}

/// The `brief` object on the detail response.
public struct TodayBriefEnvelope: Decodable, Equatable, Hashable, Sendable {
    public var status: TodayBriefStatus
    /// Present exactly when `status == .ok`.
    public var brief: TodayItemBrief?
    /// Why it failed, in one sentence — shown instead of a bare "error".
    public var failure: String?

    public init(status: TodayBriefStatus, brief: TodayItemBrief? = nil,
                failure: String? = nil) {
        self.status = status
        self.brief = brief
        self.failure = failure
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(TodayBriefStatus.self, forKey: .status) ?? .unknown
        brief = try c.decodeIfPresent(TodayItemBrief.self, forKey: .brief)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
    }

    private enum CodingKeys: String, CodingKey { case status, brief, failure }
}

// MARK: - The outcome

/// The four answers `GET /jesse/today/items/{id}/detail` gives.
public enum TodayDetailResult: Equatable, Sendable {
    /// `200 {"status":"ok"}` — the note.
    case detail(TodayItemDetail)
    /// `200 {"status":"no-detail"}` — an ordinary item with nothing behind it.
    case noDetail(TodayNoDetail)
    /// `304` — unchanged since the `If-None-Match` we sent. Carries the tag the bridge
    /// echoed, which is the same one we sent; a caller re-uses whatever it cached
    /// under it.
    case notModified(etag: String?)
    /// `410` — this id is not in the day file any more. Drop the row; do not retry the
    /// URL, which is not wrong so much as pointing at something that no longer exists.
    case itemGone

    /// The note, when there is one.
    public var note: TodayItemDetail? {
        if case .detail(let d) = self { return d }
        return nil
    }

    /// The ETag this answer should be cached under, when it has one. Both `.detail` and
    /// `.noDetail` carry a tag; a `304` carries the one it matched.
    public var etag: String? {
        switch self {
        case .detail(let d): return d.etag
        case .noDetail(let n): return n.etag
        case .notModified(let tag): return tag
        case .itemGone: return nil
        }
    }
}

// MARK: - The seam

/// The one detail call, as its own narrow protocol.
///
/// Deliberately NOT a fifth requirement on `TodayProviding`. That protocol is the day
/// screen's write surface and has fakes in both app targets; widening it would force
/// every one of them to grow a method they do not exercise, which is how a test double
/// ends up asserting the shape of code nobody calls. `JesseBridgeClient` conforms to
/// both, so a platform injects the same client for each.
public protocol TodayDetailProviding: Sendable {
    /// `GET /jesse/today/items/{id}/detail`. Pass the ETag a previous answer carried to
    /// get a `304` when neither the note nor the item's link to it has changed.
    func getItemDetail(id: String, ifNoneMatch: String?) async throws -> TodayDetailResult
}

// MARK: - The concrete client

extension JesseBridgeClient: TodayDetailProviding {

    public func getItemDetail(id: String, ifNoneMatch: String? = nil) async throws
        -> TodayDetailResult {
        guard var req = todayRequest("/jesse/today/items/\(Self.pathEscaped(id))/detail",
                                     method: "GET") else {
            throw JesseError.notConfigured
        }
        if let tag = ifNoneMatch, !tag.isEmpty {
            req.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, http) = try await todaySend(req)
        return try Self.detailResult(status: http.statusCode,
                                     data: data,
                                     etagHeader: http.value(forHTTPHeaderField: "Etag"))
    }

    /// Map one response onto the typed outcome.
    ///
    /// Split out from the call so the status contract is testable against the bridge's
    /// own captured bodies without a server or a URL-protocol stub: everything
    /// interesting about this endpoint is in this function, and none of it is transport.
    static func detailResult(status: Int, data: Data,
                             etagHeader: String?) throws -> TodayDetailResult {
        switch status {
        case 304:
            return .notModified(etag: etagHeader)
        case 410:
            return .itemGone
        case 200..<300:
            break
        default:
            throw JesseError.badResponse(status, bodyText(data))
        }
        // The body's `status` field decides which of the two `200`s this is. An
        // unrecognized value is read as "no note" rather than thrown: a body the app
        // cannot classify is not a reason to show a failure for an item that is fine.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JesseError.decoding
        }
        let decoder = JSONDecoder()
        if object["status"] as? String == "ok" {
            guard var note = try? decoder.decode(TodayItemDetail.self, from: data) else {
                throw JesseError.decoding
            }
            if note.etag == nil || note.etag?.isEmpty == true { note.etag = etagHeader }
            return .detail(note)
        }
        guard var none = try? decoder.decode(TodayNoDetail.self, from: data) else {
            throw JesseError.decoding
        }
        if none.etag == nil || none.etag?.isEmpty == true { none.etag = etagHeader }
        return .noDetail(none)
    }
}
