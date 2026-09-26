import Foundation
import Observation

// THE WHOLE OFFLINE ANSWER, END TO END, IN ONE PLACE THE APPS CALL.
//
// Gate, retrieve, answer, record. The two composers contribute a routing hook and a
// badge; everything they would otherwise each have to get right — which questions are
// refused, which folder is excluded, how big the prompt may be, what happens when the
// model errors — is here, once, and every piece of it is a seam a test drives.
//
// NOTHING ON THIS PATH TOUCHES THE NETWORK and nothing writes to the vault. The index
// is read, the model is asked, a row is appended to an in-memory diagnostics list, and
// that is the complete set of side effects.

/// The one toggle, and the one measured number the budget is derived from.
///
/// `UserDefaults` rather than a store of its own because both values are single scalars
/// a person sets from a Settings row, which is exactly what `UserDefaults` is for, and
/// because the probe that produces the number is pressed on a diagnostics screen in a
/// different object entirely.
/// `@unchecked Sendable`: the only stored property is a `UserDefaults`, which is
/// documented as thread-safe but is not annotated `Sendable`. The same judgement every
/// other defaults-backed store in this app makes.
public struct OfflineLookupSettings: @unchecked Sendable {
    public static let enabledKey = "vault.offlineLookup.enabled"
    public static let measuredPromptKey = "vault.offlineLookup.measuredPromptCharacters"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// On unless it has been turned off.
    ///
    /// The documented default is "on when the folder is set", and this is that: the
    /// route ALSO requires a folder (`OfflineLookupRouting.route`), so a device with no
    /// folder cannot take the on-device path whatever this says. Encoding the folder
    /// condition here as well would be the same rule in two places.
    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// The largest prompt the on-device model accepted, as `ModelProbe` measured it on
    /// THIS device. Nil until the diagnostics screen's probe has been run.
    ///
    /// `ModelProbeReport` held this only in the report struct, which meant the number
    /// existed for as long as the screen was on screen and then was gone. The budget
    /// needs it on every offline question, so the probe persists it here.
    public var measuredPromptCharacters: Int? {
        get {
            let value = defaults.integer(forKey: Self.measuredPromptKey)
            return value > 0 ? value : nil
        }
        nonmutating set {
            if let newValue, newValue > 0 {
                defaults.set(newValue, forKey: Self.measuredPromptKey)
            } else {
                defaults.removeObject(forKey: Self.measuredPromptKey)
            }
        }
    }

    /// The budget this device's measurement implies.
    public var budget: VaultRetrievalBudget {
        VaultRetrievalBudget.forMeasuredPrompt(measuredPromptCharacters)
    }

    /// The Settings row's second line.
    public var description: String {
        VaultRetrievalBudget.describe(measuredPromptCharacters)
    }
}

/// One offline question, as the diagnostics list shows it.
public struct OfflineLookupRecord: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let question: String
    /// What the gate decided, in one phrase.
    public let gateVerdict: String
    public let hitCount: Int
    public let chunkCount: Int
    /// Characters of note text actually put in front of the model.
    public let characters: Int
    public let elapsed: TimeInterval
    /// What came out.
    public let outcome: String

    public init(id: UUID = UUID(), question: String, gateVerdict: String,
                hitCount: Int, chunkCount: Int, characters: Int,
                elapsed: TimeInterval, outcome: String) {
        self.id = id
        self.question = question
        self.gateVerdict = gateVerdict
        self.hitCount = hitCount
        self.chunkCount = chunkCount
        self.characters = characters
        self.elapsed = elapsed
        self.outcome = outcome
    }

    /// The monospaced line the diagnostics screen draws.
    public var line: String {
        String(format: "%@ — %@ · %d hits · %d chunks · %d chars · %.1f s · %@",
               question.count > 48 ? String(question.prefix(47)) + "…" : question,
               gateVerdict, hitCount, chunkCount, characters, elapsed, outcome)
    }
}

/// The last few offline questions. In memory only, deliberately: this is a debugging
/// aid for a feature that reads personal notes, and a log of what someone asked their
/// own vault is not something to leave on disk for a support flow nobody has.
@MainActor
@Observable
public final class OfflineLookupDiagnostics {
    /// See the GOTCHA in this target's `Package.swift` comment.
    nonisolated deinit {}

    public static let shared = OfflineLookupDiagnostics()
    public static let capacity = 10

    /// Newest first.
    public private(set) var records: [OfflineLookupRecord] = []

    public init() {}

    public func record(_ entry: OfflineLookupRecord) {
        records.insert(entry, at: 0)
        if records.count > Self.capacity {
            records.removeLast(records.count - Self.capacity)
        }
    }

    public func clear() { records = [] }
}

/// What a composer asks of the on-device path: where a send goes, and what the device makes
/// of a question it takes.
///
/// A protocol over the two calls the apps actually make, so a test can drive the whole send
/// path — routed offline, answered, refused, queued — without a vault folder, an index, or a
/// model on the host. The production conformance is `OfflineAnswerService` below and there is
/// no other; this exists to make the app's own behaviour testable, not to invite a second
/// implementation of the offline pipeline.
@MainActor
public protocol OfflineAnswering: AnyObject {
    /// The route one send takes.
    func route(reachability: BridgeReachabilityState) -> OfflineSendRoute
    /// Answer one question from the copy of the vault on this device.
    func answer(_ question: String) async -> VaultAnswerOutcome
}

/// Gate, retrieve, answer.
@MainActor
public final class OfflineAnswerService: OfflineAnswering {
    /// See the GOTCHA in this target's `Package.swift` comment.
    nonisolated deinit {}

    /// The app's one service. One `FoundationVaultAnswerSession`, which is now the only
    /// thing on this path that talks to a model at all: the gate is rules, so a refused
    /// question never opens a session.
    public static let shared: OfflineAnswerService = {
        OfflineAnswerService(generator: FoundationVaultAnswerSession())
    }()

    private let source: VaultIndexSource
    private let generator: any VaultAnswerGenerating
    private let embedding: any ChunkEmbedding
    private let expander: any VaultQueryExpanding
    private let settings: OfflineLookupSettings
    private let diagnostics: OfflineLookupDiagnostics
    private let timeLimit: TimeInterval
    private let now: @Sendable () -> Date

    public init(source: VaultIndexSource = .shared,
                generator: any VaultAnswerGenerating,
                embedding: any ChunkEmbedding = NaturalLanguageChunkEmbedding(),
                expander: any VaultQueryExpanding = NoVaultExpansion(),
                settings: OfflineLookupSettings = OfflineLookupSettings(),
                diagnostics: OfflineLookupDiagnostics = .shared,
                timeLimit: TimeInterval = VaultAnswerer.defaultTimeLimit,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.generator = generator
        self.embedding = embedding
        self.expander = expander
        self.settings = settings
        self.diagnostics = diagnostics
        self.timeLimit = timeLimit
        self.now = now
    }

    /// Whether this device can take the on-device route at all. Read by the composer's
    /// routing decision, and the reason a device with no model behaves exactly as it
    /// did before this feature existed.
    public var isModelAvailable: Bool { generator.isAvailable }

    /// Whether the toggle is on.
    public var isEnabled: Bool { settings.isEnabled }

    /// Whether this device holds a vault folder.
    public var hasVaultFolder: Bool { source.root != nil }

    /// The route one send takes.
    ///
    /// REACHABILITY AND THE TOGGLE FIRST, and on their own, because the other two inputs
    /// are not free: `hasVaultFolder` resolves a security-scoped bookmark and
    /// `isModelAvailable` asks the system about the model. This is called on EVERY send,
    /// and the overwhelmingly common case is a reachable bridge, which must not pay for
    /// either. Swift evaluates all four arguments before the pure rule can short-circuit
    /// them, so the short-circuit has to be here.
    public func route(reachability: BridgeReachabilityState) -> OfflineSendRoute {
        guard reachability == .unreachable, isEnabled else { return .bridge }
        return OfflineLookupRouting.route(reachability: reachability,
                                          hasVaultFolder: hasVaultFolder,
                                          isEnabled: true,
                                          modelAvailable: isModelAvailable)
    }

    /// Answer one question from the copy of the vault on this device.
    ///
    /// Never throws, and every exit records a diagnostics row — including the cheap
    /// refusals, because "why did it queue that?" is the question the list exists to
    /// answer.
    public func answer(_ question: String) async -> VaultAnswerOutcome {
        let started = now()
        func finish(_ outcome: VaultAnswerOutcome, gate: String,
                    hits: Int = 0, chunks: Int = 0, characters: Int = 0)
            -> VaultAnswerOutcome {
            diagnostics.record(OfflineLookupRecord(
                question: question, gateVerdict: gate, hitCount: hits,
                chunkCount: chunks, characters: characters,
                elapsed: now().timeIntervalSince(started), outcome: outcome.label))
            return outcome
        }

        // 1. The gate, which is the whole gate: rules, free, deterministic.
        if case .refused(let refusal) = LookupGate.rule(question) {
            return finish(.unanswered(.gateRefused(refusal)), gate: refusal.rule)
        }
        // 2. The index. No folder, or an index that will not open, is "no hits" rather
        //    than an error: from the composer's side the two are one outcome.
        guard let index = (try? source.index()) ?? nil else {
            return finish(.unanswered(.noHits), gate: "passed")
        }

        let retriever = VaultRetriever(index: index, expander: expander, embedding: embedding)
        let retrieved = await retriever.retrieve(question: question, budget: settings.budget)
        guard !retrieved.chunks.isEmpty else {
            return finish(.unanswered(.noHits), gate: "passed", hits: retrieved.hitCount)
        }

        let outcome = await VaultAnswerer(generator: generator, timeLimit: timeLimit)
            .answer(question: question, chunks: retrieved.chunks)
        return finish(outcome, gate: "passed", hits: retrieved.hitCount,
                      chunks: retrieved.chunks.count, characters: retrieved.characters)
    }

    /// Warm the model when a composer on an unreachable device gains focus. Silent
    /// no-op everywhere else.
    public func prewarm() {
        (generator as? FoundationVaultAnswerSession)?.prewarm()
    }
}
