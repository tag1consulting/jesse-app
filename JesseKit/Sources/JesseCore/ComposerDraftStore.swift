import Foundation
import SwiftData

// The composer's unsent draft: what it is, when it is written, and what a keystroke costs.
//
// ── NOTHING REACTS TO TYPING ─────────────────────────────────────────────────────────
// While a composer is on screen, its own `@State` IS the draft. No keystroke touches
// anything else in the app: not this store, not a `ModelContext`, not a file, not a
// `Task`. There is no per-character hook to be cheap about, because there is no
// per-character hook.
//
// The draft is captured at DEPARTURES, and there are four: the chat view disappearing,
// the app leaving the foreground, termination, and send. Each capture updates one
// dictionary and writes it, once, off the main thread. Those are human-scale events — a
// few dozen a day — so there is no debounce, no quiet period, no timer, no dirty set and
// no generation counter here to go wrong.
//
// Two everyday things this has to survive, and it is shaped by both:
//
//   1. Switching conversations to go and read something earlier, then coming back. Every
//      conversation typed into holds its own text, several at a time — that is the
//      DICTIONARY, and a switch costs one `onDisappear` capture.
//   2. Leaving the app and coming back much later, to a process the system has reclaimed.
//      A cold launch has to put the drafts back — that is the FILE, read once at launch
//      before any composer can appear.
//
// ── WHAT IS DELIBERATELY LOST ────────────────────────────────────────────────────────
// Two things, both stated in the CHANGELOG rather than hidden here:
//
//   * A kill that runs NO CODE (a crash; Force Quit on the Mac with the window frontmost)
//     loses whatever was typed since the last departure. On the phone that window is
//     effectively zero, because reaching the app switcher backgrounds the app first. An
//     ORDINARY quit is not in this category: the termination capture writes on the calling
//     thread, precisely because an async write there may never get a turn.
//   * Staged FILES are held in the dictionary and never written to disk, so they survive a
//     switch between conversations and do not survive a cold launch. A draft that comes
//     back without them SAYS SO, the way the recording and context notices already do.
//
// ── WHY NOT SWIFTDATA (still true, and the reason 131 existed) ───────────────────────
// The draft's first shape put the text on `JesseThread` and wrote it on every keystroke.
// The write itself was cheap — 23 µs — but the view's main `ModelContext` has autosave on,
// so a dirtied context saves itself on the run loop whatever any debounce intends: 200
// keystrokes produced 197 sqlite transactions and 391 extra body evaluations from the
// `@Query` fan-out. The draft is therefore not a model object, and now it is not even a
// per-keystroke dictionary assignment.
//
// ── THE SEND HANDOFF ─────────────────────────────────────────────────────────────────
// The draft and the turn live in two stores, so a send cannot be one atomic save. The
// replacement is an ORDER plus a RECONCILIATION: the turn is persisted FIRST, the draft is
// released SECOND and only on a `true` return, and on restore `ComposerDraftStaleness`
// discards a draft that is already the thread's newest user turn. A refused send or a
// staging save that threw releases nothing and leaves the text on screen.

/// One file staged in a composer, as a value — the platform-neutral shape of a draft
/// attachment.
///
/// The iOS composer's own `JesseAttachment` lives in the app target and carries a UI
/// identity; this is the same bytes without it, so the shared draft layer never has to
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

/// A composer's current state, as the thing a departure hands over.
///
/// Every departure on both shells builds one of these and passes it to
/// `ComposerDrafts.capture`. It is the whole contract between a view and this layer: a
/// shell that has different values to hand converts them into this and calls that one
/// function — it never reaches past it to mutate the dictionary or write the file.
public nonisolated struct ComposerDraftCapture: Equatable, Sendable {
    /// The unsent text, byte-for-byte as the composer holds it.
    public var text: String
    /// The staged files. Held in memory only; see the header.
    public var files: [ComposerDraftFile]
    /// A recording whose transcription is still running as the composer is left.
    public var pendingRecording: String?
    /// The label of the screen context attached to this conversation, if any.
    public var contextLabel: String?

    public init(text: String, files: [ComposerDraftFile] = [],
                pendingRecording: String? = nil, contextLabel: String? = nil) {
        self.text = text
        self.files = files
        self.pendingRecording = pendingRecording
        self.contextLabel = contextLabel
    }

    /// Whether there is anything here at all — what decides whether a never-saved
    /// conversation is worth inserting for.
    public var isEmpty: Bool {
        text.isEmpty && files.isEmpty && pendingRecording == nil && contextLabel == nil
    }
}

/// Everything a composer needs to put itself back the way the user left it.
public nonisolated struct ComposerDraftSnapshot: Equatable, Sendable {
    /// The unsent text, byte-for-byte as it was recorded: newlines, Unicode and whitespace
    /// all preserved. Empty for a composer the user deliberately emptied AND for one that
    /// never had a draft — the difference matters to the reaper (see
    /// `ComposerDraftStore.hasDraft`), never to what gets shown.
    public var text: String
    public var files: [ComposerDraftFile]
    /// A recording whose transcription was still running when this draft was captured.
    /// Non-nil on restore means that run never finished (see `ComposerDraftNotice`).
    public var pendingRecording: String?
    /// The label of the screen context attached when this draft was captured, if any.
    public var contextLabel: String?
    /// When this draft was last captured. Nil for a draft that was never captured. Read by
    /// `ComposerDraftStaleness` to tell a live draft from one a send already spent.
    public var updatedAt: Date?
    /// How many staged files this draft HAD and does not have now — the count that was
    /// captured, less what is still in memory. Non-zero after a cold launch (files are
    /// never written to disk) or an eviction, and what `ComposerDraftNotice` names.
    public var lostFiles: Int

    public init(text: String, files: [ComposerDraftFile] = [],
                pendingRecording: String? = nil, contextLabel: String? = nil,
                updatedAt: Date? = nil, lostFiles: Int = 0) {
        self.text = text
        self.files = files
        self.pendingRecording = pendingRecording
        self.contextLabel = contextLabel
        self.updatedAt = updatedAt
        self.lostFiles = lostFiles
    }

    public var isEmpty: Bool {
        text.isEmpty && files.isEmpty && pendingRecording == nil && contextLabel == nil
    }

    /// Whether this draft is worth keeping a turn-less conversation alive for. The two
    /// one-shot markers deliberately do NOT count: a draft is text or files.
    public var isWorthKeeping: Bool { !text.isEmpty || !files.isEmpty }
}

/// One conversation's draft as the dictionary holds it: everything, files included.
public nonisolated struct ComposerDraftRecord: Equatable, Sendable {
    public var text: String
    public var pendingRecording: String?
    public var contextLabel: String?
    public var updatedAt: Date
    public var files: [ComposerDraftFile]
    /// How many files were staged when this draft was captured. Survives the trip to disk
    /// even though the bytes do not, so a restored composer can SAY what is missing
    /// instead of quietly turning into a different message.
    public var stagedFileCount: Int

    public init(text: String, pendingRecording: String? = nil, contextLabel: String? = nil,
                updatedAt: Date, files: [ComposerDraftFile] = [],
                stagedFileCount: Int? = nil) {
        self.text = text
        self.pendingRecording = pendingRecording
        self.contextLabel = contextLabel
        self.updatedAt = updatedAt
        self.files = files
        self.stagedFileCount = stagedFileCount ?? files.count
    }

    public var snapshot: ComposerDraftSnapshot {
        ComposerDraftSnapshot(text: text, files: files, pendingRecording: pendingRecording,
                              contextLabel: contextLabel, updatedAt: updatedAt,
                              lostFiles: max(0, stagedFileCount - files.count))
    }

    /// How much of the in-memory budget this record is using.
    var retainedBytes: Int {
        text.utf8.count + files.reduce(0) { $0 + $1.data.count }
    }
}

// MARK: - Persistence

/// One conversation's draft as DISK holds it: the same thing without the bytes.
///
/// Staged files are deliberately absent. Writing them would mean recopying a 20 MB photo
/// at every departure, for a case — a cold launch with an unsent photo attached — that the
/// composer can honestly report instead of silently paying for.
public nonisolated struct ComposerDraftPersisted: Equatable, Sendable, Codable {
    public var text: String
    public var pendingRecording: String?
    public var contextLabel: String?
    public var updatedAt: Date
    /// How many files were staged. The COUNT crosses to disk even though the bytes do not,
    /// so a cold-launched composer can name what is missing.
    public var stagedFileCount: Int

    public init(text: String, pendingRecording: String? = nil, contextLabel: String? = nil,
                updatedAt: Date, stagedFileCount: Int = 0) {
        self.text = text
        self.pendingRecording = pendingRecording
        self.contextLabel = contextLabel
        self.updatedAt = updatedAt
        self.stagedFileCount = stagedFileCount
    }

    // Hand-written so a document missing a key decodes rather than taking EVERY draft in
    // the file down with it. The map is one document: a throw here is total loss.
    private enum CodingKeys: String, CodingKey {
        case text, pendingRecording, contextLabel, updatedAt, stagedFileCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        pendingRecording = try c.decodeIfPresent(String.self, forKey: .pendingRecording)
        contextLabel = try c.decodeIfPresent(String.self, forKey: .contextLabel)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        stagedFileCount = try c.decodeIfPresent(Int.self, forKey: .stagedFileCount) ?? 0
    }
}

/// The store's back end, and the only thing in the app that knows the draft file's format
/// or its path.
///
/// A protocol so a test can COUNT writes — which is how the two claims this change exists
/// for are asserted at all: that typing writes nothing, and that every departure path on
/// both shells routes through this one door.
///
/// `load` is synchronous and `write` is not, deliberately. The map has to be in hand
/// before any composer can appear (an `await` there is a visible frame of empty field),
/// and it is one small text-only document; a WRITE on the other hand must never be on the
/// main thread.
public protocol ComposerDraftWriting: Sendable {
    /// Every stored draft, read once at launch.
    func load() -> [UUID: ComposerDraftPersisted]
    /// Replace the stored map with this one. Called only by `ComposerDraftStore.persist`.
    func write(_ map: [UUID: ComposerDraftPersisted]) async
    /// The same write, on the CALLING thread, for termination and nothing else.
    ///
    /// A quit is the one departure where an asynchronous write may never get a turn: the
    /// handler returns and the process is gone. Everywhere else the main thread must not
    /// be made to wait on a file, so everywhere else uses `write`.
    func writeNow(_ map: [UUID: ComposerDraftPersisted])
}

/// The on-disk writer: ONE file under Application Support holding every conversation's
/// draft text.
///
///     ComposerDrafts.json     { "<conversation uuid>": { text, markers, updatedAt } }
///
/// An actor, so the write is off the main thread and one write cannot interleave with
/// another. It holds no schedule and no state beyond its own path: it writes the map it is
/// handed.
public actor ComposerDraftFileWriter: ComposerDraftWriting {
    private let file: URL
    /// The 131-and-earlier shape, adopted and removed once. See `load`.
    private let legacyDirectory: URL

    public init(root: URL = ComposerDraftFileWriter.defaultRoot) {
        self.file = root.appendingPathComponent("ComposerDrafts.json")
        self.legacyDirectory = root.appendingPathComponent("ComposerDrafts", isDirectory: true)
    }

    public static var defaultRoot: URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }

    public nonisolated func load() -> [UUID: ComposerDraftPersisted] {
        var map: [UUID: ComposerDraftPersisted] = [:]
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: ComposerDraftPersisted].self,
                                                  from: data) {
            for (key, value) in stored {
                guard let id = UUID(uuidString: key) else { continue }
                map[id] = value
            }
        }
        adoptLegacyDrafts(into: &map)
        return map
    }

    /// Take over what 131's per-conversation directories are still holding, then delete
    /// them.
    ///
    /// 131 wrote `ComposerDrafts/<uuid>/draft.json` plus a `files/` directory beside it.
    /// Upgrading without this would both lose a draft in progress and leave those
    /// directories on disk forever. A one-shot in practice: it removes the tree, so the
    /// second launch finds nothing and the directory listing costs one failed `stat`.
    /// The attachment bytes are NOT adopted — nothing writes them any more.
    private nonisolated func adoptLegacyDrafts(into map: inout [UUID: ComposerDraftPersisted]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: legacyDirectory.path))
        guard let names, !names.isEmpty else {
            try? FileManager.default.removeItem(at: legacyDirectory)
            return
        }
        for name in names {
            guard let id = UUID(uuidString: name), map[id] == nil else { continue }
            let url = legacyDirectory.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("draft.json")
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(LegacyDraft.self, from: data)
            else { continue }
            map[id] = ComposerDraftPersisted(text: doc.text,
                                             pendingRecording: doc.pendingRecording,
                                             contextLabel: doc.contextLabel,
                                             updatedAt: doc.updatedAt,
                                             stagedFileCount: doc.files.count)
        }
        try? FileManager.default.removeItem(at: legacyDirectory)
    }

    public func write(_ map: [UUID: ComposerDraftPersisted]) async {
        Self.encode(map, to: file)
    }

    public nonisolated func writeNow(_ map: [UUID: ComposerDraftPersisted]) {
        Self.encode(map, to: file)
    }

    /// The write itself, written once and reached from both doors above.
    private nonisolated static func encode(_ map: [UUID: ComposerDraftPersisted],
                                           to file: URL) {
        do {
            guard !map.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            var stored: [String: ComposerDraftPersisted] = [:]
            for (id, record) in map { stored[id.uuidString] = record }
            try JSONEncoder().encode(stored).write(to: file, options: .atomic)
        } catch {
            // A draft that could not be written is a draft that will be written again at
            // the next departure. Nothing here is worth taking the app down for, and there
            // is no user-facing action.
        }
    }

    /// 131's per-conversation document, read once on the way out.
    private struct LegacyDraft: Codable {
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

/// The drafts, as one dictionary on the main actor with one file behind it.
///
/// A plain class and NOT `@Observable`: nothing observes it. A composer reads it once on
/// appear and writes it once per departure, so an observation relationship would only buy
/// body evaluations nobody asked for.
@MainActor
public final class ComposerDraftStore {

    /// The app's store. Views, the migration and the reapers use this.
    ///
    /// A `var` so a test can substitute one over a temporary directory: the reapers and the
    /// delete paths reach for `shared` by name, and pointing them at a scratch store is the
    /// only way to drive them without writing into the real Application Support directory.
    /// Nothing in the app assigns it.
    public static var shared = ComposerDraftStore()

    /// How many bytes of draft may be held in memory at once, across every conversation.
    /// Three conversations' worth of a full 20 MB attachment set, which is far more than
    /// anyone stages and still bounded.
    public nonisolated static let defaultByteCap = 64 * 1024 * 1024

    private let writer: ComposerDraftWriting
    private let byteCap: Int

    /// The live drafts, by conversation id. One entry per conversation, any number at once.
    private var drafts: [UUID: ComposerDraftRecord]

    /// The write in flight, so the next one can be chained behind it. NOT a schedule and
    /// not a dirty set: it exists only so two departures a microsecond apart reach disk in
    /// the order they happened, without a generation counter to keep in step.
    private var writeTask: Task<Void, Never>?
    /// Set by the terminating write. After it, nothing else reaches disk — the process is
    /// on its way out and that map is the last word.
    private var terminated = false

    /// Reads the stored map ONCE, synchronously, so every draft is in hand before any
    /// composer can appear.
    public init(writer: ComposerDraftWriting = ComposerDraftFileWriter(),
                byteCap: Int = ComposerDraftStore.defaultByteCap) {
        self.writer = writer
        self.byteCap = byteCap
        self.drafts = writer.load().mapValues {
            // Files are not on disk, and `stagedFileCount` is how the composer knows to
            // say so rather than silently coming back as a different message.
            ComposerDraftRecord(text: $0.text, pendingRecording: $0.pendingRecording,
                                contextLabel: $0.contextLabel, updatedAt: $0.updatedAt,
                                files: [], stagedFileCount: $0.stagedFileCount)
        }
    }

    /// Spelled out for the reason the rest of this module spells it out: under
    /// `defaultIsolation(MainActor.self)` an instance released off the main actor by a test
    /// host must never route through an isolated-deinit executor hop.
    nonisolated deinit {}

    // MARK: - Reading

    /// What the composer should be showing for `id`. Pure memory.
    public func snapshot(for id: UUID) -> ComposerDraftSnapshot {
        drafts[id]?.snapshot ?? ComposerDraftSnapshot(text: "")
    }

    /// Whether this conversation is holding an unsent draft worth keeping alive.
    ///
    /// Read by both shells' empty-thread reapers: a never-sent conversation with a draft is
    /// not an abandoned `+`-then-back, it is a message in progress, and reaping it would be
    /// the very loss the draft exists to prevent. A deliberately EMPTIED draft (`""`) is
    /// not worth keeping a turn-less thread alive for, so it reads false and the reaper may
    /// take the thread as it always did.
    ///
    /// One dictionary lookup, for every thread in the list. That is also the fix for the
    /// reaper's old cost, which faulted `draftAttachments` for EVERY thread to answer it.
    public func hasDraft(_ id: UUID) -> Bool {
        drafts[id]?.snapshot.isWorthKeeping ?? false
    }

    /// Whether anything at all is held for `id`. Tests read it; nothing else needs to.
    public func holdsDraft(_ id: UUID) -> Bool { drafts[id] != nil }

    // MARK: - Open composers

    /// Conversations whose composer is ON SCREEN: restored and not yet left. In memory only —
    /// after a launch nothing is open.
    private var openComposers: Set<UUID> = []

    /// A composer appeared. Called by `ComposerDrafts.restore`, once per composer.
    public func composerOpened(_ id: UUID) { openComposers.insert(id) }

    /// A composer was LEFT. Called by `ComposerDrafts.leave`.
    public func composerClosed(_ id: UUID) { openComposers.remove(id) }

    public func isComposerOpen(_ id: UUID) -> Bool { openComposers.contains(id) }

    /// WHAT BOTH SHELLS' REAPERS ASK: nothing held, and no composer still open on it.
    ///
    /// The second clause removes the one ordering this design depended on. A draft exists
    /// only once its composer is LEFT, and nothing orders an iPhone pop's list `onAppear` —
    /// where the reaper runs — after the popped composer's `onDisappear` delivers that
    /// departure. When the list ran first, asking `hasDraft` alone judged a conversation the
    /// user had just typed into as empty, and deleted it (App 1.0 (132)). An open composer is
    /// never the reaper's to judge; its departure posts `ComposerDrafts.composerLeft` and the
    /// reaper runs then.
    public func mayReap(_ id: UUID) -> Bool { !hasDraft(id) && !isComposerOpen(id) }

    // MARK: - Capture

    /// Record a composer's state, because it is being left. THE ONLY MUTATOR A DEPARTURE
    /// REACHES, and the only thing that ever writes the file.
    ///
    /// Call it through `ComposerDrafts.capture`, which also puts the conversation on disk.
    /// Returns whether anything actually changed — a departure from an untouched composer
    /// writes nothing.
    ///
    /// `id` is passed explicitly and is the ONLY conversation touched. That is what makes a
    /// late departure safe: it records the conversation it was typed in, whatever the user
    /// is looking at now.
    @discardableResult
    public func capture(_ state: ComposerDraftCapture, for id: UUID,
                        now: Date = Date(), terminating: Bool = false) -> Bool {
        let current = drafts[id]
        // An untouched composer being left is the common case and must cost nothing.
        if let current,
           current.text == state.text,
           current.pendingRecording == state.pendingRecording,
           current.contextLabel == state.contextLabel,
           sameFiles(current.files, state.files) {
            return false
        }
        if current == nil && state.isEmpty { return false }
        drafts[id] = ComposerDraftRecord(text: state.text,
                                         pendingRecording: state.pendingRecording,
                                         contextLabel: state.contextLabel,
                                         updatedAt: now,
                                         files: state.files)
        evictIfOverBudget(keeping: id)
        persist(synchronously: terminating)
        return true
    }

    /// Files compared by (filename, mime, byte count) rather than by bytes: two staged
    /// files with the same name, type and length are the same file for this purpose, and
    /// hashing megabytes at every departure to prove it would cost more than the write it
    /// saves.
    private func sameFiles(_ lhs: [ComposerDraftFile], _ rhs: [ComposerDraftFile]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.filename == $1.filename && $0.mime == $1.mime && $0.data.count == $1.data.count
        }
    }

    /// Report and clear the two one-shot markers, so a notice is shown once and not on
    /// every subsequent appearance.
    ///
    /// IN MEMORY ONLY, and no write: this runs on appear, which is not a departure. The
    /// composer's next departure records the markers afresh from what is actually true
    /// then — which for a transcription that never finished is nothing. The cost of a kill
    /// in between is that the notice is shown twice, over text that is still correct.
    public func clearNotices(for id: UUID) {
        guard var record = drafts[id],
              record.pendingRecording != nil || record.contextLabel != nil else { return }
        record.pendingRecording = nil
        record.contextLabel = nil
        drafts[id] = record
    }

    // MARK: - The send handoff

    /// Give up the draft because its message has been persisted.
    ///
    /// Called AFTER the turn is on disk and only on a successful stage, which is the whole
    /// of the ordering rule this file's header states. Returns what was released.
    @discardableResult
    public func release(for id: UUID) -> ComposerDraftSnapshot {
        let released = snapshot(for: id)
        if drafts.removeValue(forKey: id) != nil { persist() }
        return released
    }

    /// Forget a conversation's draft because the conversation itself is gone.
    public func delete(_ id: UUID) {
        if drafts.removeValue(forKey: id) != nil { persist() }
    }

    /// Drop stored drafts for conversations that no longer exist. The backstop for a delete
    /// this store never saw — a cross-device delete, or one on a path that forgot to call
    /// `delete`. Run once at launch.
    public func sweep(keeping live: Set<UUID>) {
        let doomed = drafts.keys.filter { !live.contains($0) }
        guard !doomed.isEmpty else { return }
        for id in doomed { drafts.removeValue(forKey: id) }
        persist()
    }

    // MARK: - Writing

    /// THE ONE WRITE. Every departure, release, delete and sweep ends here and nothing
    /// else in the app reaches the writer at all.
    ///
    /// Chained behind whatever is already in flight so two writes cannot land out of
    /// order, and handed a TEXT-ONLY map so the off-main task never retains a staged
    /// photo.
    private func persist(synchronously: Bool = false) {
        guard !terminated else { return }
        let map = drafts.mapValues {
            ComposerDraftPersisted(text: $0.text, pendingRecording: $0.pendingRecording,
                                   contextLabel: $0.contextLabel, updatedAt: $0.updatedAt,
                                   stagedFileCount: $0.stagedFileCount)
        }
        // A QUIT. The handler returns and the process is gone, so an asynchronous write
        // may never get a turn — the one place it is right to make the main thread wait
        // on a small file. Nothing may be written after it: this map is the last word, and
        // an in-flight write carrying an older one must not land on top of it.
        if synchronously {
            terminated = true
            writer.writeNow(map)
            writeTask = nil
            return
        }
        let previous = writeTask
        let writer = self.writer
        writeTask = Task { @MainActor in
            await previous?.value
            await writer.write(map)
        }
    }

    /// Wait for every write asked for so far to reach disk. For tests; the app never
    /// waits on a draft.
    public func settle() async { await writeTask?.value }

    /// Keep the in-memory bytes bounded. Staged files go first, oldest conversation first;
    /// only if dropping every other conversation's files is still not enough does a whole
    /// entry (and with it its TEXT) go — text last, and in practice never, because the
    /// whole map's text is a few kilobytes.
    ///
    /// `keeping` is the conversation just captured: it is never the one thrown away.
    private func evictIfOverBudget(keeping: UUID) {
        var total = drafts.values.reduce(0) { $0 + $1.retainedBytes }
        guard total > byteCap else { return }
        let oldestFirst = drafts
            .filter { $0.key != keeping }
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .map(\.key)
        for id in oldestFirst where total > byteCap {
            guard var record = drafts[id], !record.files.isEmpty else { continue }
            total -= record.files.reduce(0) { $0 + $1.data.count }
            record.files = []
            drafts[id] = record
        }
        // Still over: the captured conversation alone is bigger than the budget. Its files
        // are the only thing left that is large.
        if total > byteCap, var record = drafts[keeping], !record.files.isEmpty {
            total -= record.files.reduce(0) { $0 + $1.data.count }
            record.files = []
            drafts[keeping] = record
        }
        // Text last, oldest first. Unreachable with any realistic cap; here so the budget
        // is a real bound rather than a hopeful one.
        for id in oldestFirst where total > byteCap {
            guard let record = drafts.removeValue(forKey: id) else { continue }
            total -= record.retainedBytes
        }
    }
}

// MARK: - The one implementation every call site reaches

/// Capture, restore and release — one function each, shared by both shells.
///
/// The per-shell code is the departure hooks, the restore call, and a small adapter
/// between a view's own attachment type and `ComposerDraftFile`. If a behaviour has to be
/// described twice, once for each shell, it is in the wrong place and belongs here: that
/// is what stops the two shells growing two ideas of what a draft is.
@MainActor
public enum ComposerDrafts {

    /// A composer is being left. Record what it holds, and make sure the conversation it
    /// belongs to exists on disk.
    ///
    /// Every departure on both shells calls THIS: the chat view disappearing, the scene
    /// leaving the foreground, termination, and a send that was refused. A hook with
    /// different arguments to hand converts them and calls it; none of them writes
    /// anything itself.
    ///
    /// - Returns: whether the draft changed.
    @discardableResult
    public static func capture(_ state: ComposerDraftCapture,
                               for thread: JesseThread,
                               in context: ModelContext,
                               store: ComposerDraftStore = .shared,
                               now: Date = Date(),
                               terminating: Bool = false) -> Bool {
        // A draft is keyed on `JesseThread.id` and stored outside the object graph, so a
        // draft whose conversation is not persisted is a file nothing can ever lead the
        // user back to. THIS is where that is fixed — not on the first keystroke.
        ComposerDraftThreadInsertion.persistIfNeeded(thread, in: context,
                                                     hasSomethingToKeep: !state.isEmpty)
        return store.capture(state, for: thread.id, now: now, terminating: terminating)
    }

    /// Put a composer back the way the user left it. Called once per composer, on appear.
    ///
    /// - Parameters:
    ///   - newestUserTurn: the visible text and creation date of the thread's newest user
    ///     turn, for the already-sent check.
    ///   - contextStillAttached: whether the coordinator still holds the screen context
    ///     this conversation was opened with.
    public static func restore(for thread: JesseThread,
                               newestUserTurn: (text: String, createdAt: Date)?,
                               contextStillAttached: Bool,
                               store: ComposerDraftStore = .shared)
    -> ComposerDraftRestoration {
        // THE COMPOSER IS OPEN from here until `leave`, and no reaper may judge its
        // conversation meanwhile. See `ComposerDraftStore.mayReap`.
        store.composerOpened(thread.id)
        let saved = store.snapshot(for: thread.id)
        // A draft whose message ALREADY WENT is not a draft. The turn is persisted before
        // the draft is released, so a kill between the two leaves both on disk; this is
        // where that window is closed, rather than by pretending the two stores share a
        // transaction. See `ComposerDraftStaleness`.
        guard !ComposerDraftStaleness.isSpent(saved, newestUserTurn: newestUserTurn) else {
            store.delete(thread.id)
            return .nothing
        }
        // Say what did NOT come back, if anything did not. Both markers are one-shot: they
        // describe the moment the composer was left, so they are reported once and cleared.
        let notice = ComposerDraftNotice.message(for: saved,
                                                 contextStillAttached: contextStillAttached)
        if saved.pendingRecording != nil || saved.contextLabel != nil {
            store.clearNotices(for: thread.id)
        }
        return ComposerDraftRestoration(text: saved.text, files: saved.files, notice: notice)
    }

    /// The message went. Give up the draft.
    ///
    /// Called only after the turn is durably staged — a refused send and a staging save
    /// that threw both call `capture` instead, leaving the text on screen and getting it
    /// to disk.
    @discardableResult
    public static func release(for thread: JesseThread,
                               store: ComposerDraftStore = .shared) -> ComposerDraftSnapshot {
        store.release(for: thread.id)
    }

    /// Posted when a composer is LEFT, with the conversation's id as the object. The iPhone
    /// list runs its reaper on it: if on a pop the list appeared first, it skipped the
    /// conversation as still open, and this is the first moment its draft is known.
    public static let composerLeft = Notification.Name("JesseComposerDraftLeft")

    /// The composer is being LEFT — the departure after which it is gone: the iPhone popping
    /// it, the iPad or Mac detail column replacing it. Capture it as any departure does, stop
    /// exempting its conversation from the reapers, and say so.
    ///
    /// The scene going to the background and a refused send are departures too, but the
    /// composer is still on screen after them, so they call `capture` and leave it open.
    /// Reaping stays the list's: a departure never deletes anything itself, because a tab
    /// switch on the iPad also fires `onDisappear` on a composer that is still showing.
    ///
    /// - Returns: whether the draft changed.
    @discardableResult
    public static func leave(_ state: ComposerDraftCapture,
                             for thread: JesseThread,
                             in context: ModelContext,
                             store: ComposerDraftStore = .shared) -> Bool {
        let changed = capture(state, for: thread, in: context, store: store)
        store.composerClosed(thread.id)
        NotificationCenter.default.post(name: composerLeft, object: thread.id)
        return changed
    }
}

/// What a composer gets back on appear: its text, its files, and the sentence to show if
/// something that was part of the pending message is not coming back with it.
public nonisolated struct ComposerDraftRestoration: Equatable, Sendable {
    public var text: String
    public var files: [ComposerDraftFile]
    public var notice: String?

    public init(text: String, files: [ComposerDraftFile] = [], notice: String? = nil) {
        self.text = text
        self.files = files
        self.notice = notice
    }

    /// Nothing to put back.
    public static let nothing = ComposerDraftRestoration(text: "")
}

// MARK: - A draft a send already spent

/// The reconciliation that replaces the old one-save atomicity.
///
/// With the turn and the draft in two stores, a kill between "the turn is saved" and "the
/// draft is deleted" leaves both on disk, and the composer would put the sent message back
/// as if it were unsent. So a restore DISCARDS a draft that is already a turn: same text,
/// and captured no later than the turn that carries it.
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
/// All three cases are the same shape of honesty: the text is restored, and the thing that
/// is gone is NAMED, because a draft that quietly turns into a different message is worse
/// than one that says what it lost.
public nonisolated enum ComposerDraftNotice {

    /// The notice for a restored `snapshot`, or nil when nothing was lost.
    ///
    /// - `contextStillAttached`: whether the coordinator still holds the screen context
    ///   this conversation was opened with. Attached context lives in memory and dies with
    ///   the process, so a draft captured against one and restored after a relaunch would
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
        // Staged files live in memory and are never written to disk, so a draft that comes
        // back from a cold launch comes back without them. Named rather than dropped: the
        // text is right there, and "I attached a photo to this" must not become quietly
        // untrue.
        if snapshot.lostFiles > 0 {
            parts.append(snapshot.lostFiles == 1
                         ? "The file you attached isn’t here any more — attach it again "
                           + "before sending."
                         : "The \(snapshot.lostFiles) files you attached aren’t here any "
                           + "more — attach them again before sending.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
