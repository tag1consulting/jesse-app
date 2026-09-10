import Foundation
import SwiftData

// The composer's unsent draft: where it is written, how it is read back, and how a send
// takes ownership of it.
//
// ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────
// Both composers held their text in view `@State` alone. That loses it twice over, and
// neither loss is a race: navigating away DESTROYS the view (both shells put
// `.id(thread.id)` on the detail column, and the iPhone pops the stack entirely), and
// process termination takes view state regardless. The durable half was simply missing.
//
// ── THE ONE PLACE ────────────────────────────────────────────────────────────────────
// Every write and every read goes through this file, on both platforms, so the phone and
// the Mac cannot grow two ideas of what a draft is or when it is spent. The composers
// keep their view state — a text view has to bind to something — but the view state is
// now a MIRROR of this, restored from it on appearance and written through to it on every
// edit.
//
// ── WHAT IT DELIBERATELY DOES NOT DO ─────────────────────────────────────────────────
// It does not save. `write` mutates the model and nothing else; the caller decides when
// the change reaches disk (`ComposerDraftAutosave` for an edit, the send's own staging
// save for a release). That split is the whole reason a send can hand ownership over
// ATOMICALLY: the save that persists the outbox item is the same save that drops the
// draft, so there is no instant in which a message exists in neither place, and none in
// which it exists in both.

/// One file staged in a composer, as a value — the platform-neutral shape of a draft
/// attachment.
///
/// The iOS composer's own `JesseAttachment` lives in the app target and carries a
/// UI identity; this is the same bytes without it, so the shared draft layer never has to
/// know what a chip looks like.
public nonisolated struct ComposerDraftFile: Equatable, Sendable {
    public var filename: String
    public var mime: String
    public var data: Data

    public init(filename: String, mime: String, data: Data) {
        self.filename = filename
        self.mime = mime
        self.data = data
    }
}

/// Everything a composer needs to put itself back the way the user left it.
public nonisolated struct ComposerDraftSnapshot: Equatable, Sendable {
    /// The unsent text, byte-for-byte as it was recorded: newlines, Unicode and
    /// whitespace all preserved. Empty for a composer the user deliberately emptied AND
    /// for one that never had a draft — the difference matters to the reaper (see
    /// `JesseThread.hasComposerDraft`), never to what gets shown.
    public var text: String
    public var files: [ComposerDraftFile]
    /// A recording whose transcription was still running when this draft was recorded.
    /// Non-nil on restore means that run never finished (see `ComposerDraftNotice`).
    public var pendingRecording: String?
    /// The label of the screen context attached when this draft was recorded, if any.
    public var contextLabel: String?

    public init(text: String, files: [ComposerDraftFile] = [],
                pendingRecording: String? = nil, contextLabel: String? = nil) {
        self.text = text
        self.files = files
        self.pendingRecording = pendingRecording
        self.contextLabel = contextLabel
    }

    /// Whether there is anything here at all — used to decide whether a draft is worth
    /// inserting a not-yet-persisted conversation for.
    public var isEmpty: Bool {
        text.isEmpty && files.isEmpty && pendingRecording == nil && contextLabel == nil
    }
}

public enum ComposerDraft {

    // MARK: - Reading

    /// What the composer should be showing for `thread`.
    public static func snapshot(of thread: JesseThread) -> ComposerDraftSnapshot {
        ComposerDraftSnapshot(
            text: thread.draftText ?? "",
            files: thread.orderedDraftAttachments.map {
                ComposerDraftFile(filename: $0.filename, mime: $0.mime, data: $0.data)
            },
            pendingRecording: thread.draftPendingRecording,
            contextLabel: thread.draftContextLabel)
    }

    // MARK: - Writing

    /// Record the composer's TEXT and its two situational markers. In memory only.
    ///
    /// This is the per-keystroke path, so it does exactly three attribute writes and no
    /// byte comparison; `writeFiles` handles the attachments, which change far less often
    /// and cost far more to compare. Returns whether anything actually changed, so a
    /// caller can skip arming a save for an edit that was not one.
    ///
    /// A conversation that is NOT YET IN THE STORE (a staged Health ask or Today
    /// discussion, which are deliberately not inserted until their first send) is inserted
    /// here the moment there is a draft to keep — typing into it is the intent that a bare
    /// `+`-then-back was not. It stays uninserted for an empty draft, so an abandoned
    /// staged thread still costs nothing.
    ///
    /// `thread` is passed explicitly and is the ONLY thread touched. That is what makes an
    /// asynchronous picker or transcription completion safe: it writes to the conversation
    /// it was started from, whatever the user is looking at now.
    @discardableResult
    public static func write(text: String,
                             pendingRecording: String? = nil,
                             contextLabel: String? = nil,
                             to thread: JesseThread,
                             in context: ModelContext,
                             now: Date = Date()) -> Bool {
        guard thread.draftText != text
                || thread.draftPendingRecording != pendingRecording
                || thread.draftContextLabel != contextLabel else { return false }
        guard insertIfNeeded(thread, in: context,
                             hasSomethingToKeep: !text.isEmpty || pendingRecording != nil
                                                    || contextLabel != nil
                                                    || !thread.draftAttachments.isEmpty)
        else { return false }
        thread.draftText = text
        thread.draftPendingRecording = pendingRecording
        thread.draftContextLabel = contextLabel
        thread.draftUpdatedAt = now
        return true
    }

    /// Record the composer's staged FILES, replacing whatever was there. In memory only.
    ///
    /// Compared by (filename, mime, byte count) rather than by bytes: two staged files with
    /// the same name, type and length are the same file for this purpose, and hashing
    /// megabytes on every composer render to prove it would cost more than the write it
    /// saves.
    @discardableResult
    public static func writeFiles(_ files: [ComposerDraftFile],
                                  to thread: JesseThread,
                                  in context: ModelContext,
                                  now: Date = Date()) -> Bool {
        let existing = thread.orderedDraftAttachments
        let unchanged = existing.count == files.count
            && zip(existing, files).allSatisfy {
                $0.filename == $1.filename && $0.mime == $1.mime
                    && $0.data.count == $1.data.count
            }
        if unchanged { return false }
        guard insertIfNeeded(thread, in: context,
                             hasSomethingToKeep: !files.isEmpty
                                                    || !(thread.draftText ?? "").isEmpty)
        else { return false }
        for row in existing { context.delete(row) }
        thread.draftAttachments = []
        // A monotonic stamp per file so `orderedDraftAttachments` reproduces the composer's
        // order. `Date()` alone can repeat inside one call at the clock's resolution.
        for (offset, file) in files.enumerated() {
            let row = DraftAttachment(filename: file.filename, mime: file.mime, data: file.data,
                                      createdAt: now.addingTimeInterval(Double(offset) / 1000))
            row.thread = thread
            context.insert(row)
            thread.draftAttachments.append(row)
        }
        thread.draftUpdatedAt = now
        return true
    }

    /// Report and clear the two one-shot markers, so a notice is shown once and not on
    /// every subsequent appearance. In memory only.
    public static func clearNotices(on thread: JesseThread) {
        thread.draftPendingRecording = nil
        thread.draftContextLabel = nil
    }

    // MARK: - The send handoff

    /// Give up the draft because its message has been staged. In memory only — and that is
    /// the point: the CALLER calls this inside the same `save` that persists the outbox
    /// item (iOS) or the optimistic user turn (macOS), so the message is never in neither
    /// place and never in both.
    ///
    /// Returns what was released, so a staging save that THROWS can put it straight back
    /// (`restore`) instead of the user watching their message disappear into a failure.
    /// Unconditional: it does not compare the draft with the text being sent, because a
    /// send does not have to come from the composer's current contents (an opening starter
    /// is written and sent in one main-actor turn, before any edit is recorded).
    @discardableResult
    public static func release(from thread: JesseThread,
                               in context: ModelContext) -> ComposerDraftSnapshot {
        let released = snapshot(of: thread)
        for row in thread.draftAttachments { context.delete(row) }
        thread.draftAttachments = []
        thread.draftText = nil
        thread.draftUpdatedAt = nil
        thread.draftPendingRecording = nil
        thread.draftContextLabel = nil
        return released
    }

    /// Put a released draft back after a staging save failed. In memory only; the caller's
    /// next save persists it.
    public static func restore(_ released: ComposerDraftSnapshot,
                               to thread: JesseThread,
                               in context: ModelContext,
                               now: Date = Date()) {
        guard !released.isEmpty else { return }
        thread.draftText = released.text
        thread.draftPendingRecording = released.pendingRecording
        thread.draftContextLabel = released.contextLabel
        thread.draftUpdatedAt = now
        writeFiles(released.files, to: thread, in: context, now: now)
    }

    // MARK: - Private

    /// Ensure `thread` is in the store when there is a draft worth keeping. Returns false
    /// only when there is nothing to keep AND nowhere to keep it, which is the one case a
    /// write may skip entirely.
    private static func insertIfNeeded(_ thread: JesseThread, in context: ModelContext,
                                       hasSomethingToKeep: Bool) -> Bool {
        if thread.modelContext != nil { return true }
        guard hasSomethingToKeep else { return false }
        context.insert(thread)
        return true
    }
}

/// The sentence a restored composer shows when something that WAS part of the pending
/// message is not coming back with it.
///
/// Both cases are the same shape of honesty: the text is restored, and the thing that is
/// gone is NAMED, because a draft that quietly turns into a different message is worse
/// than one that says what it lost.
public nonisolated enum ComposerDraftNotice {

    /// The notice for a restored `snapshot`, or nil when nothing was lost.
    ///
    /// - `contextStillAttached`: whether the coordinator still holds the screen context
    ///   this conversation was opened with. Attached context lives in memory and dies with
    ///   the process, so a draft recorded against one and restored after a relaunch would
    ///   otherwise send as a bare message on a conversation whose entire subject was the
    ///   reading it was opened about.
    public static func message(for snapshot: ComposerDraftSnapshot,
                               contextStillAttached: Bool) -> String? {
        var parts: [String] = []
        if let name = snapshot.pendingRecording, !name.isEmpty {
            parts.append(
                "“\(name)” was still being transcribed when you left this conversation. "
                + "Its audio has already been deleted, so the transcript isn’t coming — "
                + "attach the recording again to read it.")
        }
        if let label = snapshot.contextLabel, !label.isEmpty, !contextStillAttached {
            parts.append(
                "\(label) is no longer attached, so this message will be sent on its own.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The debounce in front of `ModelContext.save()`.
///
/// Every edit is written into the model IMMEDIATELY (see `ComposerDraft.write`) — that is
/// in-memory and costs nothing — but a sqlite transaction per keystroke is not what a
/// composer should feel like. So the disk write trails the last keystroke by a quiet
/// period, and the pending window is closed EXPLICITLY at every point where the draft is
/// about to stop being reachable: the composer disappearing, the scene leaving the
/// foreground, and the send that spends it.
///
/// It is deliberately not the only durability mechanism. The quiet period is short, the
/// SwiftUI main context autosaves on its own besides, and the model-side write has already
/// happened — so the exposure is bounded by `quietPeriod` and only for a kill that lands
/// inside it.
@MainActor
public final class ComposerDraftAutosave {
    /// How long after the last edit the save fires. Injectable so a test does not have to
    /// wait out a human-scale debounce to prove the trailing write happens.
    public let quietPeriod: Duration

    private var timer: Task<Void, Never>?
    private var commit: (@MainActor () -> Void)?

    public init(quietPeriod: Duration = .milliseconds(250)) {
        self.quietPeriod = quietPeriod
    }

    /// Whether a write is waiting to reach disk.
    public var isArmed: Bool { commit != nil }

    /// (Re)arm the trailing save. Called on every edit; the newest `commit` wins, so a
    /// burst of typing produces one save after the burst rather than one per character.
    public func arm(_ commit: @escaping @MainActor () -> Void) {
        self.commit = commit
        timer?.cancel()
        timer = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.quietPeriod)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    /// Run an armed save NOW and disarm. A no-op when nothing is armed, so it is safe to
    /// call from every lifecycle hook that might be the last one.
    public func flush() {
        timer?.cancel()
        timer = nil
        let pending = commit
        commit = nil
        pending?()
    }

    /// Forget an armed save without running it. Used at the one moment a pending draft
    /// write must NOT land: a send whose own staging save has already persisted the whole
    /// context, draft release included.
    public func disarm() {
        timer?.cancel()
        timer = nil
        commit = nil
    }

    /// Spelled out for the reason the rest of this module spells it out: under
    /// `defaultIsolation(MainActor.self)` an instance released off the main actor by a test
    /// host must never route through an isolated-deinit executor hop. The timer holds
    /// `self` weakly, so a dropped autosaver leaves nothing running.
    nonisolated deinit {}
}
