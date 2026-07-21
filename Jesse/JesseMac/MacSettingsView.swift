import SwiftUI

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
