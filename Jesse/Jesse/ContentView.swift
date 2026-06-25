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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.resume(context: context)
                inbox.drain()
            }
        }
        .onChange(of: inbox.pending) { _, req in
            guard let req else { return }
            inbox.pending = nil
            startVoiceThread(req)
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

struct SettingsView: View {
    @Binding var config: JesseConfig
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = ""
    @State private var token = ""

    @State private var showScanner = false
    @State private var scanError: String?

    // Per-mode prompt editors. `*Prompt` is the editable text; `*Default` mirrors
    // the cached bridge default (for the differs-from-default check and Reset).
    @State private var askPrompt = ""
    @State private var tellPrompt = ""
    @State private var askDefault = ""
    @State private var tellDefault = ""
    // The fixed safety floors the bridge always prepends, shown read-only. These
    // are display-only and never feed the editors or the override that's sent.
    @State private var askFloor = ""
    @State private var tellFloor = ""
    @State private var promptsError: String?
    @State private var loadingPrompts = false

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
                    fixedFloorView(askFloor)
                    TextEditor(text: $askPrompt)
                        .frame(minHeight: 120)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Reset to default") { resetToDefault(.ask) }
                        .disabled(loadingPrompts)
                } header: {
                    Text("Ask Jesse prompt")
                } footer: {
                    // The invariant lives in the locked floor above; the editor
                    // only customizes the framing that follows it.
                    Text("The locked text above is always applied and can’t be removed: “Ask” means Jesse won’t take actions you didn’t request, but he always records a durable fact, correction, or status change to the vault. Your editor only customizes the framing after it. Leave empty to use the bridge default.")
                }

                Section {
                    fixedFloorView(tellFloor)
                    TextEditor(text: $tellPrompt)
                        .frame(minHeight: 120)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Reset to default") { resetToDefault(.tell) }
                        .disabled(loadingPrompts)
                } header: {
                    Text("Tell Jesse prompt")
                } footer: {
                    Text("The locked text above is always applied and can’t be removed: Jesse always records durable facts to the vault. Your editor only customizes how a “Tell” is framed after it. Leave empty to use the bridge default.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        config = JesseConfig(host: host,
                                             port: Int(port) ?? 8765,
                                             token: token)
                        ConfigStore.save(config)
                        // Persist the prompt editors. `save` re-derives each
                        // mode's customized flag (non-empty AND differs from the
                        // cached default); an empty field stays "use the default".
                        PromptStore.save(.ask, text: askPrompt, default: askDefault)
                        PromptStore.save(.tell, text: tellPrompt, default: tellDefault)
                        dismiss()
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
                askPrompt = PromptStore.text(.ask)
                tellPrompt = PromptStore.text(.tell)
                askDefault = PromptStore.cachedDefault(.ask)
                tellDefault = PromptStore.cachedDefault(.tell)
                askFloor = PromptStore.floor(.ask)
                tellFloor = PromptStore.floor(.tell)
            }
            .sheet(isPresented: $showScanner) {
                scannerSheet
            }
        }
    }

    // MARK: - Prompt defaults

    /// Fetch the bridge's built-in wrapper defaults using the host/token the user
    /// has entered (not necessarily saved yet), so pairing + loading defaults can
    /// happen in one visit. Returns nil and sets `promptsError` on any failure.
    /// On success it also refreshes the read-only floor cards (and their cache),
    /// since the fixed floors ride along on the same response.
    private func fetchDefaults() async -> PromptDefaults? {
        loadingPrompts = true
        defer { loadingPrompts = false }
        promptsError = nil
        let cfg = JesseConfig(host: host, port: Int(port) ?? 8765, token: token)
        do {
            let d = try await JesseClient(config: cfg).fetchPrompts()
            // Floors are display-only: update the cards and cache, never the editors.
            askFloor = d.askFloor
            tellFloor = d.tellFloor
            PromptStore.cacheFloor(.ask, d.askFloor)
            PromptStore.cacheFloor(.tell, d.tellFloor)
            return d
        } catch {
            let detail = (error as? JesseError)?.errorDescription ?? error.localizedDescription
            promptsError = "Couldn’t load defaults — connect to the bridge first. (\(detail))"
            return nil
        }
    }

    /// A read-only card showing a mode's fixed safety floor — the clause the
    /// bridge always prepends and a custom wrapper can't remove. Empty until a
    /// fetch populates it, in which case it nudges the user to load defaults.
    @ViewBuilder
    private func fixedFloorView(_ floor: String) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.08))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Always applied — can’t be edited", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if floor.isEmpty {
                        Text("Load defaults from the bridge to see the fixed safety text.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(floor)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Reset to default" for one mode: overwrite that editor with the freshly
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

    /// "Load defaults from bridge": cache both defaults and fill the editors.
    /// With `fillEmptyOnly`, only blank editors are populated so a custom prompt
    /// is never clobbered — the first-use affordance for empty editors.
    private func loadDefaults(fillEmptyOnly: Bool) {
        Task {
            guard let d = await fetchDefaults() else { return }
            askDefault = d.ask
            tellDefault = d.tell
            if !fillEmptyOnly || askPrompt.isEmpty { askPrompt = d.ask }
            if !fillEmptyOnly || tellPrompt.isEmpty { tellPrompt = d.tell }
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
