import Foundation

// Pure, Foundation-only presentation logic for the redesigned Today screen: the
// activity-ring fill/neutral decision, the calories hero's center label + net
// line, and the exercise-symbol mapping. NOTHING here touches SwiftUI — a ring's
// color still comes from `statusColor(gauge.status)` in the view, so a ring can
// never disagree with the bar on the Macros screen. Every judgment is the
// semantics engine's; this only shapes it for drawing, and is unit-tested.

enum HealthRing {
    /// A ring's fill fraction, clamped to [0, 1]. The engine already set
    /// `gauge.fraction` per metric type (floor value/target, fat value/cap on a
    /// normal day, fat value/ceiling on a carb-load day, fiber value/floor); the
    /// ring just pegs full over 100% — the center grams and status color carry the
    /// "over" story. A nil fraction (no usable target) reads as empty.
    static func fill(_ gauge: MetricGauge) -> Double {
        min(max(gauge.fraction ?? 0, 0), 1)
    }

    /// Whether the ring renders neutral (gray, no color judgment). True exactly when
    /// the engine suspended the metric — fiber on a carb-load day. The neutral color
    /// itself is `statusColor(.suspended)` in the view; this is the decision.
    static func isNeutral(_ gauge: MetricGauge) -> Bool {
        gauge.status == .suspended
    }

    /// The compact grams shown in a macro ring's center ("142g"); calories pass an
    /// empty unit so it's just the number.
    static func centerLabel(_ gauge: MetricGauge) -> String {
        "\(DietSemantics.fmt(gauge.value))\(gauge.unit)"
    }
}

enum CaloriesHero {
    /// The big number in the ring's center — the remaining magnitude. "620" when
    /// 620 under a ceiling, "0" at the limit, "180" when 180 over, or the distance
    /// to whichever window edge the engine's `remaining` names. With no usable
    /// target it falls back to the raw intake so the hero is never blank.
    static func centerNumber(_ gauge: MetricGauge) -> String {
        guard let t = gauge.target else { return DietSemantics.fmt(gauge.value) }
        return DietSemantics.fmt(abs(t - gauge.value))
    }

    /// The caption under the big number — the engine's remaining annotation verbatim
    /// ("620 left", "at limit", "180 over limit", or the carb-load window phrasing).
    /// Never recomputed here; a wrong caption would mean the engine and hero disagree.
    static func centerCaption(_ gauge: MetricGauge) -> String {
        gauge.remaining
    }

    /// The one-line net-calorie caption under the ring ("1,840 eaten · 420 burned ·
    /// 1,420 net"), grouped with the locale's thousands separator. Nil when no
    /// exercise burn exists — the line only appears when it adds information.
    static func netLine(_ net: NetCalories, locale: Locale = .current) -> String? {
        guard net.burned > 0 else { return nil }
        return "\(grouped(net.intake, locale: locale)) eaten · \(grouped(net.burned, locale: locale)) burned · \(grouped(net.net, locale: locale)) net"
    }

    /// Whole-number formatting with the locale's grouping separator ("1,840" in
    /// en_US). Locale is injected so the separator is deterministic under test.
    static func grouped(_ x: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        f.maximumFractionDigits = 0
        f.roundingMode = .halfUp
        return f.string(from: NSNumber(value: x)) ?? DietSemantics.fmt(x)
    }
}

enum DayStyleExplain {
    /// The short human label for a day-style (the chip text and the explainer's
    /// value line): "Carb-load", "Long run", "Normal", etc. `isCarbLoad` (the
    /// engine's decision) wins so the label never disagrees with the flipped rules.
    static func headline(dayStyle: String?, isCarbLoad: Bool) -> String {
        switch dayStyle {
        case "carb-load-training", "carb-load-race": return "Carb-load"
        case "long-run": return "Long run"
        case "refeed": return "Refeed"
        case "sick": return "Sick"
        case "fasting": return "Fasting"
        case "normal", nil, "": return isCarbLoad ? "Carb-load" : "Normal"
        default:
            if isCarbLoad { return "Carb-load" }
            return dayStyle?.capitalized ?? "Normal"
        }
    }
}

enum ExerciseSymbol {
    /// The SF Symbol for an exercise type: case-insensitive substring match, checked
    /// in a fixed priority order, falling back to a generic cardio glyph for
    /// anything unrecognized. Pure so the mapping is unit-tested, never a view guess.
    static func name(for type: String) -> String {
        let t = type.lowercased()
        if t.contains("run") { return "figure.run" }
        if t.contains("walk") { return "figure.walk" }
        if t.contains("swim") { return "figure.pool.swim" }
        if t.contains("bike") || t.contains("cycling") { return "figure.outdoor.cycle" }
        if t.contains("strength") || t.contains("weights") { return "dumbbell" }
        if t.contains("hike") { return "figure.hiking" }
        return "figure.mixed.cardio"
    }
}
