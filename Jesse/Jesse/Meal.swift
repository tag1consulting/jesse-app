import Foundation

// The dietary write-back feature's pure core. A diet-logging reply ends with a
// machine-readable `JESSE_MEAL_LOG v1` line; the bridge extracts + strips it and
// attaches it under `directives.meal_log`, which the app decodes (`JesseMealLog`)
// and this file validates into domain `Meal`s to write into Apple Health. All the
// policy — field optionality, caps, strict date parsing, the streaming display
// scrubber — lives here, Foundation-only and fully unit-tested; the untestable
// HealthKit write surface stays in `HealthKitMealWriter`.

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
    /// The four micronutrients, each the sum of ONLY the meal's items that carried a
    /// known value — nil when NO item in the meal did (never a summed 0). Written as
    /// their own HealthKit samples; sodium/potassium in mg, saturated fat/sugars in g.
    let sodiumMg: Double?
    let satFatGrams: Double?
    let sugarGrams: Double?
    let potassiumMg: Double?
}

/// The pure validator + display scrubber for the `JESSE_MEAL_LOG v1` contract.
/// Never touches HealthKit or I/O.
nonisolated enum MealLogParser {
    /// Max meals one directive may carry — mirrors the bridge's cap. Over it the
    /// whole block is rejected (never partially written), matching how the bridge
    /// treats an over-cap block as malformed and how `NeedsHealthRequest.validated`
    /// rejects a whole health request rather than fulfilling it partially.
    static let maxMeals = 10

    /// The version-1 sentinel prefix. The scrubber strips only a `v1` line; an
    /// unknown version (`v2…`) is left visible — loud by contract, so a future bump
    /// fails loudly instead of being silently hidden.
    static let sentinelV1 = "JESSE_MEAL_LOG v1"

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

    /// Validate one wire meal, or `nil` on any violation.
    static func meal(from m: JesseMeal) -> Meal? {
        let id = m.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty, let date = parseDate(m.consumedAt) else { return nil }
        for value in [m.kcal, m.proteinGrams, m.carbGrams, m.fatGrams, m.fiberGrams,
                      m.sodiumMg, m.satFatGrams, m.sugarGrams, m.potassiumMg] {
            if let v = value, !(v.isFinite && v >= 0) { return nil }
        }
        return Meal(id: id, consumedAt: date, name: name,
                    kcal: m.kcal, proteinGrams: m.proteinGrams,
                    carbGrams: m.carbGrams, fatGrams: m.fatGrams,
                    fiberGrams: m.fiberGrams,
                    sodiumMg: m.sodiumMg, satFatGrams: m.satFatGrams,
                    sugarGrams: m.sugarGrams, potassiumMg: m.potassiumMg)
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
        // Match `JESSE_MEAL_LOG v1` exactly or followed by a space (its JSON) —
        // never `v10`/`v11`/`v2`, so an unknown version stays visible.
        guard trimmed == sentinelV1 || trimmed.hasPrefix(sentinelV1 + " ") else { return text }
        lines.removeSubrange(idx..<lines.count)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
