import Foundation
import Security
import JesseCore
import JesseDietDisplay
// Re-export the shared networking layer so the rest of the iOS target (app + tests) sees
// JesseConfig, JesseReply, JesseError, the wire/result types, DietSnapshot, the SSE
// parser, and the concrete JesseBridgeClient by their bare names — exactly as before this
// surface moved into the JesseNetworking package.
@_exported import JesseNetworking

// The iOS bridge client is now a THIN platform layer over the shared JesseBridgeClient.
// Everything view-free and health-free — endpoint/URL construction, the bearer-auth
// request builder, the SSE parser, the wire types, error mapping, config, and the diet
// snapshot models — lives once in JesseNetworking and is shared with the macOS app. This
// file adds only the iOS-specific concerns: the per-turn `health_context` body assembled
// from HealthKit, and the iOS-only send/fulfill machinery on top of that shared client.

/// A file the user picked to send with a turn. `data` is the raw bytes; the
/// client base64-encodes it for the wire. Held in the composer as a removable
/// chip and cleared after a successful send.
struct JesseAttachment: Identifiable, Equatable {
    let id = UUID()
    var filename: String
    var mime: String
    var data: Data

    var byteCount: Int { data.count }
    var isImage: Bool { mime.hasPrefix("image/") }

    /// Detect a whitelisted MIME from the file's magic bytes — the same sniff
    /// the bridge runs — so the declared type always matches the actual bytes
    /// (a PhotosPicker item may be HEIC even when it looks like a JPEG). Returns
    /// nil for anything not on the whitelist.
    ///
    /// Explicitly `nonisolated`: a pure function over its `Data` argument, called
    /// from the `nonisolated` `AttachmentDownscaler.fitToCap`. Under this module's
    /// MainActor default isolation the compiler's `nonisolated` inference for it is
    /// fragile (it can flip to main-actor-isolated as unrelated code in this file
    /// changes), so pin it here rather than rely on inference.
    nonisolated static func sniffMime(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        func match(_ ascii: String, at off: Int = 0) -> Bool {
            let sig = Array(ascii.utf8)
            guard b.count >= off + sig.count else { return false }
            return Array(b[off..<off + sig.count]) == sig
        }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if match("GIF87a") || match("GIF89a") { return "image/gif" }
        if match("%PDF-") { return "application/pdf" }
        if match("RIFF") && match("WEBP", at: 8) { return "image/webp" }
        if match("ftyp", at: 4) {
            let brand = b.count >= 12 ? Array(b[8..<12]) : []
            let brands = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
            if brands.contains(where: { Array($0.utf8) == brand }) { return "image/heic" }
        }
        return nil
    }

    /// The on-disk extension matching a whitelisted MIME (for display names).
    static func fileExtension(forMime mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "application/pdf": return "pdf"
        default: return "bin"
        }
    }
}

/// Client-side attachment limits. Mirror the bridge's server-side caps
/// (`JESSE_MAX_ATTACHMENT*`) so a file that would be rejected is caught before
/// it's uploaded; the server still enforces them as the authority.
enum AttachmentLimits {
    static let maxCount = 4
    static let maxBytesPerFile = 10 * 1024 * 1024
    static let maxBytesTotal = 20 * 1024 * 1024

    /// MIME types the bridge will accept (magic-byte-verified server-side).
    static let allowedMimes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/heic",
        "application/pdf",
    ]

    /// Validate adding `candidate` to the `existing` set. Returns a
    /// user-facing error message if it should be rejected, else nil.
    static func rejectionReason(adding candidate: JesseAttachment,
                                to existing: [JesseAttachment]) -> String? {
        if existing.count >= maxCount {
            return "You can attach at most \(maxCount) files."
        }
        if !allowedMimes.contains(candidate.mime) {
            return "“\(candidate.filename)” isn’t a supported type (images or PDF only)."
        }
        if candidate.byteCount > maxBytesPerFile {
            return "“\(candidate.filename)” is too large (max \(maxBytesPerFile / 1_048_576) MB per file)."
        }
        let total = existing.reduce(0) { $0 + $1.byteCount } + candidate.byteCount
        if total > maxBytesTotal {
            return "Attachments exceed the \(maxBytesTotal / 1_048_576) MB total limit."
        }
        return nil
    }
}

/// The two bridge calls the coordinator drives a turn with, plus the iOS-only surface
/// (health fulfillment, diet snapshot, push registration). Pulled behind a protocol
/// purely so a fake can exercise the poll loop in tests without a server; `JesseClient`
/// is the only production conformer.
///
/// `Sendable` because the coordinator races a turn's stream and poll in two concurrent
/// child tasks (`consume`), so the client value crosses into them.
protocol JesseClientProtocol: Sendable {
    func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseAttachment]) async throws -> JesseSendResult
    /// Send carrying the outbox idempotency key (`request_id`). Defaulted in the
    /// extension to forward to the plain `send` (dropping the id).
    func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseAttachment], requestId: UUID?) async throws -> JesseSendResult
    /// Fulfill a `JESSE_NEEDS_HEALTH` directive and re-send the SAME turn on the SAME
    /// thread with the requested data attached (bypassing the classifier).
    func sendFulfilling(_ request: NeedsHealthRequest, mode: JesseMode, text: String,
                        sessionId: String?, voice: Bool, instructions: String?,
                        floorOverride: String?) async throws -> JesseSendResult
    func result(jobId: String) async throws -> JesseResultState
    /// Fetch the diet snapshot (`GET /jesse/diet`) for the Health tab. Throws a
    /// `DietFetchError` distinguishing offline / auth / an older bridge / a bad date /
    /// a broken diet-today / a decode failure.
    func fetchDietSnapshot(date: String?) async throws -> DietSnapshot
    /// Probe `GET /health` and parse the bridge's reported version.
    func health() async throws -> BridgeHealth
    /// Best-effort request to stop an in-flight turn server-side. Idempotent.
    func cancelJob(jobId: String) async throws
    /// Delete a thread's remote Claude Code session server-side. Idempotent (404 → ok).
    func deleteSession(_ sessionId: String) async throws
    /// Live token stream for a running turn (`GET /jesse/stream/{job_id}`).
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error>
    /// Register (idempotent upsert) this phone's APNs device token with the bridge.
    func registerDevice(token: String) async throws
    /// Ask the bridge to push when `jobId` completes. Best-effort and idempotent.
    func notifyOnComplete(jobId: String) async throws
    /// Ask the bridge to mint a short conversation title from `digest`. Returns the
    /// title, or nil for ANY failure — it NEVER throws to the UI.
    func title(forDigest digest: String) async -> String?
}

extension JesseClientProtocol {
    // Default for fakes/callers that don't carry an idempotency key: forward to the
    // plain `send`, dropping `requestId`.
    func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseAttachment], requestId: UUID?) async throws -> JesseSendResult {
        try await send(mode: mode, text: text, sessionId: sessionId, voice: voice,
                       instructions: instructions, floorOverride: floorOverride,
                       attachments: attachments)
    }
    // Default for fakes that don't exercise the metrics/retry channel: re-send the SAME
    // turn via `send` (dropping the directive).
    func sendFulfilling(_ request: NeedsHealthRequest, mode: JesseMode, text: String,
                        sessionId: String?, voice: Bool, instructions: String?,
                        floorOverride: String?) async throws -> JesseSendResult {
        try await send(mode: mode, text: text, sessionId: sessionId, voice: voice,
                       instructions: instructions, floorOverride: floorOverride, attachments: [])
    }
    // Default "no version" so existing conformers (the test fakes) need not implement
    // the health probe.
    func health() async throws -> BridgeHealth { BridgeHealth(version: nil) }
    // Default "old bridge": a fake that doesn't model the diet endpoint behaves exactly
    // like a bridge that predates it (404 → the "bridge update needed" empty state).
    func fetchDietSnapshot(date: String?) async throws -> DietSnapshot { throw DietFetchError.endpointMissing }
    // Convenience: today's snapshot (the un-dated request).
    func fetchDietSnapshot() async throws -> DietSnapshot { try await fetchDietSnapshot(date: nil) }
    // Default no-ops so existing conformers (the test fakes) need not implement the push
    // methods; only the production `JesseClient` does the real calls.
    func registerDevice(token: String) async throws {}
    func notifyOnComplete(jobId: String) async throws {}
    // Default no-op so fakes that don't exercise remote session deletion behave like a
    // bridge that always succeeds.
    func deleteSession(_ sessionId: String) async throws {}
    // Default "no title": a fake that doesn't opt into titling degrades exactly like a
    // bridge without the endpoint (the row keeps its derived title).
    func title(forDigest digest: String) async -> String? { nil }
}

/// The production `JesseClientProtocol`: the shared `JesseBridgeClient` plus the iOS-only
/// `health_context` assembly. Every network call flows through `bridge`; this type owns
/// only the classify-then-attach decision and the HealthKit/diet block composition.
// The iOS client satisfies the shared dashboard's narrow fetch seam (it already has
// `fetchDietSnapshot`), so the Health tab injects it unchanged as before the display
// layer moved into JesseDietDisplay.
extension JesseClient: DietSnapshotProviding {}

struct JesseClient: JesseClientProtocol {
    var config: JesseConfig

    /// The one shared bridge client — endpoint construction, the request builder, the SSE
    /// parser, and error mapping all live in it (and in the macOS app's copy of it).
    let bridge: JesseBridgeClient

    /// Reads recent workouts + daily-summary metrics for the per-turn `health_context`
    /// block. Defaults to the live provider; injectable so tests drive it with a fake.
    let healthProvider: any HealthContextProviding

    /// Whether the "attach health context" feature is on. Read at send time.
    let isHealthContextEnabled: @Sendable () -> Bool

    /// Decides whether a turn's message is health-related, so the block is attached only
    /// when relevant (classify-then-attach).
    let healthClassifier: any HealthRelevanceClassifying

    /// The highest meal-corrections `corrections_seq` the app has taken responsibility
    /// for, read at send time and attached to every turn so the bridge can prune its queue.
    let mealCorrectionsAck: @Sendable () -> Int?

    init(config: JesseConfig,
         session: URLSession = JesseBridgeClient.boundedSession,
         streamSession: URLSession? = nil,
         healthProvider: any HealthContextProviding = HealthContextProvider(),
         isHealthContextEnabled: @escaping @Sendable () -> Bool = { HealthContextSettings.isEnabled },
         healthClassifier: any HealthRelevanceClassifying = UnionHealthClassifier(),
         mealCorrectionsAck: @escaping @Sendable () -> Int? = { MealCorrectionsAckStore.pendingSeq }) {
        self.config = config
        self.bridge = JesseBridgeClient(config: config, session: session, streamSession: streamSession)
        self.healthProvider = healthProvider
        self.isHealthContextEnabled = isHealthContextEnabled
        self.healthClassifier = healthClassifier
        self.mealCorrectionsAck = mealCorrectionsAck
    }

    // MARK: - Send (with the iOS health_context body)

    /// Pass `sessionId` to continue a thread; `voice` asks for a SPOKEN: summary. A
    /// non-empty `instructions` overrides the bridge's built-in wrapper; a non-empty
    /// `floorOverride` rewords the always-prepended safety floor. Returns either the
    /// inline reply or, if the turn outran the grace window, a `running` job id to poll.
    func send(mode: JesseMode, text: String,
              sessionId: String? = nil, voice: Bool = false,
              instructions: String? = nil,
              floorOverride: String? = nil,
              attachments: [JesseAttachment] = []) async throws -> JesseSendResult {
        try await send(mode: mode, text: text, sessionId: sessionId, voice: voice,
                       instructions: instructions, floorOverride: floorOverride,
                       attachments: attachments, requestId: nil)
    }

    func send(mode: JesseMode, text: String,
              sessionId: String?, voice: Bool,
              instructions: String?,
              floorOverride: String?,
              attachments: [JesseAttachment],
              requestId: UUID?) async throws -> JesseSendResult {
        // Classify-then-attach, in the request-building path so EVERY turn — typed, Siri,
        // and the watch relay — inherits it. The block is attached ONLY when the master
        // toggle is on AND the message classifies as health-related. Best-effort
        // throughout: resolution returns nil on no-data/error/timeout, so a turn is never
        // blocked or broken.
        let enabled = isHealthContextEnabled()
        let relevant = enabled ? await healthClassifier.isRelevant(text) : false
        let attach = HealthContextGate.shouldAttach(enabled: enabled, relevant: relevant)
        // Resolve the HealthKit block and the diet nutrient rollup concurrently so the
        // extra diet GET doesn't add serial latency, then compose them into the one
        // health_context.
        async let healthBlock = HealthContextResolver.resolve(
            enabled: attach, provider: healthProvider, now: Date())
        async let dietRollup = dietRollupBlock(enabled: attach)
        let healthContext = DietContextComposer.combine(
            healthBlock: await healthBlock, dietRollup: await dietRollup)
        let request = Self.makeRequest(mode: mode, text: text, sessionId: sessionId,
                                       voice: voice, instructions: instructions,
                                       floorOverride: floorOverride,
                                       attachments: attachments,
                                       healthContext: healthContext,
                                       mealCorrectionsAck: mealCorrectionsAck(),
                                       requestId: requestId)
        return try await bridge.sendPrepared(request)
    }

    /// The compact multi-window nutrient rollup for the coach's `health_context`, or nil.
    /// Best-effort and gated on the same health-relevance decision as the HealthKit block.
    private func dietRollupBlock(enabled: Bool) async -> String? {
        guard enabled else { return nil }
        guard let snapshot = try? await fetchDietSnapshot() else { return nil }
        guard let series = snapshot.nutrientSeries, NutrientTrends.isAvailable(series) else { return nil }
        let text = NutrientTrends.coachRollup(series: series, targets: snapshot.today.targets,
                                              meals: snapshot.today.meals,
                                              ownerName: PromptStore.ownerName)
        return text.isEmpty ? nil : text
    }

    func sendFulfilling(_ requested: NeedsHealthRequest, mode: JesseMode, text: String,
                        sessionId: String?, voice: Bool,
                        instructions: String?, floorOverride: String?) async throws -> JesseSendResult {
        // A retry answering a JESSE_NEEDS_HEALTH directive: bypass the classifier, fulfill
        // the request from the provider (honoring the master toggle), and re-send the SAME
        // text on the SAME thread with the data + the flags. When it can't be fulfilled we
        // still re-send — marked unavailable, no block — so the agent answers from vault
        // data and never re-requests (no loop).
        let outgoing = await fulfill(requested)
        let request = Self.makeRequest(mode: mode, text: text, sessionId: sessionId,
                                       voice: voice, instructions: instructions,
                                       floorOverride: floorOverride,
                                       attachments: [],
                                       healthContext: outgoing.block,
                                       healthContextRequested: outgoing.requested ? true : nil,
                                       healthContextUnavailable: outgoing.unavailable ? true : nil,
                                       mealCorrectionsAck: mealCorrectionsAck())
        return try await bridge.sendPrepared(request)
    }

    /// Fulfill a validated needs-health request from the health provider, honoring the
    /// master toggle. Off, or nothing gathered → `unavailable` (no block).
    private func fulfill(_ request: NeedsHealthRequest) async -> OutgoingHealthContext {
        guard isHealthContextEnabled() else {
            return OutgoingHealthContext(block: nil, requested: false, unavailable: true)
        }
        let snapshot = request.sections.isEmpty ? HealthSnapshot.empty : await healthProvider.snapshot()
        var series: [RequestableMetric: [MetricSeriesPoint]] = [:]
        for m in request.metrics {
            series[m.metric] = await healthProvider.series(for: m.metric, windowDays: m.windowDays)
        }
        let block = HealthRequestFulfiller.block(request: request, snapshot: snapshot,
                                                 series: series, now: Date())
        if let block {
            return OutgoingHealthContext(block: block, requested: true, unavailable: false)
        }
        return OutgoingHealthContext(block: nil, requested: false, unavailable: true)
    }

    // MARK: - Straight forwards to the shared client

    /// The bounded session the short request/response calls go through, and the
    /// long-lived session the SSE stream uses — surfaced from the shared client so the
    /// integration tests can assert the session-separation invariant.
    var session: URLSession { bridge.session }
    var streamSession: URLSession { bridge.streamSession }

    func result(jobId: String) async throws -> JesseResultState {
        try await bridge.result(jobId: jobId)
    }

    func health() async throws -> BridgeHealth {
        try await bridge.health()
    }

    func cancelJob(jobId: String) async throws {
        try await bridge.cancelJob(jobId: jobId)
    }

    func deleteSession(_ sessionId: String) async throws {
        try await bridge.deleteSession(sessionId)
    }

    func registerDevice(token: String) async throws {
        try await bridge.registerDevice(token: token)
    }

    func notifyOnComplete(jobId: String) async throws {
        try await bridge.notifyOnComplete(jobId: jobId)
    }

    func title(forDigest digest: String) async -> String? {
        await bridge.title(text: digest, sessionId: nil)
    }

    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        bridge.stream(jobId: jobId)
    }

    func fetchDietSnapshot(date: String? = nil) async throws -> DietSnapshot {
        try await bridge.fetchDietSnapshot(date: date)
    }

    /// Fetch the bridge's built-in Ask/Tell wrapper defaults (`GET /jesse/prompts`). Used
    /// by Settings to populate the editors and to reset a field to the current default.
    func fetchPrompts() async throws -> PromptDefaults {
        try await bridge.fetchPrompts()
    }

    // MARK: - Request building (iOS attachment mapping over the shared builder)

    /// Build the `POST /jesse` request from the iOS composer's `[JesseAttachment]` — the
    /// one iOS-specific step, base64-encoding each attachment for the wire — then hand off
    /// to the shared builder for the omit-when-default normalization. Kept here (with the
    /// same signature the app and wire tests already use) so the attachment encoding stays
    /// unit-testable while the byte-shape logic lives once in `JesseBridgeClient`.
    static func makeRequest(mode: JesseMode, text: String, sessionId: String?,
                            voice: Bool, instructions: String?,
                            floorOverride: String?,
                            attachments: [JesseAttachment],
                            healthContext: String? = nil,
                            healthContextRequested: Bool? = nil,
                            healthContextUnavailable: Bool? = nil,
                            mealCorrectionsAck: Int? = nil,
                            requestId: UUID? = nil) -> JesseRequest {
        JesseBridgeClient.makeRequest(
            mode: mode, text: text, sessionId: sessionId, voice: voice,
            instructions: instructions, floorOverride: floorOverride,
            // Base64-in-JSON, re-validated by the bridge for type and size.
            attachments: attachments.map {
                JesseRequest.Attachment(filename: $0.filename, mime: $0.mime,
                                        dataBase64: $0.data.base64EncodedString())
            },
            healthContext: healthContext,
            healthContextRequested: healthContextRequested,
            healthContextUnavailable: healthContextUnavailable,
            mealCorrectionsAck: mealCorrectionsAck,
            // Encode the outbox idempotency key as its string form; nil drops the field.
            requestId: requestId?.uuidString)
    }

    // MARK: - Pure encode/decode forwards (the wire-contract test surface)

    // These re-export the shared static helpers under the name the iOS wire tests already
    // use. The implementations live once in `JesseBridgeClient`; these are one-line
    // forwards so `JesseClient.decodeX(...)` keeps resolving.
    static func encodeBody<T: Encodable>(_ value: T) throws -> Data {
        try JesseBridgeClient.encodeBody(value)
    }
    static func decodeSend(data: Data, resp: URLResponse) throws -> JesseSendResult {
        try JesseBridgeClient.decodeSend(data: data, resp: resp)
    }
    static func decodeResult(data: Data, resp: URLResponse) throws -> JesseResultState {
        try JesseBridgeClient.decodeResult(data: data, resp: resp)
    }
    static func decodeHealth(data: Data, resp: URLResponse) throws -> BridgeHealth {
        try JesseBridgeClient.decodeHealth(data: data, resp: resp)
    }
    static func decodePrompts(data: Data, resp: URLResponse) throws -> PromptDefaults {
        try JesseBridgeClient.decodePrompts(data: data, resp: resp)
    }
    static func decodeDiet(data: Data, resp: URLResponse) throws -> DietSnapshot {
        try JesseBridgeClient.decodeDiet(data: data, resp: resp)
    }
    static func decodeStreamFrame(event: String, data: String) -> JesseStreamEvent? {
        SSEParser.decodeStreamFrame(event: event, data: data)
    }
    static func framesFromLines<S: Sequence<String>>(_ lines: S) -> [JesseStreamEvent] {
        SSEParser.framesFromLines(lines)
    }
}

// MARK: - Reply directives (iOS validators)

extension JesseReply {
    /// The validated needs-health request this reply asks for, or nil if there is no
    /// `needs_health` directive or it fails the contract (unknown metric, window out of
    /// range, >4 metrics) — an invalid request is never partially fulfilled.
    var needsHealthRequest: NeedsHealthRequest? {
        guard let nh = directives?.needsHealth else { return nil }
        return NeedsHealthRequest.validated(
            sections: nh.sections ?? [],
            metrics: (nh.metrics ?? []).map { (metric: $0.metric, windowDays: $0.windowDays) })
    }

    /// The validated meals this reply logged, or nil if there is no `meal_log` directive
    /// or it fails the contract. (v1 view; the v2 correction flow uses `mealBatch`.)
    var mealsToLog: [Meal]? {
        guard let ml = directives?.mealLog else { return nil }
        return MealLogParser.meals(from: ml)
    }

    /// The validated v2 meal-events batch this reply/turn delivered — upserts + retracts +
    /// the `corrections_seq` to ack — or nil if there is no `meal_log` directive or it
    /// fails the contract. An invalid block is never partially applied.
    var mealBatch: MealBatch? {
        guard let ml = directives?.mealLog else { return nil }
        return MealLogParser.batch(from: ml)
    }
}

// MARK: - Keychain-backed config store

/// The iOS facade over the shared `KeychainConfigStore` (service `com.tag1.jesse`). Keeps
/// the static `load`/`save` entry points and the three injectable `SecItem*` seams the app
/// and tests already use, while the actual Keychain read/write logic lives once in the
/// package (and is shared with the macOS app's config store).
enum ConfigStore {
    private static let service = "com.tag1.jesse"

    /// Seams for the three Keychain primitives so a test can force an `OSStatus` or supply
    /// an in-memory backend without a real Keychain. Production uses the `SecItem*`
    /// functions directly.
    nonisolated(unsafe) static var addItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    nonisolated(unsafe) static var copyItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    nonisolated(unsafe) static var deleteItem: (CFDictionary) -> OSStatus = SecItemDelete

    /// A fresh store bound to the CURRENT seam values, so a test that reassigns a seam
    /// after import still routes through its stub.
    private static var store: KeychainConfigStore {
        KeychainConfigStore(service: service, add: addItem, copy: copyItem, delete: deleteItem)
    }

    static func load() -> JesseConfig { store.load() }

    /// Persist the config. Returns `false` if any field's write failed (e.g. the Keychain
    /// was locked), so a caller can surface "couldn't save the token".
    @discardableResult
    static func save(_ c: JesseConfig) -> Bool { store.save(c) }
}

// MARK: - Version surfacing

/// The app's own version, read from the bundle — never hardcoded, so it always matches
/// `CFBundleShortVersionString`/`CFBundleVersion`.
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
    /// e.g. "1.0 (2)".
    static var display: String { "\(short) (\(build))" }
}

/// A minimal SemVer triple (`major.minor.patch`) for comparison only. Pre-release and
/// build metadata are ignored. A missing minor/patch reads as `0`. Anything that isn't a
/// clean numeric triple parses to `nil` rather than guessing.
struct SemVer: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        let core = raw.trimmingCharacters(in: .whitespaces)
            .prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums = [0, 0, 0]
        for (i, p) in parts.enumerated() {
            guard let n = Int(p), n >= 0 else { return nil }
            nums[i] = n
        }
        (major, minor, patch) = (nums[0], nums[1], nums[2])
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// Compares the running bridge version against the minimum this app build is designed
/// for. Pure and testable — no I/O. Drives a **non-blocking** advisory in Settings only.
enum BridgeCompatibility {
    /// The oldest bridge this app build expects. Bump when the app starts relying on a
    /// bridge behavior newer than the value here.
    static let minimumBridgeVersion = "0.7.0"

    /// True iff `bridgeVersion` is present, parseable, AND strictly older than `minimum`.
    static func isOutdated(bridgeVersion: String?,
                           minimum: String = minimumBridgeVersion) -> Bool {
        guard let bridgeVersion,
              let running = SemVer(bridgeVersion),
              let floor = SemVer(minimum) else { return false }
        return running < floor
    }
}

/// Persists the last-seen bridge version (from `GET /health`) so Settings can show it even
/// before a fresh probe returns. Backed by `UserDefaults`; the store is injectable purely
/// so a test can point it at a scratch suite.
enum BridgeVersionStore {
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    private static let key = "bridgeVersion"

    /// The last version the bridge reported, or nil if never fetched.
    static var current: String? { defaults.string(forKey: key) }

    static func set(_ version: String?) {
        if let version, !version.isEmpty {
            defaults.set(version, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Probe health via `client` and store the reported version. Returns the value now
    /// stored (the fresh version on success, else the previously-stored one — a failed
    /// probe never clobbers a known-good version).
    @discardableResult
    static func refresh(using client: JesseClientProtocol) async -> String? {
        if let health = try? await client.health(), let v = health.version, !v.isEmpty {
            set(v)
            return v
        }
        return current
    }
}
