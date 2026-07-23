import SwiftUI
import JesseNetworking

// Bridge connection settings. MVP pairing is the manual field (host + token) the plan
// puts first; a paste-able `jesse://pair?...` link and camera QR are later polish. The
// host field accepts whatever gets pasted (full URL, host:port, bare host) — it's
// sanitized on save.

struct MacSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let configStore: MacConfigStore

    @State private var host: String = ""
    @State private var port: String = ""
    @State private var token: String = ""
    @State private var pasteLink: String = ""

    // Master switch for the on-device query-expansion tier (Tier 2), matching the
    // iPhone's Settings toggle. Same key and default (ON). Off -> sidebar search is
    // pure Tier-1 token matching with no on-device model calls.
    @AppStorage("searchExpansionEnabled") private var searchExpansionEnabled = true

    // Per-turn model selection (retire the global switch): the selectable models, used here
    // ONLY to choose THIS Mac's default model for NEW conversations (`LastUsedModelStore`) —
    // never the bridge's global default, so the phone is unaffected. `deviceDefaultID` mirrors
    // the per-device default so the checkmark updates live.
    @State private var modelState: ModelSwitchState?
    @State private var deviceDefaultID: String? = LastUsedModelStore.id
    @State private var loadingModels = false
    @State private var switchingModel = false
    @State private var modelsError: String?
    // Phase 2: the model awaiting write-enable confirmation (granting writes is gated).
    @State private var pendingWriteModel: ModelInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bridge Connection").font(.title2.weight(.semibold)).padding()
            Divider()
            Form {
                Section {
                    TextField("Host", text: $host, prompt: Text("studio.tailnet.ts.net or 100.x.y.z"))
                    TextField("Port", text: $port, prompt: Text("\(JesseConfig.defaultPort)"))
                    SecureField("Bearer token", text: $token)
                } header: {
                    Text("Manual")
                } footer: {
                    Text("The bridge runs on the Studio over your tailnet. Paste the host and the shared bearer token.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        TextField("jesse://pair?url=…&token=…", text: $pasteLink)
                        Button("Apply") { applyPairLink() }
                            .disabled(pasteLink.isEmpty)
                    }
                } header: {
                    Text("Pairing link")
                } footer: {
                    Text("Paste a jesse://pair link to fill the fields above.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Smart search (on-device)", isOn: $searchExpansionEnabled)
                } header: {
                    Text("Search")
                } footer: {
                    Text("Widens sidebar search with related terms suggested by the on-device model. Everything stays on this Mac; turn it off to match only what you type.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                modelSwitchSection
                writeAccessSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                        || token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
        .onAppear {
            host = configStore.config.host
            port = configStore.config.port == JesseConfig.defaultPort ? "" : String(configStore.config.port)
            token = configStore.config.token
        }
    }

    /// The per-device DEFAULT-model section: the selectable models, this Mac's default checked.
    /// Selecting a model sets THIS Mac's default for NEW conversations only
    /// (`LastUsedModelStore`) — it never changes the bridge's global default and never touches
    /// an existing conversation (each thread keeps its own choice, changed from the thread's own
    /// picker). An unavailable model is disabled with a short reason — "not configured" or
    /// "unreachable" — and the list polls on a light interval while Settings is open so a health
    /// change shows live.
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
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if !model.isDefault && !model.writesAllowed {
                                    Text("read-only")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model.id == resolvedDefaultID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.available)
                }
            } else if loadingModels {
                HStack { ProgressView().controlSize(.small); Text("Loading models…").foregroundStyle(.secondary) }
            }
            if let modelsError {
                Text(modelsError).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Default model for new conversations")
        } footer: {
            Text("Sets which model NEW conversations on this Mac start on. Each conversation keeps its own choice — change it from the picker inside a conversation — and this is per device, so your Mac and phone can differ. The background helpers (titles, diet, vault lookups) are unaffected. A non-default model reads your vault but can't write it until you enable writes for it. A model that is unreachable or not yet configured is shown disabled.")
                .font(.caption).foregroundStyle(.secondary)
        }
        // Poll on appear and every `modelPollInterval` while Settings is open; SwiftUI cancels
        // this `.task` when the sheet closes, so polling backs off then (never a tight loop).
        .task { await pollModelsWhileVisible() }
    }

    /// The health poll cadence while Settings is open — long enough to never be a tight loop.
    private static let modelPollInterval: Duration = .seconds(25)

    /// Fetch on appear, then re-fetch every `modelPollInterval` for as long as this view's
    /// `.task` lives. Skips a poll mid-swap so a background refresh can't clobber an in-flight
    /// selection.
    private func pollModelsWhileVisible() async {
        while !Task.isCancelled {
            if !switchingModel { await loadModels() }
            try? await Task.sleep(for: Self.modelPollInterval)
        }
    }

    /// Phase 2: per-model write access, gated behind a confirmation. Mirrors the iPhone.
    @ViewBuilder
    private var writeAccessSection: some View {
        if let modelState, modelState.models.contains(where: { $0.available && !$0.isDefault }) {
            Section {
                ForEach(modelState.models.filter { $0.available && !$0.isDefault }) { model in
                    Toggle(isOn: writeBinding(for: model)) {
                        Text("Allow \(model.label) to write the vault")
                    }
                    .disabled(switchingModel)
                }
            } header: {
                Text("Write access")
            } footer: {
                Text("Off by default, every non-default model can read your vault but not change it. Turn this on only for a model you trust to edit files; the reply badge marks a writing model (e.g. “glm-5.2 · write”).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("Allow writes?", isPresented: writeConfirmPresented) {
                Button("Cancel", role: .cancel) { pendingWriteModel = nil }
                Button("Allow writes", role: .destructive) {
                    if let model = pendingWriteModel { setWrites(model, enabled: true) }
                    pendingWriteModel = nil
                }
            } message: {
                Text("\(pendingWriteModel?.label ?? "This model") will be able to modify files in your vault when it backs a conversation. You can turn this off at any time.")
            }
        }
    }

    private func writeBinding(for model: ModelInfo) -> Binding<Bool> {
        Binding(
            get: { modelState?.models.first { $0.id == model.id }?.writesAllowed ?? false },
            set: { newValue in
                if newValue { pendingWriteModel = model } else { setWrites(model, enabled: false) }
            }
        )
    }

    private var writeConfirmPresented: Binding<Bool> {
        Binding(get: { pendingWriteModel != nil }, set: { if !$0 { pendingWriteModel = nil } })
    }

    private func setWrites(_ model: ModelInfo, enabled: Bool) {
        Task {
            switchingModel = true
            defer { switchingModel = false }
            do {
                try await modelClient().setWrites(id: model.id, enabled: enabled)
                modelsError = nil
            } catch {
                let detail = (error as? JesseError)?.errorDescription ?? error.localizedDescription
                modelsError = "Couldn’t change write access. (\(detail))"
            }
            await loadModels()
        }
    }

    /// A bridge client over the entered fields (or the saved config), for the switch calls.
    private func modelClient() -> JesseBridgeClient {
        let cfg = JesseConfig(host: host.isEmpty ? configStore.config.host : host,
                              port: Int(port) ?? configStore.config.port,
                              token: token.isEmpty ? configStore.config.token : token)
        return JesseBridgeClient(config: cfg)
    }

    private func loadModels() async {
        guard modelClient().config.isConfigured else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            modelState = try await modelClient().fetchModels()
            modelsError = nil
        } catch {
            // Leave `modelState` as-is: never loaded (older bridge 404s) → stays nil and the
            // section stays hidden; already loaded → KEEP the last-known list so a transient
            // blip during interval polling doesn't blank a working switcher.
        }
    }

    /// This Mac's default shown checked: its stored default when still selectable, else the
    /// ambient `opus` (the effective default a new conversation gets).
    private var resolvedDefaultID: String? {
        modelState?.resolvedModel(threadModelID: nil, deviceDefaultID: deviceDefaultID)?.id
    }

    /// Make `model` this Mac's default for NEW conversations (`LastUsedModelStore`). Purely
    /// local — no bridge write — so the phone and every existing conversation are unaffected.
    private func selectDefaultModel(_ model: ModelInfo) {
        guard model.available else { return }
        LastUsedModelStore.id = model.id
        deviceDefaultID = model.id
        modelsError = nil
    }

    private func save() {
        configStore.save(host: host, port: Int(port), token: token)
        dismiss()
    }

    /// Fill the fields from a `jesse://pair?url=host:port&token=…` link.
    private func applyPairLink() {
        guard let parsed = MacPairLink.parse(pasteLink) else { return }
        let (h, p) = JesseConfig.sanitize(parsed.host)
        host = h
        if let port = p ?? parsed.port { self.port = String(port) }
        token = parsed.token
        pasteLink = ""
    }
}

/// Parser for a `jesse://pair?url=<host[:port]>&token=<token>` pairing link.
nonisolated enum MacPairLink {
    static func parse(_ raw: String) -> (host: String, port: Int?, token: String)? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme == "jesse", comps.host == "pair" else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let urlValue = value("url") ?? value("host"),
              let token = value("token"), !token.isEmpty else { return nil }
        let (host, port) = JesseConfig.sanitize(urlValue)
        return (host, port, token)
    }
}
