import Foundation

// The two strand calls the Strands segment makes, as a narrow seam the shared display
// model depends on — the shape `TodayProviding` and `DietSnapshotProviding` already
// have, so each app injects its own client and a test injects a fake.
//
// `304` is a result and not a thrown error, for `TodayProviding`'s reason: the board is
// polled, the ETag is strong, and the common answer to a poll is "nothing changed".
// Rendering that as an error banner is exactly what a typed result prevents.
//
// There is no mutation here and there will not be one. A strand's queue is edited by
// ticking a checkbox in the note, which the vault reader already does through the
// guarded write — a second write path to the same lines, over the network, is how two
// spellings of "tick a box" end up disagreeing about what was ticked.
//
// `postStrandTick` is not one. It edits nothing: it tells the bridge that the reader
// wrote a tick into this device's copy, so the bridge can start the turn that closes the
// step on the Studio. See `StrandTickReport` in JesseVault for why the write alone never
// got there.

/// The outcome of `GET /jesse/strands`.
public enum StrandsFetchResult: Equatable, Sendable {
    /// `200` — a fresh board. Its `etag` is what the next poll carries.
    case snapshot(StrandsSnapshot)
    /// `304` — unchanged since the `If-None-Match` we sent.
    case notModified
}

/// The two read calls.
public protocol StrandsProviding: Sendable {
    /// `GET /jesse/strands`. Pass the last ETag to get a `304` when nothing changed.
    func getStrands(ifNoneMatch: String?) async throws -> StrandsFetchResult

    /// `GET /jesse/strands/{slug}` — one note's markdown beside its parsed form.
    ///
    /// Read only when the device cannot read the note itself: with the vault folder
    /// held, the file on disk is both fresher and free.
    func getStrand(slug: String) async throws -> StrandDetail
}

// MARK: - The concrete client

extension JesseBridgeClient: StrandsProviding {

    public func getStrands(ifNoneMatch: String? = nil) async throws -> StrandsFetchResult {
        // No `client_tz` query. The day file's endpoint sends one because the bridge
        // derives which DAY to serve from it; a strand board is the same board in every
        // zone, and sending a zone it does not read would be a parameter nobody owns.
        guard var req = todayRequest("/jesse/strands", method: "GET") else {
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
        let snapshot = try Self.decodeStrands(data: data, http: http)
        cacheStrands(body: data, snapshot: snapshot)
        return .snapshot(snapshot)
    }

    public func getStrand(slug: String) async throws -> StrandDetail {
        guard var req = todayRequest("/jesse/strands/\(Self.pathEscaped(slug))",
                                     method: "GET") else {
            throw JesseError.notConfigured
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await todaySend(req)
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, Self.bodyText(data))
        }
        guard let detail = try? StrandDetail.decode(from: data) else {
            throw JesseError.decoding
        }
        return detail
    }

    /// `POST /jesse/strands/{slug}/ticks` — the reader wrote a tick (or an untick) of step
    /// `id` into this device's copy of the note. Answers the bridge's one word state
    /// (`pending`, `cancelled`, `already_fired`, `nothing`, `done`).
    ///
    /// `404` is thrown as `JesseError.badResponse(404, …)` like any other status: the
    /// caller decides that a note or step the bridge does not have is not worth resending.
    public func postStrandTick(slug: String, id: String, checked: Bool) async throws -> String {
        guard var req = todayRequest("/jesse/strands/\(Self.pathEscaped(slug))/ticks",
                                     method: "POST") else {
            throw JesseError.notConfigured
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "checked": checked])
        let (data, http) = try await todaySend(req)
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, Self.bodyText(data))
        }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["state"] as? String ?? ""
    }

    /// Decode a board, preferring the ETag the body carries and falling back to the
    /// header — `decodeToday`'s contract, for the same reason: a cached body alone must
    /// be enough to make the next `GET` conditional.
    static func decodeStrands(data: Data, http: HTTPURLResponse) throws -> StrandsSnapshot {
        guard var snap = try? StrandsSnapshot.decode(from: data) else { throw JesseError.decoding }
        if snap.etag == nil || snap.etag?.isEmpty == true {
            snap.etag = http.value(forHTTPHeaderField: "Etag")
        }
        return snap
    }

    private func cacheStrands(body: Data, snapshot: StrandsSnapshot) {
        guard let cache = snapshotCache else { return }
        cache.store(body, key: SnapshotCacheKey.strands, etag: snapshot.etag, fetchedAt: Date())
    }
}
