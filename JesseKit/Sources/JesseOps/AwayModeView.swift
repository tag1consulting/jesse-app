import SwiftUI
import JesseNetworking

// Away mode: where the owner declares that they are somewhere else, in which zone, until when.
//
// The screen shows the STORED period and whether it is in force separately, because they are
// different facts: a period whose deadline has passed is still on disk while the bridge has
// already gone back to deriving dates at home. Collapsing the two is how a screen comes to say
// "away until last Tuesday".

public struct AwayModeView: View {
    @State private var model: AwayModel

    @State private var wantsAway = false
    @State private var until = AwayModel.defaultUntil()
    @State private var zone = TimeZone.current.identifier
    @State private var note = ""
    @State private var showZonePicker = false
    /// Set once the loaded profile has seeded the editors, so a refresh mid-edit does not
    /// overwrite what is being typed.
    @State private var didSeed = false

    public init(configuration: OpsConfiguration) {
        _model = State(initialValue: AwayModel(configuration: configuration))
    }

    public var body: some View {
        Form {
            currentSection
            editorSection
            if model.profile?.isAway == true { comeHomeSection }
        }
        .formStyle(.grouped)
        .navigationTitle("Away mode")
        .task {
            await model.refresh()
            seedFromProfile()
        }
        .sheet(isPresented: $showZonePicker) {
            TimeZonePickerSheet(selection: $zone) { showZonePicker = false }
        }
    }

    // MARK: - What is in force

    private var currentSection: some View {
        Section {
            LabeledContent("Profile", value: model.profileName)
            if let p = model.profile {
                LabeledContent("Deriving dates in", value: p.tz ?? "unknown")
                LabeledContent("The Studio's own zone", value: p.processTz ?? "unknown")
                if let until = p.until {
                    LabeledContent(p.isAway ? "Until" : "Last period ended",
                                   value: OpsFormat.dayAndTime(until, in: .current))
                }
                if !p.note.isEmpty { LabeledContent("Note", value: p.note) }
                if !p.isAway, p.untilMs != nil {
                    // The stored-but-lapsed case, said out loud.
                    Text("An away period is on record but is no longer in force.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.isLoading {
                HStack { ProgressView(); Text("Asking the bridge…").foregroundStyle(.secondary) }
            }
            if let error = model.loadError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Now")
        } footer: {
            Text("While away, the bridge derives every date — the diet day, the schedule's clock, the day file — in the zone below instead of the Studio's. Your phone's own zone still wins for anything it asks for itself.")
        }
    }

    // MARK: - Declaring one

    private var editorSection: some View {
        Section {
            Toggle("Away", isOn: $wantsAway)
            if wantsAway {
                DatePicker("Until", selection: $until)
                Button {
                    showZonePicker = true
                } label: {
                    LabeledContent("Time zone", value: zone)
                }
                TextField("Note (rides on every prompt)", text: $note)
            }
            Button {
                Task { await save() }
            } label: {
                if model.isSaving {
                    HStack { ProgressView(); Text("Saving…") }
                } else {
                    Text("Save")
                }
            }
            .disabled(model.isSaving || !wantsAway)
            if let error = model.saveError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Away period")
        } footer: {
            Text("An away period must end: the bridge refuses one without a future deadline, because the failure mode of a manual switch is forgetting to switch back.")
        }
    }

    private var comeHomeSection: some View {
        Section {
            Button("Back home") {
                Task {
                    await model.goHome()
                    wantsAway = false
                }
            }
            .disabled(model.isSaving)
        } footer: {
            Text("Ends the period now. If the schedule declares an on-return job, coming home is what runs it.")
        }
    }

    // MARK: - Wiring

    private func save() async {
        guard wantsAway else { return }
        await model.goAway(tz: zone, until: until, note: note)
    }

    /// Fill the editors from what is in force, once. A period already running is shown as it
    /// stands so "extend it by three days" is an edit rather than a re-entry.
    private func seedFromProfile() {
        guard !didSeed, let p = model.profile else { return }
        didSeed = true
        wantsAway = p.isAway
        if let tz = p.tz { zone = tz }
        if p.isAway, let u = p.until { until = u }
        note = p.note
    }
}

// MARK: - The zone picker

/// Every zone the device knows, searchable. The list is `TimeZone.knownTimeZoneIdentifiers`,
/// which is the same tz database the bridge validates against, so a name picked here is a name
/// the bridge accepts.
struct TimeZonePickerSheet: View {
    @Binding var selection: String
    let onDone: () -> Void

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(AwayModel.zones(matching: query), id: \.self) { id in
                Button {
                    selection = id
                    onDone()
                } label: {
                    HStack {
                        Text(id.replacingOccurrences(of: "_", with: " "))
                        Spacer()
                        if id == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, prompt: "Search zones")
            .navigationTitle("Time zone")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }
}

// MARK: - The banner

/// The thin line the Chats list wears while an away period is in force, and the profile name
/// the Today header shows.
///
/// Both are driven by one `AwayModel` the platform shell owns and refreshes on app-active, so
/// the two can never disagree — and neither renders anything at all when the profile is home,
/// which is the overwhelmingly common case.
public struct AwayBanner: View {
    private let text: String

    /// Nil-returning by design at the call site: `if let text = model.bannerText` reads better
    /// in a shell than a banner that renders an empty row.
    public init(text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "airplane")
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.15))
        .accessibilityElement(children: .combine)
    }
}

/// The banner, wired to its own profile read — one line for a platform shell to embed.
///
/// It owns the `AwayModel` rather than taking one, because the two places it is mounted (the
/// Chats list and the Today header) are in different view trees on both platforms and threading
/// one model between them would mean an app-level singleton for a string. It re-reads on app
/// active, which is when an away period most often changes: the phone was somewhere else when
/// the owner declared it.
public struct AwayProfileBanner: View {
    @State private var model: AwayModel
    @Environment(\.scenePhase) private var scenePhase
    /// When true the view renders the profile NAME as a small caption when nothing is in force —
    /// what the Today header wants, since "home" is an answer worth showing there.
    private let alwaysShowName: Bool

    public init(configuration: OpsConfiguration, alwaysShowName: Bool = false) {
        _model = State(initialValue: AwayModel(configuration: configuration))
        self.alwaysShowName = alwaysShowName
    }

    public var body: some View {
        Group {
            if let text = model.bannerText {
                AwayBanner(text: text)
            } else if alwaysShowName {
                Text(model.profileName)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }
}
