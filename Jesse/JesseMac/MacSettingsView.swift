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

    // The global model switch (bridge 0.27.0), mirroring the iPhone's Settings switcher. The
    // bridge is the source of truth, so both devices converge on one active model.
    @State private var modelState: ModelSwitchState?
    @State private var loadingModels = false
    @State private var switchingModel = false
    @State private var modelsError: String?

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

    /// The global model switch section: the selectable models, the active one checked, an
    /// unavailable model disabled with a "pending" note. Mirrors the iPhone's switcher.
    @ViewBuilder
    private var modelSwitchSection: some View {
        Section {
            if let modelState {
                ForEach(modelState.models) { model in
                    Button {
                        selectModel(model)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.label)
                                    .foregroundStyle(model.available ? .primary : .secondary)
                                if !model.available {
                                    Text("pending — not yet available")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if !model.isDefault && !model.writesAllowed {
                                    Text("read-only")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model.id == modelState.active {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.available || switchingModel)
                }
            } else if loadingModels {
                HStack { ProgressView().controlSize(.small); Text("Loading models…").foregroundStyle(.secondary) }
            }
            if let modelsError {
                Text(modelsError).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Chooses which model answers your conversations. The background helpers (titles, diet, vault lookups) are unaffected. A non-default model reads your vault but can't write it until you enable writes for it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await loadModels() }
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
            modelState = nil // older bridge → hide the section
        }
    }

    private func selectModel(_ model: ModelInfo) {
        guard model.available, model.id != modelState?.active else { return }
        Task {
            switchingModel = true
            defer { switchingModel = false }
            do {
                try await modelClient().setActiveModel(model.id)
                modelsError = nil
            } catch {
                let detail = (error as? JesseError)?.errorDescription ?? error.localizedDescription
                modelsError = "Couldn’t switch model. (\(detail))"
            }
            await loadModels()
        }
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
