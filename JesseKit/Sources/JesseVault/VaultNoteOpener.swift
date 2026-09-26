import Foundation

// A NOTE OPENED BY NAME IS THE STUDIO'S NOTE, WHENEVER THE STUDIO CAN BE ASKED.
//
// Obsidian on iOS syncs only while Obsidian is open in the foreground, so the vault folder
// on the phone is routinely hours behind the Studio. Every surface that opened a note by
// name — a strand, a wiki link in a reply, a citation, a search hit — read that folder
// FIRST and trusted it: a stale strand note opened in the editable reader, a tick landed on
// an out of date file, and on 2026-09-24 a folder renamed on the Studio did not exist on
// the phone until Obsidian was opened, so strand taps failed.
//
// So opening a note is now one decision, made here, in this order:
//
//   1. The bridge reachable: fetch `GET /jesse/vault/note` with the local copy's hash as
//      `If-None-Match`, so "is my copy current" is one conditional round trip.
//   2. The hashes equal (a `304`, or the same sha256): open the LOCAL reader exactly as
//      before, editor, checkboxes and all.
//   3. The local copy differs or is missing: open the Studio's copy, with a line that says
//      the device is behind. The Obsidian folder is never offered for editing then.
//   4. The bridge unreachable, erroring, or an older bridge without the route: the local
//      copy, as before, with the offline line.
//   5. The Studio has no such note: say so, and show the local copy as local only if
//      there is one.
//
// `TodayDetailModel` already worked this way round for the day's item notes; this is the
// same rule for every other note.

/// One note as the Studio has it.
public struct VaultBridgeNote: Equatable, Sendable {
    /// Vault relative, in the bridge's terms.
    public let path: String
    public let markdown: String
    public let modified: Date?
    /// Of the WHOLE file, even when `markdown` is cut.
    public let sha256: String
    /// The note is longer than the route's cap and `markdown` is a prefix.
    public let truncated: Bool

    public init(path: String, markdown: String, modified: Date?, sha256: String,
                truncated: Bool) {
        self.path = path
        self.markdown = markdown
        self.modified = modified
        self.sha256 = sha256
        self.truncated = truncated
    }

    /// The stamp a write made against this copy carries as its base.
    public var stamp: VaultFileStamp {
        VaultFileStamp(bytes: markdown.utf8.count, digest: sha256)
    }
}

/// What one fetch came back with.
public enum VaultBridgeNoteFetch: Equatable, Sendable {
    case note(VaultBridgeNote)
    /// The `If-None-Match` hash is the Studio's: the local copy is current.
    case notModified
    /// The Studio has no such note.
    case noteNotFound
    /// A bridge without the route (an older build). Offline behaviour.
    case routeMissing
    /// Not reached, or an answer that is not the contract. Offline behaviour.
    case failed(String)

    /// The word the route's `404` carries for a missing NOTE. An older bridge's unknown
    /// route `404` never has it, which is how the two are told apart.
    public static let noteNotFoundError = "note_not_found"

    /// Read one response.
    public static func interpret(status: Int, body: Data) -> VaultBridgeNoteFetch {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        switch status {
        case 304:
            return .notModified
        case 404:
            return object?["error"] as? String == noteNotFoundError ? .noteNotFound : .routeMissing
        case 200..<300:
            break
        default:
            return .failed("HTTP \(status)")
        }
        guard let object,
              let path = object["path"] as? String,
              let markdown = object["markdown"] as? String,
              let sha = object["sha256"] as? String
        else { return .failed("The bridge's note was not the contract.") }
        let modified = (object["modified"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return .note(VaultBridgeNote(path: path, markdown: markdown, modified: modified,
                                     sha256: sha, truncated: object["truncated"] as? Bool ?? false))
    }
}

/// Whatever can reach `GET /jesse/vault/note`. A thrown error means "not reached".
public protocol VaultBridgeNoteFetching: Sendable {
    /// Exactly one of `path` and `target`. `ifNoneMatch` is a bare sha256.
    func fetchVaultNote(path: String?, target: String?,
                        ifNoneMatch: String?) async throws -> (status: Int, body: Data)
}

/// What opening one note shows.
public enum VaultNoteOpening: Equatable, Sendable {
    /// The local copy, which is the Studio's (or no bridge is configured at all).
    case local
    /// The local copy, because the Studio could not be asked.
    case offline
    /// The Studio's copy: the local one is behind, or not on this device.
    case bridge(VaultBridgeNote)
    /// The Studio has no such note; the local copy, labelled local only.
    case localOnly
    /// Neither the Studio nor this device has it.
    case notOnStudio
    /// No local copy, and the Studio could not be asked.
    case unavailable

    /// The decision, as a pure function of the local copy's stamp and the fetch.
    public static func decide(localStamp: VaultFileStamp?,
                              fetch: VaultBridgeNoteFetch) -> VaultNoteOpening {
        switch fetch {
        case .notModified:
            return localStamp == nil ? .unavailable : .local
        case .note(let note):
            if let localStamp, localStamp.digest.caseInsensitiveCompare(note.sha256) == .orderedSame {
                return .local
            }
            return .bridge(note)
        case .noteNotFound:
            return localStamp == nil ? .notOnStudio : .localOnly
        case .routeMissing, .failed:
            return localStamp == nil ? .unavailable : .offline
        }
    }
}

/// Where a wiki target leads.
public enum VaultTargetResolution: Equatable, Sendable {
    /// Open this path: the reader then makes the bridge first decision for it.
    case path(String)
    /// Nothing to open, and the sentence that says so.
    case missing(String)
}

/// The one opener every by-name open goes through.
public actor VaultNoteOpener {

    /// The one the readers use. Configured by each app shell with its bridge client.
    public static let shared = VaultNoteOpener()

    /// How long a note fetched to resolve a link is reused by the open that follows it, so
    /// a tap costs one request rather than two.
    public static let reuseWindow: TimeInterval = 10

    private var makeClient: (@Sendable () async -> (any VaultBridgeNoteFetching)?)?
    private var reachability: (@Sendable () async -> BridgeReachabilityState)?
    private var recent: [String: (note: VaultBridgeNote, at: Date)] = [:]

    public init() {}

    /// A configured opener, for a test.
    public init(client: any VaultBridgeNoteFetching,
                reachability: BridgeReachabilityState = .reachable) {
        makeClient = { client }
        self.reachability = { reachability }
    }

    public func configure(client: @escaping @Sendable () async -> (any VaultBridgeNoteFetching)?,
                          reachability: @escaping @Sendable () async -> BridgeReachabilityState) {
        makeClient = client
        self.reachability = reachability
    }

    /// Whether a shell has handed this a bridge. Unconfigured (a preview, a test that is not
    /// about this), every open is the local copy exactly as it always was.
    public var isConfigured: Bool { makeClient != nil }

    /// The client, when the bridge is worth asking: configured, and not already known to be
    /// unreachable. A screen that has just said "offline" should not spend a timeout
    /// proving it again.
    private func client() async -> (any VaultBridgeNoteFetching)? {
        guard let makeClient else { return nil }
        if await reachability?() == .unreachable { return nil }
        return await makeClient()
    }

    private func fetch(_ client: any VaultBridgeNoteFetching, path: String?, target: String?,
                       ifNoneMatch: String?) async -> VaultBridgeNoteFetch {
        do {
            let (status, body) = try await client.fetchVaultNote(path: path, target: target,
                                                                 ifNoneMatch: ifNoneMatch)
            let result = VaultBridgeNoteFetch.interpret(status: status, body: body)
            if case .note(let note) = result { recent[note.path] = (note, Date()) }
            return result
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Open the note at device relative `localPath`, whose local copy has `localStamp`
    /// (nil: not on this device).
    public func open(localPath: String, localStamp: VaultFileStamp?) async -> VaultNoteOpening {
        guard isConfigured else { return localStamp == nil ? .unavailable : .local }
        let path = VaultBridgePath.bridge(fromLocal: localPath)
        if let cached = recent[path], Date().timeIntervalSince(cached.at) < Self.reuseWindow {
            recent[path] = nil
            return VaultNoteOpening.decide(localStamp: localStamp, fetch: .note(cached.note))
        }
        guard let client = await client() else {
            return VaultNoteOpening.decide(localStamp: localStamp, fetch: .failed("offline"))
        }
        let result = await fetch(client, path: path, target: nil,
                                 ifNoneMatch: localStamp?.digest)
        return VaultNoteOpening.decide(localStamp: localStamp, fetch: result)
    }

    /// Where a wiki link leads, given what the local index made of it.
    ///
    /// The bridge's answer wins when there is one: a note created or renamed on the Studio
    /// an hour ago is exactly the note a reply links, and exactly the one the phone's folder
    /// does not have yet.
    public func resolve(target: String, localPath: String?) async -> VaultTargetResolution {
        let missing = VaultTargetResolution.missing(
            VaultWikiLink.missingCaption(targets: [target]) ?? Self.notOnStudioCaption(target))
        guard let client = await client() else {
            return localPath.map(VaultTargetResolution.path) ?? missing
        }
        switch await fetch(client, path: nil, target: target, ifNoneMatch: nil) {
        case .note(let note):
            if let localPath, VaultBridgePath.bridge(fromLocal: localPath) == note.path {
                return .path(localPath)
            }
            return .path(note.path)
        case .noteNotFound:
            return localPath.map(VaultTargetResolution.path)
                ?? .missing(Self.notOnStudioCaption(target))
        case .notModified, .routeMissing, .failed:
            return localPath.map(VaultTargetResolution.path) ?? missing
        }
    }

    /// Forget a fetched copy, so the next open asks again: what a write through the outbox
    /// calls before its reader reloads.
    public func forget(path: String) {
        recent[VaultBridgePath.bridge(fromLocal: path)] = nil
    }

    // MARK: - The words

    /// The line above a note the device is behind on.
    public static func behindCaption(modified: Date?) -> String {
        let lead = "The Obsidian copy on this device is behind. Showing the Studio's copy"
        guard let modified else { return lead + "." }
        return lead + ", saved \(modified.formatted(date: .abbreviated, time: .shortened))."
    }

    public static let offlineCaption = "Offline: the Studio couldn't be reached, so this is the copy on this device."

    public static let localOnlyCaption = "This note doesn't exist on the Studio. Showing the copy on this device only."

    public static func notOnStudioCaption(_ name: String) -> String {
        "\(VaultWikiLink.basename(name)) doesn't exist on the Studio, and there's no copy on this device."
    }

    public static let truncatedCaption = "Only the first 64 KB are shown, and it can't be edited here."
}
