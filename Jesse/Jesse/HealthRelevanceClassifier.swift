import Foundation

// Decides whether a turn's message is health-related, so the app attaches the
// device health-context block ONLY when it's relevant — instead of on every turn.
//
// Correctness invariant (see the bridge's directive channel): the classifier only
// optimizes token cost. A wrong "not relevant" never produces a wrong answer — the
// agent can still ask for the data via JESSE_NEEDS_HEALTH and the app fulfills it
// on a retry. So the classifier is biased toward attaching (a union of two tiers),
// and a miss costs at most one slower turn.

/// The seam the send path classifies through. Async because Tier 1 is an on-device
/// model call; Tier 0 answers instantly. `Sendable` so it can live on the
/// `JesseClient` value and cross to the send task.
protocol HealthRelevanceClassifying: Sendable {
    func isRelevant(_ text: String) async -> Bool
}

// MARK: - Tier 0 — keyword floor (always available, pure, tested)

/// The always-available keyword floor. Foundation-only and pure, so it is fully
/// unit-tested. Case-insensitive and **word-boundary aware** (matches whole
/// alphanumeric tokens, so "brunch" never fires "run" and "restaurant" never fires
/// "rest"). A single hit is enough — biased toward attaching. The list mirrors the
/// health surface the block reports; keep it maintained.
nonisolated struct HealthKeywordClassifier: HealthRelevanceClassifying {
    /// Whole-word triggers (matched as complete alphanumeric tokens).
    static let words: Set<String> = [
        "log", "logged", "logging",
        "swim", "swam", "swimming", "swims",
        "run", "ran", "jog", "jogged", "jogging", "running", "runs",
        "walk", "walked", "walking", "walks", "hike", "hiked", "hiking", "hikes",
        "workout", "workouts", "exercise", "exercised", "exercising", "exercises",
        "train", "trained", "training", "trains",
        "sleep", "slept", "sleeping", "sleeps", "nap", "napped", "napping", "naps",
        "weigh", "weighed", "weighing", "weighs", "weight", "scale",
        "meal", "meals", "ate", "eat", "eating", "eats",
        "lunch", "dinner", "breakfast", "snack", "snacks", "snacked",
        "calorie", "calories", "protein", "carb", "carbs", "fat", "fats",
        "heart", "hr", "hrv", "pulse", "recovery", "recovered",
        "step", "steps", "health", "healthy", "vo2", "vo2max",
        "tired", "sore", "overtraining", "overtrained",
    ]

    /// Multi-word / ambiguous triggers matched as substrings (so a bare "rest"
    /// doesn't fire on "the rest of it", but "rest day" does).
    static let phrases: [String] = ["rest day", "rest days", "day off", "heart rate"]

    func isRelevant(_ text: String) async -> Bool { Self.matches(text) }

    /// True if `text` contains any whole-word trigger or trigger phrase. Pure.
    static func matches(_ text: String) -> Bool {
        let lower = text.lowercased()
        for phrase in phrases where lower.contains(phrase) { return true }
        // Scan alphanumeric tokens; a token is a hit only as its own whole word.
        var token = ""
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                token.unicodeScalars.append(scalar)
            } else if !token.isEmpty {
                if words.contains(token) { return true }
                token = ""
            }
        }
        return !token.isEmpty && words.contains(token)
    }
}

// MARK: - Union of Tier 0 ∪ Tier 1

/// The production classifier: Tier 0 (keyword floor) UNION Tier 1 (on-device
/// model). Attaches when EITHER says yes — biased toward attaching. Tier 1 is
/// consulted only when Tier 0 misses (a keyword hit short-circuits, saving a model
/// call), and a Tier 1 that is unavailable / times out / errors returns `nil`, so
/// **Tier 0's answer stands** (never a spurious yes from a broken model).
///
/// Both tiers are injected as closures so the union logic is unit-tested without
/// the (Simulator-unavailable) model: the default `keyword` is
/// `HealthKeywordClassifier`, the default `model` is the 300 ms-bounded
/// `FoundationHealthClassifier`.
nonisolated struct UnionHealthClassifier: HealthRelevanceClassifying {
    let keyword: @Sendable (String) -> Bool
    /// `nil` means Tier 1 gave no usable answer (unavailable/timeout/error).
    let model: @Sendable (String) async -> Bool?

    init(keyword: @escaping @Sendable (String) -> Bool = { HealthKeywordClassifier.matches($0) },
         model: @escaping @Sendable (String) async -> Bool? = { await FoundationHealthClassifier.shared.classify($0) }) {
        self.keyword = keyword
        self.model = model
    }

    func isRelevant(_ text: String) async -> Bool {
        if keyword(text) { return true }        // Tier 0 hit → done, no model call
        return (await model(text)) ?? false     // Tier 1, or Tier 0's "no" on failure
    }
}

// MARK: - Gate (pure policy)

/// The pure attach decision: the master "Attach health context" toggle gates
/// everything — off means **never attach and never fulfill a request**; on defers
/// to the classifier. Kept separate and pure so the policy is unit-tested apart
/// from the async classifier.
nonisolated enum HealthContextGate {
    static func shouldAttach(enabled: Bool, relevant: Bool) -> Bool {
        enabled && relevant
    }
}
