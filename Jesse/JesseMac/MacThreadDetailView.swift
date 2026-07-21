import SwiftUI
import SwiftData
import JesseCore

// One conversation: the transcript (hydrated from the bridge on open, cache-first) plus
// the live streaming reply and the composer. Resume is implicit — the thread carries a
// `session_id`, and sending continues that same Claude Code session on the Studio.

struct MacThreadDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(MacCoordinator.self) private var coordinator

    @Bindable var thread: JesseThread

    @State private var draft: String = ""
    @State private var mode: JesseMode = .ask

    private var running: Bool { coordinator.isRunning(thread.id) }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .navigationTitle(displayTitle)
        .navigationSubtitle(thread.sessionId == nil ? "Not yet started" : "")
        .onAppear { mode = thread.modeValue }
        .task(id: thread.id) {
            await coordinator.hydrate(thread: thread, context: context)
        }
    }

    private var displayTitle: String {
        if let ai = thread.aiTitle, !ai.isEmpty { return ai }
        if !thread.title.isEmpty { return thread.title }
        return "New conversation"
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(thread.orderedTurns) { turn in
                        MacTurnBubble(turn: turn)
                            .id(turn.id)
                    }
                    if running {
                        MacStreamingBubble(text: coordinator.streamingText, activity: coordinator.activity)
                            .id(Self.streamAnchor)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: thread.orderedTurns.count) { scrollToBottom(proxy) }
            .onChange(of: coordinator.streamingText) { scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    private static let bottomAnchor = "bottom"
    private static let streamAnchor = "stream"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let error = coordinator.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Picker("", selection: $mode) {
                    ForEach(JesseMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
                .disabled(running)

                TextField("Message Jesse…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
        }
        .padding(12)
    }

    private var canSend: Bool {
        coordinator.configStore.isConfigured && !running
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task { await coordinator.send(text: text, mode: mode, thread: thread, context: context) }
    }
}

/// A persisted turn — a user message (right, tinted) or a Jesse reply (left, rendered
/// Markdown).
struct MacTurnBubble: View {
    let turn: Turn

    var body: some View {
        if turn.isUser {
            HStack {
                Spacer(minLength: 60)
                Text(turn.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.tint.opacity(0.85), in: .rect(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                jesseGlyph
                MacMarkdownView(text: turn.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 40)
            }
        }
    }

    private var jesseGlyph: some View {
        Image(systemName: "sparkle")
            .font(.callout)
            .foregroundStyle(.tint)
            .padding(.top, 2)
    }
}

/// The in-flight assistant reply while a turn streams.
struct MacStreamingBubble: View {
    let text: String
    let activity: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle").font(.callout).foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                if text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(activity.isEmpty ? "Thinking…" : "\(activity)…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    MacMarkdownView(text: text)
                    if !activity.isEmpty {
                        Text("\(activity)…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 40)
        }
    }
}
