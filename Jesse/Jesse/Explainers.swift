import Foundation

// The "understand the numbers" content, baked in as static strings and
// parameterized with the live numbers from the snapshot where noted. Written in
// plain second person from the diet's own rules. Pure (Foundation-only) so the
// wording can be unit-tested and reused by any bar row.

enum Explainers {
    private static func line(_ g: MetricGauge) -> String {
        let v = DietSemantics.fmt(g.value)
        if let t = g.target { return "\(v) / \(DietSemantics.fmt(t))\(g.unit) — \(g.remaining)" }
        return "\(v)\(g.unit) — \(g.remaining)"
    }

    /// What today's day-style changes — which metrics are floors, ceilings, or
    /// windows. Opened by tapping the day chip under the header. Carb-load days flip
    /// the calorie and fat rules and suspend fiber; a normal day is the baseline.
    static func dayStyle(_ dayStyle: String?, isCarbLoad: Bool) -> Explainer {
        let paras: [String]
        if isCarbLoad {
            paras = [
                "Today is a carb-load day. The point is to top off glycogen before a long run or race, so the rules flip from an ordinary day.",
                "Calories become a window, not a ceiling: 92–100% of target is the goal, and under-eating fails the load. Fat becomes a minimize-it ceiling — keep it low to leave calorie room for carbs. Protein and carbs stay floors (hit them or beat them).",
                "Fiber is suspended: low-residue eating before a long effort is deliberate, so it shows a plain gray ring with no color judgment today. It returns to a 38g floor on your next normal day.",
            ]
        } else {
            paras = [
                "Today is an ordinary day, so the usual rules apply.",
                "Calories are a ceiling — stay at or under target. Protein, carbs, and fiber are floors — hit them or beat them. Fat is a window: a 50g hormonal floor, a 65g working cap, a 70g hard cap.",
                "On a carb-load day these flip — calories become a window, fat a minimize-it ceiling, and fiber is suspended — but not today.",
            ]
        }
        let title = isCarbLoad ? "Carb-load day" : "Today's day type"
        let valueLine = DayStyleExplain.headline(dayStyle: dayStyle, isCarbLoad: isCarbLoad)
        return Explainer(id: "daystyle", title: title, valueLine: valueLine, paragraphs: paras)
    }

    static func calories(_ g: MetricGauge, isCarbLoad: Bool) -> Explainer {
        let paras = isCarbLoad
            ? ["On a carb-load day calories flip to a window: 92–100% of target is the goal. Under-eating a carb-load fails it — the point is to top off glycogen before a long run or race.",
               "That's why this bar reads red below 92% (not just above 100%): too few calories is the failure mode here, not too many."]
            : ["On a cut day calories are a ceiling — stay at or under target.",
               "Today's target is a phase base plus half of your logged exercise calories added back, so a bigger training day earns a bit more food. Travel and maintenance days use a declared maintenance base instead, which simply arrives here as a larger target.",
               "Green under 80%, yellow approaching the limit, red once you go over."]
        return Explainer(id: "calories", title: "Calories", valueLine: line(g), paragraphs: paras)
    }

    /// The explainer for a macro, wired with the live context each one needs (carbs'
    /// bonus, fat/fiber's carb-load flip). Lets the rings row and the Macros screen
    /// build explainers while iterating `Macro.allCases` in canonical order, instead
    /// of naming each builder in a hand-written sequence.
    static func macro(_ macro: Macro, gauges g: DietGauges) -> Explainer {
        switch macro {
        case .protein: return protein(g.protein)
        case .carbs: return carbs(g.carbs, hasBonus: g.carbsBonus != nil)
        case .fiber: return fiber(g.fiber, isCarbLoad: g.isCarbLoad)
        case .fat: return fat(g.fat, isCarbLoad: g.isCarbLoad)
        }
    }

    static func protein(_ g: MetricGauge) -> Explainer {
        Explainer(id: "protein", title: Macro.protein.displayName, valueLine: line(g), paragraphs: [
            "Protein is a floor — hit it or beat it. It preserves muscle while you cut at marathon-training volume.",
            "Under half your target reads red, most of the way there yellow, at or past target green. There's no penalty for going over.",
        ])
    }

    static func carbs(_ g: MetricGauge, hasBonus: Bool) -> Explainer {
        var paras = [
            "Carbs are a floor — the remainder of your budget after protein and fat are set. Hit the base to fuel training.",
        ]
        if hasBonus {
            paras.append("The bonus row is extra carb budget you earned by exercising — optional fuel, not an obligation. Eat into it on a big day; skip it on an easy one.")
        }
        return Explainer(id: "carbs", title: Macro.carbs.displayName, valueLine: line(g), paragraphs: paras)
    }

    static func fat(_ g: MetricGauge, isCarbLoad: Bool) -> Explainer {
        let paras = isCarbLoad
            ? ["On a carb-load day fat becomes a minimize-it ceiling: keep it low to leave calorie room for carbs.",
               "Green well under the cap, yellow approaching it, red over."]
            : ["Fat is a window, not just a cap. 50g is a hormonal floor — below it you risk low energy availability and fat-soluble vitamin uptake. 65g is the working ceiling; 70g the hard ceiling.",
               "So this bar reads red BELOW 50g (deliberately — that's too low), green 50–65g, yellow 65–70g, and red again over 70g."]
        return Explainer(id: "fat", title: Macro.fat.displayName, valueLine: line(g), paragraphs: paras)
    }

    static func fiber(_ g: MetricGauge, isCarbLoad: Bool) -> Explainer {
        let paras = isCarbLoad
            ? ["Fiber is suspended on carb-load days. Low-residue eating before a long run or race is deliberate — an empty gut is the goal, so there's no color judgment today.",
               "It'll return to a 38g floor on your next normal day."]
            : ["Fiber is a 38g floor for gut health and satiety. Hit it or beat it on a normal day.",
               "It's suspended on carb-load days, when low-residue eating before a long effort is deliberate."]
        return Explainer(id: "fiber", title: Macro.fiber.displayName, valueLine: line(g), paragraphs: paras)
    }

    static func netCalories(_ net: NetCalories) -> Explainer {
        Explainer(id: "net", title: "Net calories",
                  valueLine: "\(DietSemantics.fmt(net.net)) net · \(DietSemantics.fmt(net.burned)) burned",
                  paragraphs: [
                    "Net is what you ate minus what exercise burned. The striped portion of the bar shows what your training bought back.",
                    "It's a rough accounting — the calorie target already adds part of your exercise back — so read it as context, not a second budget.",
                  ])
    }

    static func pace(_ progress: DietProgress?) -> Explainer {
        var paras = [
            "Both paces are 14-day regressions of your weigh-ins. The trough pace regresses the rolling daily minima — a smoothed read that's the primary signal. The raw pace regresses every point, so it's noisy and swings with water weight.",
            "The zone chip judges the pace against this phase's target band. A wide split between trough and raw usually means hydration noise, not real change — trust the trough.",
        ]
        if let p = progress, let sub = p.paceSubMain { paras.insert(sub, at: 0) }
        return Explainer(id: "pace", title: "Pace — trough vs raw",
                         valueLine: paceLine(progress), paragraphs: paras)
    }

    static func fatLeanPace(_ progress: DietProgress?) -> Explainer {
        Explainer(id: "fatlean", title: "Fat vs lean pace",
                  valueLine: fatLeanLine(progress),
                  paragraphs: [
                    "These are 28-day regressions over a composition window: one of fat mass, one of lean mass.",
                    "Losing fat fast is good — but only while lean change stays small. Lean loss under 0.5 lb/week is good, 0.5–1.0 is worth watching, and over 1.0 is a concern (you're burning muscle, not just fat).",
                  ])
    }

    static func weight() -> Explainer {
        Explainer(id: "weight", title: "Weight", valueLine: "Morning weigh-ins",
                  paragraphs: [
                    "These are morning weigh-ins. Day-to-day jumps of 1–4 lb are mostly water and glycogen, not fat gained or lost.",
                    "That's exactly why the trend line and the trough regression exist — they see through the daily noise to the real direction.",
                  ])
    }

    private static func paceLine(_ p: DietProgress?) -> String {
        guard let p else { return "trough vs raw" }
        let t = p.paceBarLabel ?? p.troughPace.map { "\(DietSemantics.fmt($0)) lb/wk" } ?? "—"
        return "trough \(t)"
    }

    private static func fatLeanLine(_ p: DietProgress?) -> String {
        guard let p else { return "fat vs lean" }
        let f = p.fatBarLabel ?? p.fatPace.map { "\(DietSemantics.fmt($0)) lb/wk" } ?? "—"
        let l = p.leanBarLabel ?? p.leanPace.map { "\(DietSemantics.fmt($0)) lb/wk" } ?? "—"
        return "fat \(f) · lean \(l)"
    }
}
