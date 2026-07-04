import SwiftUI
import SwiftData

// Root of the app: a NavigationStack hosting the thread list. Cross-cutting
// concerns live here — re-attaching to backgrounded runs on foreground, draining
// Siri/voice hand-offs into fresh threads — because the stack and its path do.
struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(RunCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var inbox = JesseInbox.shared
    @StateObject private var pushRouter = PushRouter.shared
    @State private var path: [JesseThread] = []
    @State private var config = ConfigStore.load()
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ThreadListView(path: $path, config: $config, showSettings: $showSettings)
                .navigationDestination(for: JesseThread.self) { thread in
                    ThreadDetailView(thread: thread)
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(config: $config)
                }
        }
        .onAppear {
            coordinator.resume(context: context)
            inbox.drain()
            PushManager.shared.refreshRegistration()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                coordinator.resume(context: context)
                inbox.drain()
                // Re-register the device token (covers a token change / bridge
                // restart / host change since last launch).
                PushManager.shared.refreshRegistration()
            case .background:
                // "I'm leaving, ping me": ask the bridge to push when any
                // still-in-flight turn finishes, so it only pushes when needed.
                coordinator.notifyBackgroundInFlight()
            default:
                break
            }
        }
        .onChange(of: inbox.pending) { _, req in
            guard let req else { return }
            inbox.pending = nil
            startVoiceThread(req)
        }
        .onChange(of: pushRouter.pendingJobId) { _, jobId in
            guard let jobId else { return }
            pushRouter.pendingJobId = nil
            openThread(forJobId: jobId)
        }
    }

    /// A "Jesse finished" notification was tapped. Find the thread whose in-flight
    /// job matches (before `resume` delivers and clears it), re-attach to fetch the
    /// reply, then navigate there.
    private func openThread(forJobId jobId: String) {
        let threadID = coordinator.threadID(forJobId: jobId)
        coordinator.resume(context: context)
        guard let threadID else { return }
        var d = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == threadID })
        d.fetchLimit = 1
        if let thread = try? context.fetch(d).first {
            path = [thread]
        }
    }

    // Each voice invocation is its own new thread; the coordinator runs it and
    // speaks the reply. Land the user directly in the new conversation.
    private func startVoiceThread(_ req: PendingVoiceRequest) {
        let thread = JesseThread(mode: req.mode)
        context.insert(thread)
        path = [thread]
        coordinator.send(thread: thread, text: req.text, voice: true, context: context)
    }
}

/// What the Settings "Save" action should do once persistence has been attempted.
enum SaveOutcome: Equatable {
    case dismiss
    case showError
}

/// The Settings "Save" decision, factored out of the view so it's unit-testable
/// (a SwiftUI `.alert` is not). Persists the config — the bearer token plus
/// host/port — to the Keychain first; if that write fails it returns `.showError`
/// and does NOT run `persistPrompts`, so a failed token write can't half-commit the
/// prompt editors behind a dismissed sheet. Only on a successful Keychain write
/// does it run `persistPrompts` (the prompt-editor saves) and return `.dismiss`.
func settingsSaveOutcome(config: JesseConfig, persistPrompts: () -> Void) -> SaveOutcome {
    guard ConfigStore.save(config) else { return .showError }
    persistPrompts()
    return .dismiss
}

struct SettingsView: View {
    @Binding var config: JesseConfig
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = ""
    @State private var token = ""

    @State private var showScanner = false
    @State private var scanError: String?
    // Set when the Keychain write fails; drives the save-error alert so the sheet
    // stays open instead of silently dismissing on a token that never persisted.
    @State private var showSaveError = false

    // Per-mode wrapper editors. `*Prompt` is the editable text; `*Default` mirrors
    // the cached bridge default (for the differs-from-default check and Reset).
    @State private var askPrompt = ""
    @State private var tellPrompt = ""
    @State private var askDefault = ""
    @State private var tellDefault = ""
    // Per-mode floor editors. The floor is always prepended by the bridge; these
    // only customize its *wording*. Locked by default — an explicit unlock reveals
    // the editor. `*FloorDefault` is the cached recommended default (for the
    // differs/reset check); an empty editor falls back to that default (the floor
    // is never removed).
    @State private var askFloorText = ""
    @State private var tellFloorText = ""
    @State private var askFloorDefault = ""
    @State private var tellFloorDefault = ""
    @State private var askFloorUnlocked = false
    @State private var tellFloorUnlocked = false
    @State private var promptsError: String?
    @State private var loadingPrompts = false

    // Last-seen bridge version (from GET /health), shown next to the app's own.
    // Seeded from the persisted value so it's populated before a fresh probe, then
    // refreshed on appear and whenever we contact the bridge for defaults.
    @State private var bridgeVersion: String? = BridgeVersionStore.current

    // On-device search expansion (Tier 2), default ON. Off → pure multi-token
    // Tier-1 search with no model calls. Same key the thread list reads.
    @AppStorage("searchExpansionEnabled") private var searchExpansionEnabled = true

    // "Attach recent workouts" — default OFF until Apple Health is connected once,
    // then flipped on. Same UserDefaults key `JesseClient` reads at send time
    // (`WorkoutContextSettings`). `connectingHealth` gates the connect row.
    @AppStorage(WorkoutContextSettings.enabledKey) private var attachHealthContext = false
    @State private var connectingHealth = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Laptop (tailnet)") {
                    TextField("host — name or 100.x IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("port", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("Auth") {
                    SecureField("bearer token", text: $token)
                    // Pairing augments manual entry — it doesn't replace the
                    // fields above, which stay as the fallback.
                    Button {
                        scanError = nil
                        showScanner = true
                    } label: {
                        Label("Scan to pair", systemImage: "qrcode.viewfinder")
                    }
                    if let scanError {
                        Text(scanError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        loadDefaults(fillEmptyOnly: true)
                    } label: {
                        Label("Load defaults from bridge", systemImage: "arrow.down.circle")
                    }
                    .disabled(loadingPrompts)
                    if loadingPrompts {
                        HStack { ProgressView(); Text("Contacting the bridge…").foregroundStyle(.secondary) }
                    }
                    if let promptsError {
                        Text(promptsError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Prompt customization")
                } footer: {
                    Text("Customize how Ask and Tell wrap your message before Jesse sees it. An empty field uses the bridge's built-in default.")
                }

                Section {
                    bigEditor($askPrompt, editable: true)
                    Button("Reset to default") { resetToDefault(.ask) }
                        .disabled(loadingPrompts)
                } header: {
                    Text("Ask Jesse prompt")
                } footer: {
                    // The invariant lives in the floor section below; the wrapper
                    // editor only customizes the framing that follows it.
                    Text("Customizes how an “Ask” wraps your message — the framing that follows the safety floor below. Leave empty to use the bridge default.")
                }

                floorSection(for: .ask)

                Section {
                    bigEditor($tellPrompt, editable: true)
                    Button("Reset to default") { resetToDefault(.tell) }
                        .disabled(loadingPrompts)
                } header: {
                    Text("Tell Jesse prompt")
                } footer: {
                    Text("Customizes how a “Tell” wraps your message — the framing that follows the safety floor below. Leave empty to use the bridge default.")
                }

                floorSection(for: .tell)

                Section {
                    Toggle("Smart search expansion", isOn: $searchExpansionEnabled)
                } header: {
                    Text("Search")
                } footer: {
                    Text("When on, search also finds conversations that match synonyms or rephrasings of your words, using Apple Intelligence entirely on-device. Off uses exact word matching only. Requires a device with Apple Intelligence; otherwise search works the same as off.")
                }

                Section {
                    Toggle("Attach recent workouts", isOn: $attachHealthContext)
                    Button {
                        Task { await connectAppleHealth() }
                    } label: {
                        Label("Connect Apple Health", systemImage: "heart.text.square")
                    }
                    .disabled(connectingHealth)
                    if connectingHealth {
                        HStack { ProgressView(); Text("Requesting access…").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Jesse attaches your recent workouts (from Apple Health) so you can ask it to log one — “Log my swim.” Nothing is read until you connect, and you can turn it off anytime.")
                }

                Section {
                    LabeledContent("App", value: AppVersion.display)
                    LabeledContent("Bridge", value: bridgeVersion ?? "unknown")
                } header: {
                    Text("Version")
                } footer: {
                    Text("The bridge version updates when you load defaults or reopen Settings while connected.")
                }
            }
            .navigationTitle("Settings")
            .alert("Couldn’t save your settings", isPresented: $showSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your token couldn’t be saved to this iPhone’s Keychain, so pairing didn’t finish. Nothing was changed — please tap Save again.")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cfg = JesseConfig(host: host,
                                              port: Int(port) ?? JesseConfig.defaultPort,
                                              token: token)
                        // The config (token included) must persist before we commit
                        // anything else — on a Keychain failure we keep the sheet up
                        // and surface the error rather than half-committing the
                        // prompt editors and the in-memory config behind a dismiss.
                        let outcome = settingsSaveOutcome(config: cfg) {
                            config = cfg
                            // Persist the prompt editors. `save` re-derives each
                            // slot's customized flag (non-empty AND differs from the
                            // cached default); an empty field stays "use the default".
                            PromptStore.save(.ask, .wrapper, text: askPrompt, default: askDefault)
                            PromptStore.save(.tell, .wrapper, text: tellPrompt, default: tellDefault)
                            // Floor overrides: an empty editor falls back to the
                            // recommended default — the floor itself is never removed.
                            PromptStore.save(.ask, .floor, text: askFloorText, default: askFloorDefault)
                            PromptStore.save(.tell, .floor, text: tellFloorText, default: tellFloorDefault)
                        }
                        switch outcome {
                        case .dismiss:   dismiss()
                        case .showError: showSaveError = true
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                host = config.host
                port = String(config.port)
                token = config.token
                askPrompt = PromptStore.text(.ask, .wrapper)
                tellPrompt = PromptStore.text(.tell, .wrapper)
                askDefault = PromptStore.cachedDefault(.ask, .wrapper)
                tellDefault = PromptStore.cachedDefault(.tell, .wrapper)
                // Seed each floor editor from its override if customized, else the
                // cached recommended default; always re-lock on open.
                askFloorDefault = PromptStore.cachedDefault(.ask, .floor)
                tellFloorDefault = PromptStore.cachedDefault(.tell, .floor)
                askFloorText = PromptStore.override(for: .ask, .floor) ?? askFloorDefault
                tellFloorText = PromptStore.override(for: .tell, .floor) ?? tellFloorDefault
                askFloorUnlocked = false
                tellFloorUnlocked = false
            }
            .task { await refreshBridgeVersion() }
            .sheet(isPresented: $showScanner) {
                scannerSheet
            }
        }
    }

    // MARK: - Version

    /// Probe `GET /health` with the currently-entered host/token and update the
    /// shown bridge version (and the persisted value). No-op when unconfigured; a
    /// failed probe leaves the last-known version in place rather than blanking it.
    private func refreshBridgeVersion() async {
        let cfg = JesseConfig(host: host.isEmpty ? config.host : host,
                              port: Int(port) ?? config.port,
                              token: token.isEmpty ? config.token : token)
        guard cfg.isConfigured else { return }
        let v = await BridgeVersionStore.refresh(using: JesseClient(config: cfg))
        bridgeVersion = v
    }

    // MARK: - Prompt defaults

    /// Fetch the bridge's built-in wrapper defaults using the host/token the user
    /// has entered (not necessarily saved yet), so pairing + loading defaults can
    /// happen in one visit. Returns nil and sets `promptsError` on any failure.
    /// On success it also refreshes the cached floor defaults (and the floor
    /// editors when they aren't customized), since the floors ride along on the
    /// same response.
    private func fetchDefaults() async -> PromptDefaults? {
        loadingPrompts = true
        defer { loadingPrompts = false }
        promptsError = nil
        let cfg = JesseConfig(host: host, port: Int(port) ?? JesseConfig.defaultPort, token: token)
        do {
            let d = try await JesseClient(config: cfg).fetchPrompts()
            // Cache the recommended floor defaults and refresh the editors when the
            // user hasn't customized them (a customized floor is preserved).
            askFloorDefault = d.askFloor
            tellFloorDefault = d.tellFloor
            PromptStore.cacheDefault(.ask, .floor, d.askFloor)
            PromptStore.cacheDefault(.tell, .floor, d.tellFloor)
            if PromptStore.override(for: .ask, .floor) == nil { askFloorText = d.askFloor }
            if PromptStore.override(for: .tell, .floor) == nil { tellFloorText = d.tellFloor }
            // We just reached the bridge — refresh the shown version off the same
            // connection attempt.
            bridgeVersion = await BridgeVersionStore.refresh(using: JesseClient(config: cfg))
            return d
        } catch {
            let detail = (error as? JesseError)?.errorDescription ?? error.localizedDescription
            promptsError = "Couldn’t load defaults — connect to the bridge first. (\(detail))"
            return nil
        }
    }

    /// A large, internally-scrollable prompt editor used by every prompt text
    /// area, so long text is fully readable. A disabled editor renders read-only
    /// but still scrolls — that's how the locked floor view shows its full text.
    @ViewBuilder
    private func bigEditor(_ text: Binding<String>, editable: Bool) -> some View {
        TextEditor(text: text)
            .frame(minHeight: 200)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollContentBackground(.hidden)
            .disabled(!editable)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    /// The per-mode safety-floor section: locked by default, editable behind an
    /// explicit "not recommended" unlock. The floor is always prepended by the
    /// bridge — unlocking only lets you reword it, and an empty editor falls back
    /// to the recommended default (it can't be removed).
    @ViewBuilder
    private func floorSection(for mode: JesseMode) -> some View {
        let floorText = floorTextBinding(for: mode)
        let unlocked = floorUnlockedBinding(for: mode)
        let customized = PromptStore.override(for: mode, .floor) != nil
        Section {
            if unlocked.wrappedValue {
                Label("Editing the floor can weaken Jesse’s safety guardrail. Only change it if you understand the risk — Jesse always prepends this text to every turn.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                bigEditor(floorText, editable: true)
                Button("Reset to recommended default") { resetFloorToDefault(mode) }
                    .disabled(loadingPrompts)
                Button {
                    unlocked.wrappedValue = false
                } label: {
                    Label("Lock", systemImage: "lock")
                }
            } else {
                Label("Recommended safety floor — locked", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                bigEditor(floorText, editable: false)
                if customized {
                    Label("Customized — differs from recommended", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    unlocked.wrappedValue = true
                } label: {
                    Label("Unlock to edit (not recommended)", systemImage: "lock.open")
                }
            }
        } header: {
            Text(mode == .ask ? "Ask safety floor" : "Tell safety floor")
        } footer: {
            Text("Always prepended to every turn — Jesse leads with this. Unlock only to customize its wording; an empty editor uses the recommended default (it can’t be removed).")
        }
    }

    private func floorTextBinding(for mode: JesseMode) -> Binding<String> {
        mode == .ask ? $askFloorText : $tellFloorText
    }

    private func floorUnlockedBinding(for mode: JesseMode) -> Binding<Bool> {
        mode == .ask ? $askFloorUnlocked : $tellFloorUnlocked
    }

    /// "Reset to default" for a wrapper: overwrite that editor with the freshly
    /// fetched bridge default and cache it. The customized flag clears on Save
    /// (text then equals the cached default).
    private func resetToDefault(_ mode: JesseMode) {
        Task {
            guard let d = await fetchDefaults() else { return }
            switch mode {
            case .ask:  askDefault = d.ask;  askPrompt = d.ask
            case .tell: tellDefault = d.tell; tellPrompt = d.tell
            }
        }
    }

    /// "Reset to recommended default" for a floor: fetch the recommended floor and
    /// load it into the editor, staying unlocked. The customized flag clears on
    /// Save (text then equals the cached default).
    private func resetFloorToDefault(_ mode: JesseMode) {
        Task {
            guard let d = await fetchDefaults() else { return }
            switch mode {
            case .ask:  askFloorDefault = d.askFloor;  askFloorText = d.askFloor
            case .tell: tellFloorDefault = d.tellFloor; tellFloorText = d.tellFloor
            }
        }
    }

    /// "Load defaults from bridge": cache both wrapper defaults and fill the
    /// editors. With `fillEmptyOnly`, only blank editors are populated so a custom
    /// prompt is never clobbered — the first-use affordance for empty editors.
    /// (Floor defaults are refreshed inside `fetchDefaults`.)
    private func loadDefaults(fillEmptyOnly: Bool) {
        Task {
            guard let d = await fetchDefaults() else { return }
            askDefault = d.ask
            tellDefault = d.tell
            if !fillEmptyOnly || askPrompt.isEmpty { askPrompt = d.ask }
            if !fillEmptyOnly || tellPrompt.isEmpty { tellPrompt = d.tell }
        }
    }

    /// "Connect Apple Health": request read authorization for the workout types.
    /// Apple hides whether READ was granted (denial just yields empty queries, so
    /// nothing is attached), so "granted once, then on" means: once the prompt has
    /// been answered without error, flip the toggle on. The user can turn it back
    /// off anytime.
    private func connectAppleHealth() async {
        connectingHealth = true
        defer { connectingHealth = false }
        if await HealthKitWorkoutProvider.requestReadAuthorization() {
            attachHealthContext = true
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRScannerView(
                onScan: { raw in
                    if let parsed = JesseConfig.fromPairing(raw) {
                        host = parsed.host
                        port = String(parsed.port)
                        token = parsed.token
                        scanError = nil
                        showScanner = false
                    } else {
                        // Keep the sheet open so the user can retry the scan.
                        scanError = "That QR isn't a Jesse pairing code."
                    }
                },
                onError: { message in
                    scanError = message
                    showScanner = false
                }
            )
            .ignoresSafeArea()
            .navigationTitle("Scan to pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showScanner = false }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
