import SwiftUI
import JesseCore
import JesseNetworking

// MARK: - Level 1: Today

struct TodayScreen: View {
    let model: HealthDashboardModel
    let snapshot: DietSnapshot
    let now: Date
    let refreshError: DietFetchError?

    @State private var explainer: Explainer?

    private var today: DietToday { snapshot.today }
    private var clockHour: Int { Calendar.current.component(.hour, from: now) }
    // The engine's current-hour: real clock for today, end-of-day (24) for a past
    // day so time-gated flags are fully resolved rather than clock-suppressed.
    private var hour: Int { HistoryRender.engineHour(isHistorical: snapshot.isHistorical, clockHour: clockHour) }
    private var gauges: DietGauges { DietSemantics.gauges(for: today, hour: hour, series: judgeSeries) }
    /// The history the BUFFERED gauges take their color from — only ever today's. Paging
    /// back must not color a past day from a window that ends after it, so a historical day
    /// judges on its own numbers alone (the same fallback an older bridge gets).
    private var judgeSeries: [NutrientDay]? { snapshot.isHistorical ? nil : snapshot.nutrientSeries }
    private var totals: MacroTotals { DietSemantics.dayTotals(today.meals) }
    private var net: NetCalories { NetCalories(intake: totals.cal, burned: DietSemantics.burnedCalories(today.exercise)) }
    // A reconstructed day renders with NO judgment; live/archived render full.
    private var mode: HistoryUI.Mode { HistoryUI.mode(fidelity: snapshot.fidelityKind) }
    private var isNeutral: Bool { mode == .neutral }
    // The stale banner is suppressed on any past day (a completed day isn't "stale").
    private var isStale: Bool {
        !HistoryUI.suppressesStaleBanner(isHistorical: snapshot.isHistorical)
            && HealthDisplay.isStale(todayDate: today.date, now: now)
    }

    // MARK: - The Day / 7d / 30d window

    /// The history the WINDOW SWITCHER reads — the same series the buffered gauges take
    /// their colour from, and for the same reason: a past day must not be reframed by a
    /// window that ends after it. Paging back therefore hides the switcher and the day
    /// renders exactly as it always has.
    private var windowSeries: [NutrientDay]? { judgeSeries }
    /// Whether the rolling modes are offered at all. An older bridge sends no
    /// `nutrientSeries`, so there is nothing to roll over: the switcher, the rolling list,
    /// and the Consistency row simply don't appear. Graceful degrade, never a crash.
    private var windowAvailable: Bool { NutrientTrends.isAvailable(windowSeries) }
    /// The mode actually in force: the session's choice, clamped to `.day` whenever the
    /// rolling modes aren't available, so a selection made on today can't strand a paged-back
    /// day on a window it has no data for.
    private var windowMode: NutrientWindowMode { windowAvailable ? model.nutrientWindow : .day }
    private var windowBinding: Binding<NutrientWindowMode> {
        Binding(get: { model.nutrientWindow }, set: { model.nutrientWindow = $0 })
    }
    /// The trend chart's opening range for anything tapped in the current mode.
    private var trendRange: NutrientTrendDetail.Range { .matching(windowMode) }

    // MARK: - The multi-day histories

    /// The per-item food history the Sources screens read, and the same past-day rule the
    /// window switcher and the buffered gauges follow: a range that ends AFTER the day you
    /// are reading would answer a question about days that day could not have had, so paging
    /// back hides it. Absent on an older bridge → the affordance simply isn't offered.
    private var historySources: [SourceDay]? { snapshot.isHistorical ? nil : snapshot.sourceSeries }
    private var sourcesAvailable: Bool { NutrientSources.isAvailable(historySources) }

    /// The exercise history the Patterns screen reads, under the same past-day rule.
    private var historyExercise: [ExerciseDay]? { snapshot.isHistorical ? nil : snapshot.exerciseSeries }
    /// Whether Patterns has all three histories it needs. The exercise field is the one an
    /// older bridge omits, and its absence hides the row rather than showing a diet-only
    /// version under a heading that promises training.
    private var correlationsAvailable: Bool {
        DietCorrelations.isAvailable(weight: snapshot.weightSeries, nutrients: windowSeries,
                                     exercise: historyExercise)
    }

    /// The Sources range that matches the tab's window mode, so a nutrient opened from a 7d
    /// read lands on 7d. The Day mode has no matching range and keeps the 30-day default.
    private var sourcesRange: Int { windowMode == .week ? 7 : 30 }

    var body: some View {
        List {
            // Paging is a DAY control: a rolling window is anchored on the data, not on the
            // day you happen to be reading, so it has nothing to page.
            if windowMode == .day { pagingSection }
            windowSection
            headerSection
            if windowMode == .day {
                summarySection
                caloriesSection
                macroRingsSection
            } else if let series = windowSeries, let days = windowMode.days {
                rollingSection(series: series, windowDays: days)
            }
            weightSection
            // The coach's headline speaks to today; a rolling review isn't the place for it.
            if windowMode == .day { coachHeadlineSection }
            navRowsSection
            updatedStampSection
        }
        .navigationTitle(HealthDisplay.headerDate(today.date))
        .dietNavTitle(.large)
        .refreshable { await model.refresh() }
        .sheet(item: $explainer) { ExplainerSheet(explainer: $0) }
    }

    // The switcher itself. It changes WHICH read every nutrient shows — today's total, or
    // the median of its known days over the last 7 or 30 — and nothing else: the same
    // gauges, the same bands, the same trend chart one tap deeper.
    @ViewBuilder
    private var windowSection: some View {
        if windowAvailable {
            Section {
                Picker("Window", selection: windowBinding) {
                    ForEach(NutrientWindowMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Nutrient window")
                .listRowBackground(Color.clear)
            }
        }
    }

    // The rolling read: every measured nutrient reframed to its window median, drawn by the
    // SAME `MetricBarRow` the day-scoped nutrient rows use — the switcher changes the data a
    // gauge reads and its coverage caption, not the gauge. Tapping a row pushes the existing
    // per-nutrient trend chart, opened on the matching range.
    private func rollingSection(series: [NutrientDay], windowDays: Int) -> some View {
        let rows = NutrientWindows.gauges(series: series, targets: today.targets,
                                          windowDays: windowDays)
        return Section {
            if rows.isEmpty {
                Text("Nothing has been measured yet, so there is nothing to roll up.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows, id: \.nutrient) { row in
                NavigationLink {
                    NutrientTrendDetail(
                        context: NutrientTrendContext(nutrient: row.nutrient, series: series,
                                                      targets: today.targets, meals: today.meals),
                        initialRange: trendRange)
                } label: {
                    MetricBarRow(gauge: row.gauge)
                }
            }
        } header: {
            Text("Last \(windowDays) days")
        } footer: {
            Text(NutrientWindows.coverageFootnote)
        }
    }

    /// Open a metric's drill-down from a Today-screen ring tap: attach the shared
    /// enriched drill-down (contributing foods + grounded insight) to the metric's
    /// explainer, so tapping the calorie or a macro ring here presents the identical
    /// sheet the Macros & calories detail does — one component, not a copied variant.
    private func openDrilldown(_ ex: Explainer, metric: ContributionMetric, gauge: MetricGauge) {
        var enriched = ex
        enriched.drilldown = FoodDrilldown.build(meals: today.meals, metric: metric,
                                                 gauge: gauge, isCarbLoad: gauges.isCarbLoad,
                                                 series: snapshot.nutrientSeries, targets: today.targets,
                                                 sourceSeries: historySources)
        explainer = enriched
    }

    // Paging control: back / forward chevrons flanking a "Today" jump button, each
    // enabled per availableDays. Chevrons (not a swipe) to avoid fighting the
    // vertical scroll and the tab-bar gestures.
    private var pagingSection: some View {
        Section {
            HStack {
                Button { Task { await model.goBack() } } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoBack)
                .foregroundStyle(model.canGoBack ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityLabel("Previous day")

                Spacer()

                if !model.isViewingToday {
                    Button { Task { await model.goToToday() } } label: {
                        Text("Today").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Jump to today")
                }

                Spacer()

                Button { Task { await model.goForward() } } label: {
                    Image(systemName: "chevron.right").font(.body.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoForward)
                .foregroundStyle(model.canGoForward ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityLabel("Next day")
            }
            .listRowBackground(Color.clear)
        }
    }

    // Header: the day-style chip (full days only — a reconstructed day has no judged
    // style) plus the stale / refresh-failed / history-unsupported banners. Emitted only
    // when it actually has something to say: an empty `Section` still claims its list
    // spacing, which on a rolling window (where the chip is suppressed) left a band of
    // dead air above the nutrients.
    private var hasHeaderContent: Bool {
        (!isNeutral && windowMode == .day) || model.historyUnsupported || isStale
            || refreshError != nil
    }

    @ViewBuilder
    private var headerSection: some View {
        if hasHeaderContent {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    // The day-style chip describes TODAY's rules; a rolling window spans days
                    // of several styles, so it would be claiming something it doesn't know.
                    if !isNeutral, windowMode == .day {
                        Button {
                            explainer = Explainers.dayStyle(today.dayStyle, isCarbLoad: gauges.isCarbLoad)
                        } label: {
                            HStack(spacing: 5) {
                                DayStyleChip(dayStyle: today.dayStyle, isCarbLoad: gauges.isCarbLoad)
                                Image(systemName: "info.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Day type: \(DayStyleExplain.headline(dayStyle: today.dayStyle, isCarbLoad: gauges.isCarbLoad)). What this changes.")
                    }

                    if model.historyUnsupported {
                        Label("Update the bridge to page back through earlier days.",
                              systemImage: "arrow.up.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if isStale {
                        Label("showing \(today.date); nothing logged today yet",
                              systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if refreshError != nil {
                        Label("couldn't refresh — showing the last update", systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    // The plain-language summary LEADS the judged day: "how am I doing" + "what would
    // help next", derived from the same gauges the rings draw (so they can't disagree).
    // A reconstructed day has no targets to summarize, so it's omitted there.
    @ViewBuilder
    private var summarySection: some View {
        if !isNeutral {
            Section {
                DaySummaryCard(summary: DaySummary.make(gauges: gauges, hour: hour,
                                                        hasFood: !today.meals.isEmpty))
            }
        }
    }

    // Calories is the number that matters most, so it's the first content: one large
    // ring. On a full day it's the judged activity ring; on a reconstructed day it's
    // the neutral hero (eaten total, no judgment).
    @ViewBuilder
    private var caloriesSection: some View {
        Section {
            if isNeutral {
                VStack(spacing: 8) {
                    NeutralCaloriesHero(totals: totals, net: net)
                    Text(NeutralMode.noTargetsCaption)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            } else {
                CaloriesHeroRing(gauge: gauges.calories, net: gauges.net) {
                    openDrilldown(Explainers.calories(gauges.calories, isCarbLoad: gauges.isCarbLoad),
                                  metric: .calories, gauge: gauges.calories)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
        }
    }

    // Four smaller rings in canonical order — protein, carbs, fiber, fat. Judged on a
    // full day; neutral gram totals on a reconstructed day. Both derive their order
    // from `Macro.allCases`; the rings stay four equal peers (ring size encodes
    // nothing, so fiber's ring is not shrunk — only its position and its label type
    // change, and the label change lives in the listings, not here).
    @ViewBuilder
    private var macroRingsSection: some View {
        Section {
            if isNeutral {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Macro.allCases, id: \.self) { macro in
                        NeutralMacroRing(label: macro.displayName, grams: totals.grams(for: macro))
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(gauges.orderedMacros, id: \.macro) { entry in
                        MacroRing(gauge: entry.gauge) {
                            openDrilldown(Explainers.macro(entry.macro, gauges: gauges),
                                          metric: .macro(entry.macro), gauge: entry.gauge)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    // The weight card moves below the rings and becomes a NavigationLink into the
    // Weight & trend screen (chevron makes the affordance obvious).
    @ViewBuilder
    private var weightSection: some View {
        if let card = HealthDisplay.weightCard(today: today, series: snapshot.weightSeries) {
            Section {
                NavigationLink {
                    WeightTrendDetail(series: snapshot.weightSeries ?? [], progress: snapshot.progress)
                } label: {
                    WeightCardView(card: card)
                }
            }
        }
    }

    @ViewBuilder
    private var coachHeadlineSection: some View {
        if let note = snapshot.coach?.notes.first {
            Section {
                Text(CoachHTML.plainText(note))
                    .font(.subheadline).lineLimit(2).truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var updatedStampSection: some View {
        // Today: the mtime "Updated HH:MM" stamp. A past day: a fidelity label
        // ("Archived day" / "Rebuilt from logs") instead of a stale mtime.
        if let footer = HistoryUI.footer(isHistorical: snapshot.isHistorical,
                                         fidelity: snapshot.fidelityKind,
                                         updated: HealthDisplay.updatedTime(fromMtime: snapshot.todayMtime)) {
            Section {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
    }

    // Macros subtitle: the judged protein annotation on a full day, plain totals on
    // a reconstructed day (no judgment to summarize).
    private var macrosSubtitle: String {
        if isNeutral {
            return "\(DietSemantics.fmt(totals.cal)) cal · \(DietSemantics.fmt(totals.p))g protein"
        }
        return "\(DietSemantics.fmt(gauges.calories.value)) cal · \(gauges.protein.remaining)"
    }

    private var navRowsSection: some View {
        Section {
            NavigationLink {
                MacrosCaloriesDetail(today: today, hour: hour, neutral: isNeutral,
                                     nutrientSeries: snapshot.nutrientSeries,
                                     isHistorical: snapshot.isHistorical,
                                     sourceSeries: snapshot.sourceSeries)
            } label: {
                NavRow(title: "Macros & calories", icon: "chart.bar.fill",
                       subtitle: macrosSubtitle)
            }

            // Consistency: not "what is a typical day" (that is the rolling median above)
            // but "is this being held" — a run of days meeting each goal. A nav row rather
            // than an inline block, matching how every other multi-day view on this screen
            // is reached, and present in every mode because a streak is inherently
            // multi-day. Hidden entirely when the bridge sent no history.
            if windowAvailable, let series = windowSeries {
                let streaks = NutrientStreaks.all(series: series, targets: today.targets)
                if let subtitle = NutrientStreaks.subtitle(streaks) {
                    NavigationLink {
                        NutrientStreaksDetail(series: series, targets: today.targets,
                                              meals: today.meals, trendRange: trendRange)
                    } label: {
                        NavRow(title: "Consistency", icon: "flame", subtitle: subtitle)
                    }
                }
            }

            // Sources: the other half of every rolling read. The window switcher and the
            // trend charts say a nutrient runs high or short; this says which foods it is
            // actually coming from, which is the half you can act on. Inherently multi-day,
            // so it is present in every window mode.
            if sourcesAvailable, let sources = historySources {
                NavigationLink {
                    NutrientSourcesOverview(series: sources, targets: today.targets,
                                            nutrientSeries: windowSeries, meals: today.meals,
                                            initialRange: sourcesRange)
                } label: {
                    NavRow(title: "Sources", icon: "list.bullet.rectangle",
                           subtitle: sourcesSubtitle)
                }
            }

            // Patterns: what moved together across weight, training and intake. Guarded hard
            // in the engine (a minimum sample, a weak floor, association wording only), and
            // hidden entirely unless all three histories are present.
            if correlationsAvailable {
                let report = DietCorrelations.report(weight: snapshot.weightSeries,
                                                     nutrients: windowSeries,
                                                     exercise: historyExercise)
                if let subtitle = DietCorrelations.subtitle(report) {
                    NavigationLink {
                        DietCorrelationsDetail(weightSeries: snapshot.weightSeries ?? [],
                                               nutrientSeries: windowSeries ?? [],
                                               exerciseSeries: historyExercise ?? [])
                    } label: {
                        NavRow(title: "Patterns", icon: "chart.dots.scatter", subtitle: subtitle)
                    }
                }
            }

            NavigationLink {
                FoodJournalDetail(today: today, proposed: snapshot.proposed)
            } label: {
                NavRow(title: "Food journal", icon: "fork.knife",
                       subtitle: "\(today.meals.count) \(today.meals.count == 1 ? "meal" : "meals") · \(DietSemantics.fmt(DietSemantics.dayTotals(today.meals).cal)) cal")
            }

            NavigationLink {
                ExerciseDetail(exercise: today.exercise)
            } label: {
                NavRow(title: "Exercise", icon: "figure.run",
                       subtitle: "\(today.exercise.count) \(today.exercise.count == 1 ? "session" : "sessions") · \(DietSemantics.fmt(DietSemantics.burnedCalories(today.exercise))) cal")
            }

            // Weight & trend stays reachable on a past day — the chart is inherently
            // historical.
            unavailableOr(section: snapshot.weightSeries?.isEmpty == false ? snapshot.weightSeries : nil,
                          label: "Weight", errors: snapshot.errors,
                          icon: "scalemass", title: "Weight & trend",
                          subtitle: weightSubtitle) { series in
                WeightTrendDetail(series: series, progress: snapshot.progress)
            }

            // Progress & pace and Coach's notes are CURRENT-STATE only (the bridge
            // returns them null on history), so they're hidden on a past day.
            if HistoryUI.showsCurrentStateRows(isHistorical: snapshot.isHistorical) {
                unavailableOr(section: snapshot.progress, label: "Progress", errors: snapshot.errors,
                              icon: "target", title: "Progress & pace",
                              subtitle: snapshot.progress?.trajectory) { progress in
                    ProgressPaceDetail(progress: progress, today: today, series: snapshot.weightSeries)
                }

                unavailableOr(section: snapshot.coach, label: "Coach", errors: snapshot.errors,
                              icon: "quote.bubble", title: "Coach's notes",
                              subtitle: snapshot.coach?.title) { coach in
                    CoachDetail(coach: coach)
                }
            }
        }
    }

    /// The Sources row's subtitle: how many nutrients the range can actually answer for.
    /// Never a leading food name — which food leads depends on the nutrient, and picking one
    /// for the row would be a verdict the screen hasn't been asked for yet.
    private var sourcesSubtitle: String {
        let count = NutrientSources.overview(historySources ?? [], windowDays: sourcesRange).count
        return count == 0
            ? "last \(sourcesRange) days"
            : "\(count) \(count == 1 ? "nutrient" : "nutrients") · last \(sourcesRange) days"
    }

    private var weightSubtitle: String? {
        guard let card = HealthDisplay.weightCard(today: today, series: snapshot.weightSeries) else { return nil }
        return "\(DietSemantics.fmt(card.lbs)) lb" + (card.isTodayWeighIn ? " today" : (card.lastWeighInDate.map { " · last \($0)" } ?? ""))
    }

    /// A nav row that pushes `destination(value)` when `section` is present, else a
    /// muted "unavailable" row surfaced from `errors` (never hidden).
    @ViewBuilder
    private func unavailableOr<Value, Destination: View>(
        section: Value?, label: String, errors: [String],
        icon: String, title: String, subtitle: String?,
        @ViewBuilder destination: @escaping (Value) -> Destination
    ) -> some View {
        if let value = section {
            NavigationLink { destination(value) } label: {
                NavRow(title: title, icon: icon, subtitle: subtitle)
            }
        } else {
            NavRow(title: title, icon: icon,
                   subtitle: unavailableReason(label: label, errors: errors), muted: true)
        }
    }

    private func unavailableReason(label: String, errors: [String]) -> String {
        switch HealthDisplay.availability(present: false, label: label, errors: errors) {
        case .unavailable(let reason): return reason
        case .present: return ""
        }
    }
}

// MARK: - Small Level-1 pieces

struct DayStyleChip: View {
    let dayStyle: String?
    let isCarbLoad: Bool
    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
    private var color: Color { isCarbLoad ? .purple : .secondary }
    private var label: String { DayStyleExplain.headline(dayStyle: dayStyle, isCarbLoad: isCarbLoad) }
}

struct WeightCardView: View {
    let card: HealthDisplay.WeightCard
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(DietSemantics.fmt(card.lbs)) lb")
                    .font(.title.weight(.bold).monospacedDigit())
                if let kg = card.kg {
                    Text("\(DietSemantics.fmt(kg)) kg").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let delta = card.deltaLbs {
                    let up = delta >= 0
                    Label("\(up ? "+" : "")\(String(format: "%.1f", delta))",
                          systemImage: up ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(up ? .orange : .green)
                        .labelStyle(.titleAndIcon)
                }
            }
            if card.isTodayWeighIn, let bf = card.bf {
                HStack(spacing: 12) {
                    Text("\(DietSemantics.fmt(bf))% bf").font(.caption).foregroundStyle(.secondary)
                    if let lean = card.leanLbs {
                        Text("\(DietSemantics.fmt(lean)) lb lean").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if !card.isTodayWeighIn, let last = card.lastWeighInDate {
                Text("last weigh-in \(last)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NavRow: View {
    let title: String
    let icon: String
    var subtitle: String?
    var muted: Bool = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(muted ? .secondary : .primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(muted ? "unavailable — \(subtitle)" : subtitle)
                        .font(.caption).foregroundStyle(muted ? .tertiary : .secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Empty states

struct HealthEmptyState: View {
    let error: DietFetchError
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if showsRetry { Button("Try again", action: retry) }
        }
    }

    private var title: String {
        switch error {
        case .notConfigured: return "Not paired yet"
        case .unreachable: return "Can't reach the bridge"
        case .authFailed: return "Authentication failed"
        case .endpointMissing: return "Bridge update needed"
        case .unavailable: return "Today's data is unavailable"
        case .decodeFailed, .server: return "Something went wrong"
        }
    }
    private var icon: String {
        switch error {
        case .notConfigured: return "qrcode.viewfinder"
        case .unreachable: return "wifi.slash"
        case .authFailed: return "lock.trianglebadge.exclamationmark"
        case .endpointMissing: return "arrow.up.circle"
        case .unavailable: return "exclamationmark.triangle"
        case .decodeFailed, .server: return "exclamationmark.triangle"
        }
    }
    private var message: String {
        switch error {
        case .notConfigured:
            return "Pair with your laptop bridge in Settings to see your diet dashboard."
        case .unreachable(let host):
            return host
        case .authFailed:
            return "Your token was rejected. Re-pair in Settings."
        case .endpointMissing:
            return "This bridge doesn't have the diet endpoint yet. Update the bridge on your laptop (0.5.0 or newer) and try again."
        case .unavailable:
            return "The bridge is up but today's diet file couldn't be read. It usually regenerates on your next log."
        case .decodeFailed:
            return "The reply couldn't be read. Try again in a moment."
        case .server(let code):
            return "The bridge returned an error (\(code)). Try again in a moment."
        }
    }
    private var showsRetry: Bool {
        switch error {
        case .notConfigured, .authFailed: return false
        default: return true
        }
    }
}

// MARK: - Quick log

public struct QuickLogSheet: View {
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// `onSend` runs the finished sentence (each platform wires it to its own send path;
    /// iOS opens a Tell turn through `RunCoordinator`). Explicit public init because the
    /// synthesized memberwise one is internal.
    public init(onSend: @escaping (String) -> Void) {
        self.onSend = onSend
    }

    private let templates = [
        ("Meal", "fork.knife", "Log a meal: "),
        ("Snack", "carrot", "Log a snack: "),
        ("Weigh-in", "scalemass", "Log a weigh-in: "),
        ("Workout", "figure.run", "Log a workout: "),
    ]

    @State private var scaffold: String?
    @State private var detail = ""

    public var body: some View {
        NavigationStack {
            Group {
                if let scaffold {
                    Form {
                        Section {
                            Text(scaffold).font(.subheadline).foregroundStyle(.secondary)
                            TextField("Finish the sentence…", text: $detail, axis: .vertical)
                                .lineLimit(2...5)
                        } footer: {
                            Text("This runs as a Tell turn on a new thread. Jesse logs it and the dashboard refreshes when it's done.")
                        }
                    }
                } else {
                    List(templates, id: \.0) { t in
                        Button {
                            scaffold = t.2
                        } label: {
                            Label(t.0, systemImage: t.1)
                        }
                    }
                }
            }
            .navigationTitle("Quick log")
            .dietNavTitle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if scaffold != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            let full = (scaffold ?? "") + detail.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSend(full)
                            dismiss()
                        }
                        .disabled(detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Shared dashboard content

/// The Health dashboard's platform-neutral body: the loading / empty / content switch,
/// driven by a `HealthDashboardModel`. Both apps embed this inside their own navigation
/// chrome (iOS adds the quick-log toolbar + sheet; the Mac adds a manual refresh button),
/// so the render, the paging, and the state machine are shared and only the chrome is
/// platform-specific. It loads on appear; each platform layers its own extra refresh
/// triggers on top.
public struct HealthDashboardContent: View {
    private let model: HealthDashboardModel

    public init(model: HealthDashboardModel) {
        self.model = model
    }

    public var body: some View {
        content
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.displayState {
        case .loading:
            ProgressView("Loading today…").frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Health")
        case .empty(let error):
            HealthEmptyState(error: error) { Task { await model.load() } }
                .navigationTitle("Health")
        case .content(let snapshot):
            // TodayScreen sets its own navigation title (the date) and drives paging
            // through the model.
            TodayScreen(model: model, snapshot: snapshot, now: model.now(),
                        refreshError: model.refreshError)
        }
    }
}
