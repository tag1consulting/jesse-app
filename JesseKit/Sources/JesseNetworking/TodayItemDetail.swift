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

    public init(id: String, path: String = "", target: String = "", markdown: String = "",
                truncated: Bool = false, etag: String? = nil, generatedAt: String? = nil) {
        self.id = id
        self.path = path
        self.target = target
        self.markdown = markdown
        self.truncated = truncated
        self.etag = etag
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, target, markdown, truncated, etag, generatedAt
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

    public init(id: String, reason: TodayNoDetailReason = .noTarget,
                etag: String? = nil, generatedAt: String? = nil) {
        self.id = id
        self.reason = reason
        self.etag = etag
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, reason, etag, generatedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        reason = try c.decodeIfPresent(TodayNoDetailReason.self, forKey: .reason) ?? .unknown
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
    }
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
