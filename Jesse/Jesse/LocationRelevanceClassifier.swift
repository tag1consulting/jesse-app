import Foundation

// Decides whether a turn's message is about WHERE HE IS, so the app attaches the device
// location block only when it's relevant — instead of on every turn. The sibling of
// `HealthRelevanceClassifier`, and it inherits that file's correctness invariant:
//
// The classifier only optimizes token cost and, here, privacy. A wrong "not relevant"
// never produces a wrong answer — the agent can still ask via JESSE_NEEDS_LOCATION and
// the app fulfills it on a retry. So a miss costs at most one slower turn.
//
// Where it deliberately DIVERGES from the health classifier: it is biased toward
// attaching there, and only mildly so here. A spurious health attach spends tokens; a
// spurious location attach sends a coordinate the turn had no use for. So the keyword
// set is tight and phrase-led rather than a broad union of single words — "walk" alone
// is a health word ("I walked 8km"), and it earns a location attach only in company
// ("walking distance", "walk to").

/// The seam the send path classifies through. Async to match
/// `HealthRelevanceClassifying`, so both channels are resolved the same way from
/// `JesseClient.send`. `Sendable` so it can live on the client value.
protocol LocationRelevanceClassifying: Sendable {
    func isRelevant(_ text: String) async -> Bool
}

// MARK: - Keyword floor (always available, pure, tested)

/// The always-available keyword floor. Foundation-only and pure, so it is fully
/// unit-tested. Case-insensitive, diacritic-insensitive (so "più vicino" matches a
/// typed "piu vicino"), and **word-boundary aware** for the single-word triggers, so
/// "nearest" never fires on "nearestneighbour" and "qui" never fires inside "quindi".
///
/// The owner is often in Italy, so the same question in Italian has to fire the same
/// channel. The Italian entries are the direct counterparts of the English ones, not a
/// wider net: `vicino`, `qui`, `quanto dista`, `a piedi`, `aperto adesso`, `dove sono`.
nonisolated struct LocationKeywordClassifier: LocationRelevanceClassifying {
    /// Whole-word triggers (matched as complete alphanumeric tokens). Kept SHORT: a
    /// single word has to be unambiguous about place on its own to earn a coordinate.
    static let words: Set<String> = [
        // English
        "nearby", "closest", "nearest", "directions",
        // Italian
        "vicino", "vicini", "vicina", "vicine", "vicinanze",
        "qui", "qua", "dintorni", "indicazioni",
    ]

    /// Multi-word / ambiguous triggers matched as substrings. This is where most of the
    /// signal lives: "walk", "drive", "far" and "open" are all ordinary words that mean
    /// something about place only in company.
    static let phrases: [String] = [
        // English
        "near me", "near here", "around here", "round here", "near by",
        // "how far" needs its preposition. A bare "how far" also matches "how far
        // ALONG is the migration", which is a progress question and has no business
        // reading a coordinate — and "how far did I run", which belongs to the health
        // channel. Requiring the distance forms keeps both out.
        "how far is", "how far to", "how far from", "how far away", "how far's",
        "how long to get to", "how long does it take to get to",
        "walking distance", "driving distance", "walk to", "drive to", "cycle to",
        "get to", "open now", "open right now", "still open",
        "where am i", "where i am", "this area", "around the corner",
        "closest to me", "nearest to me", "on my way", "from here", "to here",
        // Italian
        "vicino a me", "qui vicino", "qua vicino", "piu vicino", "più vicino",
        "quanto dista", "quanto e lontano", "quanto è lontano", "quanto ci vuole",
        "a piedi", "in macchina", "aperto adesso", "aperto ora", "e aperto",
        "è aperto", "dove sono", "dove mi trovo", "da qui", "in zona", "qui intorno",
    ]

    func isRelevant(_ text: String) async -> Bool { Self.matches(text) }

    /// True if `text` contains any whole-word trigger or trigger phrase. Pure.
    static func matches(_ text: String) -> Bool {
        let normalized = fold(text)
        for phrase in phrases where normalized.contains(fold(phrase)) { return true }
        // Scan alphanumeric tokens; a token is a hit only as its own whole word.
        var token = ""
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                token.unicodeScalars.append(scalar)
            } else if !token.isEmpty {
                if words.contains(token) { return true }
                token = ""
            }
        }
        return !token.isEmpty && words.contains(token)
    }

    /// Lowercase and strip diacritics, so a typed "piu vicino" matches "più vicino"
    /// and vice versa. Both sides of every comparison go through this, so the table
    /// above can carry the properly-accented form and still match either spelling.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

// MARK: - Gate (pure policy)

/// The pure attach decision for the location channel. TWO conditions, not one:
///
///  * the master "Attach location context" toggle, which defaults OFF and is the
///    owner's standing consent for the feature at all; and
///  * the LIVE CoreLocation authorization status, which is the system's consent and
///    can be revoked in Settings at any time without the app hearing about it.
///
/// Both must hold. Checking only the toggle would mean a revoked permission produced a
/// mid-turn system prompt — asking for location because of a message he typed, at a
/// moment he did not choose. `.authorizedWhenInUse` is the ONLY accepted status: not
/// `.notDetermined` (asking for the first time mid-turn is the same ambush), and not
/// `.authorizedAlways`, which this app never requests and would only ever see on a
/// device where some other build had granted it.
///
/// Kept separate and pure so the policy is unit-tested apart from CoreLocation.
nonisolated enum LocationContextGate {
    static func shouldAttach(enabled: Bool, authorized: Bool, relevant: Bool) -> Bool {
        enabled && authorized && relevant
    }

    /// Whether a fulfillment may run at all — the same two consents, without the
    /// relevance test, because a directive IS the relevance signal on that path.
    static func mayFulfill(enabled: Bool, authorized: Bool) -> Bool {
        enabled && authorized
    }
}

// MARK: - Settings

/// The persisted "attach location context" toggle. Backed by `UserDefaults` (a
/// non-secret preference), and **defaults OFF** — a fresh install never attaches a
/// coordinate until the owner turns this on, and turning it on is separate from
/// granting the system permission. `JesseClient` reads `isEnabled` at send time; the
/// Settings row binds the same key.
nonisolated enum LocationContextSettings {
    static let enabledKey = "attachLocationContext"
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    static var isEnabled: Bool { defaults.bool(forKey: enabledKey) }
    static func setEnabled(_ on: Bool) { defaults.set(on, forKey: enabledKey) }
}
