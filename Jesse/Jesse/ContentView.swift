import SwiftUI

struct ContentView: View {
    @State private var mode: JesseMode = .ask
    @State private var input = ""
    @State private var response = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var showSettings = false
    @State private var config = ConfigStore.load()

    // Thinking indicator: the send button fills left→right over 10s; once past
    // 10s a live seconds counter is appended. Both are derived each frame from
    // `startDate` via a TimelineView, so they're immune to the layout shift the
    // Cancel button causes on the first send. `startDate` is nil while idle.
    @State private var startDate: Date?

    // Thread continuity. `sessionId` is the last thread we can resume;
    // `continueThread` decides whether the next send resumes it or starts fresh.
    @State private var sessionId: String?
    @State private var continueThread = false

    @FocusState private var inputFocused: Bool

    // Voice hand-off from Siri + a handle on the in-flight run so Cancel can abort it.
    @StateObject private var inbox = JesseInbox.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Mode", selection: $mode) {
                    ForEach(JesseMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                TextField(mode == .ask ? "Ask Jesse anything…"
                                       : "Tell Jesse something…",
                          text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .focused($inputFocused)

                // Appears only once there's a thread to continue.
                if sessionId != nil {
                    Toggle("Continue thread", isOn: $continueThread)
                        .font(.callout)
                }

                HStack {
                    // Own the layers so the left→right fill sweeps behind the
                    // white label with a deterministic z-order: accent base,
                    // a darker overlay whose width tracks elapsed time (only
                    // while busy), then the spinner + label on top in white.
                    //
                    // The fill is driven by a continuous clock — not a
                    // `withAnimation` width tween — so it survives the layout
                    // shift the Cancel button introduces on the first send.
                    // TimelineView ticks every frame while busy and pauses idle;
                    // each tick recomputes the fill against *live* geometry.
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !busy)) { context in
                        let elapsed = (busy ? startDate.map { context.date.timeIntervalSince($0) } : nil) ?? 0
                        let secs = Int(elapsed)
                        Button(action: { startSend() }) {
                            HStack {
                                if busy { ProgressView().tint(.white) }
                                Text(busy ? (secs > 10 ? "Thinking… \(secs)" : "Thinking…")
                                          : (continueThread ? "Follow up" : mode.label))
                                    .foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(alignment: .leading) {
                                ZStack(alignment: .leading) {
                                    Color.accentColor
                                    GeometryReader { geo in
                                        Rectangle()
                                            .fill(Color.black.opacity(0.18))
                                            .frame(width: geo.size.width * min(elapsed / 10, 1))
                                            .opacity(busy ? 1 : 0)
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(sendDisabled)
                        .opacity(dimmed ? 0.5 : 1)
                    }

                    if busy {
                        Button("Cancel") { sendTask?.cancel() }
                            .buttonStyle(.bordered)
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ScrollView {
                    MarkdownText(response)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle("Jesse")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(config: $config)
            }
            .onAppear { inbox.drain() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { inbox.drain() }
            }
            .onChange(of: inbox.pending) { _, req in
                guard let req else { return }
                inbox.pending = nil
                mode = req.mode
                input = req.text
                continueThread = false
                startSend(voice: true)
            }
        }
    }

    // Disabled while a run is in flight or there's nothing to send.
    private var sendDisabled: Bool {
        busy || input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Dim only the truly-inactive (empty-input) state. While busy we keep full
    // opacity so the fill sweep and white label stay crisp and readable.
    private var dimmed: Bool {
        !busy && input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func startSend(voice: Bool = false) {
        inputFocused = false
        errorText = nil
        // Stamp the clock the timeline reads, then go busy — the fill and
        // counter both derive from this instant.
        startDate = Date()
        busy = true
        let text = input
        let resume = continueThread ? sessionId : nil
        sendTask = Task {
            do {
                let reply = try await JesseClient(config: config)
                    .send(mode: mode, text: text, sessionId: resume, voice: voice)
                response = reply.displayText
                sessionId = reply.sessionId ?? sessionId
                input = ""
                // Auto-arm follow-up when Jesse asks a question back.
                continueThread = reply.displayText.hasSuffix("?")
                if voice { Speaker.shared.speak(reply.spokenText) }
            } catch is CancellationError {
                // user cancelled — no error banner
            } catch {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                    // URLSession-level cancel, also silent
                } else {
                    errorText = error.localizedDescription
                    if voice {
                        Speaker.shared.speak("Sorry, that didn't work. " + error.localizedDescription)
                    }
                }
            }
            // Reset on every exit — success, error, and cancel. Clearing
            // `startDate` pauses the timeline and the sweep vanishes with `busy`.
            busy = false
            startDate = nil
            sendTask = nil
        }
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
