import Foundation
import SwiftData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// The composer's unsent draft: where it lives, what a keystroke costs, and how a send
// takes ownership of it.
//
// ── WHY THIS IS NOT IN SWIFTDATA ─────────────────────────────────────────────────────
// It was, and typing paid for it. The draft's first shape put the text on `JesseThread`
// and wrote it on every keystroke. The write itself is cheap — 23 µs, measured — but the
// view's main `ModelContext` has autosave on, so a dirtied context saves itself on the
// run loop whatever the debounce in front of `save()` intends. Measured in the simulator,
// 200 keystrokes into a conversation produced 197 sqlite transactions, 246 ms of
// main-thread time inside `save`, and 391 extra `ThreadDetailView` body evaluations from
// the fan-out those saves triggered on every `@Query` over the container. The 250 ms
// debounce never decided anything.
//
// So the draft is not a model object. It is a small per-device file per conversation, and
// the keystroke path is one dictionary assignment on the main actor: no SwiftData
// mutation, no save, no `@Query` refetch, no file I/O. `ComposerDraftStoreTests`
// asserts that with a counting writer and `context.hasChanges`.
//
// ── WHAT THAT COSTS, STATED PLAINLY ──────────────────────────────────────────────────
// The old shape could hand a draft to a send ATOMICALLY: the save that persisted the
// outbox item was the same save that dropped the draft, so the message was never in
// neither place and never in both. Two stores cannot do that, and this one does not
// claim to. The replacement is an ORDER plus a RECONCILIATION:
//
//   1. The turn is persisted FIRST (`RunCoordinator.send` / `MacStore.send` save it).
//   2. The draft is released SECOND, and only on a `true` return — so a refused send or
//      a staging save that threw never releases anything, and the text stays on screen.
//   3. The window between them is a real one: a kill there leaves the turn on disk and
//      the draft file beside it. `ComposerDraftStaleness.isSpent` closes it on RESTORE —
//      a draft whose text is the thread's newest user turn, and which predates that turn,
//      has already been sent and is discarded rather than shown again.
//
// The exposure that remains is the one the requirement actually wants: a hard kill can
// lose the seconds since the last quiet period. Nothing is lost on navigation,
// backgrounding, a clean quit, a relaunch or a send — those flush unconditionally.

/// One file staged in a composer, as a value — the platform-neutral shape of a draft
/// attachment.
///
/// The iOS composer's own `JesseAttachment` lives in the app target and carries a
/// UI identity; this is the same bytes without it, so the shared draft layer never has to
/// know what a chip looks like.
public nonisolated struct ComposerDraftFile: Equatable, Sendable, Codable {
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
    /// `ComposerDraftStore.hasDraft`), never to what gets shown.
    public var text: String
    public var files: [ComposerDraftFile]
    /// A recording whose transcription was still running when this draft was recorded.
    /// Non-nil on restore means that run never finished (see `ComposerDraftNotice`).
    public var pendingRecording: String?
    /// The label of the screen context attached when this draft was recorded, if any.
    public var contextLabel: String?
    /// When this draft was last recorded. Nil for a draft that was never recorded. Read
    /// by `ComposerDraftStaleness` to tell a live draft from one a send already spent.
    public var updatedAt: Date?

    public init(text: String, files: [ComposerDraftFile] = [],
                pendingRecording: String? = nil, contextLabel: String? = nil,
                updatedAt: Date? = nil) {
        self.text = text
        self.files = files
        self.pendingRecording = pendingRecording
        self.contextLabel = contextLabel
        self.updatedAt = updatedAt
    }

    /// Whether there is anything here at all — used to decide whether a draft is worth
    /// inserting a not-yet-persisted conversation for.
    public var isEmpty: Bool {
        text.isEmpty && files.isEmpty && pendingRecording == nil && contextLabel == nil
    }

    /// Whether this draft is worth keeping a turn-less conversation alive for. The two
    /// one-shot markers deliberately do NOT count, exactly as they never did: a draft is
    /// text or files.
    public var isWorthKeeping: Bool { !text.isEmpty || !files.isEmpty }
}

// MARK: - Persistence

/// What one conversation's draft looks like on disk. Split from `ComposerDraftSnapshot`
/// so the attachment BYTES stay out of the json: the manifest names them, the writer puts
/// each one in its own file, and a 20 MB staged photo is never base64'd into a document
/// that gets rewritten every quiet period.
public nonisolated struct ComposerDraftRecord: Equatable, Sendable {
    public var text: String
    public var pendingRecording: String?
    public var contextLabel: String?
    public var updatedAt: Date
    public var files: [ComposerDraftFile]

    public init(text: String, pendingRecording: String? = nil, contextLabel: String? = nil,
                updatedAt: Date, files: [ComposerDraftFile] = []) {
        self.text = text
        self.pendingRecording = pendingRecording
        self.contextLabel = contextLabel
        self.updatedAt = updatedAt
        self.files = files
    }

    public var snapshot: ComposerDraftSnapshot {
        ComposerDraftSnapshot(text: text, files: files, pendingRecording: pendingRecording,
                              contextLabel: contextLabel, updatedAt: updatedAt)
    }
}

/// The store's back end. A protocol so a test can COUNT writes — which is the only way to
/// assert the thing this whole change exists for, that typing does not write anything.
///
/// Reads are synchronous and writes are not, deliberately. A composer has to be put back
/// the instant its view exists (an `await` there is a visible frame of empty field), and
/// one small file read on first appearance is nothing; a WRITE on the other hand must
/// never be on the main thread, and never on the keystroke.
public protocol ComposerDraftWriting: Sendable {
    /// Every conversation id that has something stored. Called once, at startup.
    func storedIDs() -> Set<UUID>
    /// Read one conversation's draft. Synchronous; nil when there is none.
    func load(_ id: UUID) -> ComposerDraftRecord?
    /// Write one conversation's draft. `generation` is monotonic per id; a writer that
    /// has already written a HIGHER generation for that id must drop this call, because
    /// `Task` ordering into an actor is not FIFO and a stale write would resurrect text
    /// the user has already changed or sent.
    func write(_ record: ComposerDraftRecord, for id: UUID, generation: UInt64) async
    /// Remove one conversation's draft entirely. Ordered against `write` by the SAME
    /// monotonic `generation`: a release followed by a restore (a draft put back) must not
    /// be beaten by its own delete, and a delete must not be beaten by a stale write.
    func delete(_ id: UUID, generation: UInt64) async
}

/// The on-disk writer: one directory per conversation under Application Support.
///
///     ComposerDrafts/<conversation uuid>/draft.json      text, markers, manifest
///     ComposerDrafts/<conversation uuid>/files/<n>-<name>  the staged bytes
///
/// An actor, so writes for one conversation are serialized against each other and none of
/// them is on the main thread.
public actor ComposerDraftFileWriter: ComposerDraftWriting {
    private let root: URL
    /// The highest generation written per id, so an out-of-order `Task` is dropped rather
    /// than allowed to write backwards.
    private var written: [UUID: UInt64] = [:]

    public init(root: URL = ComposerDraftFileWriter.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ComposerDrafts", isDirectory: true)
    }

    private nonisolated func directory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public nonisolated func storedIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names.compactMap(UUID.init(uuidString:)))
    }

    public nonisolated func load(_ id: UUID) -> ComposerDraftRecord? {
        let dir = directory(id)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("draft.json")),
              let doc = try? JSONDecoder().decode(StoredDraft.self, from: data)
        else { return nil }
        let files: [ComposerDraftFile] = doc.files.compactMap { entry in
            guard let bytes = try? Data(contentsOf: dir.appendingPathComponent("files",
                                                                               isDirectory: true)
                .appendingPathComponent(entry.storedName)) else { return nil }
            return ComposerDraftFile(filename: entry.filename, mime: entry.mime, data: bytes)
        }
        return ComposerDraftRecord(text: doc.text, pendingRecording: doc.pendingRecording,
                                   contextLabel: doc.contextLabel,
                                   updatedAt: doc.updatedAt, files: files)
    }

    public func write(_ record: ComposerDraftRecord, for id: UUID, generation: UInt64) async {
        guard generation > (written[id] ?? 0) else { return }
        written[id] = generation
        let dir = directory(id)
        let filesDir = dir.appendingPathComponent("files", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
            // Attachment bytes are rewritten only when the manifest changes; a keystroke
            // never reaches here at all, and a quiet-period flush that only changed the
            // text must not recopy megabytes. Compared by (name, mime, byte count), the
            // same identity `writeFiles` uses.
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: filesDir.path)) ?? []
            var entries: [StoredDraft.FileEntry] = []
            var keep: Set<String> = []
            for (offset, file) in record.files.enumerated() {
                let storedName = "\(offset)-\(file.filename.replacingOccurrences(of: "/", with: "_"))"
                keep.insert(storedName)
                let url = filesDir.appendingPathComponent(storedName)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                            as? Int) ?? nil
                if size != file.data.count {
                    try file.data.write(to: url, options: .atomic)
                }
                entries.append(StoredDraft.FileEntry(filename: file.filename, mime: file.mime,
                                                     storedName: storedName))
            }
            for stale in existing where !keep.contains(stale) {
                try? FileManager.default.removeItem(at: filesDir.appendingPathComponent(stale))
            }
            let doc = StoredDraft(text: record.text, pendingRecording: record.pendingRecording,
                                  contextLabel: record.contextLabel, updatedAt: record.updatedAt,
                                  files: entries)
            let data = try JSONEncoder().encode(doc)
            try data.write(to: dir.appendingPathComponent("draft.json"), options: .atomic)
        } catch {
            // A draft that could not be written is a draft that will be written again at
            // the next quiet period or flush point. Nothing here is worth taking the app
            // down for, and there is no user-facing action.
        }
    }

    public func delete(_ id: UUID, generation: UInt64) async {
        guard generation > (written[id] ?? 0) else { return }
        written[id] = generation
        try? FileManager.default.removeItem(at: directory(id))
    }

    private struct StoredDraft: Codable {
        struct FileEntry: Codable {
            var filename: String
            var mime: String
            var storedName: String
        }
        var text: String
        var pendingRecording: String?
        var contextLabel: String?
        var updatedAt: Date
        var files: [FileEntry]
    }
}

// MARK: - The store

/// The one place a composer's unsent draft is read and written, on both shells.
///
/// Main-actor and in-memory in front, a serialized off-main writer behind. Every method
/// here except `flush`/`flushAll`/`release`/`delete` is pure memory.
@MainActor
public final class ComposerDraftStore {

    /// The app's store. Views and the reapers use this.
    ///
    /// A `var` so a test can substitute one over a temporary directory: the reapers and the
    /// delete paths reach for `shared` by name, and pointing them at a scratch store is the
    /// only way to drive them without writing into the real Application Support directory.
    /// Nothing in the app assigns it.
    public static var shared = ComposerDraftStore()

    private let writer: ComposerDraftWriting
    /// How long after the last edit an idle draft reaches disk. A BACKSTOP, not the
    /// contract: the contract is the unconditional flush at every point the composer stops
    /// being reachable. Two seconds because losing the last couple of seconds of typing to
    /// a hard kill is acceptable and paying for durability on every keystroke is not.
    public let quietPeriod: Duration

    /// The live drafts, by conversation id. The keystroke path writes here and nowhere
    /// else.
    private var drafts: [UUID: ComposerDraftRecord] = [:]
    /// Ids whose disk copy has not been read into `drafts` yet.
    private var unloaded: Set<UUID>
    /// Ids with an unwritten change, and the monotonic stamp the writer orders by.
    private var dirty: Set<UUID> = []
    private var generation: UInt64 = 0
    /// The single in-flight quiet-period task. ONE per burst of typing, not one per
    /// keystroke: `arm` re-reads `lastEdit` when it wakes and sleeps again if the burst is
    /// still going, so a hundred characters allocate one `Task`, not a hundred.
    private var timer: Task<Void, Never>?
    private var lastEdit: ContinuousClock.Instant = .now

    /// The lifecycle observers, in a box a `nonisolated deinit` may touch: a test's own
    /// store must not leave them behind, and the deinit cannot reach main-actor state.
    private nonisolated final class LifecycleTokens: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        deinit { for t in tokens { NotificationCenter.default.removeObserver(t) } }
    }
    private nonisolated let lifecycleTokens = LifecycleTokens()

    public init(writer: ComposerDraftWriting = ComposerDraftFileWriter(),
                quietPeriod: Duration = .seconds(2),
                observesAppLifecycle: Bool = true) {
        self.writer = writer
        self.quietPeriod = quietPeriod
        self.unloaded = writer.storedIDs()
        if observesAppLifecycle { observeAppLifecycle() }
    }

    /// THE DURABILITY CONTRACT, and it lives here rather than in each shell's view so it
    /// cannot be half-wired. The quiet period is a backstop; these are the guarantee.
    /// Backgrounding, resigning active and terminating all flush unconditionally — which,
    /// with the composers' own `onDisappear` and the send path, leaves exactly one way to
    /// lose text: a hard kill inside the quiet period. That loss is accepted.
    private func observeAppLifecycle() {
        #if os(iOS)
        let names: [Notification.Name] = [UIApplication.willResignActiveNotification,
                                          UIApplication.didEnterBackgroundNotification,
                                          UIApplication.willTerminateNotification]
        #elseif os(macOS)
        let names: [Notification.Name] = [NSApplication.willResignActiveNotification,
                                          NSApplication.willTerminateNotification]
        #else
        let names: [Notification.Name] = []
        #endif
        for name in names {
            lifecycleTokens.tokens.append(
                NotificationCenter.default.addObserver(forName: name, object: nil,
                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.flushAll() }
                })
        }
    }

    /// Spelled out for the reason the rest of this module spells it out: under
    /// `defaultIsolation(MainActor.self)` an instance released off the main actor by a test
    /// host must never route through an isolated-deinit executor hop.
    nonisolated deinit {}

    // MARK: - Reading

    /// What the composer should be showing for `id`. Synchronous: reads one small file the
    /// first time a conversation is touched, then pure memory.
    public func snapshot(for id: UUID) -> ComposerDraftSnapshot {
        load(id)?.snapshot ?? ComposerDraftSnapshot(text: "")
    }

    /// Whether this conversation is holding an unsent draft worth keeping alive.
    ///
    /// Read by both shells' empty-thread reapers: a never-sent conversation with a draft is
    /// not an abandoned `+`-then-back, it is a message in progress, and reaping it would be
    /// the very loss the draft exists to prevent. A deliberately EMPTIED draft (`""`) is
    /// not worth keeping a turn-less thread alive for, so it reads false and the reaper may
    /// take the thread as it always did.
    ///
    /// Costs nothing for the overwhelming majority of conversations: an id with no stored
    /// draft is answered from a set in memory without touching the disk. That is also the
    /// fix for the reaper's old cost, which faulted `draftAttachments` for EVERY thread in
    /// the list to answer the same question.
    public func hasDraft(_ id: UUID) -> Bool {
        guard drafts[id] != nil || unloaded.contains(id) else { return false }
        return load(id)?.snapshot.isWorthKeeping ?? false
    }

    private func load(_ id: UUID) -> ComposerDraftRecord? {
        if let held = drafts[id] { return held }
        guard unloaded.remove(id) != nil else { return nil }
        guard let stored = writer.load(id) else { return nil }
        drafts[id] = stored
        return stored
    }

    // MARK: - Writing

    /// Record the composer's TEXT and its two situational markers. THE KEYSTROKE PATH.
    ///
    /// One dictionary assignment and a comparison. No model mutation, no `save`, no file
    /// I/O, no `Task` unless a quiet period is not already running. Returns whether
    /// anything actually changed.
    ///
    /// `id` is passed explicitly and is the ONLY conversation touched. That is what makes
    /// an asynchronous picker or transcription completion safe: it writes to the
    /// conversation it was started from, whatever the user is looking at now.
    @discardableResult
    public func write(text: String,
                      pendingRecording: String? = nil,
                      contextLabel: String? = nil,
                      for id: UUID,
                      now: Date = Date()) -> Bool {
        let current = load(id)
        guard current?.text != text
                || current?.pendingRecording != pendingRecording
                || current?.contextLabel != contextLabel else { return false }
        var record = current ?? ComposerDraftRecord(text: "", updatedAt: now)
        record.text = text
        record.pendingRecording = pendingRecording
        record.contextLabel = contextLabel
        record.updatedAt = now
        drafts[id] = record
        markDirty(id)
        return true
    }

    /// Record the composer's staged FILES, replacing whatever was there.
    ///
    /// Compared by (filename, mime, byte count) rather than by bytes: two staged files with
    /// the same name, type and length are the same file for this purpose, and hashing
    /// megabytes on every composer render to prove it would cost more than the write it
    /// saves. Files change on a picker, never on a keystroke.
    @discardableResult
    public func writeFiles(_ files: [ComposerDraftFile], for id: UUID,
                           now: Date = Date()) -> Bool {
        let current = load(id)
        let existing = current?.files ?? []
        let unchanged = existing.count == files.count
            && zip(existing, files).allSatisfy {
                $0.filename == $1.filename && $0.mime == $1.mime
                    && $0.data.count == $1.data.count
            }
        if unchanged { return false }
        var record = current ?? ComposerDraftRecord(text: "", updatedAt: now)
        record.files = files
        record.updatedAt = now
        drafts[id] = record
        markDirty(id)
        return true
    }

    /// Report and clear the two one-shot markers, so a notice is shown once and not on
    /// every subsequent appearance.
    public func clearNotices(for id: UUID) {
        guard var record = load(id),
              record.pendingRecording != nil || record.contextLabel != nil else { return }
        record.pendingRecording = nil
        record.contextLabel = nil
        drafts[id] = record
        markDirty(id)
    }

    // MARK: - The send handoff

    /// Give up the draft because its message has been persisted.
    ///
    /// Called AFTER the turn is on disk and only on a successful stage — which is the
    /// whole of the ordering rule this file's header states. Returns what was released so
    /// a caller can put it back, though with the release moved after the save there is no
    /// longer a failure path that needs to.
    @discardableResult
    public func release(for id: UUID) -> ComposerDraftSnapshot {
        let released = snapshot(for: id)
        drafts[id] = nil
        unloaded.remove(id)
        dirty.remove(id)
        scheduleDelete(id)
        return released
    }

    /// Put a released draft back. In memory; the next flush persists it.
    public func restore(_ released: ComposerDraftSnapshot, for id: UUID,
                        now: Date = Date()) {
        guard !released.isEmpty else { return }
        drafts[id] = ComposerDraftRecord(text: released.text,
                                         pendingRecording: released.pendingRecording,
                                         contextLabel: released.contextLabel,
                                         updatedAt: now,
                                         files: released.files)
        markDirty(id)
    }

    /// Forget a conversation's draft because the conversation itself is gone.
    public func delete(_ id: UUID) {
        drafts[id] = nil
        unloaded.remove(id)
        dirty.remove(id)
        scheduleDelete(id)
    }

    private func scheduleDelete(_ id: UUID) {
        generation &+= 1
        let stamp = generation
        let writer = self.writer
        Task { await writer.delete(id, generation: stamp) }
    }

    /// Drop stored drafts for conversations that no longer exist. The backstop for a
    /// delete this store never saw — a cross-device delete, or one on a path that forgot
    /// to call `delete`. Run once at launch.
    public func sweep(keeping live: Set<UUID>) {
        for id in unloaded.union(drafts.keys) where !live.contains(id) {
            delete(id)
        }
    }

    // MARK: - Flushing

    /// Persist one conversation's draft NOW, if it has unwritten changes.
    ///
    /// Called at every point the composer stops being reachable — the view disappearing,
    /// the scene leaving the foreground, and a send — which is where the durability
    /// guarantee actually comes from. The quiet period is only a backstop.
    public func flush(_ id: UUID) {
        guard dirty.remove(id) != nil, let record = drafts[id] else { return }
        generation &+= 1
        let stamp = generation
        let writer = self.writer
        Task { await writer.write(record, for: id, generation: stamp) }
    }

    /// Persist every unwritten draft. The scene-phase and termination hook.
    public func flushAll() {
        timer?.cancel()
        timer = nil
        flushDirty()
    }

    /// Whether anything is waiting to reach disk. Tests read it; nothing else needs to.
    public var hasUnwrittenChanges: Bool { !dirty.isEmpty }

    private func flushDirty() {
        for id in dirty {
            guard let record = drafts[id] else { continue }
            generation &+= 1
            let stamp = generation
            let writer = self.writer
            Task { await writer.write(record, for: id, generation: stamp) }
        }
        dirty.removeAll()
    }

    private func markDirty(_ id: UUID) {
        dirty.insert(id)
        lastEdit = .now
        // One task per BURST. An already-running quiet period re-reads `lastEdit` when it
        // wakes and goes back to sleep, so typing allocates nothing after the first
        // character.
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while let live = self {
                let due = live.lastEdit.advanced(by: live.quietPeriod)
                if ContinuousClock.now >= due { break }
                try? await Task.sleep(until: due, clock: .continuous)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.timer = nil
            self.flushDirty()
        }
    }
}

// MARK: - A draft a send already spent

/// The reconciliation that replaces the old one-save atomicity.
///
/// With the turn and the draft in two stores, a kill between "the turn is saved" and "the
/// draft is deleted" leaves both on disk, and the composer would put the sent message back
/// as if it were unsent. So a restore DISCARDS a draft that is already a turn: same text,
/// and recorded no later than the turn that carries it.
///
/// Both halves are load-bearing. Text alone would eat a genuine "send it again" the user
/// retyped; the timestamp alone would eat any draft on a thread that had ever been sent to.
public nonisolated enum ComposerDraftStaleness {

    /// Whether `snapshot` is a draft whose message has already gone.
    ///
    /// - `newestUserTurn`: the visible text and creation date of the thread's newest user
    ///   turn (`Turn.visibleText` — the user's OWN half, which is what the draft held; the
    ///   turn's `text` may additionally carry a screen context the composer never showed).
    public static func isSpent(_ snapshot: ComposerDraftSnapshot,
                               newestUserTurn: (text: String, createdAt: Date)?) -> Bool {
        guard let turn = newestUserTurn, let recorded = snapshot.updatedAt else { return false }
        guard !snapshot.files.isEmpty || !snapshot.text.isEmpty else { return false }
        let typed = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed == turn.text else { return false }
        return recorded <= turn.createdAt
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
