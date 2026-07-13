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
struct DietItem: Decodable, Equatable, Sendable {
    var item: String
    var amount: String?
    var cal: Double?
    var p: Double?
    var f: Double?
    var c: Double?
    var fiber: Double?
}

/// A logged meal: a name, an optional `HH:MM` time, and its items.
struct DietMeal: Decodable, Equatable, Sendable {
    var name: String
    var time: String?
    var items: [DietItem]
}

/// A logged exercise session. Every field but `type` may be absent.
struct DietExercise: Decodable, Equatable, Sendable {
    var type: String
    var time: String?
    var desc: String?
    var distance: Double?
    var unit: String?
    var duration: String?
    var pace: String?
    var avgHR: Double?
    var calories: Double?
}

/// The day's weigh-in, or null on a non-weigh-in day. `bf`/`mm` may be absent
/// even on a weigh-in day.
struct DietWeight: Decodable, Equatable, Sendable {
    var lbs: Double
    var kg: Double?
    var bf: Double?
    var mm: Double?
    var notes: String?
}

/// The day's macro/calorie targets. `carbsBase` and `fiber` may be absent in old
/// files (fiber defaults to 38 downstream — see `DietSemantics`).
struct DietTargets: Decodable, Equatable, Sendable {
    var calories: Double?
    var protein: Double?
    var fat: Double?
    var carbs: Double?
    var carbsBase: Double?
    var fiber: Double?
}

/// `DIET_TODAY` — the normalized snapshot of today.
struct DietToday: Decodable, Equatable, Sendable {
    var date: String
    var dayStyle: String?
    var dayType: String?
    var weight: DietWeight?
    var exercise: [DietExercise]
    var meals: [DietMeal]
    var targets: DietTargets

    // Tolerate a generator that omits the collections entirely (older files) by
    // defaulting them to empty rather than failing the whole decode.
    enum CodingKeys: String, CodingKey {
        case date, dayStyle, dayType, weight, exercise, meals, targets
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        dayStyle = try c.decodeIfPresent(String.self, forKey: .dayStyle)
        dayType = try c.decodeIfPresent(String.self, forKey: .dayType)
        weight = try c.decodeIfPresent(DietWeight.self, forKey: .weight)
        exercise = try c.decodeIfPresent([DietExercise].self, forKey: .exercise) ?? []
        meals = try c.decodeIfPresent([DietMeal].self, forKey: .meals) ?? []
        targets = try c.decodeIfPresent(DietTargets.self, forKey: .targets) ?? DietTargets()
    }
    // A memberwise init for tests/previews (the custom decoder suppresses the
    // synthesized one).
    init(date: String, dayStyle: String? = nil, dayType: String? = nil,
         weight: DietWeight? = nil, exercise: [DietExercise] = [],
         meals: [DietMeal] = [], targets: DietTargets = DietTargets()) {
        self.date = date; self.dayStyle = dayStyle; self.dayType = dayType
        self.weight = weight; self.exercise = exercise; self.meals = meals
        self.targets = targets
    }
}

/// A proposed meal idea.
struct DietIdea: Decodable, Equatable, Sendable {
    var name: String
    var time: String?
    var items: [DietItem]
    var notes: String?

    enum CodingKeys: String, CodingKey { case name, time, items, notes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        items = try c.decodeIfPresent([DietItem].self, forKey: .items) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
    init(name: String, time: String? = nil, items: [DietItem] = [], notes: String? = nil) {
        self.name = name; self.time = time; self.items = items; self.notes = notes
    }
}

/// `PROPOSED_DIET` — meal ideas. The bridge already normalizes empty `ideas` to a
/// null `proposed`, so a decoded value always has at least one idea.
struct DietProposed: Decodable, Equatable, Sendable {
    var date: String?
    var source: String?
    var ideas: [DietIdea]
    var gapNote: String?

    enum CodingKeys: String, CodingKey { case date, source, ideas, gapNote }
    init(from decoder: Decoder) throws {
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
struct DietTarget: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    /// A tight-space label (chips, chart rules); nil in old data → use `title`.
    var short: String?
    var weight: Double
    /// `yyyy-MM-dd`, or nil for an undated goal.
    var date: String?
    /// Days until `date` (negative when past); nil when undated.
    var daysLeft: Int?
    /// lb/wk needed to hit the date from the latest weigh-in; nil when undated,
    /// past, or already achieved.
    var requiredPace: Double?
    /// Latest weigh-in at or under `weight`.
    var achieved: Bool?
    /// Prerendered 0…20 bar fill, like the legacy `*BarFilled` fields.
    var barFilled: Double?
    /// Prerendered progress label, like the legacy `*BarLabel` fields.
    var barLabel: String?

    /// The label for tight spaces, falling back to `title` when `short` is absent.
    var shortLabel: String { short ?? title }

    // A memberwise init (with defaults) for the legacy-fallback synthesis, tests,
    // and previews. Synthesized Decodable keeps this available and ignores unknown
    // keys; `id`/`title`/`weight` are required in emitted data.
    init(id: String, title: String, short: String? = nil, weight: Double,
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
struct DietProgress: Decodable, Equatable, Sendable {
    var startWeight: Double?
    var raceTarget: Double?
    var maintTarget: Double?
    var raceDate: String?
    var targets: [DietTarget]?
    var troughPace: Double?
    var rawPace: Double?
    var fatPace: Double?
    var leanPace: Double?
    var paceScale: Double?
    var leanScale: Double?
    var paceZone: String?
    var fatZone: String?
    var leanZone: String?
    var barColor: String?
    var raceBarFilled: Double?
    var maintBarFilled: Double?
    var raceBarLabel: String?
    var maintBarLabel: String?
    var paceBarLabel: String?
    var fatBarLabel: String?
    var leanBarLabel: String?
    var paceSubMain: String?
    var paceSubZone: String?
    var paceSubLow: String?
    var paceSubHigh: String?
    var fatSubMain: String?
    var leanSubMain: String?
    var trajectory: String?
}

/// A short attributed quote in the coach section.
struct DietQuote: Decodable, Equatable, Sendable {
    var text: String
    var author: String?
}

/// `DIET_COACH` — the coach's notes, "what's ahead", and a closing quote. Note
/// strings carry a limited HTML subset (`<strong>` + a few entities), formatted
/// for display by `CoachHTML`, never here.
struct DietCoach: Decodable, Equatable, Sendable {
    var date: String?
    var title: String?
    var notes: [String]
    var ahead: [String]
    var quote: DietQuote?

    enum CodingKeys: String, CodingKey { case date, title, notes, ahead, quote }
    init(from decoder: Decoder) throws {
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
struct WeightPoint: Decodable, Equatable, Sendable {
    var date: String
    var lbs: Double
    var kg: Double?
    var phase: String?
    var bf: Double?
    var leanLbs: Double?
    var notes: String?
}

/// The tier a day's data came from (bridge ≥ 0.7.0). `live` is today; `archived`
/// is a past day served from its saved `diet-today.js` copy (full targets, judged
/// like today); `reconstructed` is a past day rebuilt from the append-only CSVs
/// (no targets recorded, so rendered WITHOUT judgment colors). An absent/unknown
/// value from an older bridge reads as `live`.
enum DietFidelity: String, Equatable, Sendable {
    case live, archived, reconstructed
}

/// The whole `GET /jesse/diet` response. `today` is always present (the bridge
/// returns 503 otherwise); every other section is null when its file was
/// missing/unparseable, with a human-readable line in `errors`.
///
/// `availableDays`/`historical`/`fidelity` are additive (bridge ≥ 0.7.0) and all
/// optional so an older bridge's payload (which omits them) still decodes cleanly.
struct DietSnapshot: Decodable, Equatable, Sendable {
    var asOf: String
    var todayMtime: String?
    var today: DietToday
    var proposed: DietProposed?
    var progress: DietProgress?
    var coach: DietCoach?
    var weightSeries: [WeightPoint]?
    var errors: [String]
    /// Every date the app can page to (union of the logs + archives + today),
    /// sorted ascending. Absent on an old bridge → paging stays disabled.
    var availableDays: [String]?
    /// True for a past day, false/absent for today.
    var historical: Bool?
    /// `"live" | "archived" | "reconstructed"`; absent on an old bridge.
    var fidelity: String?

    enum CodingKeys: String, CodingKey {
        case asOf, todayMtime, today, proposed, progress, coach, weightSeries, errors
        case availableDays, historical, fidelity
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf) ?? ""
        todayMtime = try c.decodeIfPresent(String.self, forKey: .todayMtime)
        today = try c.decode(DietToday.self, forKey: .today)
        proposed = try c.decodeIfPresent(DietProposed.self, forKey: .proposed)
        progress = try c.decodeIfPresent(DietProgress.self, forKey: .progress)
        coach = try c.decodeIfPresent(DietCoach.self, forKey: .coach)
        weightSeries = try c.decodeIfPresent([WeightPoint].self, forKey: .weightSeries)
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
        availableDays = try c.decodeIfPresent([String].self, forKey: .availableDays)
        historical = try c.decodeIfPresent(Bool.self, forKey: .historical)
        fidelity = try c.decodeIfPresent(String.self, forKey: .fidelity)
    }
    // A memberwise init for tests/previews (the custom decoder suppresses the
    // synthesized one).
    init(asOf: String = "", todayMtime: String? = nil, today: DietToday,
         proposed: DietProposed? = nil, progress: DietProgress? = nil,
         coach: DietCoach? = nil, weightSeries: [WeightPoint]? = nil,
         errors: [String] = [], availableDays: [String]? = nil,
         historical: Bool? = nil, fidelity: String? = nil) {
        self.asOf = asOf; self.todayMtime = todayMtime; self.today = today
        self.proposed = proposed; self.progress = progress; self.coach = coach
        self.weightSeries = weightSeries; self.errors = errors
        self.availableDays = availableDays; self.historical = historical
        self.fidelity = fidelity
    }

    /// Whether this snapshot is a past day (not today). Absent → today.
    var isHistorical: Bool { historical ?? false }
    /// The data tier, defaulting an absent/unknown value to `.live`.
    var fidelityKind: DietFidelity { DietFidelity(rawValue: fidelity ?? "live") ?? .live }
    /// A reconstructed day carries no targets, so it renders WITHOUT any judgment.
    var isNeutral: Bool { fidelityKind == .reconstructed }

    /// Decode a snapshot from raw bytes with the app's shared decoder settings.
    static func decode(from data: Data) throws -> DietSnapshot {
        try JSONDecoder().decode(DietSnapshot.self, from: data)
    }
}
