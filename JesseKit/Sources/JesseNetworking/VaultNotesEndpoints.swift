import Foundation

// THE TWO VAULT ROUTES, AS RAW CALLS.
//
// `GET /jesse/vault/note` serves one note by path or wiki target, so the app can open the
// Studio's current copy instead of the phone's Obsidian folder, which syncs only in the
// foreground. `POST /jesse/vault/writes` takes every write the app makes to a note, applied
// against the Studio's current file.
//
// Raw on purpose: the status and the body go back unread. What a `404` means (no such note,
// or an older bridge without the route) and what a write's answer means are decided in
// JesseVault, beside the opener and the outbox that act on them, and tested there without
// a server. This target knows HTTP and nothing about notes.

extension JesseBridgeClient {

    /// `GET /jesse/vault/note?path=…` or `?target=…`. `ifNoneMatch` is a bare sha256 of
    /// the device's own copy; a `304` means that copy is the Studio's.
    public func getVaultNote(path: String?, target: String?,
                             ifNoneMatch: String?) async throws -> (status: Int, body: Data) {
        var query: [URLQueryItem] = []
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        if let target { query.append(URLQueryItem(name: "target", value: target)) }
        guard var req = todayRequest("/jesse/vault/note", method: "GET", query: query) else {
            throw JesseError.notConfigured
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // The device's hash IS the question; a cached answer to it would be a guess.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let sha = ifNoneMatch, !sha.isEmpty {
            req.setValue("\"\(sha)\"", forHTTPHeaderField: "If-None-Match")
        }
        let (data, http) = try await todaySend(req)
        return (http.statusCode, data)
    }

    /// `POST /jesse/vault/writes` with a JSON array of records.
    public func postVaultWrites(_ body: Data) async throws -> (status: Int, body: Data) {
        guard var req = todayRequest("/jesse/vault/writes", method: "POST") else {
            throw JesseError.notConfigured
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, http) = try await todaySend(req)
        return (http.statusCode, data)
    }
}
