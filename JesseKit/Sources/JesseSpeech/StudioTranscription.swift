import Foundation

// Recorded audio, transcribed ON THE STUDIO — the strongest machine in the system and the
// one that is always on — with this device's own engine as the fallback when the Studio
// cannot be reached.
//
// THE RULE THIS FILE HOLDS, which replaced "audio never goes on the network" (App 1.0
// (124)): a recording may travel to the Jesse bridge on the Studio and to NOTHING ELSE. The
// only request in this file that carries audio is `URLSessionStudioTransport.uploadRequest`,
// and its destination is the bridge's own `/jesse/transcriptions` on the host and token the
// app is paired with — the same connection every turn already uses (loopback on the Studio
// itself, the tailnet everywhere else). The bridge transcribes it with models running in
// its own process and deletes it; it never forwards it. Once the audio is text, the text is
// an ordinary message and flows like one.
//
// WHY THE STUDIO. A phone is capable, but it is the weakest, battery-bound processor in
// this system. On a hard recording — a reverberant hall, several speakers, far-field
// speech — the difference between a small model and a large one on conditioned audio is
// names, dates and numbers coming back right instead of plausibly wrong. And the Studio can
// read the recording twice with two different models and say where they disagree, which
// no single reading can.
//
// WHEN THE FALLBACK RUNS, and only then: the Studio cannot be reached, or cannot
// transcribe (no pairing, an older bridge without the route, transcription switched off),
// or contact is lost mid-run for longer than `contactTolerance`. A Studio that ANSWERS and
// refuses (too large, unreadable) is a real answer and is shown as one. Either way the
// user is told: a fallback result carries a `notice`, and the message header names where
// the transcript was made.

/// Where the Studio's bridge is and how to authenticate to it. Built by the app from the
/// pairing it already has.
public struct StudioEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public let token: String

    /// Nil unless both are present — an unpaired app has no Studio to reach.
    public init?(baseURL: URL?, token: String) {
        guard let baseURL, !token.isEmpty else { return nil }
        self.baseURL = baseURL
        self.token = token
    }
}

/// One Studio run, as `GET /jesse/transcriptions/{id}` reports it.
public struct StudioRunStatus: Decodable, Sendable, Equatable {
    public struct Engine: Decodable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let role: String

        public init(id: String, label: String, role: String) {
            self.id = id
            self.label = label
            self.role = role
        }
    }

    public struct Disagreement: Decodable, Sendable, Equatable {
        public let startMs: UInt64
        public let endMs: UInt64
        public let primary: String
        public let alternative: String

        enum CodingKeys: String, CodingKey {
            case startMs = "start_ms", endMs = "end_ms", primary, alternative
        }

        public init(startMs: UInt64, endMs: UInt64, primary: String, alternative: String) {
            self.startMs = startMs
            self.endMs = endMs
            self.primary = primary
            self.alternative = alternative
        }
    }

    public struct Failure: Decodable, Sendable, Equatable {
        public let kind: String
        public let message: String

        public init(kind: String, message: String) {
            self.kind = kind
            self.message = message
        }
    }

    public let id: String
    /// `running`, `done`, `failed` or `cancelled`.
    public let state: String
    public let phase: String
    public let fraction: Double
    public let engine: String?
    public let transcript: String?
    public let engines: [Engine]
    public let disagreements: [Disagreement]
    public let notes: [String]
    public let error: Failure?

    enum CodingKeys: String, CodingKey {
        case id, state, phase, fraction, engine, transcript, engines, disagreements, notes, error
    }

    public init(id: String, state: String, phase: String, fraction: Double = 0,
                engine: String? = nil, transcript: String? = nil, engines: [Engine] = [],
                disagreements: [Disagreement] = [], notes: [String] = [], error: Failure? = nil) {
        self.id = id
        self.state = state
        self.phase = phase
        self.fraction = fraction
        self.engine = engine
        self.transcript = transcript
        self.engines = engines
        self.disagreements = disagreements
        self.notes = notes
        self.error = error
    }

    /// Lenient in everything but identity, so a bridge that adds a field or omits an empty
    /// list still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decode(String.self, forKey: .state)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? state
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction) ?? 0
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        engines = try c.decodeIfPresent([Engine].self, forKey: .engines) ?? []
        disagreements = try c.decodeIfPresent([Disagreement].self, forKey: .disagreements) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        error = try c.decodeIfPresent(Failure.self, forKey: .error)
    }
}

/// How a call to the Studio went wrong, sorted by the one question the fallback asks.
public enum StudioTransportError: Error, Equatable, Sendable {
    /// The Studio could not be reached, or cannot transcribe at all. → Fall back.
    case unavailable(String)
    /// The Studio answered and refused. → Show its answer; do not fall back.
    case refused(String)
    /// A poll went unanswered. The run may still be going. → Keep asking, within limits.
    case lostContact(String)

    /// Sort the bridge's answer to an UPLOAD.
    public static func forUpload(status: Int, body: String) -> StudioTransportError {
        let said = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 404:
            return .unavailable("the paired bridge doesn’t transcribe recordings yet")
        case 503:
            return .unavailable(said.isEmpty ? "the bridge’s transcription is switched off" : said)
        case 401:
            return .refused("the bridge didn’t accept this device’s token")
        case 413:
            return .refused(said.isEmpty ? "the recording is larger than the Studio accepts" : said)
        default:
            return .refused(said.isEmpty ? "the bridge answered \(status)" : said)
        }
    }

    /// A request that never got an answer: nothing reached the Studio.
    public static func forTransport(_ error: Error) -> StudioTransportError {
        .unavailable(error.localizedDescription)
    }
}

/// The seam between the transcriber and the network, so the whole Studio path — the
/// upload, the polling, the fallback — is tested against a fake.
public protocol StudioTranscriptionTransport: Sendable {
    /// Send the recording. The ONLY call that carries audio.
    func upload(fileAt url: URL, contentType: String, language: String,
                onProgress: @escaping @Sendable (Double) -> Void) async throws -> StudioRunStatus
    func status(id: String) async throws -> StudioRunStatus
    /// Best effort: the run is abandoned either way.
    func cancel(id: String) async
}

/// The type the bridge expects for a recording with this extension, or nil for one the
/// Studio does not read. Mirrors the bridge's intake sniff (`bridge/src/speech/intake.rs`),
/// which is the check that actually decides.
public enum AudioContentType {
    public static func forFile(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "wav", "wave": return "audio/wav"
        case "aif", "aiff", "aifc": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        default: return nil
        }
    }
}

/// The real transport: the paired bridge, over the connection the app already uses.
public struct URLSessionStudioTransport: StudioTranscriptionTransport {
    /// Resolved at each call, on the main actor, so a re-pairing takes effect at the next
    /// recording without rebuilding anything.
    public typealias EndpointProvider = @MainActor @Sendable () -> StudioEndpoint?

    private let endpoint: EndpointProvider
    private let session: URLSession

    public init(endpoint: @escaping EndpointProvider,
                session: URLSession = URLSessionStudioTransport.defaultSession) {
        self.endpoint = endpoint
        self.session = session
    }

    /// An upload may take minutes over a slow link, so the RESOURCE bound is hours; but it
    /// does not wait for connectivity, because an unreachable Studio must fail fast and let
    /// the fallback start now rather than in two minutes.
    public static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 3 * 3600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// THE ONE REQUEST THAT CARRIES AUDIO. Its destination is the paired bridge's own
    /// transcription route and nothing else; a test pins that.
    public static func uploadRequest(endpoint: StudioEndpoint, language: String,
                                     contentType: String) -> URLRequest {
        var request = Self.request(endpoint: endpoint, path: "jesse/transcriptions", method: "POST",
                                   query: [URLQueryItem(name: "language", value: language)])
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    static func request(endpoint: StudioEndpoint, path: String, method: String,
                        query: [URLQueryItem] = []) -> URLRequest {
        let url = endpoint.baseURL.appendingPathComponent(path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        var request = URLRequest(url: components?.url ?? url)
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func upload(fileAt url: URL, contentType: String, language: String,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws -> StudioRunStatus {
        guard let endpoint = await endpoint() else {
            throw StudioTransportError.unavailable("this device isn’t paired with a Jesse bridge")
        }
        let request = Self.uploadRequest(endpoint: endpoint, language: language, contentType: contentType)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: url,
                                                        delegate: UploadProgress(onProgress))
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            throw StudioTransportError.forTransport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 202 || status == 200 else {
            throw StudioTransportError.forUpload(status: status, body: String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(StudioRunStatus.self, from: data)
        } catch {
            throw StudioTransportError.refused("the bridge’s answer couldn’t be read")
        }
    }

    public func status(id: String) async throws -> StudioRunStatus {
        guard let endpoint = await endpoint() else {
            throw StudioTransportError.lostContact("this device is no longer paired")
        }
        var request = Self.request(endpoint: endpoint, path: "jesse/transcriptions/\(id)", method: "GET")
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            throw StudioTransportError.lostContact(error.localizedDescription)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            do {
                return try JSONDecoder().decode(StudioRunStatus.self, from: data)
            } catch {
                throw StudioTransportError.lostContact("the bridge’s answer couldn’t be read")
            }
        case 404:
            throw StudioTransportError.refused("the Studio no longer has this recording’s run — it restarted, or the result expired")
        case let other:
            throw StudioTransportError.lostContact("the bridge answered \(other)")
        }
    }

    public func cancel(id: String) async {
        guard let endpoint = await endpoint() else { return }
        let request = Self.request(endpoint: endpoint, path: "jesse/transcriptions/\(id)/cancel", method: "POST")
        _ = try? await session.data(for: request)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}

/// Upload progress, from the session's own byte count.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// THE STUDIO FIRST, this device only when the Studio cannot be reached.
public struct StudioFirstTranscriber: AudioFileTranscribing {
    public let studio: any StudioTranscriptionTransport
    public let onDevice: any AudioFileTranscribing
    /// How often a running Studio run is asked how it is doing.
    public let pollInterval: Duration
    /// How long a run may go unanswered before it is given up on and read here instead.
    /// Long enough to ride out a lift, a tunnel or a Wi-Fi handover; the run keeps going
    /// on the Studio meanwhile.
    public let contactTolerance: TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> TimeInterval

    public init(studio: any StudioTranscriptionTransport,
                onDevice: any AudioFileTranscribing = SpeechAnalyzerFileTranscriber(),
                pollInterval: Duration = .seconds(1),
                contactTolerance: TimeInterval = 90,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.studio = studio
        self.onDevice = onDevice
        self.pollInterval = pollInterval
        self.contactTolerance = contactTolerance
        self.sleep = sleep
        self.now = now
    }

    /// What the progress row and the header call the Studio.
    public static let studioName = "the Studio"

    public func transcribe(fileAt url: URL, locale: Locale,
                           onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws -> TranscriptionResult {
        guard let contentType = AudioContentType.forFile(url) else {
            return try await fallBack(because: "it doesn’t read .\(url.pathExtension) files",
                                      url: url, locale: locale, onProgress: onProgress)
        }
        let name = Self.studioName
        onProgress(TranscriptionUpdate(phase: .uploading, fraction: 0, engine: name))
        let accepted: StudioRunStatus
        do {
            accepted = try await studio.upload(fileAt: url, contentType: contentType,
                                               language: Self.languageTag(locale)) { fraction in
                onProgress(TranscriptionUpdate(phase: .uploading, fraction: fraction, engine: name))
            }
        } catch StudioTransportError.unavailable(let why) {
            return try await fallBack(because: why, url: url, locale: locale, onProgress: onProgress)
        } catch StudioTransportError.lostContact(let why) {
            return try await fallBack(because: why, url: url, locale: locale, onProgress: onProgress)
        } catch StudioTransportError.refused(let why) {
            throw TranscriptionFailure.studioRefused(reason: why)
        } catch is CancellationError {
            throw TranscriptionFailure.cancelled
        } catch {
            throw TranscriptionFailure.studioFailed(reason: error.localizedDescription)
        }
        return try await follow(accepted, url: url, locale: locale, onProgress: onProgress)
    }

    /// Poll the run to its end.
    private func follow(_ first: StudioRunStatus, url: URL, locale: Locale,
                        onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws -> TranscriptionResult {
        var status = first
        var lastContact = now()
        while true {
            if let update = Self.update(from: status) { onProgress(update) }
            switch status.state {
            case "done": return try Self.result(from: status)
            case "failed": throw Self.failure(from: status)
            case "cancelled": throw TranscriptionFailure.cancelled
            default: break
            }
            do {
                try await sleep(pollInterval)
            } catch {
                abandon(status.id)
                throw TranscriptionFailure.cancelled
            }
            do {
                status = try await studio.status(id: status.id)
                lastContact = now()
            } catch is CancellationError {
                abandon(status.id)
                throw TranscriptionFailure.cancelled
            } catch StudioTransportError.refused(let why) {
                throw TranscriptionFailure.studioFailed(reason: why)
            } catch {
                // Lost contact. The run is most likely still going on the Studio, so keep
                // asking — until the silence has gone on long enough that reading it here
                // is the better bet.
                if Task.isCancelled {
                    abandon(status.id)
                    throw TranscriptionFailure.cancelled
                }
                if now() - lastContact > contactTolerance {
                    abandon(status.id)
                    return try await fallBack(because: "contact with it was lost mid-transcription",
                                              url: url, locale: locale, onProgress: onProgress)
                }
            }
        }
    }

    /// Tell the Studio to stop, from outside the (possibly cancelled) task that asked.
    private func abandon(_ id: String) {
        let studio = self.studio
        Task.detached { await studio.cancel(id: id) }
    }

    /// Read it here instead, and SAY SO.
    private func fallBack(because why: String, url: URL, locale: Locale,
                          onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws -> TranscriptionResult {
        let here = TranscriptionPlace.thisDevice
        var result = try await onDevice.transcribe(fileAt: url, locale: locale) { update in
            var tagged = update
            if tagged.engine == nil { tagged.engine = here }
            onProgress(tagged)
        }
        result.notice = Self.fallbackNotice(reason: why, place: here)
        return result
    }

    /// The sentence the composer shows when the Studio was not used.
    public static func fallbackNotice(reason: String, place: String) -> String {
        var why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = why.last, ".!?".contains(last) { why.removeLast() }
        return "The Studio wasn’t used (\(why)), so this was transcribed on \(place) — expect more mistakes in names, numbers and dates."
    }

    /// The language as the bridge takes it: the bare language code.
    public static func languageTag(_ locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? locale.identifier
    }

    static func update(from status: StudioRunStatus) -> TranscriptionUpdate? {
        let phase: TranscriptionUpdate.Phase
        switch status.phase {
        case "queued": phase = .queued
        case "downloading_model": phase = .downloadingModel
        case "preparing": phase = .preparing
        case "conditioning": phase = .conditioning
        case "transcribing": phase = .transcribing
        case "second_reading": phase = .secondReading
        case "reconciling": phase = .reconciling
        default: return nil
        }
        let engine = status.engine.map { "\(studioName) · \($0)" } ?? studioName
        return TranscriptionUpdate(phase: phase, fraction: status.fraction, engine: engine)
    }

    static func result(from status: StudioRunStatus) throws -> TranscriptionResult {
        let text = (status.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionFailure.noSpeechFound }
        return TranscriptionResult(
            text: text,
            engine: engineDescription(status.engines),
            disagreements: status.disagreements.map {
                TranscriptDisagreement(startSeconds: Double($0.startMs) / 1000,
                                       endSeconds: Double($0.endMs) / 1000,
                                       primary: $0.primary,
                                       alternative: $0.alternative)
            },
            notes: status.notes)
    }

    /// "the Studio (Whisper large-v3, checked against Whisper large-v3 turbo)".
    static func engineDescription(_ engines: [StudioRunStatus.Engine]) -> String {
        let primary = engines.first { $0.role == "primary" }?.label
        let second = engines.first { $0.role == "second" }?.label
        switch (primary, second) {
        case let (p?, s?): return "\(studioName) (\(p), checked against \(s))"
        case let (p?, nil): return "\(studioName) (\(p))"
        default: return studioName
        }
    }

    static func failure(from status: StudioRunStatus) -> TranscriptionFailure {
        guard let error = status.error else {
            return .studioFailed(reason: "the run ended without saying why")
        }
        switch error.kind {
        case "no_speech": return .noSpeechFound
        default: return .studioFailed(reason: error.message)
        }
    }
}
