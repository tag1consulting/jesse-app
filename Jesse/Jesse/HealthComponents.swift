import SwiftUI
import UIKit

// Shared building blocks for the Health tab. Every view here is a pure function of
// its inputs — the numbers and statuses are computed upstream by `DietSemantics` /
// `HealthDisplay`; nothing here decides a color band or a remaining string. Dark
// mode falls out of the semantic colors and grouped backgrounds; no emoji.

/// Map a semantic status to a display color. Yellow → orange for legibility;
/// `suspended` → secondary (shown plain, no judgment).
func statusColor(_ status: DietSemantics.Status) -> Color {
    switch status {
    case .red: return .red
    case .yellow: return .orange
    case .green: return .green
    case .suspended: return .secondary
    }
}

/// The goal glyph (≥ floor, ≤ ceiling, ↕ window) in a subtle chip.
struct GoalChip: View {
    let goal: DietSemantics.Goal
    var body: some View {
        Text(goal.glyph)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color(.tertiarySystemFill)))
            .accessibilityLabel(goalName)
    }
    private var goalName: String {
        switch goal { case .floor: return "at least"; case .ceiling: return "at most"; case .window: return "within range" }
    }
}

/// A thin status-tinted progress meter. `fraction` is clamped to [0, 1] for the
/// fill; values over target simply peg full (the remaining text says "over").
struct StatusMeter: View {
    let fraction: Double?
    let status: DietSemantics.Status
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(statusColor(status))
                    .frame(width: geo.size.width * min(max(fraction ?? 0, 0), 1))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Activity rings

/// A reusable Apple-Watch-style activity ring: a thick rounded stroke on a dim
/// track, animating from empty to `fraction` on appear. `fraction` is expected
/// already clamped to [0, 1] (see `HealthRing.fill`); the color is the semantics
/// engine's status color, passed in so a ring can never pick its own judgment.
struct ActivityRing<Center: View>: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 14
    @ViewBuilder var center: Center

    @State private var animated = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), style: StrokeStyle(lineWidth: lineWidth))
            Circle()
                .trim(from: 0, to: animated ? fraction : 0)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { animated = true }
        }
    }
}

/// The calories hero ring: one large ring whose fill is intake/target clamped, its
/// color the engine's calorie status, the remaining number large in the center with
/// the engine's remaining annotation beneath it, and the net line below when a burn
/// exists. Tapping opens the calories explainer.
struct CaloriesHeroRing: View {
    let gauge: MetricGauge
    let net: NetCalories
    var onTap: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onTap) {
                ActivityRing(fraction: HealthRing.fill(gauge), color: statusColor(gauge.status), lineWidth: 20) {
                    VStack(spacing: 2) {
                        Text(CaloriesHero.centerNumber(gauge))
                            .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(statusColor(gauge.status))
                        Text(CaloriesHero.centerCaption(gauge))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
                .frame(width: 210, height: 210)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Calories: \(CaloriesHero.centerCaption(gauge))")

            if let line = CaloriesHero.netLine(net) {
                Text(line)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A small macro ring for the Today row: the engine's status color, the current
/// grams compact in the center, the macro name on ONE line beneath with its goal
/// glyph. A suspended metric (fiber on a carb-load day) renders neutral gray via the
/// status color. Tapping opens that macro's explainer.
struct MacroRing: View {
    let gauge: MetricGauge
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 7) {
                ActivityRing(fraction: HealthRing.fill(gauge), color: statusColor(gauge.status), lineWidth: 7) {
                    Text(HealthRing.centerLabel(gauge))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(statusColor(gauge.status))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(4)
                }
                .frame(width: 64, height: 64)
                HStack(spacing: 3) {
                    Text(gauge.label)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(gauge.goal.glyph)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gauge.label): \(HealthRing.centerLabel(gauge)), \(gauge.remaining)")
    }
}

// MARK: - Neutral (no-judgment) rings for a reconstructed day

/// A full neutral ring track — no colored progress arc, because a reconstructed day
/// has no target to judge against. Frames a plain total.
struct NeutralRing<Center: View>: View {
    var lineWidth: CGFloat = 14
    @ViewBuilder var center: Center
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: lineWidth))
            center
        }
    }
}

/// The neutral calories hero: a full neutral ring with the eaten total centered and
/// the burned/net caption below when exercise exists. No color, no judgment — the
/// day was rebuilt from logs and had no recorded targets.
struct NeutralCaloriesHero: View {
    let totals: MacroTotals
    let net: NetCalories

    var body: some View {
        VStack(spacing: 12) {
            NeutralRing(lineWidth: 20) {
                VStack(spacing: 2) {
                    Text(NeutralMode.caloriesCenter(totals))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let cap = NeutralMode.caloriesCaption(net: net) {
                        Text(cap)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .padding(12)
            }
            .frame(width: 210, height: 210)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Calories: \(NeutralMode.caloriesCenter(totals))")
    }
}

/// A small neutral macro ring: a full neutral ring with the gram total centered and
/// the macro name beneath. No goal glyph, no color.
struct NeutralMacroRing: View {
    let label: String
    let grams: Double
    var body: some View {
        VStack(spacing: 7) {
            NeutralRing(lineWidth: 7) {
                Text(NeutralMode.macroCenter(grams))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(4)
            }
            .frame(width: 64, height: 64)
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(NeutralMode.macroCenter(grams))")
    }
}

// MARK: - Stat & metric tiles

/// A stat tile: a caption title, a large rounded value, an optional colored zone
/// chip, and an optional short caption. Used side-by-side for pace and composition
/// (Weight & trend, Progress & pace). Tapping opens an explainer when wired.
struct StatTile: View {
    let title: String
    let value: String
    var zone: String? = nil
    var caption: String? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.bold).monospacedDigit())
            if let zone { ZoneChip(text: zone, zone: zone) }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))

        if let onTap {
            Button(action: onTap) { inner.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            inner
        }
    }
}

/// A metric cell in the exercise card's grid: a small uppercase caption over a
/// prominent rounded value.
struct MetricTile: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Calorie-source stacked bar (food journal summary)

/// Fixed macro-identity colors for the calorie-source bar and its legend —
/// independent of the status bands so the breakdown never reads as a judgment.
///
/// Fiber is a subset of carbs, so its identity color is not an independent hue: it is
/// the carbs color lightened toward white — the same teal family, clearly paler, so
/// the bar reads as carbs and its paler kin sitting side by side. The shade is derived
/// (not hand-picked) and resolved per color scheme: the carbs color is a system
/// dynamic color, so the derivation runs inside a `UIColor` dynamic provider that
/// resolves carbs in the active trait collection first, then lightens it. The result
/// is fully opaque — the bar's fiber segment sits over other content, so it must never
/// rely on alpha to look pale.
enum MacroColor {
    static let protein = Color.indigo
    static let carbs = Color.teal
    static let fat = Color.orange
    static let fiber = shade(ofSubEntry: carbs)

    /// How far a sub-entry macro's color is lightened toward white (0 = unchanged,
    /// 1 = white). High enough that carbs and fiber stay tellable apart at the bar's
    /// rendered height in both light and dark mode.
    static let subEntryLightenFraction: CGFloat = 0.5

    /// Derive a sub-entry macro's identity color from its parent's: the parent color,
    /// resolved per color scheme, lightened toward white and kept opaque.
    static func shade(ofSubEntry parent: Color) -> Color {
        Color(UIColor { traits in
            UIColor(parent).resolvedColor(with: traits)
                .lightenedTowardWhite(by: subEntryLightenFraction)
        })
    }

    /// Identity color for a macro, so no view hardcodes one. Fiber returns its
    /// carbs-derived shade.
    static func color(for macro: Macro) -> Color {
        switch macro {
        case .protein: return protein
        case .carbs: return carbs
        case .fiber: return fiber
        case .fat: return fat
        }
    }
}

private extension UIColor {
    /// This color blended toward white by `fraction` (0 = unchanged, 1 = white),
    /// staying fully opaque. Component blend in the resolved RGB space.
    func lightenedTowardWhite(by fraction: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let f = min(max(fraction, 0), 1)
        return UIColor(red: r + (1 - r) * f,
                       green: g + (1 - g) * f,
                       blue: b + (1 - b) * f,
                       alpha: 1)
    }
}

/// A single horizontal stacked bar of where the day's calories came from (protein /
/// carbs / fiber / fat at 4/4/4/9 kcal per gram), with a compact legend. Fiber is
/// carved out of carbs (its grams are a subset of carb grams), so carbs+fiber fill
/// the width the carb segment alone used to; a zero-fiber day renders no fiber
/// segment and looks exactly as it did before. The split math is pure and tested
/// (`HealthDisplay.calorieSplit`); this only draws it.
struct CalorieSourceBar: View {
    let split: HealthDisplay.CalorieSplit
    // Canonical order (Protein, Carbs, Fiber, Fat); the last segment fills the
    // remaining width so rounding never leaves a hairline gap at the cap edge.
    private var macros: [Macro] { Macro.allCases }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(macros.enumerated()), id: \.element) { index, macro in
                        Rectangle().fill(MacroColor.color(for: macro))
                            .frame(width: index == macros.count - 1
                                   ? nil : geo.size.width * split.fraction(for: macro))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                ForEach(macros, id: \.self) { macro in
                    legendItem(macro)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calorie sources: protein \(pct(split.proteinFraction)), carbs \(pct(split.netCarbsFraction)), fiber \(pct(split.fiberFraction)), fat \(pct(split.fatFraction))")
    }
    // The fiber entry reads as a sub-entry of carbs: it drops one hierarchy step
    // dimmer than the three real macros (the legend already sits at the type ramp's
    // floor — caption2 — so there's no smaller step to take here; the dimmer color
    // carries the sub-entry cue).
    private func legendItem(_ macro: Macro) -> some View {
        HStack(spacing: 4) {
            Circle().fill(MacroColor.color(for: macro)).frame(width: 8, height: 8)
            Text(macro.displayName)
                .foregroundStyle(macro.isSubEntry ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        }
    }
    private func pct(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
}

/// Renders a macro totals line as a single interpunct `Text` in the canonical order
/// (Protein · Carbs · Fiber · Fat), styling the fiber term as a sub-entry of carbs:
/// the three real-macro runs and the separators inherit the surrounding view's base
/// font and color, while the fiber run takes `fiberFont` (one type-ramp step smaller,
/// where the base has the headroom) and `fiberColor` (one hierarchy step dimmer).
/// Fiber's gram number stays present — only its type changes. Ordering comes from
/// `MacroLine.segments`, the same source the plain string uses, so a reorder can't
/// diverge between the styled and unstyled forms.
func macroCaptionText(_ totals: MacroTotals, includeFiber: Bool = true, units: Bool = true,
                      fiberFont: Font, fiberColor: Color) -> Text {
    let segments = MacroLine.segments(totals, includeFiber: includeFiber, units: units)
    var line = AttributedString()
    for (index, segment) in segments.enumerated() {
        if index > 0 { line += AttributedString(" · ") }
        var run = AttributedString(segment.text)
        if segment.macro.isSubEntry {
            run.font = fiberFont.monospacedDigit()
            run.foregroundColor = fiberColor
        }
        line += run
    }
    return Text(line)
}

/// A full-width bar row for the macros-and-calories detail screen: goal chip,
/// label, value/target/percent, the meter, the remaining annotation, and any gated
/// flag. Tapping opens the row's explainer.
struct MetricBarRow: View {
    let gauge: MetricGauge
    /// When true (fiber), the row label reads as a sub-entry of carbs: one type-ramp
    /// step smaller (subheadline → footnote) and in the secondary color. The bar, the
    /// value, and its status color are untouched — only the label's type changes.
    var isSubEntry: Bool = false
    /// The explainer tap. Nil for a micronutrient row (no explainer wired): the row
    /// then renders identically minus the info-circle affordance and the button wrap.
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if notTracked {
            // "not tracked yet": no item that day carried the value. A neutral label +
            // caption, no numeric value, no filled bar — distinct from a real zero.
            HStack(spacing: 6) {
                GoalChip(goal: gauge.goal)
                Text(gauge.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(DietSemantics.notTrackedCaption)
                    .font(.caption).foregroundStyle(.secondary)
                // A tappable not-tracked row (a micronutrient drill-down) still opens the
                // sheet — with every item under "Not estimated" — so show the affordance.
                if onTap != nil {
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    GoalChip(goal: gauge.goal)
                    Text(gauge.label)
                        .font((isSubEntry ? Font.footnote : .subheadline).weight(.semibold))
                        .foregroundStyle(isSubEntry ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Spacer()
                    Text(valueTarget).font(.subheadline.monospacedDigit())
                        .foregroundStyle(statusColor(gauge.status))
                    if onTap != nil {
                        Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                StatusMeter(fraction: gauge.fraction, status: gauge.status)
                HStack {
                    Text(gauge.remaining).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let pct = percent {
                        Text(pct).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                // A partial micronutrient total is a floor — warn how many items were
                // not estimated so the "≥" is never read as a complete number.
                if let cap = DietSemantics.partialCaption(unknownItemCount: gauge.unknownItemCount) {
                    Label(cap, systemImage: "questionmark.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let flag = gauge.flag {
                    Label(flag, systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
    }

    /// The "not tracked yet" state: a micronutrient gauge with no known contributor.
    private var notTracked: Bool { gauge.knownItemCount == 0 }

    private var valueTarget: String {
        // A partial total is a floor: prefix "≥" so it's never shown as complete.
        let prefix = gauge.partial ? "≥" : ""
        let v = DietSemantics.fmt(gauge.value)
        if let t = gauge.target { return "\(prefix)\(v) / \(DietSemantics.fmt(t))\(gauge.unit)" }
        return "\(prefix)\(v)\(gauge.unit)"
    }
    private var percent: String? {
        guard let f = gauge.fraction else { return nil }
        return "\(gauge.partial ? "≥" : "")\(Int((f * 100).rounded()))%"
    }
}

// MARK: - Explainer sheet

/// The "understand the number" content: a title, the live value/target line, and a
/// few short second-person paragraphs. Content is baked in (`Explainers`),
/// parameterized with live numbers where noted.
///
/// `drilldown` is the optional "what fed this number" extension: when a metric that
/// has a food breakdown is tapped (a macro or the calorie total), the ranked
/// contributing foods and the grounding for the on-device insight ride along here, so
/// the same sheet hosts both the explanation and the facts. Nil for metrics with no
/// foods behind them (pace, weight, net) — those render as prose only, unchanged.
struct Explainer: Identifiable, Equatable {
    let id: String
    var title: String
    var valueLine: String
    var paragraphs: [String]
    var drilldown: FoodDrilldown?
}

/// What a metric tap adds to its explainer: the ranked contributing foods (the facts,
/// rendered immediately) and the grounding for the optional on-device insight (which
/// streams in below the facts and never blocks them).
struct FoodDrilldown: Equatable, Sendable {
    let breakdown: FoodBreakdown
    let insightInput: HealthInsightInput

    /// Build the drill-down for a tapped metric — the single builder BOTH entry points
    /// use (the Today rings and the Macros & calories detail), so tapping a metric
    /// anywhere produces the identical facts and grounded insight. The headline is the
    /// gauge's own value, so the foods reconcile against the number the tap came from,
    /// and the insight is fed the gauge's deterministic goal status rather than guessing.
    static func build(meals: [DietMeal], metric: ContributionMetric,
                      gauge: MetricGauge, isCarbLoad: Bool) -> FoodDrilldown {
        let breakdown = FoodContributions.breakdown(meals, metric: metric, total: gauge.value)
        // An informational metric (total sugars) is grounded WITHOUT a target, so the
        // insight frames no goal and the judgment forbid stands alone; every other
        // metric hands over its target and deterministic status. The micronutrient
        // partiality facts (floor, N not estimated) ride along on every metric and are
        // inert for a complete macro/calorie total.
        let informational = metric.isInformational
        let input = HealthInsight.input(
            metric: metric, total: gauge.value, goal: informational ? nil : gauge.target,
            goalStatus: gauge.goalStatus, goalPhrase: HealthInsight.goalPhrase(gauge.goal),
            dayStyle: isCarbLoad ? "carb-load day" : "ordinary day",
            contributions: breakdown.contributions,
            partial: gauge.partial, knownItemCount: gauge.knownItemCount ?? 0,
            unknownItemCount: gauge.unknownItemCount, informational: informational)
        return FoodDrilldown(breakdown: breakdown, insightInput: input)
    }
}

/// A reusable explainer sheet. When the explainer carries a `drilldown` (a macro or
/// the calorie total), the contributing-foods facts render immediately below the
/// prose, and the on-device insight streams in beneath them — subordinate to the
/// facts and absent entirely when the model is unavailable.
struct ExplainerSheet: View {
    let explainer: Explainer
    /// The on-device insight generator, injectable for previews/tests; the live
    /// FoundationModels-backed seam by default.
    var insight: HealthInsightGenerating = HealthInsight.live()
    @Environment(\.dismiss) private var dismiss
    /// The live insight text, owned here so the share export carries whatever is on
    /// screen. Empty when there's no drill-down or the model produced nothing.
    @State private var insightText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(explainer.valueLine)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .textSelection(.enabled)
                    ForEach(Array(explainer.paragraphs.enumerated()), id: \.offset) { _, p in
                        Text(p).font(.body).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let drilldown = explainer.drilldown {
                        Divider()
                        ContributingFoodsView(breakdown: drilldown.breakdown)
                        // The insight is secondary to the facts: it appears below and
                        // fills in after them, and renders nothing when the model is
                        // unavailable.
                        HealthInsightView(input: drilldown.insightInput, provider: insight,
                                          text: $insightText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(explainer.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Share the whole page as clean plain text — the guaranteed path that
                // carries everything regardless of where SwiftUI text selection has
                // gaps. Shown only when there's a drill-down (a full page to share).
                if let drilldown = explainer.drilldown {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: DrilldownShare.plainText(
                            title: explainer.title, valueLine: explainer.valueLine,
                            breakdown: drilldown.breakdown,
                            insight: insightText.isEmpty ? nil : insightText))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Renders a metric drill-down as clean plain text for the share sheet: the metric
/// title with its consumed/goal line, the sorted contributing foods with amounts and
/// contributions, and the on-device insight when one is present. Plain text on
/// purpose — it pastes cleanly into a chat or note with no markdown scaffolding, and
/// it's the guaranteed carrier of the full page where on-screen selection falls short.
/// Pure and unit-tested.
enum DrilldownShare {
    static func plainText(title: String, valueLine: String, breakdown: FoodBreakdown,
                          insight: String?) -> String {
        var lines: [String] = []
        // Header: the metric and its live value/target/remaining line, joined so it
        // reads as one sentence ("Protein — 93 / 140g — need 47g more").
        lines.append("\(title) — \(valueLine)")
        lines.append("")

        lines.append("What fed this:")
        if breakdown.isEmpty {
            // An all-unknown micronutrient day has no contributors but IS honest to
            // open: say nothing carries a measured value, then list every item below
            // under "Not estimated" — never a "nothing logged" message that hides them.
            if breakdown.isPartial {
                lines.append("No logged food lists a measured \(breakdown.metric.label.lowercased()) value yet.")
            } else {
                lines.append(breakdown.hasFoodButNoContributors
                    ? "No logged food lists its \(breakdown.metric.label.lowercased()) yet."
                    : "No foods logged yet.")
            }
        } else {
            for c in breakdown.contributions {
                let amount = c.amount.map { " (\($0))" } ?? ""
                let share = Int((c.share * 100).rounded())
                lines.append("• \(c.name)\(amount): \(DietSemantics.fmt(c.value)) \(breakdown.metric.unit) — \(share)%")
            }
            if let note = breakdown.reconciliationNote {
                lines.append(note)
            }
        }

        // The "Not estimated" group: the items carrying no value for this micronutrient,
        // name and amount only, never a number — the reason the total reads "≥". Carried
        // in the export verbatim so a partial day never pastes as a complete number.
        if !breakdown.unknownFoods.isEmpty {
            lines.append("")
            let caption = DietSemantics.partialCaption(unknownItemCount: breakdown.unknownFoods.count)
                ?? "not estimated"
            lines.append("Not estimated (\(caption)):")
            for u in breakdown.unknownFoods {
                let amount = u.amount.map { " (\($0))" } ?? ""
                lines.append("• \(u.name)\(amount)")
            }
        }

        if let insight, !insight.isEmpty {
            lines.append("")
            lines.append("On-device insight:")
            lines.append(insight)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Contributing foods (the drill-down facts)

/// The "what fed this number" facts: the foods that contributed to the tapped metric,
/// most impact first, zero/absent contributors already excluded upstream. Renders an
/// honest empty state (nothing logged vs logged-but-no-detail) and any reconciliation
/// note; never invents a 0-impact row.
struct ContributingFoodsView: View {
    let breakdown: FoodBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What fed this")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if breakdown.isEmpty {
                Text(emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(breakdown.contributions) { c in
                    ContributionRow(contribution: c, metric: breakdown.metric)
                }
                if let note = breakdown.reconciliationNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The "Not estimated" group: the items with no value for this
            // micronutrient, name and amount only — never a number, never a 0. These
            // are why the header reads "≥"; surfacing them is the whole point.
            if !breakdown.unknownFoods.isEmpty {
                notEstimatedGroup
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Enable selection for the food rows too; it propagates to the descendant
        // Text views (name, amount, contribution). The share export is the guaranteed
        // carrier where a given row's selection doesn't take.
        .textSelection(.enabled)
    }

    private var notEstimatedGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Not estimated")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let caption = DietSemantics.partialCaption(unknownItemCount: breakdown.unknownFoods.count) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(breakdown.unknownFoods) { u in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(u.name).font(.subheadline).foregroundStyle(.secondary)
                    if let amount = u.amount {
                        Text(amount).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    // No number, ever — a dash marks "unknown", distinct from a 0.
                    Text("—").font(.subheadline).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, 2)
    }

    private var emptyMessage: String {
        // An all-unknown micronutrient day still opens: nothing carries a measured
        // value, and every item shows below under "Not estimated".
        if breakdown.isPartial {
            return "No logged food lists a measured \(breakdown.metric.label.lowercased()) value yet."
        }
        return breakdown.hasFoodButNoContributors
            ? "No logged food lists its \(breakdown.metric.label.lowercased()) yet."
            : "No foods logged yet."
    }
}

/// One contributing food: its name and amount, its contribution to the tapped metric,
/// and a thin proportional bar (in the metric's identity color) with its share of the
/// day's total.
struct ContributionRow: View {
    let contribution: FoodContribution
    let metric: ContributionMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(contribution.name).font(.subheadline)
                if let amount = contribution.amount {
                    Text(amount).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(DietSemantics.fmt(contribution.value)) \(metric.unit)")
                    .font(.subheadline.monospacedDigit())
            }
            HStack(spacing: 8) {
                ProportionBar(fraction: contribution.share, color: barColor)
                Text("\(Int((contribution.share * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    /// The metric's identity color — the macro palette from the calorie-source bar so
    /// the drill-down speaks the same color language, the accent for calories, and a
    /// per-nutrient identity color for a micronutrient.
    private var barColor: Color {
        switch metric {
        case .calories: return .accentColor
        case .macro(let m): return MacroColor.color(for: m)
        case .micronutrient(let n): return MicronutrientColor.color(for: n)
        }
    }
}

/// Identity colors for the four micronutrients, kept distinct from the macro palette
/// (indigo/teal/orange) so the drill-down bars don't read as a macro. One place, so no
/// view hardcodes a color.
enum MicronutrientColor {
    static func color(for n: Micronutrient) -> Color {
        switch n {
        case .sodium: return .blue
        case .saturatedFat: return .brown
        case .totalSugars: return .pink
        case .potassium: return .mint
        }
    }
}

/// A thin proportional bar (share of the day's total for a metric) in a passed color,
/// on the same dim track the status meters use.
struct ProportionBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

// MARK: - On-device insight (streamed, subordinate to the facts)

/// The optional on-device AI insight, shown below the facts. It streams the insight
/// in progressively via the `HealthInsightGenerating` seam and renders NOTHING until
/// text arrives — so the facts never wait on it, and an unavailable/failed model
/// leaves no error and no empty placeholder. Styled clearly secondary to the facts.
struct HealthInsightView: View {
    let input: HealthInsightInput
    let provider: HealthInsightGenerating
    /// The live insight text, lifted to the parent so the share export can carry it.
    /// Bound (not local `@State`) because the sheet owns it for the plain-text export.
    @Binding var text: String

    var body: some View {
        // An always-present container carries the `.task`, so the stream starts even
        // while `text` is empty (an empty conditional view can drop its `.task`). The
        // content shows only once text arrives — nothing renders otherwise.
        VStack(alignment: .leading, spacing: 6) {
            if !text.isEmpty {
                Label("On-device insight", systemImage: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: input) {
            text = ""
            // Each cumulative snapshot replaces the text so it grows in place. A model
            // that's unavailable or errors yields no snapshots, so `text` stays empty
            // and nothing renders. The guard is the deterministic backstop: if a
            // snapshot asserts a goal was reached that the computed status contradicts,
            // discard the insight outright and leave the facts standing alone.
            for await snapshot in provider.insight(for: input) {
                // The input-aware guard discards a generation that claims goal status
                // contrary to the facts, claims a partial total is complete, or renders
                // a judgment for an informational metric (total sugars).
                if HealthInsightGuard.contradicts(snapshot, input: input) {
                    text = ""
                    break
                }
                text = snapshot
            }
        }
    }
}

// MARK: - Small shared rows

/// A rounded card container matching the app's grouped look.
struct HealthCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// A small time capsule ("07:41") for meal / workout headers.
struct TimeCapsule: View {
    let time: String
    var body: some View {
        Text(time)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
            .foregroundStyle(.secondary)
    }
}
