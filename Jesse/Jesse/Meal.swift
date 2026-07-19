import CryptoKit
import Foundation

// The dietary write-back feature's pure core. A diet-logging reply (or the bridge's
// off-app corrections queue) ends with a machine-readable `JESSE_MEAL_LOG v1`/`v2`
// line; the bridge extracts + strips it and attaches it under `directives.meal_log`,
// which the app decodes (`JesseMealLog`) and this file validates into a domain
// `MealBatch` (upserts + retracts + the ack seq) to apply to Apple Health. All the
// policy — field optionality, caps, strict date parsing, the content hash, the
// streaming display scrubber — lives here, Foundation-only and fully unit-tested; the
// untestable HealthKit read/write/delete surface stays in `HealthKitMealWriter`.

/// One meal to write into Apple Health, validated from the wire. `id` is the
/// bridge-provided stable idempotency key (date + meal slot); `consumedAt` is the
/// *meal* time (parsed strictly from an ISO-8601 offset string); each macro is
/// optional and, when present, a finite non-negative number. `Codable` so the
/// pending-write store can persist a failed write across a relaunch.
nonisolated struct Meal: Codable, Equatable, Sendable {
    let id: String
    let consumedAt: Date
    let name: String
    let kcal: Double?
    let proteinGrams: Double?
    let carbGrams: Double?
    let fatGrams: Double?
    let fiberGrams: Double?
    /// The HealthKit-bound micronutrients, each the sum of ONLY the meal's items that
    /// carried a known value — nil when NO item in the meal did (never a summed 0).
    /// Written as their own HealthKit samples; sodium/potassium/calcium/magnesium in mg,
    /// saturated fat/sugars in g. Omega-3 is gauge-only (no HealthKit EPA+DHA type) and
    /// so is never a meal field.
    let sodiumMg: Double?
    let satFatGrams: Double?
    let sugarGrams: Double?
    let potassiumMg: Double?
    let calciumMg: Double?
    let magnesiumMg: Double?

    /// A stable content hash over `consumedAt`, `name`, and every **present** nutrient,
    /// with absent nutrients canonically EXCLUDED (so absent and `0` hash differently — a
    /// meal gaining its first sodium estimate hashes differently, triggering exactly one
    /// rewrite). `id` is deliberately NOT hashed: it is the store key, and the hash answers
    /// "did the content behind this id change?". The nutrient list is iterated in a FIXED
    /// canonical order and is the **one** place a new nutrient is added — a tenth field
    /// changes only this list, never the persisted store schema (field-agnostic by design).
    var contentHash: String {
        var parts: [String] = [
            "consumedAt=\(consumedAt.timeIntervalSinceReferenceDate)",
            "name=\(name)",
        ]
        // (wire-key, value?) in a fixed canonical order; only present nutrients contribute.
        let nutrients: [(String, Double?)] = [
            ("kcal", kcal), ("protein_g", proteinGrams), ("carbs_g", carbGrams),
            ("fat_g", fatGrams), ("fiber_g", fiberGrams), ("sodium_mg", sodiumMg),
            ("satfat_g", satFatGrams), ("sugar_g", sugarGrams), ("potassium_mg", potassiumMg),
            ("calcium_mg", calciumMg), ("magnesium_mg", magnesiumMg),
        ]
        for (key, value) in nutrients {
            if let value { parts.append("\(key)=\(value)") }
        }
        // Join on an ASCII unit separator (never in a value) so field boundaries are
        // unambiguous, then SHA-256 to a fixed-length hex string.
        let canonical = parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A validated v2 meal-events batch: `upserts` to insert/replace, `retracts` to delete +
/// tombstone, and the `correctionsSeq` (the highest queued batch seq) the app acks once it
/// has taken responsibility for the batch. A v1 delivery yields an all-upsert batch with an
/// empty `retracts` and a nil `correctionsSeq`.
nonisolated struct MealBatch: Equatable, Sendable {
    let upserts: [Meal]
    let retracts: [String]
    let correctionsSeq: Int?

    var isEmpty: Bool { upserts.isEmpty && retracts.isEmpty }
}

/// The pure validator + display scrubber for the `JESSE_MEAL_LOG v1` contract.
/// Never touches HealthKit or I/O.
nonisolated enum MealLogParser {
    /// Max meals one directive may carry — mirrors the bridge's cap. Over it the
    /// whole block is rejected (never partially written), matching how the bridge
    /// treats an over-cap block as malformed and how `NeedsHealthRequest.validated`
    /// rejects a whole health request rather than fulfilling it partially.
    static let maxMeals = 10

    /// Max ids one v2 batch may `retract` — mirrors the bridge's `MAX_RETRACT`. Over it
    /// the whole batch is rejected (never partially applied), like `maxMeals`.
    static let maxRetract = 10

    /// The recognized sentinel prefixes. The scrubber strips a `v1` OR `v2` line; an
    /// unknown version (`v3` and up) is left visible — loud by contract, so a future bump
    /// fails loudly instead of being silently hidden. `v10`/`v20` never match (the space /
    /// exact-match guard below), so a two-digit future version stays visible too.
    static let sentinelV1 = "JESSE_MEAL_LOG v1"
    static let sentinelV2 = "JESSE_MEAL_LOG v2"
    static let scrubbedSentinels = [sentinelV1, sentinelV2]

    /// Validate a decoded `meal_log` into domain meals, or `nil` if it violates the
    /// contract. **Atomic:** an empty array, more than `maxMeals`, a blank required
    /// field, an unparseable `consumedAt`, or a negative/non-finite macro rejects
    /// the WHOLE block (never a partial write). The bridge already validated the
    /// structure; this re-validates app-side (defense in depth) and, crucially,
    /// parses the ISO-8601 date strictly — the one check the date-library-less
    /// bridge deferred to the app.
    static func meals(from wire: JesseMealLog) -> [Meal]? {
        let raw = wire.meals
        guard !raw.isEmpty, raw.count <= maxMeals else { return nil }
        var out: [Meal] = []
        out.reserveCapacity(raw.count)
        for m in raw {
            guard let meal = meal(from: m) else { return nil }
            out.append(meal)
        }
        return out
    }

    /// Validate a decoded `meal_log` into a v2 [`MealBatch`]: `meals` become upserts and
    /// `retract` becomes deletions. **Atomic:** any violation rejects the WHOLE batch
    /// (never a partial apply):
    /// - `meals` over [`maxMeals`], or any meal failing [`meal(from:)`] (blank field,
    ///   unparseable date, negative/non-finite nutrient);
    /// - `retract` over [`maxRetract`], or any retract id blank;
    /// - the same id in both `meals` and `retract` (a meal *move* uses DIFFERENT ids, so a
    ///   collision is malformed — matching the bridge);
    /// - a delivered block with neither meals nor retracts (nothing to do).
    /// A v1 delivery (no `retract`, no `corrections_seq`) yields an all-upsert batch,
    /// so this one seam serves both versions. Reuses [`meal(from:)`] for per-meal validation.
    static func batch(from wire: JesseMealLog) -> MealBatch? {
        let rawMeals = wire.meals
        let rawRetract = wire.retract ?? []
        guard rawMeals.count <= maxMeals, rawRetract.count <= maxRetract else { return nil }
        guard !rawMeals.isEmpty || !rawRetract.isEmpty else { return nil }

        var upserts: [Meal] = []
        upserts.reserveCapacity(rawMeals.count)
        for m in rawMeals {
            guard let meal = meal(from: m) else { return nil }
            upserts.append(meal)
        }

        var retracts: [String] = []
        retracts.reserveCapacity(rawRetract.count)
        for r in rawRetract {
            let id = r.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            retracts.append(id)
        }

        // A move is retract-old + upsert-new (different ids); the SAME id in both is malformed.
        let retractSet = Set(retracts)
        guard !upserts.contains(where: { retractSet.contains($0.id) }) else { return nil }

        return MealBatch(upserts: upserts, retracts: retracts, correctionsSeq: wire.correctionsSeq)
    }

    /// Validate one wire meal, or `nil` on any violation.
    static func meal(from m: JesseMeal) -> Meal? {
        let id = m.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty, let date = parseDate(m.consumedAt) else { return nil }
        for value in [m.kcal, m.proteinGrams, m.carbGrams, m.fatGrams, m.fiberGrams,
                      m.sodiumMg, m.satFatGrams, m.sugarGrams, m.potassiumMg,
                      m.calciumMg, m.magnesiumMg] {
            if let v = value, !(v.isFinite && v >= 0) { return nil }
        }
        return Meal(id: id, consumedAt: date, name: name,
                    kcal: m.kcal, proteinGrams: m.proteinGrams,
                    carbGrams: m.carbGrams, fatGrams: m.fatGrams,
                    fiberGrams: m.fiberGrams,
                    sodiumMg: m.sodiumMg, satFatGrams: m.satFatGrams,
                    sugarGrams: m.sugarGrams, potassiumMg: m.potassiumMg,
                    calciumMg: m.calciumMg, magnesiumMg: m.magnesiumMg)
    }

    /// Parse an ISO-8601 date-time WITH offset, tolerating optional fractional
    /// seconds. `nil` for anything off-shape — the app never writes a mis-dated
    /// entry from a garbled timestamp.
    static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    // MARK: - Streaming display scrubber

    /// Strip a trailing `JESSE_MEAL_LOG v1` line from streamed *partial* reply text
    /// before it is rendered. A partial SSE delta can briefly show the sentinel
    /// line before the bridge's `done` frame strips it (the streaming caveat, by
    /// design); this hides it defensively. Only the FINAL non-empty line is a
    /// directive candidate — a `JESSE_MEAL_LOG` line with prose after it is treated
    /// as prose (matching the bridge). An unknown version is **not** scrubbed (loud
    /// by contract). The final persisted text already comes stripped from the
    /// bridge, so this is only for the live partial.
    static func scrubbedStreamingText(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let idx = lines.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return text }
        let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
        // Match a known sentinel (`v1` or `v2`) exactly or followed by a space (its JSON) —
        // never `v10`/`v11`/`v3`, so an unknown version stays visible (loud by contract).
        let isKnown = scrubbedSentinels.contains { trimmed == $0 || trimmed.hasPrefix($0 + " ") }
        guard isKnown else { return text }
        lines.removeSubrange(idx..<lines.count)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
