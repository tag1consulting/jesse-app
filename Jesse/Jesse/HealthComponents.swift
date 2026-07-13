import SwiftUI

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
enum MacroColor {
    static let protein = Color.indigo
    static let carbs = Color.teal
    static let fat = Color.orange
}

/// A single horizontal stacked bar of where the day's calories came from (protein /
/// carbs / fat at 4/4/9 kcal per gram), with a compact legend. The split math is
/// pure and tested (`HealthDisplay.calorieSplit`); this only draws it.
struct CalorieSourceBar: View {
    let split: HealthDisplay.CalorieSplit
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(MacroColor.protein)
                        .frame(width: geo.size.width * split.proteinFraction)
                    Rectangle().fill(MacroColor.carbs)
                        .frame(width: geo.size.width * split.carbsFraction)
                    Rectangle().fill(MacroColor.fat)
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                legendItem(Macro.protein.displayName, MacroColor.protein)
                legendItem(Macro.carbs.displayName, MacroColor.carbs)
                legendItem(Macro.fat.displayName, MacroColor.fat)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calorie sources: protein \(pct(split.proteinFraction)), carbs \(pct(split.carbsFraction)), fat \(pct(split.fatFraction))")
    }
    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
    private func pct(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
}

/// A full-width bar row for the macros-and-calories detail screen: goal chip,
/// label, value/target/percent, the meter, the remaining annotation, and any gated
/// flag. Tapping opens the row's explainer.
struct MetricBarRow: View {
    let gauge: MetricGauge
    var onTap: () -> Void = {}
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    GoalChip(goal: gauge.goal)
                    Text(gauge.label).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(valueTarget).font(.subheadline.monospacedDigit())
                        .foregroundStyle(statusColor(gauge.status))
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary)
                }
                StatusMeter(fraction: gauge.fraction, status: gauge.status)
                HStack {
                    Text(gauge.remaining).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let pct = percent {
                        Text(pct).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                if let flag = gauge.flag {
                    Label(flag, systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    private var valueTarget: String {
        let v = DietSemantics.fmt(gauge.value)
        if let t = gauge.target { return "\(v) / \(DietSemantics.fmt(t))\(gauge.unit)" }
        return "\(v)\(gauge.unit)"
    }
    private var percent: String? {
        guard let f = gauge.fraction else { return nil }
        return "\(Int((f * 100).rounded()))%"
    }
}

// MARK: - Explainer sheet

/// The "understand the number" content: a title, the live value/target line, and a
/// few short second-person paragraphs. Content is baked in (`Explainers`),
/// parameterized with live numbers where noted.
struct Explainer: Identifiable, Equatable {
    let id: String
    var title: String
    var valueLine: String
    var paragraphs: [String]
}

/// A reusable explainer sheet.
struct ExplainerSheet: View {
    let explainer: Explainer
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(explainer.valueLine)
                        .font(.title3.weight(.semibold).monospacedDigit())
                    ForEach(Array(explainer.paragraphs.enumerated()), id: \.offset) { _, p in
                        Text(p).font(.body).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(explainer.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
