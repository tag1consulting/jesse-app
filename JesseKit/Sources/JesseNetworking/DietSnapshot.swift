import Foundation

// The Decodable models for `GET /jesse/diet` (bridge ≥ 0.5.0). They mirror the
// bridge's response shape exactly (camelCase keys, all the may-be-absent fields
// optional). Swift's synthesized Decodable ignores unknown keys and decodes an
// absent optional to nil, so an older generator that omits a newer field — or a
// future one that adds a field we don't model — both decode cleanly.
//
// These are pure data. Every derived judgement (status colors, remaining text,
// carb-load flips, totals, gating) lives in `DietSemantics`, never here and never
// in a view.

/// One food item inside a meal (or a proposed meal idea). `fiber` is written by
/// the generator (0 when unknown); the rest may be absent on older files.
///
/// `na`/`satf`/`sug`/`k` (bridge ≥ 0.12.x), `ca`/`o3`/`mg` (bridge ≥ 0.18.0) and
/// `chol`/`tfat`/`asug`/`pur`/`hg`/`se`/`vd` are the tracked micronutrients. UNLIKE
/// `fiber` — which the generator always fills, so
/// nil-coalescing it to 0 is harmless — these are absent for MANY items. A missing value
/// is UNKNOWN, never zero: it must never be summed or shown as 0. They therefore live
/// OUTSIDE the `MacroTotals` / `total(of:)` path (which coalesces nil→0 for cal/p/f/c/fiber)
/// and are aggregated separately by `DietSemantics.micronutrientTotal`, which preserves the
/// unknowns. Synthesized Decodable decodes an absent key to nil, so no decoder change is
/// needed; the new fields carry a `= nil` default only so additive construction (tests,
/// previews) needn't name them.
public struct DietItem: Decodable, Equatable, Sendable {
    // Public memberwise init (the synthesized one is internal, so cross-module fixtures
    // in the app and tests can't reach it). Every field but `item` defaults, so a partial
    // fixture (`DietItem(item:cal:)`) still constructs.
    public init(item: String, amount: String? = nil, cal: Double? = nil, p: Double? = nil,
                f: Double? = nil, c: Double? = nil, fiber: Double? = nil, na: Double? = nil,
                satf: Double? = nil, sug: Double? = nil, k: Double? = nil, ca: Double? = nil,
                o3: Double? = nil, mg: Double? = nil, chol: Double? = nil,
                tfat: Double? = nil, asug: Double? = nil, pur: Double? = nil,
                hg: Double? = nil, se: Double? = nil, vd: Double? = nil) {
        self.item = item; self.amount = amount; self.cal = cal; self.p = p; self.f = f
        self.c = c; self.fiber = fiber; self.na = na; self.satf = satf; self.sug = sug
        self.k = k; self.ca = ca; self.o3 = o3; self.mg = mg
        self.chol = chol; self.tfat = tfat; self.asug = asug; self.pur = pur
        self.hg = hg; self.se = se; self.vd = vd
    }
    public var item: String
    public var amount: String?
    public var cal: Double?
    public var p: Double?
    public var f: Double?
    public var c: Double?
    public var fiber: Double?
    /// Sodium, milligrams. Absent (nil) = unknown, not zero.
    public var na: Double?
    /// Saturated fat, grams. Absent (nil) = unknown, not zero.
    public var satf: Double?
    /// Total sugars, grams. Absent (nil) = unknown, not zero.
    public var sug: Double?
    /// Potassium, milligrams. Absent (nil) = unknown, not zero.
    public var k: Double?
    /// Calcium, milligrams. Absent (nil) = unknown, not zero.
    public var ca: Double? = nil
    /// Omega-3 (marine EPA+DHA), milligrams. Absent (nil) = unknown, not zero.
    public var o3: Double? = nil
    /// Magnesium, milligrams. Absent (nil) = unknown, not zero.
    public var mg: Double? = nil
    /// Dietary cholesterol, milligrams. Absent (nil) = unknown, not zero. INFORMATIONAL:
    /// it carries no target and is never judged (see `Micronutrient.cholesterol`).
    public var chol: Double? = nil
    /// Trans fat, grams. Absent (nil) = unknown, not zero.
    public var tfat: Double? = nil
    /// Added sugar, grams — the added share only, NOT the `sug` total. Absent (nil) =
    /// unknown, not zero.
    public var asug: Double? = nil
    /// Purines, milligrams. Absent (nil) = unknown, not zero. A species-average estimate
    /// with wide within-species spread, so it is informational and never judged.
    public var pur: Double? = nil
    /// Methylmercury, MICROgrams. Absent (nil) = unknown, not zero. Judged only over a
    /// trailing 7-day window (see `rolling7`), never on one day.
    public var hg: Double? = nil
    /// Selenium, micrograms. Absent (nil) = unknown, not zero.
    public var se: Double? = nil
    /// Vitamin D, micrograms. Absent (nil) = unknown, not zero.
    public var vd: Double? = nil
}

/// A logged meal: a name, an optional `HH:MM` time, and its items.
public struct DietMeal: Decodable, Equatable, Sendable {
    public var name: String
    public var time: String?
    public var items: [DietItem]
    public init(name: String, time: String? = nil, items: [DietItem] = []) {
        self.name = name; self.time = time; self.items = items
    }
}

/// A logged exercise session. Every field but `type` may be absent.
public struct DietExercise: Decodable, Equatable, Sendable {
    public var type: String
    public var time: String?
    public var desc: String?
    public var distance: Double?
    public var unit: String?
    public var duration: String?
    public var pace: String?
    public var avgHR: Double?
    public var calories: Double?
    public init(type: String, time: String? = nil, desc: String? = nil, distance: Double? = nil,
                unit: String? = nil, duration: String? = nil, pace: String? = nil,
                avgHR: Double? = nil, calories: Double? = nil) {
        self.type = type; self.time = time; self.desc = desc; self.distance = distance
        self.unit = unit; self.duration = duration; self.pace = pace; self.avgHR = avgHR
        self.calories = calories
    }
}

/// The day's weigh-in, or null on a non-weigh-in day. `bf`/`mm` may be absent
/// even on a weigh-in day.
public struct DietWeight: Decodable, Equatable, Sendable {
    public var lbs: Double
    public var kg: Double?
    public var bf: Double?
    public var mm: Double?
    public var notes: String?
    public init(lbs: Double, kg: Double? = nil, bf: Double? = nil, mm: Double? = nil,
                notes: String? = nil) {
        self.lbs = lbs; self.kg = kg; self.bf = bf; self.mm = mm; self.notes = notes
    }
}

/// The day's macro/calorie targets. `carbsBase` and `fiber` may be absent in old
/// files (fiber defaults to 38 downstream — see `DietSemantics`).
///
/// `sodium`/`satFat`/`potassium`/`sugar` (bridge ≥ 0.12.x) and `calcium`/`omega3`/
/// `magnesium` (bridge ≥ 0.18.0) are the optional micronutrient day targets. Each is a
/// reference the matching gauge judges against; when absent the gauge shows the value
/// only, with no judgment. (Unsaturated fat is derived, not tracked, and has no target.)
///
/// The same shape carries a PAST day's frozen targets in `NutrientDay.targets`. Every
/// member is optional there for the same reason it is optional here: a key the archive
/// never recorded is unknown for that day, never zero.
public struct DietTargets: Decodable, Equatable, Sendable {
    // Public memberwise init (all fields optional → all default nil, so `DietTargets()`
    // and any partial fixture both construct across the module boundary).
    public init(calories: Double? = nil, protein: Double? = nil, fat: Double? = nil,
                carbs: Double? = nil, carbsBase: Double? = nil, fiber: Double? = nil,
                sodium: Double? = nil, satFat: Double? = nil, potassium: Double? = nil,
                sugar: Double? = nil, calcium: Double? = nil, omega3: Double? = nil,
                magnesium: Double? = nil, transFat: Double? = nil,
                addedSugar: Double? = nil, selenium: DietBandTarget? = nil,
                vitaminD: Double? = nil, purines: Double? = nil,
                mercuryWeekly: Double? = nil) {
        self.calories = calories; self.protein = protein; self.fat = fat; self.carbs = carbs
        self.carbsBase = carbsBase; self.fiber = fiber; self.sodium = sodium
        self.satFat = satFat; self.potassium = potassium; self.sugar = sugar
        self.calcium = calcium; self.omega3 = omega3; self.magnesium = magnesium
        self.transFat = transFat; self.addedSugar = addedSugar; self.selenium = selenium
        self.vitaminD = vitaminD; self.purines = purines
        self.mercuryWeekly = mercuryWeekly
    }
    public var calories: Double?
    public var protein: Double?
    public var fat: Double?
    public var carbs: Double?
    public var carbsBase: Double?
    public var fiber: Double?
    /// Sodium ceiling, milligrams.
    public var sodium: Double?
    /// Saturated-fat ceiling, grams.
    public var satFat: Double?
    /// Potassium floor, milligrams.
    public var potassium: Double?
    /// Total-sugars reference line, grams (informational — never a ceiling judgment).
    public var sugar: Double?
    /// Calcium floor, milligrams.
    public var calcium: Double?
    /// Omega-3 (EPA+DHA) floor, milligrams.
    public var omega3: Double?
    /// Magnesium floor, milligrams.
    public var magnesium: Double?
    /// Trans-fat ceiling, grams. Emitted as `0` — the one nutrient whose ideal is
    /// literally none, which is a REAL ceiling and not the "no usable target" state the
    /// other nutrients' zero would be (see `Micronutrient.zeroIsTheGoal`).
    public var transFat: Double?
    /// Added-sugar ceiling, grams. Distinct from `sugar`, which is the informational
    /// total-sugars reference line.
    public var addedSugar: Double?
    /// Selenium's BAND: a floor to reach AND a ceiling to stay under, in micrograms.
    /// Selenium is the one tracked nutrient with a real upper limit close enough to the
    /// floor that a single number cannot express the goal.
    public var selenium: DietBandTarget?
    /// Vitamin D floor, micrograms.
    public var vitaminD: Double?
    /// The purine level, milligrams for the day, above which the row adds its NEUTRAL
    /// note. Emitted as a target for convenience of transport; it is NOT a ceiling and
    /// purines are never judged — see `Micronutrient.purines`.
    public var purines: Double?
    /// Methylmercury's ceiling over the rolling WEEK, micrograms. A week's number, never
    /// divided into a per-day seventh.
    public var mercuryWeekly: Double?

    // Explicit keys, because four of the new ones are spelled all-lowercase on the wire
    // while their Swift names stay camelCase. Every pre-existing key is listed with the
    // exact spelling the synthesized coder used, so nothing about the old payload's
    // decoding changes.
    enum CodingKeys: String, CodingKey {
        case calories, protein, fat, carbs, carbsBase, fiber
        case sodium, satFat, potassium, sugar, calcium, omega3, magnesium
        case transFat = "transfat"
        case addedSugar = "addedsugar"
        case selenium
        case vitaminD = "vitamind"
        case purines
        case mercuryWeekly = "mercury_weekly"
    }
}

/// A BAND target: a floor to reach and a ceiling to stay under, both in the nutrient's
/// own unit. Both members are optional because an archive (or an older generator) may
/// record one edge and not the other; a band VERDICT needs both, and a half-band shows
/// the value with no judgment rather than silently judging against the edge it happens
/// to have — see `DietSemantics.bandGoalStatus`.
public struct DietBandTarget: Decodable, Equatable, Sendable {
    public var floor: Double?
    public var ceiling: Double?
    public init(floor: Double? = nil, ceiling: Double? = nil) {
        self.floor = floor; self.ceiling = ceiling
    }
    /// The complete band, or nil when either edge is missing.
    public var edges: (floor: Double, ceiling: Double)? {
        guard let floor, let ceiling else { return nil }
        return (floor, ceiling)
    }
}

/// `DIET_TODAY` — the normalized snapshot of today.
public struct DietToday: Decodable, Equatable, Sendable {
    public var date: String
    public var dayStyle: String?
    public var dayType: String?
    public var weight: DietWeight?
    public var exercise: [DietExercise]
    public var meals: [DietMeal]
    public var targets: DietTargets
    /// The trailing-window aggregate for the nutrients whose limit is defined over a week
    /// rather than a day (see `DietRollingWindow`). It rides INSIDE `DIET_TODAY` because
    /// that is where the generator writes it — the bridge passes the day literal through
    /// verbatim — so it is a member of the day, not a sibling of it. Absent → nil → the
    /// rolling gauges hide entirely.
    public var rolling7: DietRollingWindow?

    // Tolerate a generator that omits the collections entirely (older files) by
    // defaulting them to empty rather than failing the whole decode.
    enum CodingKeys: String, CodingKey {
        case date, dayStyle, dayType, weight, exercise, meals, targets, rolling7
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        dayStyle = try c.decodeIfPresent(String.self, forKey: .dayStyle)
        dayType = try c.decodeIfPresent(String.self, forKey: .dayType)
        weight = try c.decodeIfPresent(DietWeight.self, forKey: .weight)
        exercise = try c.decodeIfPresent([DietExercise].self, forKey: .exercise) ?? []
        meals = try c.decodeIfPresent([DietMeal].self, forKey: .meals) ?? []
        targets = try c.decodeIfPresent(DietTargets.self, forKey: .targets) ?? DietTargets()
        rolling7 = try c.decodeIfPresent(DietRollingWindow.self, forKey: .rolling7)
    }
    // A memberwise init for tests/previews (the custom decoder suppresses the
    // synthesized one).
    public init(date: String, dayStyle: String? = nil, dayType: String? = nil,
         weight: DietWeight? = nil, exercise: [DietExercise] = [],
         meals: [DietMeal] = [], targets: DietTargets = DietTargets(),
         rolling7: DietRollingWindow? = nil) {
        self.date = date; self.dayStyle = dayStyle; self.dayType = dayType
        self.weight = weight; self.exercise = exercise; self.meals = meals
        self.targets = targets; self.rolling7 = rolling7
    }
}

/// A proposed meal idea.
public struct DietIdea: Decodable, Equatable, Sendable {
    public var name: String
    public var time: String?
    public var items: [DietItem]
    public var notes: String?

    enum CodingKeys: String, CodingKey { case name, time, items, notes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        items = try c.decodeIfPresent([DietItem].self, forKey: .items) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
    public init(name: String, time: String? = nil, items: [DietItem] = [], notes: String? = nil) {
        self.name = name; self.time = time; self.items = items; self.notes = notes
    }
}

/// `PROPOSED_DIET` — meal ideas. The bridge already normalizes empty `ideas` to a
/// null `proposed`, so a decoded value always has at least one idea.
public struct DietProposed: Decodable, Equatable, Sendable {
    public var date: String?
    public var source: String?
    public var ideas: [DietIdea]
    public var gapNote: String?

    enum CodingKeys: String, CodingKey { case date, source, ideas, gapNote }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        ideas = try c.decodeIfPresent([DietIdea].self, forKey: .ideas) ?? []
        gapNote = try c.decodeIfPresent(String.self, forKey: .gapNote)
    }
}

/// One user weight goal (bridge/generator ≥ the labeled-targets rollout): a weight
/// plus an optional planned date and prerendered progress strings. Targets are user
/// goals, not fixed program phases — there may be zero to N of them, in display
/// order. Every field but `id`/`title`/`weight` may be absent; `short` falls back
/// to `title` (see `shortLabel`). The bar fields are prerendered exactly like the
/// legacy `raceBar*`/`maintBar*` fields — render them as-is, never parse numbers
/// out of the label. Unknown extra fields decode-and-ignore like the rest.
public struct DietTarget: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// A tight-space label (chips, chart rules); nil in old data → use `title`.
    public var short: String?
    public var weight: Double
    /// `yyyy-MM-dd`, or nil for an undated goal.
    public var date: String?
    /// Days until `date` (negative when past); nil when undated.
    public var daysLeft: Int?
    /// lb/wk needed to hit the date from the latest weigh-in; nil when undated,
    /// past, or already achieved.
    public var requiredPace: Double?
    /// Latest weigh-in at or under `weight`.
    public var achieved: Bool?
    /// Prerendered 0…20 bar fill, like the legacy `*BarFilled` fields.
    public var barFilled: Double?
    /// Prerendered progress label, like the legacy `*BarLabel` fields.
    public var barLabel: String?

    /// The label for tight spaces, falling back to `title` when `short` is absent.
    public var shortLabel: String { short ?? title }

    // A memberwise init (with defaults) for the legacy-fallback synthesis, tests,
    // and previews. Synthesized Decodable keeps this available and ignores unknown
    // keys; `id`/`title`/`weight` are required in emitted data.
    public init(id: String, title: String, short: String? = nil, weight: Double,
         date: String? = nil, daysLeft: Int? = nil, requiredPace: Double? = nil,
         achieved: Bool? = nil, barFilled: Double? = nil, barLabel: String? = nil) {
        self.id = id; self.title = title; self.short = short; self.weight = weight
        self.date = date; self.daysLeft = daysLeft; self.requiredPace = requiredPace
        self.achieved = achieved; self.barFilled = barFilled; self.barLabel = barLabel
    }
}

/// `DIET_PROGRESS` — numbers plus prerendered label strings, passed through
/// verbatim by the bridge. Every field is optional; the app renders the labels
/// as-is and never parses numbers out of the label strings.
///
/// `targets` is the new, general shape (zero to N labeled weight goals); the
/// legacy `raceTarget`/`raceDate`/`maintTarget`/`*Bar*` fields remain during the
/// transition and are synthesized into `targets` when it's absent (see
/// `DietSemantics.displayTargets`), so rendering has one code path.
public struct DietProgress: Decodable, Equatable, Sendable {
    public var startWeight: Double?
    public var raceTarget: Double?
    public var maintTarget: Double?
    public var raceDate: String?
    public var targets: [DietTarget]?
    public var troughPace: Double?
    public var rawPace: Double?
    public var fatPace: Double?
    public var leanPace: Double?
    public var paceScale: Double?
    public var leanScale: Double?
    public var paceZone: String?
    public var fatZone: String?
    public var leanZone: String?
    public var barColor: String?
    public var raceBarFilled: Double?
    public var maintBarFilled: Double?
    public var raceBarLabel: String?
    public var maintBarLabel: String?
    public var paceBarLabel: String?
    public var fatBarLabel: String?
    public var leanBarLabel: String?
    public var paceSubMain: String?
    public var paceSubZone: String?
    public var paceSubLow: String?
    public var paceSubHigh: String?
    public var fatSubMain: String?
    public var leanSubMain: String?
    public var trajectory: String?
    public init(startWeight: Double? = nil, raceTarget: Double? = nil, maintTarget: Double? = nil,
                raceDate: String? = nil, targets: [DietTarget]? = nil, troughPace: Double? = nil,
                rawPace: Double? = nil, fatPace: Double? = nil, leanPace: Double? = nil,
                paceScale: Double? = nil, leanScale: Double? = nil, paceZone: String? = nil,
                fatZone: String? = nil, leanZone: String? = nil, barColor: String? = nil,
                raceBarFilled: Double? = nil, maintBarFilled: Double? = nil,
                raceBarLabel: String? = nil, maintBarLabel: String? = nil,
                paceBarLabel: String? = nil, fatBarLabel: String? = nil, leanBarLabel: String? = nil,
                paceSubMain: String? = nil, paceSubZone: String? = nil, paceSubLow: String? = nil,
                paceSubHigh: String? = nil, fatSubMain: String? = nil, leanSubMain: String? = nil,
                trajectory: String? = nil) {
        self.startWeight = startWeight; self.raceTarget = raceTarget; self.maintTarget = maintTarget
        self.raceDate = raceDate; self.targets = targets; self.troughPace = troughPace
        self.rawPace = rawPace; self.fatPace = fatPace; self.leanPace = leanPace
        self.paceScale = paceScale; self.leanScale = leanScale; self.paceZone = paceZone
        self.fatZone = fatZone; self.leanZone = leanZone; self.barColor = barColor
        self.raceBarFilled = raceBarFilled; self.maintBarFilled = maintBarFilled
        self.raceBarLabel = raceBarLabel; self.maintBarLabel = maintBarLabel
        self.paceBarLabel = paceBarLabel; self.fatBarLabel = fatBarLabel; self.leanBarLabel = leanBarLabel
        self.paceSubMain = paceSubMain; self.paceSubZone = paceSubZone; self.paceSubLow = paceSubLow
        self.paceSubHigh = paceSubHigh; self.fatSubMain = fatSubMain; self.leanSubMain = leanSubMain
        self.trajectory = trajectory
    }
}

/// A short attributed quote in the coach section.
public struct DietQuote: Decodable, Equatable, Sendable {
    public var text: String
    public var author: String?
}

/// `DIET_COACH` — the coach's notes, "what's ahead", and a closing quote. Note
/// strings carry a limited HTML subset (`<strong>` + a few entities), formatted
/// for display by `CoachHTML`, never here.
public struct DietCoach: Decodable, Equatable, Sendable {
    public var date: String?
    public var title: String?
    public var notes: [String]
    public var ahead: [String]
    public var quote: DietQuote?

    enum CodingKeys: String, CodingKey { case date, title, notes, ahead, quote }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        ahead = try c.decodeIfPresent([String].self, forKey: .ahead) ?? []
        quote = try c.decodeIfPresent(DietQuote.self, forKey: .quote)
    }
}

/// One weigh-in from `weight-log.csv`, in chronological order. `lbs` is always
/// present; the rest are null when the CSV cell was blank.
public struct WeightPoint: Decodable, Equatable, Sendable {
    public var date: String
    public var lbs: Double
    public var kg: Double?
    public var phase: String?
    public var bf: Double?
    public var leanLbs: Double?
    public var notes: String?
    public init(date: String, lbs: Double, kg: Double? = nil, phase: String? = nil,
                bf: Double? = nil, leanLbs: Double? = nil, notes: String? = nil) {
        self.date = date; self.lbs = lbs; self.kg = kg; self.phase = phase
        self.bf = bf; self.leanLbs = leanLbs; self.notes = notes
    }
}

/// One nutrient's aggregate for a single day in `nutrientSeries` (bridge ≥ 0.21.0):
/// the sum of KNOWN item values only, and the item counts behind it. `sum` NEVER
/// includes an unknown item (unknown ≠ 0); `unknown > 0` means the day is PARTIAL — a
/// lower bound, which matters for a floor nutrient. This mirrors the per-day
/// `MicronutrientTotal` shape but is history-wide, one entry per logged day.
public struct NutrientDayValue: Decodable, Equatable, Sendable {
    public var sum: Double
    public var known: Int
    public var unknown: Int

    public init(sum: Double, known: Int, unknown: Int) {
        self.sum = sum; self.known = known; self.unknown = unknown
    }
}

/// One day in `nutrientSeries`: an ISO `yyyy-MM-dd` date, the per-nutrient
/// aggregates PRESENT that day, keyed by the bridge's short nutrient key
/// (`cal`/`p`/`f`/`c`/`fiber`/`na`/`satf`/`sug`/`k`/`ca`/`o3`/`mg`/`unsat`), and — when
/// the archive recorded them — THAT DAY's own targets. A nutrient
/// key is present only when at least one item that day carried a known value; a key
/// ABSENT from `nutrients` is a GAP (all-unknown that day), never a zero. Pure data —
/// every gap-aware computation lives in `NutrientTrends`, never here.
public struct NutrientDay: Decodable, Equatable, Sendable {
    public var date: String
    public var nutrients: [String: NutrientDayValue]
    /// That day's FROZEN targets as the archive recorded them, or nil when the day never
    /// archived any — which is a THIRD state, distinct from both zero and "the target we
    /// have today". Two of these targets genuinely move day to day: `calories` is
    /// recomputed from the day's logged exercise, and `carbs` carries an optional
    /// add-back band above `carbsBase`. Judging a past day against today's numbers is
    /// therefore a category error, so `NutrientTrends` treats a nil here (or a nil member
    /// inside it) as TARGET-UNKNOWN for that day and never substitutes any other day's.
    /// An OMITTED `carbsBase` with a present `carbs` is meaningful: that day was a
    /// carb-load day, whose full carb number is a genuine target rather than a floor.
    public var targets: DietTargets?

    enum CodingKeys: String, CodingKey { case date, nutrients, targets }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        nutrients = try c.decodeIfPresent([String: NutrientDayValue].self, forKey: .nutrients) ?? [:]
        // decodeIfPresent, so an older bridge that sends no per-day targets at all decodes
        // to nil rather than failing — and an explicit `null` reads the same as absent.
        targets = try c.decodeIfPresent(DietTargets.self, forKey: .targets)
    }
    // A memberwise init for tests/previews (the custom decoder suppresses the
    // synthesized one).
    public init(date: String, nutrients: [String: NutrientDayValue] = [:],
                targets: DietTargets? = nil) {
        self.date = date; self.nutrients = nutrients; self.targets = targets
    }
}

/// One logged food row inside a `sourceSeries` day (bridge ≥ 0.28.0): the item's name
/// and the nutrients it is KNOWN to have contributed, keyed by the same short nutrient
/// key `NutrientDay` uses (`cal`/`p`/`f`/`c`/`fiber`/`na`/`satf`/`sug`/`k`/`ca`/`o3`/`mg`/
/// `unsat`).
///
/// UNKNOWN IS NOT ZERO, and this shape is where that rule is carried at ITEM
/// granularity: `n` holds ONLY the keys whose cell was actually known for this row. A
/// blank cell is OMITTED, never written as 0 — a food credited with `na: 0` reads as a
/// food that supplied no sodium, which the log never claimed. A written 0 IS a known
/// zero and is present. The bridge drops a row that knows nothing at all, so an item
/// here always carries at least one key. Pure data: every aggregation over it lives in
/// `NutrientSources`.
public struct SourceItem: Decodable, Equatable, Sendable {
    public var name: String
    /// Known contributions only, by nutrient key. A key's ABSENCE is unknown, never 0.
    public var n: [String: Double]

    enum CodingKeys: String, CodingKey { case name, n }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        n = try c.decodeIfPresent([String: Double].self, forKey: .n) ?? [:]
    }
    // A memberwise init for tests/previews (the custom decoder suppresses the
    // synthesized one).
    public init(name: String, n: [String: Double] = [:]) {
        self.name = name; self.n = n
    }
}

/// `rolling7` — the TRAILING-WINDOW aggregate the generator emits INSIDE `DIET_TODAY`,
/// the one thing a per-day series structurally cannot answer cheaply: a nutrient whose
/// limit is defined over a WEEK (methylmercury) needs the week's total, not seven day
/// totals the app would have to re-add across the series' gaps.
///
/// NOTE THE KEY NAMESPACE, which is NOT the one the rest of the payload uses. `nutrients`
/// is keyed by the LOG COLUMN key (`mercury_ug`, `omega3_mg`) — the generator's own
/// column names — while every per-item field and every `nutrientSeries` day is keyed by
/// the short app key (`hg`, `o3`). Both are the same nutrient; only the spelling differs
/// by surface, so the lookup goes through `Micronutrient.logKey`.
///
/// The same UNKNOWN-IS-NOT-ZERO discipline as everywhere else, at ITEM granularity inside
/// the window. A nutrient with no known contributor in the window is OMITTED entirely —
/// the app then renders "not tracked yet" rather than a phantom zero week.
///
/// Absent on an older generator, and every member is tolerant of omission, so a partial or
/// reshaped block degrades to "no window" instead of failing the WHOLE snapshot decode
/// (`decodeIfPresent` throws on a present-but-malformed value, which would take the entire
/// Health tab down over one optional section).
public struct DietRollingWindow: Decodable, Equatable, Sendable {
    /// The window's length in days, named on the wire so the label and the chip come from
    /// the data rather than from a constant the app assumes.
    public var days: Int
    /// The window's first and last day (`yyyy-MM-dd`), when the generator names them.
    public var from: String?
    public var to: String?
    /// Per-nutrient aggregates over the window, keyed by LOG COLUMN key (see above).
    public var nutrients: [String: RollingNutrientTotal]

    enum CodingKeys: String, CodingKey { case days, from, to, nutrients }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A `rolling7` block that omits its own length is by definition the 7-day one.
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 7
        from = try c.decodeIfPresent(String.self, forKey: .from)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        // `try?` on the whole lookup, not `decodeIfPresent` alone: a `nutrients` map whose
        // VALUES are off-shape must degrade to "no window" rather than throw, which would
        // take the entire snapshot decode — and with it the Health tab — down with it.
        nutrients = (try? c.decode([String: RollingNutrientTotal].self,
                                   forKey: .nutrients)) ?? [:]
    }
    public init(days: Int = 7, from: String? = nil, to: String? = nil,
                nutrients: [String: RollingNutrientTotal] = [:]) {
        self.days = days; self.from = from; self.to = to; self.nutrients = nutrients
    }
}

/// One nutrient's aggregate over the rolling window.
///
/// `known` is the SUMMED VALUE of the items that carried one — NOT a count, despite the
/// name, which is why the counts beside it are spelled `knownCount`/`unknownCount`. Getting
/// that backwards would render an item count as a dose, so the field names are mirrored
/// from the generator exactly and renamed nowhere.
public struct RollingNutrientTotal: Decodable, Equatable, Sendable {
    /// The summed value of the KNOWN contributors in the window, in the nutrient's unit.
    public var known: Double
    /// How many items in the window carried a value, and how many did not. An item that did
    /// not is UNKNOWN, never a zero, so any `unknownCount > 0` makes `known` a floor.
    public var knownCount: Int
    public var unknownCount: Int

    enum CodingKeys: String, CodingKey { case known, knownCount, unknownCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        known = try c.decodeIfPresent(Double.self, forKey: .known) ?? 0
        knownCount = try c.decodeIfPresent(Int.self, forKey: .knownCount) ?? 0
        unknownCount = try c.decodeIfPresent(Int.self, forKey: .unknownCount) ?? 0
    }
    public init(known: Double, knownCount: Int, unknownCount: Int) {
        self.known = known; self.knownCount = knownCount; self.unknownCount = unknownCount
    }
}

/// One day in `sourceSeries` (bridge ≥ 0.28.0): an ISO `yyyy-MM-dd` date and that day's
/// logged food items in logged order, each with its KNOWN nutrient contributions. This
/// is what `nutrientSeries` structurally cannot answer — not "how much magnesium that
/// day" but "which foods delivered it". Capped by the bridge to the most recent 45
/// dates (tighter than the nutrient series' 90 because the payload is per item), so any
/// range shown over it is capped there too.
public struct SourceDay: Decodable, Equatable, Sendable {
    public var date: String
    public var items: [SourceItem]

    enum CodingKeys: String, CodingKey { case date, items }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        items = try c.decodeIfPresent([SourceItem].self, forKey: .items) ?? []
    }
    public init(date: String, items: [SourceItem] = []) {
        self.date = date; self.items = items
    }
}

/// One day in `exerciseSeries` (bridge ≥ 0.28.0): the date, the summed session calories,
/// and how many sessions were logged. Note the DELIBERATE asymmetry with the nutrient
/// stack, carried from the bridge: a blank session-calorie counts as 0 rather than
/// unknown (exercise kcal is not a micronutrient, and the session COUNT still records
/// that it happened). A date with no sessions never appears at all, so a rest day is a
/// GAP here, never an invented 0-kcal point — which is exactly why the correlation
/// engine pairs on dates present rather than filling missing days.
public struct ExerciseDay: Decodable, Equatable, Sendable {
    public var date: String
    public var kcal: Double
    public var sessions: Int

    enum CodingKeys: String, CodingKey { case date, kcal, sessions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        kcal = try c.decodeIfPresent(Double.self, forKey: .kcal) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
    }
    public init(date: String, kcal: Double = 0, sessions: Int = 0) {
        self.date = date; self.kcal = kcal; self.sessions = sessions
    }
}

/// The tier a day's data came from (bridge ≥ 0.7.0). `live` is today; `archived`
/// is a past day served from its saved `diet-today.js` copy (full targets, judged
/// like today); `reconstructed` is a past day rebuilt from the append-only CSVs
/// (no targets recorded, so rendered WITHOUT judgment colors). An absent/unknown
/// value from an older bridge reads as `live`.
public enum DietFidelity: String, Equatable, Sendable {
    case live, archived, reconstructed
}

/// The whole `GET /jesse/diet` response. `today` is always present (the bridge
/// returns 503 otherwise); every other section is null when its file was
/// missing/unparseable, with a human-readable line in `errors`.
///
/// `availableDays`/`historical`/`fidelity` are additive (bridge ≥ 0.7.0) and all
/// optional so an older bridge's payload (which omits them) still decodes cleanly.
public struct DietSnapshot: Decodable, Equatable, Sendable {
    public var asOf: String
    public var todayMtime: String?
    public var today: DietToday
    public var proposed: DietProposed?
    public var progress: DietProgress?
    public var coach: DietCoach?
    public var weightSeries: [WeightPoint]?
    public var errors: [String]
    /// Per-day, per-nutrient history aggregate (bridge ≥ 0.21.0), ascending by date,
    /// most recent 90 logged days. The source for the per-nutrient trend charts and the
    /// coach's multi-window rollup. Absent/empty on an older bridge → the trend
    /// affordance hides, no crash. UNKNOWN ≠ ZERO: every computation over this runs only
    /// on days where the nutrient key is present (see `NutrientTrends`), and only on the
    /// days that carry their own `targets` where a verdict is involved.
    public var nutrientSeries: [NutrientDay]?
    /// Per-day, per-ITEM food history (bridge ≥ 0.28.0), ascending by date, most recent 45
    /// logged days — the source for the Sources view ("which foods delivered this
    /// nutrient"). Absent on an older bridge → the Sources affordance hides, no crash.
    /// UNKNOWN ≠ ZERO: an item carries only the nutrient keys it actually knows, so every
    /// aggregate over this runs on known contributions only (see `NutrientSources`).
    public var sourceSeries: [SourceDay]?
    /// Per-day exercise aggregate (bridge ≥ 0.28.0), ascending by date, most recent 90
    /// logged days. Absent on an older bridge → the Correlations affordance hides, no
    /// crash. A rest day is ABSENT rather than a 0-kcal point, so a missing date is a gap
    /// and never a zero-training day.
    public var exerciseSeries: [ExerciseDay]?
    /// Every date the app can page to (union of the logs + archives + today),
    /// sorted ascending. Absent on an old bridge → paging stays disabled.
    public var availableDays: [String]?
    /// True for a past day, false/absent for today.
    public var historical: Bool?
    /// `"live" | "archived" | "reconstructed"`; absent on an old bridge.
    public var fidelity: String?

    enum CodingKeys: String, CodingKey {
        case asOf, todayMtime, today, proposed, progress, coach, weightSeries, errors
        case nutrientSeries, sourceSeries, exerciseSeries
        case availableDays, historical, fidelity
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf) ?? ""
        todayMtime = try c.decodeIfPresent(String.self, forKey: .todayMtime)
        today = try c.decode(DietToday.self, forKey: .today)
        proposed = try c.decodeIfPresent(DietProposed.self, forKey: .proposed)
        progress = try c.decodeIfPresent(DietProgress.self, forKey: .progress)
        coach = try c.decodeIfPresent(DietCoach.self, forKey: .coach)
        weightSeries = try c.decodeIfPresent([WeightPoint].self, forKey: .weightSeries)
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
        nutrientSeries = try c.decodeIfPresent([NutrientDay].self, forKey: .nutrientSeries)
        sourceSeries = try c.decodeIfPresent([SourceDay].self, forKey: .sourceSeries)
        exerciseSeries = try c.decodeIfPresent([ExerciseDay].self, forKey: .exerciseSeries)
        availableDays = try c.decodeIfPresent([String].self, forKey: .availableDays)
        historical = try c.decodeIfPresent(Bool.self, forKey: .historical)
        fidelity = try c.decodeIfPresent(String.self, forKey: .fidelity)
    }
    // A memberwise init for tests/previews (the custom decoder suppresses the
    // synthesized one).
    public init(asOf: String = "", todayMtime: String? = nil, today: DietToday,
         proposed: DietProposed? = nil, progress: DietProgress? = nil,
         coach: DietCoach? = nil, weightSeries: [WeightPoint]? = nil,
         errors: [String] = [], nutrientSeries: [NutrientDay]? = nil,
         sourceSeries: [SourceDay]? = nil, exerciseSeries: [ExerciseDay]? = nil,
         availableDays: [String]? = nil,
         historical: Bool? = nil, fidelity: String? = nil) {
        self.asOf = asOf; self.todayMtime = todayMtime; self.today = today
        self.proposed = proposed; self.progress = progress; self.coach = coach
        self.weightSeries = weightSeries; self.errors = errors
        self.nutrientSeries = nutrientSeries
        self.sourceSeries = sourceSeries; self.exerciseSeries = exerciseSeries
        self.availableDays = availableDays; self.historical = historical
        self.fidelity = fidelity
    }

    /// Whether this snapshot is a past day (not today). Absent → today.
    public var isHistorical: Bool { historical ?? false }
    /// The data tier, defaulting an absent/unknown value to `.live`.
    public var fidelityKind: DietFidelity { DietFidelity(rawValue: fidelity ?? "live") ?? .live }
    /// A reconstructed day carries no targets, so it renders WITHOUT any judgment.
    public var isNeutral: Bool { fidelityKind == .reconstructed }

    /// Decode a snapshot from raw bytes with the app's shared decoder settings.
    public static func decode(from data: Data) throws -> DietSnapshot {
        try JSONDecoder().decode(DietSnapshot.self, from: data)
    }
}
