import Foundation

// The day-file capabilities the Today screen needs from a bridge client, and the
// TYPED results the four calls answer with.
//
// The shape here follows `DietSnapshotProviding`: a narrow seam the shared display
// model depends on, rather than the platform's full client type, so each app injects
// its own client and tests inject a fake. It deliberately does NOT refine
// `BridgeClientProtocol` — that protocol has fakes in the app targets, and widening
// it would be app-target work this change is scoped out of. `JesseBridgeClient`
// conforms below.
//
// ## Why the statuses are results and not thrown errors
//
// Three of this endpoint family's status codes are ORDINARY OUTCOMES of a screen
// that polls and writes optimistically, not failures:
//
//   * `304` — the day file has not changed since our ETag. The common answer to a
//     poll; the client keeps what it has and re-renders nothing.
//   * `410` — the item is gone from the file (a rebuild dropped it, or its lead was
//     re-worded so it hashes to a different id). The client removes the row.
//   * `412` — our ETag is stale; someone (the agent, a second device) rewrote the
//     file. The client refetches and retries at most nothing — the user's tap is
//     re-offered against fresh state rather than applied blind.
//
// Making them `throws` would leave every caller re-deriving the mapping from an
// integer, which is exactly how a `304` ends up rendered as an error banner. Only
// genuine failures — transport, auth, 5xx, an undecodable body — throw
// `JesseError`.

/// The outcome of `GET /jesse/today`.
public enum TodayFetchResult: Equatable, Sendable {
    /// `200` — a fresh snapshot. Its `etag` is what the next poll and the next
    /// mutation must carry.
    case snapshot(TodaySnapshot)
    /// `304` — unchanged since the `If-None-Match` we sent.
    case notModified
}

/// The outcome of one of the three mutations (`check`, `move`, `glance`).
///
/// A mutation answers with the WHOLE fresh snapshot rather than an acknowledgement,
/// so one round trip both writes and refreshes — including the new ETag the next
/// mutation must carry, which the client would otherwise have to re-`GET`.
public enum TodayMutationResult: Equatable, Sendable {
    /// `200` — applied (or a legitimate no-op), with the fresh snapshot. The
    /// snapshot's `pending` flag says whether the change is journaled but not yet in
    /// the file because a turn is mid-write.
    case snapshot(TodaySnapshot)
    /// `410` — that item is no longer in the day file. Drop the row and refetch.
    case itemGone
    /// `412` — the day file changed since the ETag we sent. Refetch, then re-offer.
    case preconditionFailed
    /// `428` — no `If-Match` was sent at all. Distinct from `412` because it is a
    /// CLIENT BUG, not a race: the bridge separates them so a client knows which of
    /// the two it has. Reaching this means a caller passed an empty tag.
    case preconditionRequired
    /// `409` — the move is structurally impossible: the standing lead item cannot be
    /// moved, or the file has no `Do Now` section to move into. The message is the
    /// bridge's own, written to be shown or logged without translation.
    ///
    /// A `404` maps here too, and deliberately not onto `itemGone`. The bridge
    /// answers `404` when a request names something the current day does not have —
    /// an id it cannot find, a `to_section` destination that is not a heading — and
    /// the useful response to both is the notice row plus a refetch, NOT taking a
    /// row off the screen. Mapping it to `itemGone` would also mean a bridge too old
    /// to know the route at all (whose `404` is the router's, not ours) quietly
    /// deleted a row from the day.
    case conflict(String)
}

/// The five day-file calls the Today screen makes.
///
/// `at` is a `Date` on every mutation even though the wire spellings differ — the
/// two file mutations take an ISO8601 instant (the bridge rejects anything else with
/// a `400` rather than substituting its own clock, because the stamp records when
/// the USER tapped) while `glance` and `postpone` take unix milliseconds. All are
/// derived from the one `Date` here so no caller has to know which endpoint wants
/// which.
public protocol TodayProviding: Sendable {
    /// `GET /jesse/today`. Pass the last ETag to get a `304` when nothing changed.
    func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult

    /// `POST /jesse/today/items/{id}/check` — tick or untick one item, optionally
    /// recording one line of evidence beneath it. Evidence is capped and escaped
    /// bridge-side; unchecking removes any sub-line a previous check wrote.
    func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                   ifMatch: String) async throws -> TodayMutationResult

    /// `POST /jesse/today/items/{id}/move` — reorder one item. For the two ops that
    /// cross a section boundary (`.toDoNow`, `.toSection`) the returned snapshot may
    /// carry the item under a DIFFERENT id (the id hashes the section name); the
    /// response is authoritative and the caller must re-key any state it holds under
    /// the old one.
    func moveItem(id: String, op: TodayMoveOp, at: Date,
                  ifMatch: String) async throws -> TodayMutationResult

    /// `POST /jesse/today/items/{id}/defer` — postpone one item for the day, or
    /// bring it back.
    ///
    /// Like `glance`, this writes NO markdown: postponing is a decision about today,
    /// not a fact about the task, and it lives in a day-scoped bridge store whose
    /// keys expire — which is what brings the item back tomorrow with nothing to
    /// unwind. Unlike a move, the standing lead item MAY be postponed: it counts
    /// toward the badge, so it has to be dismissible.
    func postpone(id: String, deferred: Bool, at: Date,
                  ifMatch: String) async throws -> TodayMutationResult

    /// `POST /jesse/today/glance` — mark one report row seen. The only mutation that
    /// never touches `Today.md`: glance state is the app's read-tracking, kept in the
    /// bridge's state dir and scoped to the snapshot's own date.
    ///
    /// `ifMatch` is required — see the note on `TodayProviding` conformance below.
    func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult
}

// MARK: - Request bodies

// The three mutation bodies, mirroring the bridge's `CheckBody` / `MoveBody` /
// `GlanceBody`. `evidence` omits when nil (serde reads an absent field as `None`),
// which is what makes a bare check write no sub-line at all.

struct TodayCheckBody: Encodable {
    var checked: Bool
    var evidence: String?
    var at: String
}

struct TodayMoveBody: Encodable {
    var op: String
    /// Omitted for every op but `to_section`, whose destination the bridge rejects
    /// as a `400` when it is absent or blank.
    var section: String?
    var at: String
}

struct TodayGlanceBody: Encodable {
    var id: String
    var glancedAt: UInt64
}

struct TodayDeferBody: Encodable {
    var deferred: Bool
    var atMs: UInt64
}

// MARK: - The concrete client

extension JesseBridgeClient: TodayProviding {

    /// `GET /jesse/today`, conditional on `ifNoneMatch`.
    public func getToday(ifNoneMatch: String? = nil) async throws -> TodayFetchResult {
        guard var req = todayRequest("/jesse/today", method: "GET") else {
            throw JesseError.notConfigured
        }
        if let tag = ifNoneMatch, !tag.isEmpty {
            req.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, http) = try await todaySend(req)
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, Self.bodyText(data))
        }
        return .snapshot(try Self.decodeToday(data: data, http: http))
    }

    public func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                          ifMatch: String) async throws -> TodayMutationResult {
        // The bridge caps and escapes evidence itself; blank collapses to an omitted
        // field so a bare check writes no sub-line at all.
        let note = evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = TodayCheckBody(checked: checked,
                                  evidence: (note?.isEmpty ?? true) ? nil : note,
                                  at: Self.isoInstant(at))
        return try await todayMutate("/jesse/today/items/\(Self.pathEscaped(id))/check",
                                     body: body, ifMatch: ifMatch)
    }

    public func moveItem(id: String, op: TodayMoveOp, at: Date,
                         ifMatch: String) async throws -> TodayMutationResult {
        try await todayMutate("/jesse/today/items/\(Self.pathEscaped(id))/move",
                              body: TodayMoveBody(op: op.wireOp,
                                                  section: op.destinationSection,
                                                  at: Self.isoInstant(at)),
                              ifMatch: ifMatch)
    }

    public func postpone(id: String, deferred: Bool, at: Date,
                         ifMatch: String) async throws -> TodayMutationResult {
        // `atMs` is unix MILLISECONDS, like `glance` and unlike the two file
        // mutations: nothing here reaches the vault, so it is a clock reading the
        // defer store resolves concurrent claims with, not a stamp for a person to
        // read in the day file.
        try await todayMutate("/jesse/today/items/\(Self.pathEscaped(id))/defer",
                              body: TodayDeferBody(deferred: deferred,
                                                   atMs: Self.unixMillis(at)),
                              ifMatch: ifMatch)
    }

    public func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult {
        // `glancedAt` is unix MILLISECONDS here, not the ISO instant the two file
        // mutations take — the glance store resolves concurrent marks last-writer-wins
        // on that number, so it is a clock reading rather than a stamp for the vault.
        try await todayMutate("/jesse/today/glance",
                              body: TodayGlanceBody(id: id, glancedAt: Self.unixMillis(at)),
                              ifMatch: ifMatch)
    }

    // MARK: - Shared plumbing

    /// A bearer-authed request for a day-file path, or nil when unconfigured.
    ///
    /// Package-internal rather than file-private: the detail call in
    /// `TodayItemDetail.swift` is the same family of endpoints and must compose its
    /// request the same way, and a second copy of "bearer + endpoint + nil when
    /// unconfigured" is how one of them ends up sending a request with no token.
    func todayRequest(_ path: String, method: String) -> URLRequest? {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint(path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Send and unwrap to an `HTTPURLResponse`, mapping URL-loading failures to the
    /// host-naming `JesseError`. Package-internal for the same reason as
    /// `todayRequest`.
    func todaySend(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        return (data, http)
    }

    /// POST a JSON body under a required `If-Match`, and map the status codes the
    /// three mutations share onto `TodayMutationResult`.
    private func todayMutate(_ path: String, body: some Encodable,
                             ifMatch: String) async throws -> TodayMutationResult {
        guard var req = todayRequest(path, method: "POST") else { throw JesseError.notConfigured }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // An empty tag would be sent as a header the bridge cannot match; not sending
        // it at all is what earns the `428` that names the actual mistake.
        if !ifMatch.isEmpty { req.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        req.httpBody = try Self.encodeBody(body)
        let (data, http) = try await todaySend(req)
        switch http.statusCode {
        case 200..<300:
            return .snapshot(try Self.decodeToday(data: data, http: http))
        case 410:
            return .itemGone
        case 412:
            return .preconditionFailed
        case 428:
            return .preconditionRequired
        case 409:
            return .conflict(Self.bodyText(data))
        case 404:
            // The request named something this day does not have. Reported as the
            // notice row, never as a removed row — see `TodayMutationResult`. The
            // fallback sentence covers a bare router `404` from a bridge too old to
            // know the route, which carries no body of its own.
            let message = Self.bodyText(data)
            return .conflict(message.isEmpty ? Self.notFoundNotice : message)
        default:
            throw JesseError.badResponse(http.statusCode, Self.bodyText(data))
        }
    }

    /// Decode a snapshot, preferring the ETag the body carries and falling back to
    /// the header. The bridge writes the same value into both; the body copy exists
    /// so a client that stored the payload need not also keep headers, and the header
    /// fallback covers a proxy that rewrote the body's framing but not its content.
    static func decodeToday(data: Data, http: HTTPURLResponse) throws -> TodaySnapshot {
        guard var snap = try? TodaySnapshot.decode(from: data) else { throw JesseError.decoding }
        if snap.etag == nil || snap.etag?.isEmpty == true {
            snap.etag = http.value(forHTTPHeaderField: "Etag")
        }
        return snap
    }

    /// An ISO8601 instant with seconds, in UTC — the one spelling
    /// `stamp_from_iso` accepts.
    static func isoInstant(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Unix milliseconds, the glance store's last-writer-wins clock.
    static func unixMillis(_ date: Date) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded()))
    }

    /// Percent-escape an id for a path segment. Ids are 12 hex characters (plus an
    /// optional `-2` ordinal suffix) so this never changes one — it is here so a
    /// malformed id from a stale cache produces a `404`, never a path that addresses
    /// a different route.
    static func pathEscaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    static func bodyText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    /// What a `404` says when it carries no body of its own — which means the
    /// bridge has no such route, not that the day has no such item.
    static let notFoundNotice =
        "Your bridge didn't recognise that action. Update it and try again."
}
