import SwiftUI
import SwiftData
import JesseCore
import JesseOps

// Root of the app: a NavigationStack hosting the thread list. Cross-cutting
// concerns live here — re-attaching to backgrounded runs on foreground, draining
// Siri/voice hand-offs into fresh threads — because the stack and its path do.
struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(RunCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var inbox = JesseInbox.shared
    @StateObject private var pushRouter = PushRouter.shared
    @StateObject private var voice = VoiceCaptureModel()
    @State private var path: [JesseThread] = []
    @State private var config = ConfigStore.load()
    @State private var showSettings = false
    // Raised with `showSettings` by the first-run pairing CTA so Settings opens
    // straight to Scan-to-pair; cleared when the sheet dismisses so the gear
    // button's ordinary Settings open never auto-presents the scanner.
    @State private var pairViaScanner = false
    // iPad/landscape gets a real two-column split; iPhone/compact keeps the stack.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    // Probes the bridge so the list can warn "offline" before the user composes.
    // THE shared model, not one of this screen's own: three tabs each used to stand up
    // an instance and fire a `GET /health` on every activation, and two of them could
    // disagree — one showing an offline banner while the next rendered the day it had
    // just fetched. See `BridgeReachabilityModel.shared`.
    private let reachability = BridgeReachabilityModel.shared

    /// The list-level offline banner shows only when paired AND a probe came back
    /// unreachable (pure `shouldShowOfflineBanner`).
    private var offlineBannerVisible: Bool {
        shouldShowOfflineBanner(isConfigured: config.isConfigured, reachability: reachability.state)
    }

    /// The selected conversation, expressed over the existing `path` model so the
    /// split view's detail column and the stack's push share one source of truth:
    /// the visible conversation is always `path.last`. Selecting one in the sidebar
    /// replaces the detail; `newThread`/voice/push that set `path` update it too.
    private var selectedThread: Binding<JesseThread?> {
        Binding(get: { path.last },
                set: { path = $0.map { [$0] } ?? [] })
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                // iPhone / compact: the original stack — unchanged behavior.
                NavigationStack(path: $path) {
                    ThreadListView(path: $path, config: $config, showSettings: $showSettings,
                                   pairViaScanner: $pairViaScanner, selection: selectedThread,
                                   showOfflineBanner: offlineBannerVisible)
                        .navigationDestination(for: JesseThread.self) { thread in
                            ThreadDetailView(thread: thread)
                        }
                }
            } else {
                // iPad / regular: list as sidebar, conversation as detail.
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    ThreadListView(path: $path, config: $config, showSettings: $showSettings,
                                   pairViaScanner: $pairViaScanner, selection: selectedThread,
                                   showOfflineBanner: offlineBannerVisible)
                        .navigationSplitViewColumnWidth(min: 320, ideal: 360)
                } detail: {
                    if let thread = path.last {
                        // Its own stack so the detail's toolbar/title behave normally.
                        // `hidesTabBar: false` — the detail column is permanent here
                        // (nothing pops it), so hiding the tab bar would make Health
                        // unreachable for the rest of the launch.
                        NavigationStack { ThreadDetailView(thread: thread, hidesTabBar: false) }
                            .id(thread.id)
                    } else {
                        ContentUnavailableView {
                            Label("Select a conversation", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("Choose a conversation from the list, or tap the compose button to start a new one.")
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            pairViaScanner = false
            // Pairing may have changed host/token — re-probe so the banner reflects
            // the new config. FORCED past the 30s throttle: a re-pairing points at a
            // different bridge entirely, so the last answer is about something else.
            reachability.refresh(config: config, force: true)
        }) {
            SettingsView(config: $config, autoPresentScanner: pairViaScanner)
        }
        .onAppear {
            // The app-wide network monitor, and the recovery it drives: re-attach every
            // in-flight job, drain the send outbox and replay queued intents the moment the
            // phone is back on a network. Idempotent, so a second appearance is free.
            coordinator.startConnectivityRecovery(context: context)
            BridgeReachabilityModel.shared.follow(ConnectivityMonitor.shared) { ConfigStore.load() }
            coordinator.resume(context: context)
            // Pull the session list and reconcile favorite/archive flags across devices
            // (cache-first; a star/archive made on the Mac lands here). Best-effort.
            Task { await coordinator.refreshSessions(context: context) }
            inbox.drain()
            PushManager.shared.refreshRegistration()
            reachability.refresh(config: config)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                coordinator.resume(context: context)
                Task { await coordinator.refreshSessions(context: context) }
                inbox.drain()
                // Re-register the device token (covers a token change / bridge
                // restart / host change since last launch).
                PushManager.shared.refreshRegistration()
                // Re-probe reachability so the offline banner is current on return.
                reachability.refresh(config: config)
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
        .onChange(of: inbox.pendingWake) { _, wake in
            guard let wake else { return }
            inbox.pendingWake = nil
            Task { await startWakeCapture(mode: wake.mode) }
        }
        .onChange(of: pushRouter.pendingTap) { _, tap in
            guard let tap else { return }
            // NOT cleared here. The other pending values above are consumed before their
            // work because their work is synchronous; routing a tap now awaits a session
            // sync in its third branch, and clearing first meant a tap that arrived while
            // the view was still coming up was thrown away mid-resolve. It is cleared in
            // `openThread`, once routing has resolved or definitively failed.
            Task { await openThread(for: tap) }
        }
        .overlay {
            if voice.phase != .idle {
                listeningOverlay
            }
        }
    }

    /// The hands-free listening UI, shown while the wake capture records then
    /// transcribes. Stop keeps the take (transcribe what was said); Cancel discards
    /// it. It's an overlay, not a sheet, so it never fights the navigation stack.
    private var listeningOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: voice.phase == .listening ? "waveform" : "text.bubble")
                    .font(.system(size: 44))
                    .symbolEffect(.variableColor.iterative, isActive: voice.phase == .listening)
                    .foregroundStyle(.tint)
                Text(voice.phase == .listening ? "Listening…" : "Transcribing…")
                    .font(.headline)
                if voice.phase == .listening {
                    Text("Speak your request — I'll stop when you pause.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Button("Cancel", role: .cancel) { voice.cancel() }
                            .buttonStyle(.bordered)
                        Button("Stop") { voice.stop() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(40)
        }
    }

    /// A "Jesse finished" notification was tapped: re-attach to fetch the reply, resolve
    /// which conversation the notification was reporting on, and navigate there.
    ///
    /// The in-flight lookup happens FIRST and synchronously, before `resume`, which
    /// re-attaches and may deliver the reply and clear the entry out from under it. Its
    /// result is handed to the resolver so the ordering is not left to chance across the
    /// suspension points the fallback chain introduces — see
    /// `RunCoordinator.thread(forTap:liveThreadID:context:)` for the three steps.
    ///
    /// The pending tap is cleared only once this has resolved or definitively failed, so a
    /// tap that arrives before the view exists still routes.
    private func openThread(for tap: PushTap) async {
        let liveThreadID = tap.jobId.flatMap { coordinator.threadID(forJobId: $0) }
        coordinator.resume(context: context)
        let thread = await coordinator.thread(forTap: tap, liveThreadID: liveThreadID, context: context)
        if pushRouter.pendingTap == tap { pushRouter.pendingTap = nil }
        guard let thread else {
            // Not silent. Landing on the thread list is the pre-existing behaviour and an
            // acceptable one; landing there with no record of why is what made this
            // impossible to diagnose from a phone.
            Log.push.notice(
                "tap did not resolve a thread (job=\(tap.jobId ?? "-") conversation=\(tap.conversationId ?? "-")) — showing the thread list"
            )
            return
        }
        path = [thread]
    }

    // The hands-free doorbell fired: capture the spoken request in-app (Siri only
    // opened us), then run it exactly like any other voice turn. A cancel / denial /
    // empty transcript simply does nothing — the app is already foregrounded.
    private func startWakeCapture(mode: JesseMode) async {
        guard let text = await voice.capture() else { return }
        startVoiceThread(PendingVoiceRequest(mode: mode, text: text))
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
///
/// `sentinel` is written in the SAME order and with the same rule: the bridge first,
/// because that is the pairing everything else depends on, and a sentinel write that
/// fails is still `.showError` — a screen full of ops buttons pointed at a half-saved
/// sentinel would 401 on every press with no explanation. A sentinel with a blank host
/// or token is a legitimate "I don't run one" and is stored as such.
func settingsSaveOutcome(config: JesseConfig,
                         sentinel: SentinelConfig = SentinelConfig(host: "", token: ""),
                         persistPrompts: () -> Void) -> SaveOutcome {
    guard ConfigStore.save(config) else { return .showError }
    guard ConfigStore.saveSentinel(sentinel) else { return .showError }
    persistPrompts()
    return .dismiss
}

/// The six connection fields the Settings form holds, as a value.
///
/// It exists so the ONE rule a scan has to get right is testable without a camera: see
/// `fieldsAfterScan`.
struct PairingFields: Equatable {
    var host = ""
    var port = ""
    var token = ""
    var sentinelHost = ""
    var sentinelPort = ""
    var sentinelToken = ""
}

/// What a scanned pairing payload does to the fields already on screen.
///
/// THE RULE, and the only reason this is a function rather than six assignments in a closure:
/// the three sentinel keys are ADDITIVE. A QR from a bridge with no sentinel configured
/// carries none of them, and that says NOTHING about the sentinel rather than "there is none".
/// Blanking the sentinel fields on such a scan would silently unpair the Ops screen every time
/// someone re-scanned an ordinary bridge code — and the next Save would make it permanent.
func fieldsAfterScan(_ payload: PairingPayload, existing: PairingFields) -> PairingFields {
    var out = existing
    out.host = payload.bridge.host
    out.port = String(payload.bridge.port)
    out.token = payload.bridge.token
    if let sentinel = payload.sentinel {
        out.sentinelHost = sentinel.host
        out.sentinelPort = String(sentinel.port)
        out.sentinelToken = sentinel.token
    }
    return out
}

struct SettingsView: View {
    @Binding var config: JesseConfig
    // When true, open straight to the Scan-to-pair sheet — the first-run pairing
    // CTA sets this so a fresh user lands on the scanner, not the full form. The
    // gear-button open leaves it false.
    var autoPresentScanner = false
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = ""
    @State private var token = ""

    // The SENTINEL's own host, port and token — a different process on a different port
    // under a different token, so it stays reachable when the bridge is not. Seeded from
    // the Keychain on appear and written by Save alongside the bridge's.
    @State private var sentinelHost = ""
    @State private var sentinelPort = ""
    @State private var sentinelToken = ""

    @State private var showScanner = false
    @State private var scanError: String?
    // Set when the Keychain write fails. Surfaced inline in the Auth section (the
    // same pattern as `scanError`), keeping the sheet open instead of dismissing on
    // a token that never persisted — the app's one error style is inline, not an
    // alert, so this used to be the lone outlier.
    @State private var saveError: String?

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

    // Per-turn model selection (retire the global switch): the selectable models fetched from
    // the bridge, used here ONLY to choose this DEVICE's default model for NEW conversations
    // (`LastUsedModelStore`) — never the bridge's global default. `nil` until loaded / on an
    // older bridge. `deviceDefaultID` mirrors the per-device default so the checkmark updates
    // live; `switchingModel` disables the write-toggle rows during a write change.
    @State private var modelState: ModelSwitchState?
    @State private var deviceDefaultID: String? = LastUsedModelStore.id
    @State private var loadingModels = false
    @State private var switchingModel = false
    @State private var modelsError: String?
    // Phase 2: the model awaiting write-enable confirmation. Granting a non-default model
    // write access is gated behind an explicit confirm that names it and warns it can modify
    // the vault; revoking is immediate (it only ever reduces access).

    // On-device search expansion (Tier 2), default ON. Off → pure multi-token
    // Tier-1 search with no model calls. Same key the thread list reads.
    @AppStorage("searchExpansionEnabled") private var searchExpansionEnabled = true

    // "Attach health context" — default OFF until Apple Health is connected once,
    // then flipped on. Same UserDefaults key `JesseClient` reads at send time
    // (`HealthContextSettings`). `connectingHealth` gates the connect row.
    @AppStorage(HealthContextSettings.enabledKey) private var attachHealthContext = false
    @AppStorage(FrugalSettings.forcedKey) private var frugalOnCellular = false
    @State private var connectingHealth = false

    // "Write meals to Apple Health" — default OFF until write access is granted, then
    // flipped on. Same key `RunCoordinator`'s meal writer reads (`WriteMealsToHealthSettings`).
    // `mealWriteDenied` reflects the queryable WRITE status (unlike read): when the
    // user has denied write access the row says so and the toggle is disabled.
    @AppStorage(WriteMealsToHealthSettings.enabledKey) private var writeMealsToHealth = false
    @State private var mealWriteDenied = false

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
                    if let saveError {
                        Text(saveError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    TextField("host — name or 100.x IP", text: $sentinelHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("port", text: $sentinelPort)
                        .keyboardType(.numberPad)
                    SecureField("sentinel token", text: $sentinelToken)
                } header: {
                    Text("Sentinel")
                } footer: {
                    Text("The sentinel is a second process on the laptop, on its own port and its own token, that watches the bridge and can restart it. A pairing QR from a bridge that has one fills these in for you. Leave them blank if you don't run one — everything else works the same.")
                }

                Section {
                    NavigationLink {
                        OpsView(configuration: opsConfiguration)
                    } label: {
                        Label("Bridge ops", systemImage: "stethoscope")
                    }
                    NavigationLink {
                        AwayModeView(configuration: opsConfiguration)
                    } label: {
                        Label("Away mode", systemImage: "airplane")
                    }
                } header: {
                    Text("Operations")
                } footer: {
                    Text("Ops shows the laptop's health and the buttons that act on it, and leads to the schedule. Away mode tells the bridge which zone to derive dates in while you're travelling.")
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

                modelSwitchSection

                Section {
                    Toggle("Frugal on cellular", isOn: $frugalOnCellular)
                } header: {
                    Text("Data")
                } footer: {
                    Text("Jesse already does this by itself on cellular and in Low Data Mode: photos are sent smaller, it checks for the reply less often, and it reuses the health summary it already has instead of fetching a new one. Turn this on to do the same on every network. Nothing is ever refused — sending, replies and the day file all work exactly the same, they just cost less.")
                }

                Section {
                    Toggle("Smart search expansion", isOn: $searchExpansionEnabled)
                } header: {
                    Text("Search")
                } footer: {
                    Text("When on, search also finds conversations that match synonyms or rephrasings of your words, using Apple Intelligence entirely on-device. Off uses exact word matching only. Requires a device with Apple Intelligence; otherwise search works the same as off.")
                }

                Section {
                    Toggle("Attach health context", isOn: $attachHealthContext)
                    Toggle("Write meals to Apple Health", isOn: $writeMealsToHealth)
                        .disabled(mealWriteDenied)
                    Button {
                        Task { await connectAppleHealth() }
                    } label: {
                        Label("Connect Apple Health", systemImage: "heart.text.square")
                    }
                    .disabled(connectingHealth)
                    if connectingHealth {
                        HStack { ProgressView(); Text("Requesting access…").foregroundStyle(.secondary) }
                    }
                    if mealWriteDenied {
                        Text("Health write access is off. Turn on Nutrition for Jesse in the Health app › Sharing to log meals here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Jesse attaches a compact summary of your recent Apple Health — last night’s sleep, resting heart rate and other daily vitals, plus your recent workouts — so you can ask it to log one (“Log my swim”) or reflect on how you’re doing. With “Write meals” on, meals you log (“log lunch: …”) are also saved to Health as nutrition entries. Nothing is read or written until you connect, and you can turn either off anytime.")
                }
                .onAppear { mealWriteDenied = HealthKitMealWriter.isWriteDenied() }

                Section {
                    LabeledContent("App", value: AppVersion.display)
                    LabeledContent("Bridge", value: bridgeVersion ?? "unknown")
                    if BridgeCompatibility.isOutdated(bridgeVersion: bridgeVersion) {
                        // Non-blocking heads-up: the app keeps working (each endpoint
                        // degrades gracefully on its own), but a stale bridge should
                        // no longer fail silently the way the /jesse/title 404 did.
                        Label {
                            Text("Your bridge is out of date — this app expects bridge \(BridgeCompatibility.minimumBridgeVersion) or newer, but it’s \(bridgeVersion ?? "unknown"). Some newer features may not work until you update the bridge.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Version")
                } footer: {
                    Text("The bridge version updates when you load defaults or reopen Settings while connected.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveError = nil
                        let cfg = JesseConfig(host: host,
                                              port: Int(port) ?? JesseConfig.defaultPort,
                                              token: token)
                        // The config (token included) must persist before we commit
                        // anything else — on a Keychain failure we keep the sheet up
                        // and surface the error rather than half-committing the
                        // prompt editors and the in-memory config behind a dismiss.
                        let outcome = settingsSaveOutcome(config: cfg,
                                                          sentinel: enteredSentinel) {
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
                        case .showError:
                            saveError = "Your token couldn’t be saved to this iPhone’s Keychain, so pairing didn’t finish. Nothing was changed — please tap Save again."
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
                let sentinel = ConfigStore.loadSentinel()
                sentinelHost = sentinel.host
                sentinelPort = String(sentinel.port)
                sentinelToken = sentinel.token
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
                // First-run pairing CTA: jump straight to the scanner.
                if autoPresentScanner {
                    scanError = nil
                    showScanner = true
                }
            }
            .task { await refreshBridgeVersion() }
            .sheet(isPresented: $showScanner) {
                scannerSheet
            }
        }
    }

    // MARK: - Ops

    /// The six connection fields as they currently read, for `fieldsAfterScan`.
    private var currentFields: PairingFields {
        PairingFields(host: host, port: port, token: token,
                      sentinelHost: sentinelHost, sentinelPort: sentinelPort,
                      sentinelToken: sentinelToken)
    }

    /// The sentinel as the fields currently read. A blank host or token is an unconfigured
    /// sentinel, which is a supported state rather than an error: most bridges do not run one.
    private var enteredSentinel: SentinelConfig {
        SentinelConfig(host: sentinelHost,
                       port: Int(sentinelPort) ?? SentinelConfig.defaultPort,
                       token: sentinelToken)
    }

    /// What the two Ops screens are built from — the SAVED bridge config plus the sentinel as
    /// entered, so pairing the sentinel and opening Ops can happen in one visit without a
    /// round trip through Save.
    private var opsConfiguration: OpsConfiguration {
        OpsConfiguration(bridge: JesseConfig(host: host.isEmpty ? config.host : host,
                                             port: Int(port) ?? config.port,
                                             token: token.isEmpty ? config.token : token),
                         sentinel: enteredSentinel)
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

    /// The per-device DEFAULT-model section: one row per selectable model, the current device
    /// default checked. Selecting a model here sets THIS device's default for NEW conversations
    /// only (`LastUsedModelStore`) — it never changes the bridge's global default and never
    /// touches an existing conversation (each thread keeps its own choice, changed from the
    /// thread's own picker). An unavailable model is disabled with a short reason — "not
    /// configured" or "unreachable" — so a health change shows live. Hidden until models load
    /// (an older bridge has no route).
    @ViewBuilder
    private var modelSwitchSection: some View {
        Section {
            if let modelState {
                ForEach(modelState.models) { model in
                    Button {
                        selectDefaultModel(model)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.label)
                                    .foregroundStyle(model.available ? .primary : .secondary)
                                if let reason = model.unavailableReason {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let caveat = model.levelCaveat {
                                    // Every model appears in the picker whatever its level —
                                    // being able to talk to all of them is the point. What
                                    // changes is that a model below Write says so here,
                                    // before it is picked rather than after it declines.
                                    Text(caveat)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model.id == resolvedDefaultID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(!model.available)
                }
            } else if loadingModels {
                HStack { ProgressView(); Text("Loading models…").foregroundStyle(.secondary) }
            } else {
                Button {
                    Task { await loadModels() }
                } label: {
                    Label("Load models from bridge", systemImage: "cpu")
                }
            }
            if let modelsError {
                Text(modelsError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Default model for new conversations")
        } footer: {
            Text("Sets which model NEW conversations on this device start on (and the sub-agents it runs). Each conversation keeps its own choice — change it from the picker inside a conversation — and this is per device, so your phone and Mac can differ. The cheap background helpers — titles, diet logging, vault lookups — are unaffected. A non-default model can read your vault but not write it until you enable writes for it. A model that is unreachable or not yet configured is shown disabled.")
        }
        // Poll on appear AND on a light interval WHILE this settings screen is visible, so a
        // model going healthy/unhealthy shows up live. The `.task` is cancelled when the view
        // goes away (Settings dismissed), so polling backs off then — never a tight loop.
        .task { await pollModelsWhileVisible() }

        writeAccessSection
    }

    /// The health poll cadence while Settings is open — long enough to never be a tight loop.
    private static let modelPollInterval: Duration = .seconds(25)

    /// Fetch the models on appear, then re-fetch every `modelPollInterval` for as long as this
    /// view's `.task` lives (SwiftUI cancels it when the view disappears, so this stops when
    /// Settings closes). Skips a poll mid-swap so a background refresh can't clobber an
    /// in-flight selection.
    private func pollModelsWhileVisible() async {
        // Always load ONCE — the section is hidden until the list arrives, and frugal mode
        // is about spending less, never about showing less.
        if !switchingModel { await loadModels() }
        // The repeat is what frugal mode drops: a round trip every 25 seconds, for the
        // duration of a settings visit, to catch a health change that almost never happens
        // while someone is looking at the screen.
        while !Task.isCancelled, FrugalSettings.current().modelListPollingEnabled {
            try? await Task.sleep(for: Self.modelPollInterval)
            guard !Task.isCancelled else { return }
            if !switchingModel { await loadModels() }
        }
    }

    /// What a model may touch is now CONFIG, not a switch on this device.
    ///
    /// This section used to carry a per-model "allow writes" toggle backed by
    /// `POST /jesse/model/{id}/writes`. That endpoint is gone: a model's `level` lives in the
    /// bridge config and is validated at startup against the committed containment record, so
    /// a containment decision cannot be taken from a phone. The switcher still SHOWS what
    /// each model may do.
    @ViewBuilder
    private var writeAccessSection: some View {
        if let modelState, modelState.models.contains(where: { $0.available && !$0.isDefault }) {
            Section {
                ForEach(modelState.models.filter { $0.available && !$0.isDefault }) { model in
                    HStack {
                        Text(model.label)
                        Spacer()
                        Text(model.writesAllowed ? "can write the vault" : (model.levelCaveat ?? "read-only"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What each model may do")
            } footer: {
                Text("Set by the bridge's config (each model's level), not from this app. A model below “write” can answer questions but cannot change your vault.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Fetch the selectable models + active selection using the entered host/token. Silent on
    /// an older bridge (no `/jesse/models` route) — the section simply stays hidden.
    private func loadModels() async {
        let cfg = JesseConfig(host: host, port: Int(port) ?? JesseConfig.defaultPort, token: token)
        guard cfg.isConfigured else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            modelState = try await JesseClient(config: cfg).fetchModels()
            modelsError = nil
        } catch {
            // Leave `modelState` as-is: never loaded (older bridge 404s / first poll failed)
            // → stays nil, so the section stays hidden rather than shouting; already loaded →
            // KEEP the last-known list so a transient blip during interval polling doesn't
            // blank a working switcher (the next poll refreshes it).
        }
    }

    /// The device default shown checked: this device's stored default when it is still
    /// selectable, else the ambient `opus` (the effective default a new conversation gets).
    private var resolvedDefaultID: String? {
        modelState?.resolvedModel(threadModelID: nil, deviceDefaultID: deviceDefaultID)?.id
    }

    /// Make `model` this DEVICE's default for NEW conversations (`LastUsedModelStore`). Purely
    /// local — no bridge write — so another device and every existing conversation are
    /// unaffected. A no-op on an unavailable model.
    private func selectDefaultModel(_ model: ModelInfo) {
        guard model.available else { return }
        LastUsedModelStore.id = model.id
        deviceDefaultID = model.id
        modelsError = nil
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

    /// "Connect Apple Health": request read authorization for the health-context
    /// types AND write authorization for the dietary types, in one prompt. Apple
    /// hides whether READ was granted (denial just yields empty queries), so
    /// answering the prompt without error flips the read toggle on. WRITE status IS
    /// queryable, so meal-writing is flipped on only when write access wasn't denied,
    /// and the denied state is captured for the row. The user can turn either off.
    private func connectAppleHealth() async {
        connectingHealth = true
        defer { connectingHealth = false }
        if await HealthContextProvider.requestAuthorization() {
            attachHealthContext = true
            let denied = HealthKitMealWriter.isWriteDenied()
            mealWriteDenied = denied
            if !denied { writeMealsToHealth = true }
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRScannerView(
                onScan: { raw in
                    if let parsed = PairingPayload.parse(raw) {
                        let fields = fieldsAfterScan(parsed, existing: currentFields)
                        host = fields.host
                        port = fields.port
                        token = fields.token
                        sentinelHost = fields.sentinelHost
                        sentinelPort = fields.sentinelPort
                        sentinelToken = fields.sentinelToken
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
