import SwiftUI
import SwiftData

// One conversation: the full turn transcript with the composer pinned at the
// bottom. Being inside a thread *is* continuing it — every send auto-resumes the
// thread's session, so there's no "Continue thread" toggle anymore.
struct ThreadDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(RunCoordinator.self) private var coordinator
    @Bindable var thread: JesseThread

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var running: Bool { coordinator.isRunning(thread.id) }
    private var turns: [Turn] { thread.orderedTurns }

    var body: some View {
        VStack(spacing: 12) {
            transcript
            composer
        }
        .padding()
        .navigationTitle(thread.title.isEmpty ? "New conversation" : thread.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if turns.isEmpty && !running {
                        Text(thread.modeValue == .ask
                             ? "Ask Jesse anything about the vault."
                             : "Tell Jesse something to capture.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(turns) { turn in
                        TurnRow(turn: turn)
                            .id(turn.id)
                    }
                    if running {
                        ThinkingRow(startDate: coordinator.startDate(for: thread.id))
                            .id(Self.bottomAnchor)
                    }
                    if let error = coordinator.error(for: thread.id) {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(Self.bottomAnchor)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: turns.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: running) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    private static let bottomAnchor = "jesse.transcript.bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !turns.isEmpty || running else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 10) {
            // Mode is fixed once the thread has turns — hide the control then.
            if turns.isEmpty {
                Picker("Mode", selection: Binding(
                    get: { thread.modeValue },
                    set: { thread.mode = $0.rawValue }
                )) {
                    ForEach(JesseMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .disabled(running)
            }

            TextField(thread.modeValue == .ask ? "Ask Jesse anything…"
                                                : "Tell Jesse something…",
                      text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($inputFocused)

            HStack {
                SendButton(
                    running: running,
                    startDate: coordinator.startDate(for: thread.id),
                    title: turns.isEmpty ? thread.modeValue.label : "Follow up",
                    disabled: sendDisabled,
                    action: send
                )
                if running {
                    Button("Cancel") { coordinator.cancel(thread.id) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var sendDisabled: Bool {
        running || input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func send() {
        inputFocused = false
        let text = input
        input = ""
        coordinator.clearError(for: thread.id)
        coordinator.send(thread: thread, text: text, voice: false, context: context)
    }
}

// MARK: - Pieces

/// One message bubble. User turns sit right with a tinted fill; Jesse's replies
/// render as Markdown on the left.
private struct TurnRow: View {
    let turn: Turn

    var body: some View {
        if turn.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .frame(alignment: .trailing)
            }
        } else {
            MarkdownText(turn.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Live "Thinking…" row — appends a seconds counter past 10s, mirroring the send
/// button's behavior.
private struct ThinkingRow: View {
    let startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let secs = startDate.map { Int(context.date.timeIntervalSince($0)) } ?? 0
            HStack(spacing: 8) {
                ProgressView()
                Text(secs > 10 ? "Thinking… \(secs)" : "Thinking…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The send button with the left→right fill sweep, driven by a continuous clock
/// (not a width tween) so it survives the layout shift the Cancel button causes.
struct SendButton: View {
    let running: Bool
    let startDate: Date?
    let title: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { context in
            let elapsed = (running ? startDate.map { context.date.timeIntervalSince($0) } : nil) ?? 0
            let secs = Int(elapsed)
            Button(action: action) {
                HStack {
                    if running { ProgressView().tint(.white) }
                    Text(running ? (secs > 10 ? "Thinking… \(secs)" : "Thinking…") : title)
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
                                .opacity(running ? 1 : 0)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled && !running ? 0.5 : 1)
        }
    }
}
