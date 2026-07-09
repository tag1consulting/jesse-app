import SwiftUI
import SwiftData

// The Health tab: a compact, scannable "Today" screen that drills into the six
// detail screens. All rendering is a pure function of the snapshot + semantics; the
// model owns fetch/cache. Refresh happens on appear, on pull, and after any turn
// completes while this tab is active (a logged meal comes back reflected).

struct HealthTabView: View {
    /// Whether the Health tab is the selected tab — gates the after-turn refresh so
    /// a background turn doesn't refetch while the user is in Chats.
    let isActive: Bool

    @Environment(RunCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var context
    @State private var model = HealthDashboardModel()
    @State private var showQuickLog = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Health")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showQuickLog = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Quick log")
                    }
                }
                .sheet(isPresented: $showQuickLog) {
                    QuickLogSheet { text in
                        let thread = JesseThread(mode: .tell)
                        context.insert(thread)
                        coordinator.send(thread: thread, text: text, voice: false, context: context)
                    }
                }
        }
        .task { await model.load() }
        .onChange(of: coordinator.inFlight.count) { old, new in
            // A turn settled (inFlight shrank) while this tab is up → refetch so a
            // just-logged meal/weigh-in is reflected.
            if new < old && isActive { Task { await model.load() } }
        }
        .onChange(of: isActive) { _, active in
            if active { Task { await model.load() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.displayState {
        case .loading:
            ProgressView("Loading today…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty(let error):
            HealthEmptyState(error: error) { Task { await model.load() } }
        case .content(let snapshot):
            TodayScreen(snapshot: snapshot, now: model.now(), refreshError: model.refreshError) {
                await model.load()
            }
        }
    }
}

// MARK: - Level 1: Today

struct TodayScreen: View {
    let snapshot: DietSnapshot
    let now: Date
    let refreshError: DietFetchError?
    let refresh: () async -> Void

    private var today: DietToday { snapshot.today }
    private var hour: Int { Calendar.current.component(.hour, from: now) }
    private var gauges: DietGauges { DietSemantics.gauges(for: today, hour: hour) }
    private var isStale: Bool { HealthDisplay.isStale(todayDate: today.date, now: now) }

    var body: some View {
        List {
            headerSection
            weightSection
            caloriesSection
            macroStripSection
            coachHeadlineSection
            navRowsSection
        }
        .refreshable { await refresh() }
    }

    // Header: date, day-style chip, updated stamp, stale banner, refresh-failed note.
    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(prettyDate(today.date)).font(.headline)
                    DayStyleChip(dayStyle: today.dayStyle, isCarbLoad: gauges.isCarbLoad)
                    Spacer()
                    if let updated = HealthDisplay.updatedTime(fromMtime: snapshot.todayMtime) {
                        Text("updated \(updated)").font(.caption).foregroundStyle(.secondary)
                    }
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
        }
    }

    @ViewBuilder
    private var weightSection: some View {
        if let card = HealthDisplay.weightCard(today: today, series: snapshot.weightSeries) {
            Section { WeightCardView(card: card) }
        }
    }

    private var caloriesSection: some View {
        Section {
            let cal = gauges.calories
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DietSemantics.fmt(remainingMagnitude(cal)))
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(statusColor(cal.status))
                    Text(cal.remaining).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    GoalChip(goal: cal.goal)
                }
                StatusMeter(fraction: cal.fraction, status: cal.status, height: 10)
                if gauges.net.burned > 0 {
                    Text("\(DietSemantics.fmt(gauges.net.net)) net · \(DietSemantics.fmt(gauges.net.burned)) burned")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Calories")
        }
    }

    private var macroStripSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                CompactMacroGauge(gauge: gauges.protein)
                CompactMacroGauge(gauge: gauges.carbs)
                CompactMacroGauge(gauge: gauges.fat)
                CompactMacroGauge(gauge: gauges.fiber)
            }
        }
    }

    @ViewBuilder
    private var coachHeadlineSection: some View {
        if let note = snapshot.coach?.notes.first {
            Section {
                Text(CoachHTML.plainText(note))
                    .font(.subheadline).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var navRowsSection: some View {
        Section {
            NavigationLink {
                MacrosCaloriesDetail(today: today, hour: hour)
            } label: {
                NavRow(title: "Macros & calories", icon: "chart.bar.fill",
                       subtitle: "\(DietSemantics.fmt(gauges.calories.value)) cal · \(gauges.protein.remaining)")
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

            unavailableOr(section: snapshot.weightSeries?.isEmpty == false ? snapshot.weightSeries : nil,
                          label: "Weight", errors: snapshot.errors,
                          icon: "scalemass", title: "Weight & trend",
                          subtitle: weightSubtitle) { series in
                WeightTrendDetail(series: series, progress: snapshot.progress)
            }

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

    private func remainingMagnitude(_ g: MetricGauge) -> Double {
        guard let t = g.target else { return g.value }
        return abs(t - g.value)
    }

    private func prettyDate(_ iso: String) -> String {
        let inF = DateFormatter(); inF.dateFormat = "yyyy-MM-dd"
        inF.timeZone = TimeZone(identifier: "UTC")
        guard let d = inF.date(from: iso) else { return iso }
        let out = DateFormatter(); out.dateFormat = "EEEE, MMM d"
        return out.string(from: d)
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
    private var label: String {
        switch dayStyle {
        case "carb-load-training", "carb-load-race": return "Carb-load"
        case "long-run": return "Long run"
        case "refeed": return "Refeed"
        case "sick": return "Sick"
        case "fasting": return "Fasting"
        case "normal", nil, "": return isCarbLoad ? "Carb-load" : "Normal"
        default: return dayStyle?.capitalized ?? "Normal"
        }
    }
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

struct QuickLogSheet: View {
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let templates = [
        ("Meal", "fork.knife", "Log a meal: "),
        ("Snack", "carrot", "Log a snack: "),
        ("Weigh-in", "scalemass", "Log a weigh-in: "),
        ("Workout", "figure.run", "Log a workout: "),
    ]

    @State private var scaffold: String?
    @State private var detail = ""

    var body: some View {
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
            .navigationBarTitleDisplayMode(.inline)
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
