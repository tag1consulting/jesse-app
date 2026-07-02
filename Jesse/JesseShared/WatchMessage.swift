import Foundation

// The WatchConnectivity wire protocol between the Jesse iOS app (phone) and the
// Jesse Watch App, plus a PURE codec that turns each message into the
// `[String: Any]` dictionary WatchConnectivity carries and back again.
//
// This file is compiled into BOTH the phone target and the watch target so the
// two ends share one definition of the wire — there is no second, drifting copy.
// It is Foundation-only on purpose: no networking, no bridge token, no
// SwiftData, no AVFoundation. The watch never talks to the bridge, so nothing
// bridge-related may leak in here.
//
// The codec is the seam the tests drive: `encode()` → `[String: Any]` →
// `decode(_:)` round-trips cleanly, and a malformed or oversized dictionary is
// REJECTED (returns nil) rather than crashing. Transport choice (sendMessage vs
// transferUserInfo vs transferFile) lives in the session managers, not here — the
// codec is transport-agnostic so the same value survives every path.

/// Ask vs Tell, as the watch and wire understand it. Deliberately independent of
/// the phone's `JesseMode` (which lives in the networking layer the watch must not
/// import); the phone maps between the two at its boundary.
public nonisolated enum WatchMode: String, Sendable, CaseIterable {
    case ask
    case tell
}

/// One relayed turn on its way from the watch to the phone. Exactly one audio
/// source is expected: inline `audio` bytes (small clips sent via `sendMessage`),
/// or `audioViaFile == true` (larger clips delivered out-of-band by
/// `transferFile`, the bytes arriving with the file, not in the dictionary), or a
/// dictated `transcript` (the documented text fallback when audio can't be
/// captured). `requestId` keys deduplication end to end.
public nonisolated struct WatchRequest: Equatable, Sendable {
    public let requestId: UUID
    public let mode: WatchMode
    /// Inline compressed audio, when small enough to ride a `sendMessage`. nil when
    /// the audio comes via `transferFile` (`audioViaFile`) or this is a text turn.
    public let audio: Data?
    /// True when the audio is delivered as a companion file rather than inline; the
    /// receiver fills the bytes in from the transferred file.
    public let audioViaFile: Bool
    /// Dictated text fallback — used only when audio capture isn't available.
    public let transcript: String?

    public nonisolated init(requestId: UUID, mode: WatchMode, audio: Data? = nil,
                            audioViaFile: Bool = false, transcript: String? = nil) {
        self.requestId = requestId
        self.mode = mode
        self.audio = audio
        self.audioViaFile = audioViaFile
        self.transcript = transcript
    }
}

/// The phone's answer for one relayed turn — exactly what the watch renders and
/// speaks. `ok == false` carries a user-safe `error` and empty text.
public nonisolated struct WatchReply: Equatable, Sendable {
    public let requestId: UUID
    public let ok: Bool
    public let displayText: String
    public let spokenText: String
    public let sessionId: String?
    public let threadId: UUID?
    public let error: String?

    public nonisolated init(requestId: UUID, ok: Bool, displayText: String = "", spokenText: String = "",
                            sessionId: String? = nil, threadId: UUID? = nil, error: String? = nil) {
        self.requestId = requestId
        self.ok = ok
        self.displayText = displayText
        self.spokenText = spokenText
        self.sessionId = sessionId
        self.threadId = threadId
        self.error = error
    }
}

/// An immediate "I got your request" from the phone, sent when reachable so the
/// watch can show progress without waiting for the (slower) reply.
public nonisolated struct WatchAck: Equatable, Sendable {
    public let requestId: UUID
    public let accepted: Bool

    public nonisolated init(requestId: UUID, accepted: Bool) {
        self.requestId = requestId
        self.accepted = accepted
    }
}

/// The three message kinds, unified so one codec serves the whole wire.
public nonisolated enum WatchMessage: Equatable, Sendable {
    case request(WatchRequest)
    case reply(WatchReply)
    case ack(WatchAck)
}

public extension WatchMessage {
    /// Wire schema version. Bumped only on an incompatible change; `decode` rejects
    /// anything it doesn't recognize.
    nonisolated static let version = 1

    /// Reject an inline audio payload larger than this. `sendMessage` tops out
    /// around 65 KB in practice; anything bigger must go via `transferFile`, so an
    /// oversized inline blob is a malformed message, not a valid one.
    nonisolated static let maxInlineAudioBytes = 60_000

    /// Cap on any single text field, so a malformed/hostile dictionary can't force a
    /// pathological allocation. Well above any real transcript or reply.
    nonisolated static let maxTextBytes = 256 * 1024

    // Wire keys — one definition, shared by encode and decode so they can't drift.
    // `nonisolated` so `encode`/`decode` (nonisolated) can read them.
    private enum Key {
        nonisolated static let version = "v"
        nonisolated static let type = "type"
        nonisolated static let requestId = "requestId"
        nonisolated static let mode = "mode"
        nonisolated static let audio = "audio"
        nonisolated static let audioViaFile = "audioViaFile"
        nonisolated static let transcript = "transcript"
        nonisolated static let ok = "ok"
        nonisolated static let displayText = "displayText"
        nonisolated static let spokenText = "spokenText"
        nonisolated static let sessionId = "sessionId"
        nonisolated static let threadId = "threadId"
        nonisolated static let error = "error"
    }
    private enum Kind {
        nonisolated static let request = "request"
        nonisolated static let reply = "reply"
        nonisolated static let ack = "ack"
    }

    /// Serialize to the `[String: Any]` dictionary WatchConnectivity carries. Only
    /// property-list types are used (String/Int/Bool/Data), so every transport
    /// accepts it unchanged.
    nonisolated func encode() -> [String: Any] {
        var dict: [String: Any] = [Key.version: Self.version]
        switch self {
        case .request(let r):
            dict[Key.type] = Kind.request
            dict[Key.requestId] = r.requestId.uuidString
            dict[Key.mode] = r.mode.rawValue
            dict[Key.audioViaFile] = r.audioViaFile
            if let audio = r.audio { dict[Key.audio] = audio }
            if let transcript = r.transcript { dict[Key.transcript] = transcript }
        case .reply(let r):
            dict[Key.type] = Kind.reply
            dict[Key.requestId] = r.requestId.uuidString
            dict[Key.ok] = r.ok
            dict[Key.displayText] = r.displayText
            dict[Key.spokenText] = r.spokenText
            if let sessionId = r.sessionId { dict[Key.sessionId] = sessionId }
            if let threadId = r.threadId { dict[Key.threadId] = threadId.uuidString }
            if let error = r.error { dict[Key.error] = error }
        case .ack(let a):
            dict[Key.type] = Kind.ack
            dict[Key.requestId] = a.requestId.uuidString
            dict[Key.ok] = a.accepted
        }
        return dict
    }

    /// Parse a dictionary off the wire. Returns nil for ANYTHING malformed — wrong
    /// or missing version, unknown/missing type, a bad UUID, a request with no audio
    /// AND no transcript, an oversized inline audio blob, or an over-long text field.
    /// Never throws and never traps: a hostile or corrupt payload is rejected, not
    /// crashed on.
    nonisolated static func decode(_ dict: [String: Any]) -> WatchMessage? {
        guard let version = dict[Key.version] as? Int, version == Self.version else { return nil }
        guard let type = dict[Key.type] as? String else { return nil }
        guard let idString = dict[Key.requestId] as? String,
              let requestId = UUID(uuidString: idString) else { return nil }

        switch type {
        case Kind.request:
            guard let modeRaw = dict[Key.mode] as? String,
                  let mode = WatchMode(rawValue: modeRaw) else { return nil }
            let audioViaFile = (dict[Key.audioViaFile] as? Bool) ?? false
            var audio = dict[Key.audio] as? Data
            if let bytes = audio, bytes.count > Self.maxInlineAudioBytes { return nil }
            if audio?.isEmpty == true { audio = nil }
            let transcript = boundedText(dict[Key.transcript])
            if dict[Key.transcript] != nil && transcript == nil { return nil } // present but over-long
            // A request must carry SOME audio source: inline bytes, a companion
            // file, or dictated text. A request with none is malformed.
            guard audio != nil || audioViaFile || (transcript?.isEmpty == false) else { return nil }
            return .request(WatchRequest(requestId: requestId, mode: mode, audio: audio,
                                         audioViaFile: audioViaFile, transcript: transcript))

        case Kind.reply:
            guard let ok = dict[Key.ok] as? Bool else { return nil }
            let display = boundedText(dict[Key.displayText]) ?? ""
            let spoken = boundedText(dict[Key.spokenText]) ?? ""
            if dict[Key.displayText] != nil && boundedText(dict[Key.displayText]) == nil { return nil }
            if dict[Key.spokenText] != nil && boundedText(dict[Key.spokenText]) == nil { return nil }
            let sessionId = dict[Key.sessionId] as? String
            var threadId: UUID?
            if let tid = dict[Key.threadId] as? String {
                guard let parsed = UUID(uuidString: tid) else { return nil }
                threadId = parsed
            }
            let error = boundedText(dict[Key.error])
            return .reply(WatchReply(requestId: requestId, ok: ok, displayText: display,
                                     spokenText: spoken, sessionId: sessionId,
                                     threadId: threadId, error: error))

        case Kind.ack:
            guard let accepted = dict[Key.ok] as? Bool else { return nil }
            return .ack(WatchAck(requestId: requestId, accepted: accepted))

        default:
            return nil
        }
    }

    /// A string field bounded by `maxTextBytes`. Returns nil when the value is
    /// absent OR present-but-not-a-String OR longer than the cap — the caller
    /// decides whether "absent" is fatal (a required field) or fine (optional).
    private nonisolated static func boundedText(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        guard s.utf8.count <= Self.maxTextBytes else { return nil }
        return s
    }
}
