import Foundation
import JesseNetworking

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
                "Calories become a window, not a ceiling: 92–100% of target is the goal, so under-eating misses the point of a carb-load. Fat becomes a minimize-it ceiling — keep it low to leave calorie room for carbs. Protein and carbs stay floors (reach them or beat them).",
                "Fiber is resting today: low-residue eating before a long effort is deliberate, so it shows a plain gray ring with no judgment. It returns to a 38g floor on your next normal day.",
            ]
        } else {
            paras = [
                "Today is an ordinary day, so the usual rules apply.",
                "Calories are a ceiling — stay at or under target. Protein, carbs, and fiber are floors — reach them or beat them. Fat is a window: a 50g hormonal floor, a 65g working cap, a 70g hard cap.",
                "On a carb-load day these flip — calories become a window, fat a minimize-it ceiling, and fiber rests — but not today.",
            ]
        }
        let title = isCarbLoad ? "Carb-load day" : "Today's day type"
        let valueLine = DayStyleExplain.headline(dayStyle: dayStyle, isCarbLoad: isCarbLoad)
        return Explainer(id: "daystyle", title: title, valueLine: valueLine, paragraphs: paras)
    }

    static func calories(_ g: MetricGauge, isCarbLoad: Bool) -> Explainer {
        let paras = isCarbLoad
            ? ["On a carb-load day calories flip to a window: 92–100% of target is the goal. Under-eating a carb-load misses its point — it's there to top off glycogen before a long run or race.",
               "That's why the gauge nudges you below 92%, not just above 100%: here the thing to watch is eating too little, not too much."]
            : ["On a cut day calories are a ceiling — stay at or under target.",
               "Today's target is a phase base plus half of your logged exercise calories added back, so a bigger training day earns a bit more food. Travel and maintenance days use a declared maintenance base instead, which simply arrives here as a larger target.",
               "There's room to spare under target, a calm approach as you near it, and a gentle heads-up once you go over — never an alarm."]
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
            "Protein is a floor — reach it or beat it. It preserves muscle while you cut at marathon-training volume.",
            "Early in the day a low number just reads as coming along; still low late in the day, it earns a gentle nudge; at or past target, you're on track. There's no downside to going over.",
        ])
    }

    static func carbs(_ g: MetricGauge, hasBonus: Bool) -> Explainer {
        var paras = [
            "Carbs are a floor — the remainder of your budget after protein and fat are set. Reach the base to fuel training.",
        ]
        if hasBonus {
            paras.append("The bonus row is extra carb budget you earned by exercising — optional fuel, not an obligation. Eat into it on a big day; skip it on an easy one.")
        }
        return Explainer(id: "carbs", title: Macro.carbs.displayName, valueLine: line(g), paragraphs: paras)
    }

    static func fat(_ g: MetricGauge, isCarbLoad: Bool) -> Explainer {
        let paras = isCarbLoad
            ? ["On a carb-load day fat becomes a minimize-it ceiling: keep it low to leave calorie room for carbs.",
               "Plenty of room well under the cap, a calm approach as you near it, and a gentle heads-up over."]
            : ["Fat is a window, not just a cap. 50g is a hormonal floor — below it you risk low energy availability and fat-soluble vitamin uptake. 65g is the working ceiling; 70g the hard ceiling.",
               "So the gauge gives a nudge BELOW 50g (that's too low — flagged on purpose), reads on track from 50–65g, and offers a heads-up above 65g — more firmly past the 70g hard cap."]
        return Explainer(id: "fat", title: Macro.fat.displayName, valueLine: line(g), paragraphs: paras)
    }

    static func fiber(_ g: MetricGauge, isCarbLoad: Bool) -> Explainer {
        let paras = isCarbLoad
            ? ["Fiber rests on carb-load days. Low-residue eating before a long run or race is deliberate — an empty gut is the goal, so there's no judgment today.",
               "It'll return to a 38g floor on your next normal day."]
            : ["Fiber is a 38g floor for gut health and satiety. Reach it or beat it on a normal day.",
               "It rests on carb-load days, when low-residue eating before a long effort is deliberate."]
        return Explainer(id: "fiber", title: Macro.fiber.displayName, valueLine: line(g), paragraphs: paras)
    }

    /// The explainer for a micronutrient, wired with its live gauge so the sheet header
    /// mirrors the gauge exactly: a partial total reads "≥"; an all-unknown nutrient
    /// reads "not tracked yet"; a target frames the number by the nutrient's semantics
    /// (ceiling for sodium/saturated fat, floor for potassium); no target shows the value
    /// only; and total sugars stays informational — never a judgment.
    /// The title and identity come from the GAUGE's label rather than the nutrient's name,
    /// so a rolling-window row ("Mercury (7-day)") titles its sheet with the window it
    /// actually describes and gets its own sheet identity — the one place the window must
    /// not be lost is the header of the screen explaining the number.
    static func micronutrient(_ n: Micronutrient, gauge g: MetricGauge) -> Explainer {
        Explainer(id: "micro-\(g.label)", title: g.label,
                  valueLine: microLine(g), paragraphs: microParagraphs(n, g),
                  note: n.education)
    }

    /// The micronutrient header line, mirroring the gauge's own value language: "≥" when
    /// the total is a floor, the value/target and its remaining wording when a target is
    /// present, and the neutral "not tracked yet" when no item carried the value.
    ///
    /// A BAND row drops the "/ target" half deliberately. Its `target` is the band's
    /// CEILING (the bar's reference), and "120 / 300µg" at the top of the sheet reads as a
    /// ceiling of 300 — precisely the misreading a band exists to avoid. The remaining
    /// phrase already names both edges, so it carries the goal on its own.
    private static func microLine(_ g: MetricGauge) -> String {
        guard (g.knownItemCount ?? 0) > 0 else { return DietSemantics.notTrackedCaption }
        let prefix = g.partial ? "≥" : ""
        let v = DietSemantics.fmt(g.value)
        let rem = g.remaining.isEmpty ? "" : " — \(g.remaining)"
        if g.goal == .band { return "\(prefix)\(v)\(g.unit)\(rem)" }
        if let t = g.target {
            return "\(prefix)\(v) / \(DietSemantics.fmt(t))\(g.unit)\(rem)"
        }
        return "\(prefix)\(v)\(g.unit)"
    }

    private static func microParagraphs(_ n: Micronutrient, _ g: MetricGauge) -> [String] {
        var paras: [String] = []
        switch n {
        case .sodium:
            paras.append("Sodium is a ceiling — stay at or under target. Most of a day's sodium hides in bread, cheese, cured meat, and restaurant food, not the salt shaker.")
        case .saturatedFat:
            paras.append("Saturated fat is a ceiling — stay at or under target. It's the butter, cheese, and fatty-meat share of your fat, kept in check for heart health while your total fat stays in its window.")
        case .totalSugars:
            paras.append("Total sugars is shown for composition only — there's no red or green here. It counts natural sugars in fruit and dairy alongside any added, so a high number isn't automatically a problem.")
        case .unsaturatedFat:
            paras.append("Unsaturated fat is your total fat minus the saturated slice — the heart-healthy fats from olive oil, nuts, avocado, and fish. It's shown for composition only, with no target and no red or green.")
        case .potassium:
            paras.append("Potassium is a floor — hit it or beat it. Fruit, potatoes, dairy, and beans carry most of it, and it's the mineral that balances sodium's effect on blood pressure.")
        case .calcium:
            paras.append("Calcium is a floor — hit it or beat it. Dairy, fortified plant milks, tofu, and leafy greens carry most of it, and it builds bone and keeps muscles and nerves working.")
        case .omega3:
            paras.append("Omega-3 is a floor — hit it or beat it. This counts the marine EPA and DHA in oily fish, shellfish, and roe, not the plant ALA in flax or walnuts.")
        case .magnesium:
            paras.append("Magnesium is a floor — hit it or beat it. Nuts, seeds, beans, whole grains, and leafy greens carry most of it, and it supports muscle, nerve, and sleep function.")
        case .cholesterol:
            paras.append("Cholesterol here is shown for context only — there's no target and no red or green. What you eat moves your blood numbers far less than saturated fat, trans fat, and fiber do, and all three of those are already tracked with real goals.")
        case .transFat:
            paras.append("Trans fat is a ceiling of zero — not a small budget, none. It's the one fat that raises LDL and lowers HDL at the same time, so the goal is to see this row sit at zero rather than to keep it low.")
        case .addedSugar:
            paras.append("Added sugar is a ceiling — stay at or under target. It counts only what was added, not the sugar that came with fruit or milk, which is exactly why it can carry a goal where total sugars can't.")
        case .selenium:
            paras.append("Selenium is a range, not a floor: reach the low edge, stay under the high one. It's one of the few nutrients where more is genuinely worse — two Brazil nuts can cover a whole day, and a handful can overshoot it.")
        case .vitaminD:
            paras.append("Vitamin D is a floor — hit it or beat it. This counts food only: oily fish, egg yolk, and fortified milk. Sun and supplements don't appear here, so a low number means low intake from food, not necessarily a low level in you.")
        case .purines:
            paras.append("Purines are shown for context only — no target, no red or green. They become uric acid, which matters if gout does and mostly doesn't otherwise; for most people the body makes far more than the diet supplies.")
        case .mercury:
            paras.append("Mercury is judged over a rolling 7-day window, never on a single day — that's the timescale your body clears it on. One tuna steak is not a problem; one every day is what the weekly number is watching for.")
        }
        // A window row says WHAT it is measuring before anything else about the number:
        // the scope is the thing most easily misread here, and the sheet is where a reader
        // goes to settle exactly that.
        if let window = g.rollingWindow {
            let span = window.range.map { " (\($0))" } ?? ""
            paras.append("This is the total across the last \(window.days) days\(span), not today's.")
        }

        // The unknown-aware caveat: what "≥" and "not tracked yet" mean, so the number is
        // never misread as complete. The scope word follows the row's own scope, so a
        // window row never says "today".
        let scope = g.rollingWindow == nil ? "today" : "in this window"
        if (g.knownItemCount ?? 0) == 0 {
            paras.append("No food logged \(scope) lists a \(n.displayName.lowercased()) value yet, so there's nothing to total — every item is under \"Not estimated\" below.")
        } else if g.partial {
            paras.append("Some logged foods don't list their \(n.displayName.lowercased()), so this total is a floor — the real number is at least this much. Those items are listed under \"Not estimated\" below, never counted as zero.")
        }

        // A BAND names both edges rather than "a target": it has two, and saying "no
        // target" of a row that is clearly judging something would be worse than silence.
        if g.goal == .band {
            if g.goalStatus == .noGoal, g.partial {
                paras.append("Part of the day isn't estimated, so being under the low edge here proves nothing — the foods that weren't measured could carry it well past. The row says what IS known: at least this much so far.")
            }
        } else if g.target == nil {
            paras.append("No target is set for it, so it's shown as a plain value with no goal to judge against.")
        }
        return paras
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
