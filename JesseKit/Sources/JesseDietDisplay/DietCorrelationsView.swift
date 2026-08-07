import SwiftUI
import JesseNetworking

// The Patterns screen: what moved together across weight, training and intake. Reached from
// a nav row on the Health tab, in the same drill-down style as Consistency and Sources.
//
// Every number and every sentence comes from `DietCorrelations`, which is pure and
// unit-tested; this view only draws. That split is load-bearing here rather than merely
// tidy: the wording that keeps a correlation from being read as a cause is fixed in the
// engine, so no layout change can quietly turn "these moved together" into "this raises
// that". The view never formats a coefficient of its own and never has one for a pair the
// engine withheld.
//
// The set-aside pairs are shown, not hidden. A screen listing two findings and nothing else
// implies those are the only relationships in the data; listing what was too thin or too
// weak, by name, is what keeps the two that ARE shown honest.

struct DietCorrelationsDetail: View {
    let weightSeries: [WeightPoint]
    let nutrientSeries: [NutrientDay]
    let exerciseSeries: [ExerciseDay]

    private var report: DietCorrelationReport {
        DietCorrelations.report(weight: weightSeries, nutrients: nutrientSeries,
                                exercise: exerciseSeries)
    }

    var body: some View {
        let r = report
        return List {
            if r.associations.isEmpty {
                Section {
                    Text(emptyMessage(r))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section {
                    ForEach(r.associations) { a in
                        AssociationRow(association: a)
                    }
                } header: {
                    Text("Moved together")
                }
            }
            // The standing caveat rides directly under the findings, in both states.
            Section { CaveatRow(text: DietCorrelations.caveat) }

            // Everything the guardrails set aside, by name. A pair below the sample minimum
            // shows how far off it is and NEVER which way it was leaning — a hinted
            // direction is the coefficient by another route.
            if !r.misses.isEmpty {
                Section {
                    ForEach(r.misses) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(.subheadline)
                            Text(m.reasonText)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(m.title): \(m.reasonText)")
                    }
                    CaveatRow(text: "A pair needs \(DietCorrelations.minPairs) days with both "
                              + "sides measured before any number is worth showing. A day "
                              + "missing on either side is left out rather than counted as zero.")
                } header: {
                    Text("Not shown")
                }
            }
        }
        .navigationTitle("Patterns")
        .dietNavTitle(.inline)
    }

    private func emptyMessage(_ r: DietCorrelationReport) -> String {
        guard !r.misses.isEmpty else {
            return "There isn't enough overlapping weight, food and training history yet to "
                + "compare anything."
        }
        if r.thinCount == r.misses.count {
            return "Nothing has \(DietCorrelations.minPairs) days with both sides measured yet. "
                + "Weigh-ins on consecutive days are what this needs most — a weight change "
                + "needs the day before it too."
        }
        return "Nothing moved together strongly enough over these days to be worth flagging. "
            + "That is a perfectly ordinary result, and a more honest one than a weak number "
            + "dressed up as a finding."
    }
}

/// One association: the two quantities and the lag as the heading, the coefficient and
/// sample size as the numbers, and the fixed plain-language sentence beneath. Colour is
/// deliberately absent — green/red here would read as good/bad, and an association is
/// neither.
struct AssociationRow: View {
    let association: DietAssociation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(association.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(association.coefficientText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("\(association.strengthWord) · \(association.pairs) paired days")
                .font(.caption).foregroundStyle(.secondary)
            Text(association.sentence)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(association.title). \(association.strengthWord) association, "
                            + "coefficient \(association.coefficientText), "
                            + "\(association.pairs) paired days. \(association.sentence)")
    }
}
