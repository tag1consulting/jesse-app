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
                    // The invariant: "Ask" forbids unrequested action, never writing.
                    Text("“Ask” means Jesse won’t take actions you didn’t request — but it never stops him from recording a durable fact, correction, or status change to the vault. Leave empty to use the bridge default.")
                }

                Section {
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
                    Text("How a “Tell” is framed for Jesse to capture or act on. Leave empty to use the bridge default.")
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
    private func fetchDefaults() async -> (ask: String, tell: String)? {
        loadingPrompts = true
        defer { loadingPrompts = false }
        promptsError = nil
        let cfg = JesseConfig(host: host, port: Int(port) ?? 8765, token: token)
        do {
            return try await JesseClient(config: cfg).fetchPrompts()
        } catch {
            let detail = (error as? JesseError)?.errorDescription ?? error.localizedDescription
            promptsError = "Couldn’t load defaults — connect to the bridge first. (\(detail))"
            return nil
        }
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
