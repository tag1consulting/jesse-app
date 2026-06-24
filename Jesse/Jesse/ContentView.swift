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
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        config = JesseConfig(host: host,
                                             port: Int(port) ?? 8765,
                                             token: token)
                        ConfigStore.save(config)
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
            }
            .sheet(isPresented: $showScanner) {
                scannerSheet
            }
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
