import SwiftUI
import JesseNetworking

// The Consistency screen: for every nutrient that carries a verdict, how long it has been
// held, the best run in the series, and how long since the last miss. It is deliberately a
// compact list of rows, not a second chart stack — the chart already exists one tap deeper
// (`NutrientTrendDetail`), and this screen answers a different question: not "what is the
// typical day" (a median) but "is this being held" (a run).
//
// Every number comes from `NutrientStreaks`, which is pure and unit-tested; this view only
// draws. The gap rule is stated at the top rather than left implied, and a row standing on
// thin measurement says so on the row itself.

struct NutrientStreaksDetail: View {
    let series: [NutrientDay]
    let targets: DietTargets
    let meals: [DietMeal]
    /// The range a tapped nutrient's trend chart opens on, matching whichever window mode
    /// the Health tab was in when this screen was pushed.
    var trendRange: NutrientTrendDetail.Range = .d30

    private var streaks: [NutrientStreak] {
        NutrientStreaks.all(series: series, targets: targets)
    }

    var body: some View {
        List {
            if streaks.isEmpty {
                Section {
                    Text("No nutrient has enough measured days to show a streak yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section {
                    ForEach(streaks) { streak in
                        NavigationLink {
                            NutrientTrendDetail(
                                context: NutrientTrendContext(nutrient: streak.nutrient,
                                                              series: series, targets: targets,
                                                              meals: meals),
                                initialRange: trendRange)
                        } label: {
                            StreakRow(streak: streak)
                        }
                    }
                } header: {
                    Text("Streaks")
                } footer: {
                    Text(NutrientStreaks.gapRule)
                }
            }
        }
        .navigationTitle("Consistency")
        .dietNavTitle(.inline)
    }
}

/// One nutrient's consistency row: the goal glyph and name, the current run as the headline
/// number, then the best run and the last miss beneath. Colour follows the one-meaning
/// `Tone` the rest of the Health tab uses — green while a run is live, neutral when it
/// isn't. A run is never coloured amber or clay: not having a streak is not a problem to
/// flag, it is simply an absence.
struct StreakRow: View {
    let streak: NutrientStreak

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                GoalChip(goal: streak.nutrient.displayGoal)
                Text(streak.nutrient.fullName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(currentText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(toneColor(streak.current > 0 ? .onTrack : .inProgress))
            }
            // The best run and the last miss stack rather than sharing a row: the last-miss
            // line wraps on a narrow screen, and side by side it collided with "best".
            Text("best \(streak.longest) \(streak.longest == 1 ? "day" : "days") · \(streak.lastMissLine)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(streak.coverageNote)
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(streak.nutrient.fullName): current streak \(currentText), "
            + "best \(streak.longest) days. \(streak.lastMissLine). \(streak.coverageNote)")
    }

    private var currentText: String {
        streak.current == 0 ? "no run" : "\(streak.current) \(streak.current == 1 ? "day" : "days")"
    }
}
