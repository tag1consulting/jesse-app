import Foundation
@testable import JesseVault

/// The bridge, as far as notes are concerned: `GET /jesse/vault/note`,
/// `POST /jesse/vault/writes`, and the old strand tick route, scripted.
final class FakeVaultBridge: VaultWriteSending, VaultBridgeNoteFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _reachable = true
    private var _writeRouteMissing = false
    private var _noteRouteMissing = false
    private var _busy = false
    private var _received: [[String: Any]] = []
    private var _sends = 0
    private var _ticks: [StrandTickReport] = []
    private var _notes: [String: String] = [:]
    private var _fetches: [(path: String?, target: String?, ifNoneMatch: String?)] = []
    private var _answer: ([String: Any]) -> [String: Any] = { record in
        ["id": record["id"] ?? "", "status": "applied", "sha256": "0"]
    }
    /// Called at the start of each write send, before it answers.
    var onSend: (@Sendable () async -> Void)?

    var reachable: Bool {
        get { lock.withLock { _reachable } }
        set { lock.withLock { _reachable = newValue } }
    }
    var writeRouteMissing: Bool {
        get { lock.withLock { _writeRouteMissing } }
        set { lock.withLock { _writeRouteMissing = newValue } }
    }
    var noteRouteMissing: Bool {
        get { lock.withLock { _noteRouteMissing } }
        set { lock.withLock { _noteRouteMissing = newValue } }
    }
    var busy: Bool {
        get { lock.withLock { _busy } }
        set { lock.withLock { _busy = newValue } }
    }
    /// Every record the write route received, in order, across every send.
    var received: [[String: Any]] { lock.withLock { _received } }
    var sends: Int { lock.withLock { _sends } }
    var ticks: [StrandTickReport] { lock.withLock { _ticks } }
    var fetches: [(path: String?, target: String?, ifNoneMatch: String?)] {
        lock.withLock { _fetches }
    }
    func answer(with rule: @escaping ([String: Any]) -> [String: Any]) {
        lock.withLock { _answer = rule }
    }
    /// The Studio's notes, by vault relative path.
    func setNote(_ path: String, _ markdown: String?) {
        lock.withLock { _notes[path] = markdown }
    }

    func sendVaultWrites(_ body: Data) async throws -> (status: Int, body: Data) {
        guard reachable else { throw URLError(.notConnectedToInternet) }
        await onSend?()
        return lock.withLock {
            _sends += 1
            if _writeRouteMissing { return (404, Data()) }
            if _busy { return (503, Data(#"{"error":"busy"}"#.utf8)) }
            let records = (try? JSONSerialization.jsonObject(with: body) as? [[String: Any]]) ?? []
            _received.append(contentsOf: records)
            let answers = records.map(_answer)
            return (200, (try? JSONSerialization.data(withJSONObject: answers)) ?? Data())
        }
    }

    func reportStrandTick(_ report: StrandTickReport) async throws -> StrandTickDelivery {
        try lock.withLock {
            guard _reachable else { throw URLError(.notConnectedToInternet) }
            _ticks.append(report)
            return .delivered
        }
    }

    func fetchVaultNote(path: String?, target: String?,
                        ifNoneMatch: String?) async throws -> (status: Int, body: Data) {
        try lock.withLock {
            guard _reachable else { throw URLError(.notConnectedToInternet) }
            _fetches.append((path, target, ifNoneMatch))
            if _noteRouteMissing { return (404, Data()) }
            let key = path ?? "\(target ?? "").md"
            guard let markdown = _notes[key] else {
                return (404, Data(#"{"error":"note_not_found","message":"no such note"}"#.utf8))
            }
            let sha = VaultFileStamp(text: markdown).digest
            if ifNoneMatch == sha { return (304, Data()) }
            let body: [String: Any] = ["path": key, "markdown": markdown,
                                       "modified": "2026-09-26T08:00:00Z",
                                       "sha256": sha, "truncated": false]
            return (200, try JSONSerialization.data(withJSONObject: body))
        }
    }
}

/// A scratch outbox file, never the app's.
func scratchOutbox(_ directory: URL) -> VaultWriteOutbox {
    VaultWriteOutbox(fileURL: directory.appendingPathComponent("outbox.json"),
                     migrateLegacy: false)
}
