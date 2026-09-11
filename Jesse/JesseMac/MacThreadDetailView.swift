import SwiftUI
import AppKit
import SwiftData
import JesseCore
import JesseNetworking
import JesseConversations
import JesseSpeech
import UniformTypeIdentifiers

// One conversation: the transcript (hydrated from the bridge on open, cache-first) plus
// the live streaming reply and the composer. Resume is implicit — the thread carries a
// `session_id`, and sending continues that same Claude Code session on the Studio.

struct MacThreadDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(MacCoordinator.self) private var coordinator

    @Bindable var thread: JesseThread

    @State private var draft: String = ""
    @State private var mode: JesseMode = .ask

    /// Attaching a RECORDING, which on this platform means transcribing it: the Mac has
    /// no attachment pipeline (it never gained one — the phone's chips and caps are
    /// iOS-only), and it does not need one here: what lands in the draft is text.
    ///
    /// The same model, the same Studio-first transcriber and the same views as the iPhone;
    /// only the way a file is chosen differs. On the Studio itself the bridge is reached over
    /// loopback, anywhere else over the tailnet, exactly as every turn is; this Mac's own
    /// engine reads the recording only when the Studio cannot be reached, and says so. The
    /// pairing is read from the Keychain at each recording rather than captured here, so a
    /// re-pairing takes effect at the next one.
    @State private var recording = RecordingAttachment(
        transcriber: StudioFirstTranscriber(studio: URLSessionStudioTransport(endpoint: {
            let config = KeychainConfigStore(service: MacConfigStore.keychainService).load()
            return StudioEndpoint(baseURL: config.endpoint("/"), token: config.token)
        })))
    @State private var showAudioImporter = false

    // ── The DURABLE half of the composer ────────────────────────────────────────────
    //
    // `draft` above is view state, and this view carries `.id(thread.id)` in the split
    // view's detail column — so selecting another conversation destroys it, and quitting
    // takes it regardless.
    //
    // NOTHING REACTS TO TYPING here either: while this composer is on screen `draft` IS
    // the draft, and it is handed over at DEPARTURES through the same shared
    // `ComposerDrafts.capture` the phone uses. The only per-shell code is which hooks
    // count as a departure.

    /// Guards the restore so it happens once per composer; a second one would overwrite
    /// live typing with a stale value.
    @State private var didRestoreDraft = false
    /// What a restored draft lost, if anything (a recording mid-transcription, or the
    /// screen context the conversation was opened about). Nil almost always.
    @State private var draftNotice: String?

    @Environment(\.scenePhase) private var scenePhase

    private var running: Bool { coordinator.isRunning(thread.id) }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .navigationTitle(displayTitle(for: thread))
        .navigationSubtitle(subtitle)
        .onAppear {
            mode = thread.modeValue
            restoreDraft()
        }
        // ── THE DEPARTURES ────────────────────────────────────────────────────────────
        // Three of the four (the fourth is `send`): the detail column replacing this view
        // on `.id(thread.id)`, the app losing the foreground, and a quit. Cmd-Q with the
        // window frontmost may not change the scene phase at all, which is why
        // `willTerminate` is here in its own right and not as a belt to a brace.
        .onDisappear { captureDraft() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { captureDraft() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            captureDraft(terminating: true)
        }
        .task(id: thread.id) {
            await coordinator.hydrate(thread: thread, context: context)
        }
    }

    // MARK: - The durable draft

    /// Put the composer back the way the user left it. One call into the shared
    /// `ComposerDrafts.restore` — the already-sent check, the notice and the one-shot
    /// markers all live there, so this shell cannot grow its own idea of them. This Mac
    /// has no attachment pipeline, so `restored.files` is nothing to it.
    private func restoreDraft() {
        guard !didRestoreDraft else { return }
        didRestoreDraft = true
        let restored = ComposerDrafts.restore(
            for: thread, newestUserTurn: newestUserTurn,
            contextStillAttached: coordinator.attachedContext(for: thread.id) != nil)
        draft = restored.text
        draftNotice = restored.notice
    }

    /// The visible text and date of this conversation's newest user turn. `visibleText`
    /// because the turn's `text` may carry a screen context the composer never held.
    private var newestUserTurn: (text: String, createdAt: Date)? {
        guard let turn = thread.orderedTurns.last(where: { $0.isUser }) else { return nil }
        return (turn.visibleText, turn.createdAt)
    }

    /// What this composer is holding right now. The two situational markers are read HERE,
    /// at the departure, rather than tracked as they change.
    private var composerState: ComposerDraftCapture {
        ComposerDraftCapture(
            text: draft,
            pendingRecording: recording.isInFlight ? recording.sourceName : nil,
            contextLabel: coordinator.attachment(for: thread.id)?.contextLabel)
    }

    /// A DEPARTURE. Hand the composer over; the shared function does the rest, including
    /// putting a never-saved conversation on disk so the draft has somewhere to belong.
    ///
    /// `terminating` is the quit: there the write happens on this thread, because an
    /// asynchronous one may never get a turn before the process is gone.
    private func captureDraft(terminating: Bool = false) {
        guard didRestoreDraft else { return }
        ComposerDrafts.capture(composerState, for: thread, in: context,
                               terminating: terminating)
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

    /// The attachment a screen is holding against this conversation — its scope title
    /// and its starters as well as its body. Fully populated by the Health tab's "Ask
    /// about this"; body-only for the Today tab's Discuss, whose two extra affordances
    /// below then simply don't render.
    private var attachment: AttachedContext? { coordinator.attachment(for: thread.id) }

    private var composer: some View {
        VStack(spacing: 8) {
            // What a restored draft LOST, named. Not an error line: the text is right
            // there, and something that was part of the pending message simply is not
            // coming back with it. On a Section footer this would ellipsise (see the
            // Health tab's caveats), so it is a row of its own.
            if let draftNotice {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(draftNotice)
                    Spacer(minLength: 0)
                    Button {
                        self.draftNotice = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = coordinator.lastError ?? recording.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Read on this Mac because the Studio could not be reached: said out loud, beside
            // the draft it produced.
            if let notice = recording.notice {
                RecordingNoticeRow(notice: notice, onDismiss: { recording.dismissNotice() })
            }
            if case .running(let update) = recording.stage {
                RecordingProgressBar(update: update,
                                     sourceName: recording.sourceName,
                                     onCancel: { recording.cancel() })
            }
            // Says why the composer is empty and why Send works with nothing typed — and,
            // for an ask, NAMES the reading it is about, so "this" is never ambiguous. One
            // small caption, not a banner; the scope is also the window's title.
            if let attachment, thread.orderedTurns.isEmpty {
                Label(attachment.title.map { "Asking about \($0). Send an empty message to have Jesse just read it." }
                        ?? "This item is attached. Ask about it, or send an empty message to have Jesse just read it.",
                      systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Opening questions, in the EMPTY state only: gone the moment anything is
            // typed, one is clicked, or the conversation has a turn. Clicking one sends it
            // through the same `send` path as anything typed.
            if let starters = attachment?.starters, !starters.isEmpty,
               thread.orderedTurns.isEmpty, draft.isEmpty, !running {
                HStack(spacing: 8) {
                    ForEach(starters, id: \.self) { starter in
                        Button(starter) { draft = starter; send() }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                    Spacer(minLength: 0)
                }
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

                Button {
                    recording.dismissError()
                    showAudioImporter = true
                } label: {
                    Image(systemName: "waveform")
                }
                .buttonStyle(.plain)
                .help("Transcribe an audio recording into this message")
                .accessibilityLabel("Transcribe a recording")
                .disabled(running || recording.isBusy)

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
        .fileImporter(isPresented: $showAudioImporter,
                      allowedContentTypes: AudioRecordingTypes.contentTypes,
                      allowsMultipleSelection: false,
                      onCompletion: handleAudioImport)
        .sheet(isPresented: Binding(get: { recording.stage == .choosingLanguage },
                                    set: { if !$0 { recording.abandon() } })) {
            RecordingLanguageSheet(model: recording)
                .frame(minWidth: 380, minHeight: 420)
        }
        .onChange(of: recording.completed) { _, value in
            guard value != nil, let done = recording.takeCompleted() else { return }
            draft = done.messageBody(typed: draft)
        }
        // NO `onChange(of: draft)` and none for the recording stage. Typing changes this
        // view's own state and nothing else; what the composer holds is read off that
        // state at the next departure.
    }

    /// A picked recording. Transcribed on the Studio (on this Mac only when the Studio can't
    /// be reached), sent to the paired bridge and nowhere else, and the working copy is
    /// deleted however the run ends — the model owns all three.
    private func handleAudioImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await recording.begin(pickedFileAt: url)
        }
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

    /// THE COMPOSER IS CLEARED ONLY ON A DURABLE STAGE. `stageAndSend` persists the user
    /// turn synchronously and returns whether that succeeded. A refused send and a staging
    /// save that threw both return false, leave the draft in place, and leave the text on
    /// screen — the release below is ORDERED AFTER the save and simply never runs.
    private func send() {
        guard canSend else { return }
        guard coordinator.stageAndSend(text: draft, mode: mode, thread: thread,
                                       context: context) else {
            // Nothing was released, so the composer is still the truth. A refused send is
            // a departure like any other: capture it.
            captureDraft()
            return
        }
        // Durably staged: the user turn is on disk. Only now is the draft released.
        ComposerDrafts.release(for: thread)
        draft = ""
        draftNotice = nil
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
                // The same one menu the iPhone renders, from the same `ModelMenuLayout`.
                Menu {
                    ForEach(layout.sections) { section in
                        if let header = section.header {
                            Section(header) { rows(section, in: modelState) }
                        } else {
                            rows(section, in: modelState)
                        }
                    }
                    if let control = layout.effort,
                       let resolved = modelState.resolvedModel(
                        threadModelID: thread.selectedModelID,
                        deviceDefaultID: LastUsedModelStore.id) {
                        Section("Effort") { effortControl(control, on: resolved) }
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

    private var buttonLabel: some View { Label(layout.buttonLabel, systemImage: "cpu") }

    /// Everything the menu renders — shared with the iPhone's picker.
    private var layout: ModelMenuLayout {
        ModelMenuLayout(state: store.state, threadModelID: thread.selectedModelID,
                        deviceDefaultID: LastUsedModelStore.id, threadEffort: thread.selectedEffort)
    }

    /// One family's rows: the checkmark and the harness/version detail on the resolved model, a
    /// disabled row with its reason for one that cannot be picked right now.
    @ViewBuilder
    private func rows(_ section: ModelMenuSection, in state: ModelSwitchState) -> some View {
        ForEach(section.rows) { row in
            Button {
                if let model = state.offered.first(where: { $0.id == row.id }) { select(model) }
            } label: {
                if row.isSelected, let subtitle = row.subtitle {
                    Label("\(row.title) — \(subtitle)", systemImage: "checkmark")
                } else if row.isSelected {
                    Label(row.title, systemImage: "checkmark")
                } else {
                    Text(row.title)
                }
            }
            .disabled(!row.isEnabled)
        }
    }

    /// The resolved model's declared effort control: one row per value, or a single switch.
    ///
    /// Rows rather than an inline `Picker`, matching the iPhone: an inline picker in a menu
    /// replaces the enclosing `Section("Effort")` with its own, so the values render with no
    /// header saying what they are. Proven on iOS by `ModelPickerMenuUITests`; applied here
    /// because this menu is built from the same construct. **Not observed rendering on
    /// macOS** — there is no macOS UI-test target, so the Mac side of this rests on the
    /// shared construct and on `JesseMacTests` staying green, not on a screenshot.
    @ViewBuilder
    private func effortControl(_ control: ModelEffortControl, on model: ModelInfo) -> some View {
        switch control {
        case .picker(let values, let selected):
            ForEach(values, id: \.self) { value in
                Button {
                    selectEffort(value, on: model)
                } label: {
                    if value == selected {
                        Label(value, systemImage: "checkmark")
                    } else {
                        Text(value)
                    }
                }
            }
        case .toggle(let off, let on, let isOn):
            Toggle("Thinking", isOn: Binding(get: { isOn },
                                             set: { selectEffort($0 ? on : off, on: model) }))
        }
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
        // Drop a stored effort the resolved model no longer declares, exactly as the iPhone does.
        if let state = store.state {
            let kept = ModelMenuAction.sanitizedEffort(
                state: state, threadModelID: thread.selectedModelID,
                deviceDefaultID: LastUsedModelStore.id, threadEffort: thread.selectedEffort)
            if kept != thread.selectedEffort {
                thread.selectedEffort = kept
                try? context.save()
            }
        }
    }

    /// Pick a model for THIS conversation: store it on the thread and make it this Mac's
    /// default for the next new conversation. No bridge write — the phone is unaffected. A
    /// different model clears the thread's effort.
    private func select(_ model: ModelInfo) {
        guard model.available, model.id != thread.selectedModelID else { return }
        let next = ModelMenuAction.pick(model, currentModelID: thread.selectedModelID,
                                        currentEffort: thread.selectedEffort)
        thread.selectedModelID = next.modelID
        thread.selectedEffort = next.effort
        LastUsedModelStore.id = model.id
        try? context.save()
    }

    /// Pick an effort for the resolved model; it pins that model to the thread.
    private func selectEffort(_ value: String, on model: ModelInfo) {
        let next = ModelMenuAction.pickEffort(value, on: model)
        thread.selectedModelID = next.modelID
        thread.selectedEffort = next.effort
        LastUsedModelStore.id = next.modelID
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
                VStack(alignment: .trailing, spacing: 2) {
                    // What a screen attached to this turn, when it attached something.
                    // One caption naming the scope — never the snapshot itself, which
                    // `turn.text` still carries for the model. Mirrors iOS.
                    if turn.hasAttachedContext, let label = turn.contextLabel {
                        Label(label, systemImage: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // An ask sent on an empty composer has no typed half to draw — the
                    // caption above is the whole turn.
                    if !turn.visibleText.isEmpty {
                        Text(turn.visibleText)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(.tint.opacity(0.85), in: .rect(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                }
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
