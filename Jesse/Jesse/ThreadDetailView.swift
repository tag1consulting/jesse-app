import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import JesseCore

// One conversation: the full turn transcript with the composer pinned at the
// bottom. Being inside a thread *is* continuing it — every send auto-resumes the
// thread's session, so there's no "Continue thread" toggle anymore.
struct ThreadDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(RunCoordinator.self) private var coordinator
    @Bindable var thread: JesseThread

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
    @State private var attachError: String?

    // Every persisted outbox record; filtered per-turn below. Small (only messages
    // in flight or failed live here), and observed so a message flipping to `.failed`
    // (or being retried/discarded) re-renders the affected turn's controls live.
    @Query private var outbox: [OutboxItem]

    private var running: Bool { coordinator.isRunning(thread.id) }
    private var turns: [Turn] { thread.orderedTurns }

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
        .navigationTitle(thread.title.isEmpty ? "New conversation" : thread.title)
        .navigationBarTitleDisplayMode(.inline)
        // Hide the root TabView's bar while a conversation is open, so the tabs are
        // present on the conversation list and within Health but gone inside a
        // thread. Applying it here (on the pushed detail) means every entry point
        // that lands on a thread — deep link, Siri, notification tap — inherits it,
        // since they all converge on this view.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    thread.toggleFavorite()
                    do {
                        try context.save()
                    } catch {
                        Log.run.error("favorite toggle save failed: \(error.localizedDescription)")
                    }
                } label: {
                    Label(thread.isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: thread.isFavorite ? "star.fill" : "star")
                }
                .tint(thread.isFavorite ? .yellow : nil)
            }
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
                            StreamingPartialText(text: partial, running: running)
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

            if let attachError {
                Text(attachError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !attachments.isEmpty {
                attachmentChips
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
        // iOS 17 imperative presenters, toggled from the paperclip menu.
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: AttachmentLimits.maxCount, matching: .images)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.pdf], allowsMultipleSelection: true,
                      onCompletion: handleFileImport)
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
        if let fitted = AttachmentDownscaler.fitToCap(data, cap: AttachmentLimits.maxBytesPerFile) {
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

    private var sendDisabled: Bool {
        running || input.trimmingCharacters(in: .whitespaces).isEmpty
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

/// The live streaming reply, with its markdown parse coalesced to ~10Hz (M8). A
/// `TimelineView` clock (the same pattern `SendButton` uses) re-evaluates at the
/// renderer's interval; `MarkdownStreamRenderer` caches the parsed blocks between
/// ticks, so the O(n²) "re-parse the whole growing string on every delta" is gone.
/// The persisted Turn renders the complete text once the turn finishes.
private struct StreamingPartialText: View {
    let text: String
    let running: Bool
    @State private var renderer = MarkdownStreamRenderer()

    var body: some View {
        TimelineView(.animation(minimumInterval: MarkdownStreamRenderer.interval, paused: !running)) { context in
            MarkdownText(blocks: renderer.blocks(for: text, now: context.date))
        }
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
private struct TurnRow: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: turn.isUser ? .trailing : .leading, spacing: 2) {
            if !turn.attachments.isEmpty {
                TurnAttachmentsView(attachments: turn.orderedAttachments)
            }
            bubble
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
            // word/sentence selection within the bubble.
            SelectableText(attributed: NSAttributedString(
                string: turn.text,
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

/// The send button with the left→right fill sweep, driven by a continuous clock
/// (not a width tween) so it survives the layout shift the Cancel button causes.
struct SendButton: View {
    let running: Bool
    let startDate: Date?
    let title: String
    let disabled: Bool
    let action: () -> Void

    /// Seconds for the left→right "thinking" fill to sweep fully across, and the
    /// threshold past which the elapsed-seconds counter is shown.
    private static let fillSweepSeconds: Double = 10

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { context in
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
