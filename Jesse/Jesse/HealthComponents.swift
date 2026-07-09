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

/// A compact macro gauge for the Level-1 strip: label + goal glyph, value/target,
/// a short meter, and the status as its tint.
struct CompactMacroGauge: View {
    let gauge: MetricGauge
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(gauge.label).font(.caption.weight(.semibold))
                GoalChip(goal: gauge.goal)
            }
            Text(valueTarget)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(statusColor(gauge.status))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            StatusMeter(fraction: gauge.fraction, status: gauge.status, height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gauge.label): \(valueTarget), \(gauge.remaining)")
    }
    private var valueTarget: String {
        let v = DietSemantics.fmt(gauge.value)
        if let t = gauge.target { return "\(v)/\(DietSemantics.fmt(t))\(gauge.unit)" }
        return "\(v)\(gauge.unit)"
    }
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

/// A labeled macro triple ("P 18 · F 15 · C 1 · fib 8") for item/meal rows.
func macroLine(_ t: MacroTotals, includeFiber: Bool = true) -> String {
    var parts = ["P \(DietSemantics.fmt(t.p))", "F \(DietSemantics.fmt(t.f))", "C \(DietSemantics.fmt(t.c))"]
    if includeFiber { parts.append("fib \(DietSemantics.fmt(t.fiber))") }
    return parts.joined(separator: " · ")
}
