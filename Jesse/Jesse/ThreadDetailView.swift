import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// One conversation: the full turn transcript with the composer pinned at the
// bottom. Being inside a thread *is* continuing it — every send auto-resumes the
// thread's session, so there's no "Continue thread" toggle anymore.
struct ThreadDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(RunCoordinator.self) private var coordinator
    @Bindable var thread: JesseThread

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    // Attachments staged for the next send, plus the pickers' presentation state.
    @State private var attachments: [JesseAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var attachError: String?

    private var running: Bool { coordinator.isRunning(thread.id) }
    private var turns: [Turn] { thread.orderedTurns }

    // Auto-scroll follows the newest text only while the user is parked at the
    // bottom. Scrolling up (even mid-stream) suppresses follow and reveals the
    // "jump to latest" button; the follow decision itself lives in the pure,
    // unit-tested `TranscriptScroll` helper.
    @State private var isAtBottom = true

    var body: some View {
        VStack(spacing: 12) {
            transcript
            composer
        }
        .padding()
        .navigationTitle(thread.title.isEmpty ? "New conversation" : thread.title)
        .navigationBarTitleDisplayMode(.inline)
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
                        TurnRow(turn: turn)
                            .id(turn.id)
                    }
                    // Live, streaming reply: the partial text as it arrives, plus
                    // a coarse activity line under the spinner. Cleared and
                    // replaced by the persisted Turn the instant the turn finishes.
                    if running {
                        let partial = coordinator.partialText(for: thread.id) ?? ""
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

            TextField(thread.modeValue == .ask ? "Ask Jesse anything…"
                                                : "Tell Jesse something…",
                      text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($inputFocused)

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

    /// Sniff the type, name it, run the client-side caps, and stage it — or set
    /// `attachError`. The bridge re-validates all of this as the authority.
    private func addAttachment(data: Data, fallbackName: String, suggestedName: String? = nil) {
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

/// One message bubble. User turns sit right with a tinted fill; Jesse's replies
/// render as Markdown on the left.
private struct TurnRow: View {
    let turn: Turn

    var body: some View {
        bubble
            // Long-press any message to copy or share it. Copies the *raw*
            // Markdown (`turn.text`), not the rendered text, so links and
            // formatting are preserved.
            .contextMenu {
                Button {
                    UIPasteboard.general.string = turn.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                ShareLink(item: turn.text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
    }

    @ViewBuilder private var bubble: some View {
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
