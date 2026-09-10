import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import JesseCore
import JesseNetworking
import JesseConversations
import JesseSpeech

// One conversation: the full turn transcript with the composer pinned at the
// bottom. Being inside a thread *is* continuing it — every send auto-resumes the
// thread's session, so there's no "Continue thread" toggle anymore.
struct ThreadDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(RunCoordinator.self) private var coordinator
    @Bindable var thread: JesseThread

    /// Whether opening this conversation should hide the root tab bar. True only
    /// when the detail was PUSHED onto a stack (iPhone/compact), where the back
    /// swipe pops the thread and brings the bar back. In the iPad split view the
    /// detail column has no pop — selecting a thread just replaces it — so hiding
    /// the bar there strands the user in Chats with no way back to Health. The
    /// caller decides, because `ContentView` is what knows which layout it built.
    var hidesTabBar = true

    @State private var input = ""
    // Plain @State (not @FocusState): the composer is a UITextView-backed
    // representable that drives first-responder from this binding.
    @State private var inputFocused = false

    // Bumped once per send() so `.sensoryFeedback` fires a light tap the instant
    // the user dispatches a turn — the phone had no haptics; the watch already
    // taps on reply. See the `.sensoryFeedback` trio on `body`.
    @State private var sendHaptic = 0

    // Attachments staged for the next send, plus the pickers' presentation state.
    @State private var attachments: [JesseAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var showAudioImporter = false
    @State private var attachError: String?

    /// The recording-to-transcript flow, whichever way a recording arrived: the
    /// paperclip's "Audio Recording", or the share sheet, which opens a conversation and
    /// leaves the hand-off on the coordinator for this view to pick up.
    ///
    /// One model per conversation, held across the whole flow, because the flow outlives
    /// every individual sheet in it — the language picker, the progress view, and the
    /// error line are three views of one run.
    @State private var recording = RecordingAttachment()
    // Whether the composer's frugal glyph has been tapped for its explanation.
    @State private var showFrugalExplanation = false

    /// The frugal decision this composer is drawing: the live path plus the Settings
    /// toggle.
    ///
    /// It reads `ConnectivityMonitor.shared.path` directly rather than going through
    /// `FrugalSettings`, so this view RE-RENDERS when the path changes: the monitor is
    /// `@Observable`, and the off-main mirror the rest of the app reads is a plain value,
    /// which cannot be observed. Computed (not stored) so the memberwise initializer stays
    /// internal — a stored property with a default makes it private, and two other screens
    /// construct this view.
    private var frugalPolicy: FrugalPolicy {
        FrugalPolicy.decide(path: ConnectivityMonitor.shared.path, forcedOn: FrugalSettings.isForced)
    }

    // Every persisted outbox record; filtered per-turn below. Small (only messages
    // in flight or failed live here), and observed so a message flipping to `.failed`
    // (or being retried/discarded) re-renders the affected turn's controls live.
    @Query private var outbox: [OutboxItem]

    private var running: Bool { coordinator.isRunning(thread.id) }
    private var turns: [Turn] { thread.orderedTurns }

    /// Context a screen attached to this thread without firing a turn (today: the
    /// Today tab's Discuss). Non-nil means the transcript is empty ON PURPOSE — the
    /// item is already in hand, waiting on the user's first message — which is what
    /// makes an empty composer sendable here and nowhere else.
    private var attachedContext: String? { coordinator.attachedContext(for: thread.id) }

    /// The whole attachment — its scope title and its starters as well as its body. The
    /// Health tab's "Ask about this" fills all three; the Today tab's Discuss fills only
    /// the body, and the two extra affordances below simply don't render for it.
    private var attachment: AttachedContext? { coordinator.attachment(for: thread.id) }

    /// The `.failed` outbox item for a given user turn, if any — drives the compact
    /// per-message "Not delivered" line with Retry/Discard under that bubble.
    private func failedItem(for turnID: UUID) -> OutboxItem? {
        outbox.first { $0.turnID == turnID && $0.threadID == thread.id && $0.state == .failed }
    }

    // Haptic decisions, pulled out of `body` as typed methods so the SwiftUI
    // type-checker doesn't have to infer the trailing closures inline (the
    // already-large `body` tips over its complexity budget otherwise).
    // A reply just landed iff the turn count rose while the run is no longer in
    // flight — `finish` appends the Jesse turn and clears the run together, while
    // the optimistic user-turn append happens with `running` still true.
    private func completionFeedback(old: Int, new: Int) -> SensoryFeedback? {
        new > old && !running ? .success : nil
    }
    private func errorFeedback(old: String?, new: String?) -> SensoryFeedback? {
        new != nil && new != old ? .error : nil
    }

    // Auto-scroll follows the newest text only while the user is parked at the
    // bottom. Scrolling up (even mid-stream) suppresses follow and reveals the
    // "jump to latest" button; the follow decision itself lives in the pure,
    // unit-tested `TranscriptScroll` helper.
    @State private var isAtBottom = true

    /// The name this conversation shows in the navigation bar: the shared
    /// `displayTitle(for:)` resolution, the same one the list row draws, and NOT a
    /// fallback chain of its own. This modifier used to read `thread.title` raw
    /// with an inline empty check, so a thread with an `aiTitle` was named one way
    /// in the list and another the moment it was opened. Extracted as a property so
    /// the detail view's OWN title is assertable without a view host.
    var navigationTitleText: String { displayTitle(for: thread) }

    var body: some View {
        VStack(spacing: 12) {
            transcript
            // The composer outranks the transcript for vertical space: when the
            // keyboard, the chips row, and an error line make the screen tight,
            // the transcript scrolls/yields while the input keeps its multi-line
            // floor (see ComposerLayout) instead of collapsing to one line.
            composer
                .layoutPriority(1)
        }
        .padding()
        // Haptics (iOS 17 `.sensoryFeedback`, not UIFeedbackGenerator): a light
        // tap on send, a success tap when a reply lands, and an error tap when a
        // failure surfaces. The completion tap keys off `turns.count` rising while
        // NOT running — that is the moment `finish` appends the Jesse turn and
        // clears the run in one mutation. The optimistic user-turn append happens
        // while `running` is still true (so it's excluded), and a user Cancel
        // neither appends a turn nor sets an error (so it stays silent).
        .sensoryFeedback(.impact(weight: .light), trigger: sendHaptic)
        .sensoryFeedback(trigger: turns.count, completionFeedback)
        .sensoryFeedback(trigger: coordinator.error(for: thread.id), errorFeedback)
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        // Hide the root TabView's bar while a conversation is open, so the tabs are
        // present on the conversation list and within Health but gone inside a
        // thread. Applying it here (on the pushed detail) means every entry point
        // that lands on a thread — deep link, Siri, notification tap — inherits it,
        // since they all converge on this view. Compact only: see `hidesTabBar`.
        .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
        // Hydrate the transcript from the bridge when this conversation is opened,
        // cache-first: an adopted stub (started on the Mac) pulls its full transcript
        // here, a phone-started thread just seeds its cursor, and either way an
        // unreachable or older bridge leaves the cached copy untouched. Mirrors the
        // Mac detail view's `.task(id:)` hydrate.
        .task(id: thread.id) {
            await coordinator.hydrateOnOpen(thread: thread, context: context)
        }
        // A staged discussion opens ON the composer, empty and focused: not firing a
        // turn is only an improvement if the user's first move is to type. (A thread
        // opened any other way keeps the keyboard down, as before.)
        .onAppear {
            if attachedContext != nil && turns.isEmpty { inputFocused = true }
        }
        // DECLARATION ORDER IS LEFT-TO-RIGHT, ordered by taps per day: the star is a
        // one-tap toggle that undoes itself, so it is declared LAST and sits farthest
        // right; the model picker is set once for a conversation and rarely touched
        // again; Share is the rarest of the three and the only one that leaves the app,
        // so it is farthest from the mis-tap slot. See README, "UI conventions".
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Share the whole conversation as a role-labeled Markdown
                // transcript. ShareLink gives Copy + the system share sheet for
                // free. Hidden until there's something to share.
                if !turns.isEmpty {
                    ShareLink(item: thread.sharedTranscript) {
                        Label("Share conversation", systemImage: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // The PER-CONVERSATION model picker, one tap from the thread: shows the model
                // THIS conversation will send its next turn on and lets you change it without
                // leaving the thread. The choice is local — per thread and per device — so it
                // never affects another conversation or another device. Hidden on an older
                // bridge (no models route). The next turn uses the new model; earlier turns
                // keep the model that served them (each reply's chip is authoritative).
                ModelPickerMenu(thread: thread)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    thread.toggleFavorite()
                    do {
                        try context.save()
                    } catch {
                        Log.run.error("favorite toggle save failed: \(error.localizedDescription)")
                    }
                    // Best-effort mirror to the bridge so the Mac converges; self-healing
                    // if it fails (see RunCoordinator.pushFavoriteChange).
                    coordinator.pushFavoriteChange(for: thread)
                } label: {
                    Label(thread.isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: thread.isFavorite ? "star.fill" : "star")
                }
                .tint(thread.isFavorite ? .yellow : nil)
            }
        }
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
                        VStack(alignment: turn.isUser ? .trailing : .leading, spacing: 4) {
                            TurnRow(turn: turn)
                            // A user turn whose message never reached the bridge shows
                            // a compact per-message failure line with its own Retry /
                            // Discard — the composer stays enabled, and each failed
                            // message retries independently.
                            if let item = failedItem(for: turn.id) {
                                OutboxFailedControls(
                                    lastError: item.lastError,
                                    onRetry: { coordinator.retry(itemID: item.id, context: context) },
                                    onDiscard: { coordinator.discard(itemID: item.id, context: context) })
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: turn.isUser ? .trailing : .leading)
                        .id(turn.id)
                    }
                    // Delivery caption under the LAST user bubble, exactly where Messages
                    // puts "Delivered". "Sending…" is the pre-ACK window (the message could
                    // still be lost with the POST); "Received" means the bridge registered
                    // the conversation and accepted the turn, so it will be answered even if
                    // the app is closed. It disappears when Jesse's turn is appended, just as
                    // Messages' caption is replaced by the next message.
                    if let phase = coordinator.phase(thread.id), turns.last?.isUser == true {
                        DeliveryCaption(phase: phase)
                    }
                    // Live, streaming reply: the partial text as it arrives, plus
                    // a coarse activity line under the spinner. Cleared and
                    // replaced by the persisted Turn the instant the turn finishes.
                    if running {
                        // Scrub a trailing JESSE_MEAL_LOG v1 line from the live
                        // partial: a delta can briefly show the sentinel before the
                        // bridge's `done` frame strips it (the streaming caveat).
                        // Unknown versions are left visible (loud by contract).
                        let partial = MealLogParser.scrubbedStreamingText(
                            coordinator.partialText(for: thread.id) ?? "")
                        if !partial.isEmpty {
                            // Coalesced to ~10Hz so a long stream doesn't re-parse
                            // the whole growing string on every delta (M8).
                            StreamingPartialText(text: partial)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let activity = coordinator.activity(for: thread.id) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(activity)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // A whole-answer model pushes no deltas, so without this the only sign
                        // of a turn in flight is the "Received" receipt — indistinguishable
                        // from a turn that has silently stalled. Shown only when nothing else
                        // is, so there is never a second spinner.
                        if WholeAnswerProgress.shouldShow(
                            isRunning: true,
                            streamsText: NonStreamingModelStore.streamsText(
                                id: thread.selectedModelID ?? LastUsedModelStore.id),
                            partialText: partial,
                            activity: coordinator.activity(for: thread.id)) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(WholeAnswerProgress.caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Working. This model replies all at once.")
                        }
                    }
                    if let error = coordinator.error(for: thread.id) {
                        let recheckable = coordinator.canRecheck(thread.id)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
                                // Recoverable (still retrievable) reads as a soft
                                // warning; a genuinely-gone reply reads as an error.
                                .font(.callout)
                                .foregroundStyle(recheckable ? .orange : .red)
                            if recheckable {
                                Button {
                                    coordinator.recheck(thread.id, context: context)
                                } label: {
                                    Label("Re-check", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Track whether the user is parked at the bottom straight from the
            // scroll geometry, tolerating rubber-banding and the growing partial.
            .onScrollGeometryChange(for: Bool.self) { geo in
                TranscriptScroll.isAtBottom(
                    contentOffsetY: geo.contentOffset.y,
                    contentHeight: geo.contentSize.height,
                    containerHeight: geo.containerSize.height)
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            // A finished reply (turns.count) or the running flag flipping follows
            // only when at the bottom; a settled change animates gently.
            .onChange(of: turns.count) { _, _ in autoScroll(proxy, trigger: .jesseTurnAppended) }
            .onChange(of: running) { _, _ in autoScroll(proxy, trigger: .runningChanged) }
            // Keep the newest streamed text in view as it grows — but never
            // animate a delta (a 0.2s tween against a moving target is the
            // over-scroll churn) and never yank a user who has scrolled up.
            .onChange(of: coordinator.partialText(for: thread.id)) { _, _ in
                autoScroll(proxy, trigger: .streamDelta)
            }
            .onAppear { autoScroll(proxy, trigger: .appeared) }
            // One-tap return to live when the user has scrolled up during (or
            // after) a reply. Hidden while following, so it's out of the way.
            .overlay(alignment: .bottomTrailing) { jumpToLatestButton(proxy) }
        }
    }

    @ViewBuilder
    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        if !isAtBottom && (running || !turns.isEmpty) {
            Button {
                isAtBottom = true
                scrollToBottom(proxy, animated: true)
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .background(Circle().fill(.background))
            }
            .accessibilityLabel("Jump to latest")
            .padding(.trailing, 4)
            .padding(.bottom, 8)
            .transition(.opacity)
        }
    }

    private static let bottomAnchor = "jesse.transcript.bottom"

    /// Auto-scroll for a change of kind `trigger`, gated on follow state. Stream
    /// deltas and the initial appear scroll without animation (no chasing a
    /// moving target; land instantly on open); settled turn/running changes get
    /// a short ease. `.userSentTurn`/`.appeared` scroll regardless of position.
    private func autoScroll(_ proxy: ScrollViewProxy, trigger: ScrollTrigger) {
        guard TranscriptScroll.shouldAutoScroll(isAtBottom: isAtBottom, trigger: trigger) else { return }
        let animated = trigger != .streamDelta && trigger != .appeared
        scrollToBottom(proxy, animated: animated)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !turns.isEmpty || running else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Composer

    /// The tappable opening questions under an empty ask. A wrapping row of plain
    /// bordered buttons — the app's own control vocabulary, no new chrome.
    private func starterRow(_ starters: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(starters, id: \.self) { starter in
                    Button(starter) { sendStarter(starter) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollClipDisabled()
    }

    /// A tapped starter IS the user's first message — it goes through the same `send`
    /// path as anything typed, so the attachment is composed ahead of it exactly once.
    private func sendStarter(_ starter: String) {
        input = starter
        send()
    }

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

            // One error line for the composer, whether the complaint came from an
            // attachment or from a transcription. Two lines in two places would let a
            // rejected file and a failed transcript disagree about what went wrong.
            if let message = attachError ?? recording.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Says why the composer is empty and why Send works with nothing typed.
            // Without it, a conversation opened from Today or Health looks like a blank
            // new chat that has somehow forgotten what it is about.
            //
            // A titled attachment (a Health ask) NAMES its scope here — the pinned context
            // line — so "this" is never ambiguous. It is one small caption, not a banner:
            // the scope is also the conversation's title in the navigation bar.
            if let attachment, turns.isEmpty {
                Label(attachment.title.map { "Asking about \($0). Send an empty message to have Jesse just read it." }
                        ?? "This item is attached. Ask about it, or send an empty message to have Jesse just read it.",
                      systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
            }

            // Opening questions, in the EMPTY state only: they disappear the moment the
            // user types a character, taps one, or the conversation has any turn at all.
            // Tapping one sends it — a starter that only filled the field would be a
            // suggestion the user then has to confirm, which is a worse offer than a
            // question they can simply ask.
            if let starters = attachment?.starters, !starters.isEmpty,
               turns.isEmpty, input.isEmpty, !running {
                starterRow(starters)
            }

            if !attachments.isEmpty {
                attachmentChips
            }

            // Progress sits IN the composer rather than over the screen: an hour of
            // audio takes minutes to read, the conversation stays usable while it does,
            // and the transcript is landing in the field directly below this row.
            if case .running(let update) = recording.stage {
                RecordingProgressBar(update: update,
                                     sourceName: recording.sourceName,
                                     onCancel: { recording.cancel() })
            }

            // A UITextView-backed field: native long-press → Paste (text, and a
            // copied photo/PDF, which stages as an attachment via onPasteMedia),
            // native word/sentence selection, and a multi-line floor that never
            // collapses to one line (grows to the cap, then scrolls internally).
            ComposerInput(
                text: $input,
                isFocused: $inputFocused,
                placeholder: thread.modeValue == .ask ? "Ask Jesse anything…"
                                                      : "Tell Jesse something…",
                minLines: ComposerLayout.inputMinLines,
                maxLines: ComposerLayout.inputMaxLines,
                onPasteMedia: stagePastedMedia)

            HStack {
                attachButton
                if frugalPolicy.isActive { frugalGlyph }
                SendButton(
                    running: running,
                    startDate: coordinator.startDate(for: thread.id),
                    title: turns.isEmpty ? thread.modeValue.label : "Follow up",
                    disabled: sendDisabled,
                    action: send,
                    fps: frugalPolicy.sendSweepFPS
                )
                if running {
                    Button("Cancel") { coordinator.cancel(thread.id) }
                        .buttonStyle(.bordered)
                }
            }
        }
        // iOS 17 imperative presenters, toggled from the paperclip menu.
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: AttachmentLimits.maxCount, matching: .images)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.pdf], allowsMultipleSelection: true,
                      onCompletion: handleFileImport)
        // One recording at a time: transcribing an hour of audio is not something to
        // start four of, and the composer holds one transcript.
        .fileImporter(isPresented: $showAudioImporter,
                      allowedContentTypes: AudioRecordingTypes.contentTypes,
                      allowsMultipleSelection: false,
                      onCompletion: handleAudioImport)
        .sheet(isPresented: Binding(get: { recording.stage == .choosingLanguage },
                                    set: { if !$0 { recording.abandon() } })) {
            RecordingLanguageSheet(model: recording)
        }
        // A pending share hand-off, picked up by the conversation that was opened for
        // it. `.task(id:)` rather than `.onAppear` so it also fires for a conversation
        // that was already on screen, and `takeStagedRecording` clears on read so it
        // fires exactly once.
        .task(id: thread.id) {
            guard let staged = coordinator.takeStagedRecording(for: thread.id) else { return }
            await recording.begin(handoff: staged)
        }
        // The transcript is moved into the composer the moment it exists, composed with
        // whatever is typed AT THAT MOMENT — so text typed during a long transcription
        // is kept and stays ahead of the transcript.
        .onChange(of: recording.completed) { _, value in
            guard value != nil, let done = recording.takeCompleted() else { return }
            input = done.messageBody(typed: input)
            inputFocused = true
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await handlePhotoItems(items) }
        }
        // Full-screen camera capture. Only reachable when a camera is available
        // (the menu item is hidden otherwise), so `.camera` never initializes on a
        // device without one (e.g. Simulator).
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(onCapture: handleCameraCapture,
                         onCancel: { showCamera = false })
                .ignoresSafeArea()
        }
    }

    /// The one visible sign that frugal mode is in force: a small leaf beside the attach
    /// button. Tapping it says what is being saved and why.
    ///
    /// A glyph and not a banner, deliberately. Nothing is being refused — every decision
    /// frugal mode makes is "cheaper", never "not allowed" — so a bar across the composer
    /// would be announcing a problem that does not exist. What it has to do is answer the
    /// one question a person actually asks: "why did that photo look soft?"
    private var frugalGlyph: some View {
        Button {
            showFrugalExplanation = true
        } label: {
            Image(systemName: "leaf")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Frugal mode is on")
        .accessibilityHint("Explains what Jesse is doing to use less data.")
        .popover(isPresented: $showFrugalExplanation) {
            Text(frugalPolicy.explanation)
                .font(.callout)
                .padding()
                .frame(maxWidth: 320)
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Attachments UI

    private var attachButton: some View {
        Menu {
            Button {
                attachError = nil
                showPhotoPicker = true
            } label: {
                Label("Photo or Image", systemImage: "photo")
            }
            Button {
                attachError = nil
                showFileImporter = true
            } label: {
                Label("PDF Document", systemImage: "doc")
            }
            // Audio is NOT an attachment: the bridge never sees a byte of it. This
            // transcribes on the device and puts the TEXT in the composer, which is why
            // it sits here beside the pickers and yet never reaches `addAttachment`.
            Button {
                attachError = nil
                recording.dismissError()
                showAudioImporter = true
            } label: {
                Label("Audio Recording", systemImage: "waveform")
            }
            // Shown only when a camera exists (never on Simulator).
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    takePhoto()
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.title3)
                .frame(width: 38, height: 40)
        }
        .accessibilityLabel("Add attachment")
        .disabled(running || attachments.count >= AttachmentLimits.maxCount)
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    HStack(spacing: 6) {
                        Image(systemName: att.isImage ? "photo" : "doc.text")
                        Text(att.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            remove(att)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(att.filename)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
        }
    }

    private func remove(_ att: JesseAttachment) {
        attachments.removeAll { $0.id == att.id }
        attachError = nil
    }

    @MainActor
    private func handlePhotoItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            // loadTransferable returns Data? and can throw → Data??; flatten.
            let loaded = try? await item.loadTransferable(type: Data.self)
            guard let data = loaded ?? nil else {
                attachError = "Couldn’t load that image."
                continue
            }
            addAttachment(data: data, fallbackName: "Photo")
        }
        photoItems = []
    }

    /// "Take Photo" tapped. Branch on the camera authorization status (via the pure
    /// `CameraCapture.action`): present immediately when authorized, request access
    /// when undetermined (presenting only if granted), or surface a settings hint
    /// when denied/restricted — never presenting a `.camera` picker without
    /// permission (which would just show black).
    private func takePhoto() {
        attachError = nil
        switch CameraCapture.action(for: AVCaptureDevice.authorizationStatus(for: .video)) {
        case .present:
            showCamera = true
        case .request:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        showCamera = true
                    } else {
                        attachError = CameraCapture.deniedMessage
                    }
                }
            }
        case .denied:
            attachError = CameraCapture.deniedMessage
        }
    }

    /// A freshly captured photo (already JPEG-encoded by `CameraPicker`) — stage it
    /// through the SAME `addAttachment` path the other pickers use, so it inherits
    /// the client-side MIME/size/count caps and the whole preview + send flow.
    private func handleCameraCapture(_ data: Data) {
        showCamera = false
        addAttachment(data: data, fallbackName: "Photo",
                      suggestedName: CameraCapture.photoFilename())
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    attachError = "Couldn’t read “\(url.lastPathComponent)”."
                    continue
                }
                addAttachment(data: data, fallbackName: "Document",
                              suggestedName: url.lastPathComponent)
            }
        case .failure(let error):
            attachError = error.localizedDescription
        }
    }

    /// A picked recording. It is NOT staged as an attachment — audio never crosses the
    /// network — so it goes to `RecordingAttachment`, which copies it, transcribes it on
    /// this device, and deletes its copy however the run ends.
    private func handleAudioImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            attachError = nil
            // The security scope is held only while the bytes are copied out; the
            // transcriber reads the app's own copy for however many minutes it takes.
            let scoped = url.startAccessingSecurityScopedResource()
            Task {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await recording.begin(pickedFileAt: url)
            }
        case .failure(let error):
            attachError = error.localizedDescription
        }
    }

    /// Native paste of clipboard media (called by `ComposerInput`'s text view when
    /// the user long-presses → Paste and the clipboard holds an image or PDF).
    /// Reads the pasteboard's item PROVIDERS (not the flattened `.items` dict) so a
    /// photo loads its own compact JPEG/HEIC bytes verbatim rather than being
    /// re-encoded to a large PNG. Returns true iff it owns the paste (there is
    /// media to stage), and stages asynchronously — provider loading is async — so
    /// the text view does not also paste text. Each item flows through the SAME
    /// `addAttachment` path the pickers use, inheriting the MIME/size/count caps,
    /// the chip UI, and the send flow; the cap and any oversized/unsupported item
    /// surface via `attachError`.
    @MainActor
    private func stagePastedMedia() -> Bool {
        let providers = UIPasteboard.general.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
        }
        guard !providers.isEmpty else { return false }
        attachError = nil
        Task { await stagePastedProviders(providers) }
        return true
    }

    @MainActor
    private func stagePastedProviders(_ providers: [NSItemProvider]) async {
        for provider in providers {
            guard let data = await loadPastedData(from: provider) else {
                attachError = "Couldn’t paste that item (images or PDF only)."
                continue
            }
            // loadPastedData guarantees `data` sniffs as a whitelisted type; name it
            // pasted-<timestamp>.<ext> and let addAttachment run the caps.
            let ext = JesseAttachment.sniffMime(data)
                .map(JesseAttachment.fileExtension(forMime:)) ?? "png"
            addAttachment(data: data, fallbackName: "Pasted",
                          suggestedName: PasteAttachment.filename(ext: ext))
        }
    }

    /// Read a pasted provider's bytes as a stageable, whitelisted payload (or nil).
    /// Concrete encodings are tried in order and kept VERBATIM (a photo stays its
    /// compact JPEG/HEIC); the `hasItemConformingToTypeIdentifier` guard means a
    /// type the provider doesn't actually carry is skipped, so a JPEG photo never
    /// matches `public.png` and never gets re-encoded. A bitmap the provider only
    /// vends as a `UIImage` (no concrete data representation) is re-encoded to PNG.
    private func loadPastedData(from provider: NSItemProvider) async -> Data? {
        for type in ComposerPaste.mediaTypes {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
            if let data = await loadData(provider, type: type),
               let staged = PasteAttachment.stageableBytes(from: data) {
                return staged
            }
        }
        if provider.canLoadObject(ofClass: UIImage.self),
           let image = await loadImageObject(provider) {
            return PasteAttachment.pngData(from: image)
        }
        return nil
    }

    private func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func loadImageObject(_ provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    /// Sniff the type, name it, run the client-side caps, and stage it — or set
    /// `attachError`. The bridge re-validates all of this as the authority.
    private func addAttachment(data: Data, fallbackName: String, suggestedName: String? = nil) {
        // Oversized IMAGE → downscale to a JPEG that fits the per-file cap, so a
        // large photo attaches instead of erroring. This is the ONE shared spot, so
        // paste, photo picker, file import, and camera all behave identically (the
        // paste/picker divergence was PR #51's root cause — don't reintroduce one).
        // Under-cap images and every non-image fall through untouched (`fitToCap`
        // returns nil), preserving the byte-verbatim staging PR #51 restored. The
        // output is always JPEG, so the display name gets a `.jpg` extension.
        var data = data
        var suggestedName = suggestedName
        if let fitted = AttachmentDownscaler.fitToCap(data, cap: AttachmentLimits.maxBytesPerFile,
                                                     frugal: FrugalSettings.current()) {
            data = fitted
            suggestedName = suggestedName.map(AttachmentDownscaler.jpegFilename(from:))
        }
        guard let mime = JesseAttachment.sniffMime(data) else {
            attachError = "That file type isn’t supported (images or PDF only)."
            return
        }
        let ext = JesseAttachment.fileExtension(forMime: mime)
        let name = suggestedName ?? "\(fallbackName) \(attachments.count + 1).\(ext)"
        let candidate = JesseAttachment(filename: name, mime: mime, data: data)
        if let reason = AttachmentLimits.rejectionReason(adding: candidate, to: attachments) {
            attachError = reason
            return
        }
        attachError = nil
        attachments.append(candidate)
    }

    /// Empty input is normally nothing to send. With a context attached it is the
    /// explicit "just look at it" — the one send that runs a turn on no prose of the
    /// user's, and only ever because they tapped Send.
    private var sendDisabled: Bool {
        running || (input.trimmingCharacters(in: .whitespaces).isEmpty && attachedContext == nil)
    }

    private func send() {
        inputFocused = false
        sendHaptic &+= 1
        let text = input
        let outgoing = attachments
        input = ""
        attachments = []
        attachError = nil
        // The user just spoke — re-enable follow so the appended turn (and the
        // reply that streams after it) jumps to the bottom, even if they'd
        // scrolled up to read history. This is the `.userSentTurn` semantics:
        // the turns.count bump that `coordinator.send` triggers now scrolls
        // because `isAtBottom` is true again.
        isAtBottom = true
        // `coordinator.send` clears the thread's error itself. Don't clear it here
        // first: while a recoverable error is showing, the retained job_id would
        // otherwise make `isRunning` read true and silently drop this new send.
        coordinator.send(thread: thread, text: text, voice: false, context: context,
                         attachments: outgoing)
    }
}

// MARK: - Pieces

/// The live streaming reply, with its markdown parse coalesced to ~10Hz (M8).
/// `MarkdownStreamRenderer` caches the parsed blocks, so the O(n²) "re-parse the whole
/// growing string on every delta" is gone. The persisted Turn renders the complete text
/// once the turn finishes.
///
/// This view holds NO clock. It used to render inside
/// `TimelineView(.animation(minimumInterval: 0.1, paused: !running))`, which keeps a
/// display-link subscription alive for the WHOLE turn — measured at roughly 20 interrupt
/// wakeups/second on top of the send button's, for a screen whose text was not changing:
/// a Jesse turn spends most of its time in tool use, emitting nothing.
///
/// The clock was only ever there to service a *suppressed* parse. `partialText` is
/// published by `RunCoordinator` at most once per `MarkdownStreamRenderer.interval`
/// already (that is where the coalescing belongs and is tested — `RunCoordinatorCoalesceTests`),
/// so a publish normally parses immediately on the body re-evaluation it triggers. The one
/// exception is the tail: `flushPartial` publishes the last chunk immediately, which can
/// land inside the renderer's cooldown. So instead of a permanent timeline, arm exactly one
/// catch-up re-render, and only when `hasRendered` says a publish really was suppressed.
private struct StreamingPartialText: View {
    let text: String
    /// Bumped by the catch-up task to force one more body evaluation, past the renderer's
    /// cooldown, so a suppressed tail is never left on screen.
    @State private var catchUps = 0
    @State private var renderer = MarkdownStreamRenderer()

    var body: some View {
        MarkdownText(blocks: renderer.blocks(for: text, now: Date()))
            .task(id: CatchUpKey(text: text, catchUps: catchUps)) { await catchUpIfSuppressed() }
    }

    /// Identity for the catch-up task: a new text (or a completed catch-up) restarts it,
    /// and SwiftUI cancels the previous one — so at most one is ever pending.
    private struct CatchUpKey: Equatable {
        let text: String
        let catchUps: Int
    }

    /// If the render is already current — the overwhelmingly common case — do nothing at
    /// all, so an idle stream costs zero timers. Otherwise wait out the renderer's cooldown
    /// and trigger the single re-render that lets the parse through.
    private func catchUpIfSuppressed() async {
        guard !renderer.hasRendered(text) else { return }
        try? await Task.sleep(for: .seconds(MarkdownStreamRenderer.interval))
        guard !Task.isCancelled else { return }
        catchUps &+= 1
    }
}

/// The compact "Not delivered" line shown under a user bubble whose `OutboxItem`
/// is `.failed`: an orange exclamation, the short reason, and small Retry / Discard
/// buttons. Matches the transcript's recoverable-error / Re-check visual language
/// (warning-orange, bordered buttons) rather than inventing new styling.
private struct OutboxFailedControls: View {
    let lastError: String?
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(lastError.map { "Not delivered — \($0)" } ?? "Not delivered")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(role: .destructive, action: onDiscard) {
                    Label("Discard", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

/// One message bubble. User turns sit right with a tinted fill; Jesse's replies
/// render as Markdown on the left.
///
/// Both bubbles are backed by a `UITextView` (`SelectableText` / `MarkdownText`'s
/// selectable path), so long-pressing the text is the normal iOS gesture: it
/// starts a native selection the user drags by word / sentence, with the system
/// Copy / Select All menu. There is no per-message "…" affordance and no custom
/// long-press-to-copy gesture — the whole point is to stop fighting the native
/// selection gesture. Whole-conversation Share still lives in the toolbar.
///
/// ONE text view per bubble, including a multi-block Jesse reply: a selection
/// cannot span two text views, so a reply rendered as one view per Markdown block
/// could not be selected across paragraphs at all. See `MarkdownDocument`.
/// Selection still stops at the bubble — spanning two turns is a separate thing.
private struct TurnRow: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: turn.isUser ? .trailing : .leading, spacing: 2) {
            if !turn.attachments.isEmpty {
                TurnAttachmentsView(attachments: turn.orderedAttachments)
            }
            // What a screen attached to this turn, when it attached something. One
            // caption, above the bubble, naming the scope — never the snapshot itself.
            if turn.hasAttachedContext, let label = turn.contextLabel {
                Label(label, systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Context attached: \(label)")
            }
            // An ask sent on an empty composer has no typed half to draw — the caption
            // above is the whole turn.
            if !turn.visibleText.isEmpty { bubble }
            // Files JESSE returned on this turn — the other direction from the
            // attachments above. Nothing renders for the overwhelming majority of turns.
            if !turn.artifacts.isEmpty {
                TurnArtifactsView(artifacts: turn.orderedArtifacts)
                    .padding(.top, 4)
            }
            // Native provenance chip under a Jesse reply that carried structured
            // provenance (the badge text is already stripped from `turn.text`). Absent
            // for user turns and older/badges-off replies — nothing renders there.
            if let provenance = JesseProvenance.from(json: turn.provenanceJSON) {
                ProvenanceChip(provenance: provenance)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.isUser ? .trailing : .leading)
    }

    @ViewBuilder private var bubble: some View {
        if turn.isUser {
            // User text is shown verbatim (as typed); the UITextView gives native
            // word/sentence selection within the bubble. `visibleText` is that typed
            // half: when a screen attached context, `turn.text` also holds the snapshot
            // that was composed ahead of it, and showing a page of numbers as something
            // the user "said" would be both unreadable and untrue. The label above says
            // what was attached.
            SelectableText(attributed: NSAttributedString(
                string: turn.visibleText,
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body),
                             .foregroundColor: UIColor.label]))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            // Selectable path (native per-block word/sentence selection).
            MarkdownText(turn.text)
        }
    }
}

/// A compact row of a turn's persisted attachment previews (1..N). Each is a small
/// downscaled JPEG thumbnail (`TurnAttachment.thumbnail`); a PDF gets a corner
/// badge so it reads as a document, not a photo. Accessible via the filename. The
/// empty case is handled by the caller (this view isn't shown for turns with none).
private struct TurnAttachmentsView: View {
    let attachments: [TurnAttachment]

    private static let side: CGFloat = 78

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { att in
                thumbnail(att)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ att: TurnAttachment) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = UIImage(data: att.thumbnail) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // No decodable thumbnail (a generation failure that still recorded
                // the row) — show a typed placeholder rather than a blank.
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: Self.side, height: Self.side)
                    .overlay(
                        Image(systemName: att.isPDF ? "doc.text" : "photo")
                            .foregroundStyle(.secondary))
            }
            if att.isPDF {
                Image(systemName: "doc.text.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                    .padding(4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel(att.isPDF ? "PDF attachment: \(att.filename)"
                                      : "Image attachment: \(att.filename)")
    }
}

/// How often the send button's clock has to tick, and for how long — the whole policy,
/// pure and `nonisolated` so it is unit-testable with no view and no clock.
///
/// The button shows two time-varying things and nothing else:
///  * the left→right fill sweep, which finishes at `fillSweepSeconds` and is a constant
///    full-width rectangle from then on, and
///  * the whole-second "Thinking… N" counter, which by construction changes at 1 Hz and
///    is only shown once `N > fillSweepSeconds`.
///
/// So a smooth clock is needed for the first `fillSweepSeconds` of a turn, and 1 Hz for
/// the rest of it. It used to run at the display refresh rate for the WHOLE turn: the
/// button was driven by `TimelineView(.animation(minimumInterval: 1/30, paused: !running))`,
/// and `.animation` is the display-link-backed schedule — `minimumInterval` throttles the
/// body re-evaluation but the app is still woken on every display frame. Measured on an
/// idle, unchanging screen with one turn in flight: **121–141 interrupt wakeups/second and
/// ~4% CPU, sustained for the entire turn**, attributed by `sample` to
/// `CADisplayLink → TimelineView.UpdateFilter → SendButton.body`. Jesse turns routinely run
/// for minutes, and after the first 10 seconds not one pixel changed between those frames.
enum SendButtonCadence {
    /// Seconds for the left→right "thinking" fill to sweep fully across, and the
    /// threshold past which the elapsed-seconds counter is shown.
    nonisolated static let fillSweepSeconds: Double = 10
    /// Frame interval while the sweep is actually sweeping.
    nonisolated static let sweepInterval: TimeInterval = 1.0 / 30.0
    /// Frame interval once the sweep is complete: only the whole-second counter changes.
    nonisolated static let settledInterval: TimeInterval = 1
    /// The sweep's frame rate off the frugal path — the `sweepInterval` above, as an FPS.
    nonisolated static let defaultFPS: Double = 1.0 / sweepInterval

    /// How long to wait before the next tick, for a turn that started `elapsed` ago.
    ///
    /// `fps` is the sweep's frame rate, which frugal mode drops to 1 — at which point the
    /// sweep and the settled counter have the same cadence and the button simply stops
    /// animating. That is the right trade on a metered link: the sweep is decoration on a
    /// screen whose content is not changing, and the phone is better off asleep between
    /// whole seconds.
    nonisolated static func tickInterval(elapsed: TimeInterval, fps: Double = 30) -> TimeInterval {
        guard elapsed < fillSweepSeconds else { return settledInterval }
        guard fps > 0 else { return settledInterval }
        return min(1.0 / fps, settledInterval)
    }
}

/// The send button's timeline: `sweepInterval` ticks while the fill sweep is animating,
/// `settledInterval` ticks afterwards, and — when no turn is running — exactly ONE entry,
/// so the button renders once and no clock is left running at all.
///
/// Deliberately a timer-driven `TimelineSchedule` rather than `.animation`: a custom
/// schedule asks the run loop for the next entry date, so an idle button holds no
/// display-link subscription. That is the fix, not the cadence numbers.
struct SendButtonSchedule: TimelineSchedule {
    /// When the running turn started; `nil` when nothing is running (→ a static button).
    let turnStart: Date?
    /// The sweep's frame rate. Frugal mode passes 1; see `SendButtonCadence.tickInterval`.
    var fps: Double = SendButtonCadence.defaultFPS

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        guard let turnStart else {
            // Not running: one entry, then the sequence ends and nothing is scheduled.
            var delivered = false
            return AnyIterator {
                guard !delivered else { return nil }
                delivered = true
                return startDate
            }
        }
        // SwiftUI asks for `.lowFrequency` in Low Power Mode (and on an always-on
        // display). Honour it: drop the sweep's frame rate and keep only the cadence the
        // counter needs — exactly the trade the mode is asking us to make.
        let lowPower = mode == .lowFrequency
        var next = startDate
        return AnyIterator {
            let entry = next
            let elapsed = entry.timeIntervalSince(turnStart)
            next = entry.addingTimeInterval(
                lowPower ? SendButtonCadence.settledInterval
                         : SendButtonCadence.tickInterval(elapsed: elapsed, fps: fps))
            return entry
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
    /// The sweep's frame rate. Defaulted so every existing caller and every preview is
    /// unchanged; the composer passes the frugal policy's value.
    var fps: Double = SendButtonCadence.defaultFPS

    /// Seconds for the left→right "thinking" fill to sweep fully across, and the
    /// threshold past which the elapsed-seconds counter is shown.
    private static let fillSweepSeconds: Double = SendButtonCadence.fillSweepSeconds

    var body: some View {
        TimelineView(SendButtonSchedule(turnStart: running ? startDate : nil, fps: fps)) { context in
            let elapsed = (running ? startDate.map { context.date.timeIntervalSince($0) } : nil) ?? 0
            let secs = Int(elapsed)
            Button(action: action) {
                HStack {
                    if running { ProgressView().tint(.white) }
                    Text(running ? (secs > Int(Self.fillSweepSeconds) ? "Thinking… \(secs)" : "Thinking…") : title)
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
                                .frame(width: geo.size.width * min(elapsed / Self.fillSweepSeconds, 1))
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

/// A compact toolbar affordance for THIS conversation's model, reachable from the thread so a
/// change is one tap. The selection is LOCAL — stored on the thread (`selectedModelID`) and
/// per device — so it never mutates the bridge's global default and never affects another
/// conversation or another device. It fetches the selectable models on appear, shows the model
/// the next turn will run on (the thread's own choice, else this device's default, else the
/// ambient `opus`), and on a pick writes the thread's selection and updates this device's
/// last-used default.
///
/// The control is ALWAYS present (matching the Mac composer picker, PR #26): the button shows
/// the model the next turn will run on — the thread's own choice, else this device's default,
/// else the ambient `opus` — drawn from `ModelSelectionResolver`, even before the list loads and
/// even if it never does (an older bridge with no `/jesse/models`, or a persistent fetch
/// failure). In that case the button simply shows the resolved model and is not expandable,
/// rather than the whole control vanishing. The list is fetched with ONE bounded, backed-off
/// burst (`loadModelList`) so a slow or briefly-unreachable bridge fills in without user action
/// — and an unreachable one does not leave a poll running for as long as the thread is open.
private struct ModelPickerMenu: View {
    @Environment(\.modelContext) private var context
    @Bindable var thread: JesseThread
    @State private var modelState: ModelSwitchState?

    var body: some View {
        Group {
            if let modelState {
                // ONE menu, and the whole of it fits in one menu. What goes in it, and in which
                // order, is `ModelMenuLayout`'s — shared with the Mac so the two cannot drift.
                Menu {
                    // Families are SECTIONS, never submenus: a header costs no tap, a submenu
                    // costs one. A family of one has no header and is a plain row.
                    ForEach(layout.sections) { section in
                        if let header = section.header {
                            Section(header) { rows(section, in: modelState) }
                        } else {
                            rows(section, in: modelState)
                        }
                    }
                    // Effort: ONE inline control for the resolved model, and only when that
                    // model declares a scale. Absent otherwise — not disabled, absent.
                    if let control = layout.effort, let resolved {
                        Section("Effort") { effortControl(control, on: resolved) }
                    }
                } label: {
                    buttonLabel
                }
            } else {
                // The list has not loaded yet (slow / older bridge / transient failure). Show the
                // resolved model, non-expandable, so the control is present and truthful about the
                // next turn's model — never invisible.
                buttonLabel
                    .foregroundStyle(.secondary)
            }
        }
        .task { await loadWithRetry() }
    }

    /// Everything the menu renders, from the loaded list and this thread's selection.
    private var layout: ModelMenuLayout {
        ModelMenuLayout(state: modelState, threadModelID: thread.selectedModelID,
                        deviceDefaultID: LastUsedModelStore.id, threadEffort: thread.selectedEffort)
    }

    /// One family's rows. The resolved model carries the checkmark and, as secondary text, the
    /// harness and version it runs on — information, never a control. A disabled row still
    /// explains WHY (not configured / unreachable): an outage must not look like a deletion.
    @ViewBuilder
    private func rows(_ section: ModelMenuSection, in state: ModelSwitchState) -> some View {
        ForEach(section.rows) { row in
            Button {
                if let model = state.offered.first(where: { $0.id == row.id }) { select(model) }
            } label: {
                if row.isSelected, let subtitle = row.subtitle {
                    Label {
                        Text(row.title)
                        Text(subtitle)
                    } icon: {
                        Image(systemName: "checkmark")
                    }
                } else if row.isSelected {
                    Label(row.title, systemImage: "checkmark")
                } else {
                    Text(row.title)
                }
            }
            .disabled(!row.isEnabled)
        }
    }

    /// The effort control the resolved model declared: an inline picker over a graded scale, or
    /// a single switch for thinking on/off. Inline, so choosing costs the same one tap a model
    /// pick does.
    @ViewBuilder
    private func effortControl(_ control: ModelEffortControl, on model: ModelInfo) -> some View {
        switch control {
        case .picker(let values, let selected):
            Picker("Effort", selection: Binding(get: { selected },
                                                set: { selectEffort($0, on: model) })) {
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
        case .toggle(let off, let on, let isOn):
            Toggle("Thinking", isOn: Binding(get: { isOn },
                                             set: { selectEffort($0 ? on : off, on: model) }))
        }
    }

    /// The label carries the model name, plus the effort only when it is not the default.
    private var buttonLabel: some View { Label(layout.buttonLabel, systemImage: "cpu") }

    /// The model the next turn will run on: the thread's own selection, else this device's
    /// default, else opus. Nil only before the list loads.
    private var resolved: ModelInfo? {
        modelState?.resolvedModel(threadModelID: thread.selectedModelID,
                                  deviceDefaultID: LastUsedModelStore.id)
    }

    /// Populate the list with ONE bounded, backed-off burst of attempts (`loadModelList`), so a
    /// slow or briefly-unreachable bridge still fills in without user action but a bridge that
    /// simply cannot answer no longer leaves a standing 3-second poll running for as long as the
    /// conversation is open. The button already shows the resolved model meanwhile; a persistent
    /// failure just leaves it non-expandable, and reopening the conversation retries.
    private func loadWithRetry() async {
        let cfg = ConfigStore.load()
        modelState = await loadModelList(
            isConfigured: cfg.isConfigured,
            fetch: { try? await JesseClient(config: cfg).fetchModels() },
            sleep: { try? await Task.sleep(for: .seconds($0)) })
        // A stored effort the resolved model no longer declares (a provider change since it was
        // chosen) is dropped now, so the next turn never sends a value the bridge would refuse.
        if let modelState {
            let kept = ModelMenuAction.sanitizedEffort(
                state: modelState, threadModelID: thread.selectedModelID,
                deviceDefaultID: LastUsedModelStore.id, threadEffort: thread.selectedEffort)
            if kept != thread.selectedEffort {
                thread.selectedEffort = kept
                save("clearing a stale effort")
            }
        }
    }

    /// Pick a model for THIS conversation: store it on the thread and make it this device's
    /// default for the next new conversation. No bridge write — the selection is entirely
    /// local, so another device is unaffected. A different model clears the thread's effort,
    /// which belonged to the model it was chosen on.
    private func select(_ model: ModelInfo) {
        guard model.available, model.id != thread.selectedModelID else { return }
        let next = ModelMenuAction.pick(model, currentModelID: thread.selectedModelID,
                                        currentEffort: thread.selectedEffort)
        thread.selectedModelID = next.modelID
        thread.selectedEffort = next.effort
        LastUsedModelStore.id = model.id
        save("selecting model \(model.id)")
    }

    /// Pick an EFFORT for the resolved model. It pins that model to the thread, because an effort
    /// is only ever sent with the model it was chosen for.
    private func selectEffort(_ value: String, on model: ModelInfo) {
        let next = ModelMenuAction.pickEffort(value, on: model)
        thread.selectedModelID = next.modelID
        thread.selectedEffort = next.effort
        LastUsedModelStore.id = next.modelID
        save("selecting effort \(value) on \(model.id)")
    }

    private func save(_ what: String) {
        do {
            try context.save()
        } catch {
            Log.run.error("\(what) for thread \(thread.id): \(error.localizedDescription)")
        }
    }
}

/// The trailing delivery caption under the last user bubble: the one place the UI
/// distinguishes "still crossing the network" from "the server has it".
///
/// Standard iOS treatment only, and deliberately so: a caption in `.caption2`/`.secondary`,
/// no new symbol, no checkmark glyph, no tint, and a default crossfade on the transition. It
/// carries no second haptic either: there is already a light impact on send and a success
/// haptic on the reply, and a third buzz in between is noise.
///
/// The accessibility label is where the actual meaning lives, and it is announced on the
/// transition into `.accepted`, because that is the reassurance a screen-reader user needs
/// and a two-word caption cannot convey.
private struct DeliveryCaption: View {
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
            return "Received by Jesse. Your message is saved and will be answered even if you leave the app."
        }
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(label)
        }
        .padding(.trailing, 4)
        .padding(.top, 2)
        .animation(.default, value: phase)
        .onChange(of: phase) { _, newPhase in
            guard newPhase == .accepted else { return }
            AccessibilityNotification.Announcement(label).post()
        }
    }
}
