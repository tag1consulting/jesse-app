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
        .navigationSubtitle(subtitle)
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

    /// The window subtitle. This used to read "Not yet started" off `sessionId == nil`, which
    /// conflated two different things: a brand-new conversation and one whose first turn the
    /// bridge has already accepted but whose CLI session id has not come back yet. The phase
    /// caption below the transcript now carries the delivery state, so the subtitle is only
    /// about whether the thread has ever run.
    private var subtitle: String {
        thread.registeredAt == nil && (thread.sessionId ?? "").isEmpty ? "Not yet started" : ""
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(thread.orderedTurns) { turn in
                        MacTurnBubble(turn: turn)
                            .id(turn.id)
                    }
                    // Delivery caption under the last user bubble, the Mac's counterpart to the
                    // phone's: "Sending…" is the pre-ACK window, "Received" means the bridge has
                    // the turn and will answer it even if this window closes.
                    if let phase = coordinator.phase(thread.id),
                       thread.orderedTurns.last?.isUser == true {
                        MacDeliveryCaption(phase: phase)
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

                // An AppKit-backed text view, not a SwiftUI TextField. A `TextField` reports
                // Return through `.onSubmit`, which is handed no modifier state, so "Return
                // sends, Return with a modifier makes a newline" cannot be written there at
                // all. `ComposerTextView` decides in `keyDown(with:)`, where the modifiers
                // still exist. Send remains gated by `send()` below, the same guard the send
                // button's `disabled` state mirrors.
                ComposerTextView(text: $draft, placeholder: "Message Jesse…", onSend: send)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                // No `.keyboardShortcut(.return, modifiers: .command)` here any more: Command
                // plus Return is one of the newline combinations now, and a button shortcut
                // would win the key before the focused composer ever saw it.
            }
        }
        .padding(12)
    }

    /// An empty composer is normally not a turn — except on a thread a screen OPENED
    /// with context attached (the Today tab's Discuss). There, sending nothing is the
    /// explicit "just look at it", and the attached item is what the turn carries. The
    /// coordinator composes and re-checks either way; this only decides whether the
    /// button is live.
    private var canSend: Bool {
        coordinator.configStore.isConfigured && !running
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || coordinator.attachedContext(for: thread.id) != nil)
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

    /// Populate the shared list with ONE bounded, backed-off burst (`loadModelList`, the same
    /// policy the iPhone uses), so a slow or briefly-unreachable bridge still fills in without
    /// user action but a bridge that cannot answer no longer leaves a standing 3-second poll
    /// running for as long as the conversation is open. The button already shows the resolved
    /// model meanwhile; a persistent failure just leaves it non-expandable.
    private func loadWithRetry() async {
        _ = await loadModelList(
            isConfigured: config.isConfigured,
            fetch: {
                await store.loadIfNeeded(config: config)
                return store.state
            },
            sleep: { try? await Task.sleep(for: .seconds($0)) })
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
                    // Files JESSE returned on this turn. Nothing renders for the
                    // overwhelming majority of turns. Mirrors iOS.
                    if !turn.artifacts.isEmpty {
                        MacTurnArtifactsView(artifacts: turn.orderedArtifacts)
                    }
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
    /// Already a human line with its own ellipsis (`ToolActivity.displayLabel`), so
    /// nothing here appends punctuation to it.
    let activity: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle").font(.callout).foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                if text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(activity.isEmpty ? "Thinking…" : activity)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    MacMarkdownView(text: text)
                    if !activity.isEmpty {
                        Text(activity).font(.caption2).foregroundStyle(.secondary)
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

/// The trailing delivery caption under the last user bubble. Standard macOS treatment: a
/// `.caption`/`.secondary` line, trailing aligned, no new symbol and no tint. The
/// accessibility label carries the meaning the two words cannot.
private struct MacDeliveryCaption: View {
    let phase: TurnPhase

    private var text: String {
        switch phase {
        case .sending: return "Sending…"
        case .accepted: return "Received"
        }
    }

    private var label: String {
        switch phase {
        case .sending:
            return "Sending"
        case .accepted:
            return "Received by Jesse. Your message is saved and will be answered even if you close this window."
        }
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(label)
        }
        .padding(.trailing, 4)
        .padding(.top, 2)
        .animation(.default, value: phase)
    }
}
