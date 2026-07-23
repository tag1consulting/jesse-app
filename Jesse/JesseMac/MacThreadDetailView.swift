import SwiftUI
import SwiftData
import JesseCore
import JesseNetworking

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

                // The PER-CONVERSATION model this thread sends its next turn on. Local to this
                // Mac and this thread — never the bridge's global default, so the phone is
                // unaffected. Always present: it shows the model the next turn will use even
                // before (or without) the model list loading.
                MacModelPickerMenu(thread: thread,
                                   store: coordinator.modelList,
                                   config: coordinator.configStore.config)
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

/// The PER-CONVERSATION model picker for the Mac composer. The selection is LOCAL — stored on
/// the thread (`selectedModelID`) and per device — so it never mutates the bridge's global
/// default and never affects another conversation or the phone. On a pick it writes the thread's
/// selection and updates this Mac's last-used default.
///
/// The control is ALWAYS present. The button shows the model the next turn will run on (the
/// thread's own choice, else this Mac's default, else the ambient `opus`) drawn from the shared
/// `MacModelListStore` — even before the list loads, and even if it never does (an older bridge
/// with no `/jesse/models` route, or a persistent failure): the button then simply shows the
/// resolved model and is not expandable, rather than the whole control vanishing. The list is
/// loaded once into the shared store and retried on failure.
private struct MacModelPickerMenu: View {
    @Environment(\.modelContext) private var context
    @Bindable var thread: JesseThread
    let store: MacModelListStore
    let config: JesseConfig

    var body: some View {
        Group {
            if let modelState = store.state {
                Menu {
                    ForEach(modelState.offered) { model in
                        Button {
                            select(model)
                        } label: {
                            if model.id == selectedID {
                                Label(model.label, systemImage: "checkmark")
                            } else {
                                Text(model.menuRowLabel)
                            }
                        }
                        .disabled(!model.available)
                    }
                } label: {
                    buttonLabel
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                // The list has not loaded yet (slow / older bridge / transient failure). Show the
                // resolved model, non-expandable, so the control is present and truthful about
                // the next turn's model — never invisible.
                buttonLabel
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("The model this conversation will use. The full list is still loading.")
            }
        }
        .task { await loadWithRetry() }
    }

    private var buttonLabel: some View { Label(currentLabel, systemImage: "cpu") }

    /// The resolved model's id (for the checkmark), meaningful only once the list has loaded.
    private var selectedID: String? {
        store.state?.resolvedModel(threadModelID: thread.selectedModelID,
                                   deviceDefaultID: LastUsedModelStore.id)?.id
    }
    /// The button label, resolvable even before the list loads (falls back to the resolved id).
    private var currentLabel: String {
        ModelSelectionResolver.resolvedLabel(state: store.state,
                                             threadModelID: thread.selectedModelID,
                                             deviceDefaultID: LastUsedModelStore.id)
    }

    /// Populate the shared list, retrying on failure so a slow or briefly-unreachable bridge
    /// fills in without user action. The button already shows the resolved model meanwhile; a
    /// persistent failure just leaves it non-expandable. Stops when the list loads or the view
    /// goes away.
    private func loadWithRetry() async {
        while !Task.isCancelled && store.state == nil {
            await store.loadIfNeeded(config: config)
            if store.state != nil { break }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Pick a model for THIS conversation: store it on the thread and make it this Mac's
    /// default for the next new conversation. No bridge write — the phone is unaffected.
    private func select(_ model: ModelInfo) {
        guard model.available, model.id != thread.selectedModelID else { return }
        thread.selectedModelID = model.id
        LastUsedModelStore.id = model.id
        try? context.save()
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
                VStack(alignment: .leading, spacing: 4) {
                    MacMarkdownView(text: turn.text)
                    // Native provenance chip under a Jesse reply that carried structured
                    // provenance (the badge text is already stripped from `turn.text` when
                    // the reply was ingested). Absent for older / badges-off replies —
                    // nothing renders there and the text shows verbatim. Mirrors iOS.
                    if let provenance = JesseProvenance.from(json: turn.provenanceJSON) {
                        ProvenanceChip(provenance: provenance)
                    }
                }
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

/// A subtle capsule rendered under a Jesse message when structured provenance is present.
/// Distinct tint for local vs hosted vs emergency, and a warning state for unverified
/// citations. This is the macOS-native sibling of the iOS `ProvenanceChip`: both are pure
/// renderings of the SAME shared `JesseProvenance` presentation helpers (chipTitle /
/// costLabel / iconName / routeKind / accessibilityText live in JesseNetworking), so the
/// two chips carry byte-identical content and can never drift on what they show — only the
/// ~30 lines of SwiftUI live per platform, because there is no shared SwiftUI module the
/// two app targets both compile (JesseNetworking is view-free by design).
struct ProvenanceChip: View {
    let provenance: JesseProvenance

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: provenance.iconName)
                .font(.caption2)
            Text(provenance.chipTitle)
                .font(.caption2.weight(.medium))
            if let cost = provenance.costLabel {
                Text(cost)
                    .font(.caption2)
                    .foregroundStyle(tint.opacity(0.75))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provenance.accessibilityText)
    }

    private var tint: Color {
        switch provenance.routeKind {
        case .hosted: return .secondary
        case .local: return .teal
        case .emergency: return .orange
        case .warning: return .red
        }
    }
}
