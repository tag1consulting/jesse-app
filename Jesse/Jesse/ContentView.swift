import SwiftUI

struct ContentView: View {
    @State private var mode: JesseMode = .ask
    @State private var input = ""
    @State private var response = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var showSettings = false
    @State private var config = ConfigStore.load()

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
                    Button(action: { startSend() }) {
                        HStack {
                            if busy { ProgressView().padding(.trailing, 4) }
                            Text(busy ? "Thinking…"
                                      : (continueThread ? "Follow up" : mode.label))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)

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
                    Text(response)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                Spacer()
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

    private func startSend(voice: Bool = false) {
        inputFocused = false
        errorText = nil
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
            busy = false
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
        }
    }
}

#Preview {
    ContentView()
}
