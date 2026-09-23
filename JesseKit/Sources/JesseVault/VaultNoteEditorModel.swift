import Foundation
import Observation

// EDITING A WHOLE NOTE, AND THE FOUR WAYS THAT GOES WRONG.
//
// The model is separate from the screen for the usual reason and one specific one: the
// interesting states here are all caused by somebody else's write landing between a read
// and a save, and reproducing that against a real synced folder means two machines and a
// stopwatch. Behind the `VaultNoteWriting` seam it is four lines in a test.
//
// THE FOUR STATES, AND WHAT EACH ONE IS FOR:
//
//   dirty     Save is enabled only when the text differs from what was LOADED — not from
//             the last keystroke. Type a word and delete it and the note is not dirty,
//             because it is not different, and offering to save it would be offering to
//             rewrite a file for no reason.
//   conflict  The stamp was stale. Reload (throw my text away, take the disk's) or
//             Overwrite (take mine) — and Overwrite still goes through `replace` with the
//             FRESH stamp. There is no unguarded write anywhere in this prompt, including
//             behind the button whose whole name is "overwrite".
//   stash     Backgrounded with unsaved text. Kept, offered back, never applied on its own.
//   truncated A note the reader cut at 256 KB cannot be edited at all, because saving what
//             the editor holds would DELETE everything past the cut. That is the single
//             most destructive thing this code could do, and it is prevented by refusing
//             to open rather than by remembering to be careful at save time.

/// What the editor is doing.
@MainActor
@Observable
public final class VaultNoteEditorModel {
    /// See the GOTCHA in this target's `Package.swift` comment.
    nonisolated deinit {}

    public enum Phase: Equatable, Sendable {
        case loading
        case editing
        /// Cannot be edited here, and why.
        case refused(String)
        case failed(String)
    }

    /// What the editor is asking the person, if anything.
    public enum Prompt: Equatable, Sendable {
        /// The file changed under the edit. Reload or Overwrite.
        case conflict
        /// Overwrite was chosen and is being confirmed. TWO steps deliberately: the first
        /// is a choice between three options on a busy sheet, and "discard what somebody
        /// else wrote" is not a thing to do with one tap on a busy sheet.
        case confirmOverwrite
        /// Cancel was pressed with unsaved changes.
        case confirmDiscard
        /// There is unsaved text from a previous session.
        case restore(VaultEditStashEntry)
    }

    public let path: String
    public private(set) var phase: Phase = .loading
    /// The editor's text. The ONLY mutable-from-outside property: it is a `TextEditor`'s
    /// binding, and every keystroke writes it.
    public var text: String = ""
    public private(set) var prompt: Prompt?
    /// The text as loaded, which is what `isDirty` compares against.
    public private(set) var loaded: String = ""
    public private(set) var stamp: VaultFileStamp?
    /// The file's line endings and final newline, given back on save.
    public private(set) var shape = VaultTextShape(lineEnding: .lf, endsWithNewline: true)
    public private(set) var isSaving = false
    /// Set when a save lands, so the reader knows to reload and the screen knows to leave.
    public private(set) var didSave = false
    public private(set) var error: String?

    private let writer: any VaultNoteWriting
    private let stash: VaultEditStash

    public init(path: String,
                writer: any VaultNoteWriting = VaultNoteWriter(),
                stash: VaultEditStash = .shared) {
        self.path = path
        self.writer = writer
        self.stash = stash
    }

    /// Save is offered only for a real difference.
    public var isDirty: Bool { text != loaded }

    public var canSave: Bool {
        guard case .editing = phase else { return false }
        return isDirty && !isSaving
    }

    // MARK: - Opening

    /// Read the note, refuse it if it cannot be edited here, and offer back any unsaved
    /// text from last time.
    public func load() async {
        phase = .loading
        error = nil
        if let caption = Self.refusal(path: path) {
            phase = .refused(caption)
            return
        }
        do {
            let read = try await writer.readStamped(path: path)
            // THE TRUNCATION GUARD, and it is checked against the bytes just read rather
            // than against anything the reader passed in. The reader's own document may
            // have been parsed minutes ago; the file is what it is now.
            if read.stamp.bytes > VaultNoteDocument.byteLimit {
                phase = .refused(Self.tooLongCaption)
                return
            }
            loaded = read.text
            text = read.text
            stamp = read.stamp
            shape = VaultTextShape.of(read.text)
            phase = .editing
            let held = stash.stashed(forPath: path)
            if VaultEditStash.isWorthOffering(held, diskText: read.text), let held {
                prompt = .restore(held)
            } else if held != nil {
                // Nothing to restore — the stash matches the file. Clear it so it cannot
                // be offered again later against a file that has since moved on.
                stash.clear(path: path)
            }
        } catch {
            phase = .failed(VaultIndexer.describe(error))
        }
    }

    /// Why this note cannot be edited here, or nil.
    ///
    /// Static and pure so the reader can disable its Edit button with the SAME rule the
    /// editor enforces, rather than a second copy of it that can drift.
    public static func refusal(path: String) -> String? {
        VaultWriteExemption.isReadOnly(path: path)
            ? "Tick items on the Today tab; this file is rewritten by the bridge."
            : nil
    }

    public static let tooLongCaption = "Too long to edit here."

    // MARK: - The prompts

    public func dismissPrompt() { prompt = nil }

    /// Take the stashed text.
    public func restore(_ entry: VaultEditStashEntry) {
        text = entry.text
        prompt = nil
    }

    /// Throw the stash away and keep what is on disk.
    public func discardStash() {
        stash.clear(path: path)
        prompt = nil
    }

    /// Cancel. Asks once when there is something to lose, and the caller leaves only when
    /// this returns true.
    public func cancel() -> Bool {
        guard isDirty else {
            stash.clear(path: path)
            return true
        }
        prompt = .confirmDiscard
        return false
    }

    /// Cancel confirmed: the edit is gone, stash included.
    public func confirmDiscard() {
        stash.clear(path: path)
        prompt = nil
    }

    // MARK: - Saving

    /// Write the editor's text over the note.
    public func save() async {
        guard case .editing = phase, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        error = nil
        guard let expected = stamp else {
            error = "This note was never read, so there is nothing to write over."
            return
        }
        // THE FILE'S OWN SHAPE, given back. A text view hands back LF and no view knows
        // whether the file it came from used CRLF; saving without this is how an edit to
        // one line reports as an edit to every line.
        let payload = shape.applied(to: text)
        do {
            let written = try await writer.replace(path: path, expected: expected,
                                                   with: payload, kind: .edit)
            stamp = written
            loaded = payload
            text = payload
            stash.clear(path: path)
            didSave = true
        } catch VaultFileError.changedSinceRead {
            prompt = .conflict
        } catch {
            self.error = VaultIndexer.describe(error)
        }
    }

    /// Conflict → Reload: the disk wins, the editor's text is gone.
    public func reloadFromDisk() async {
        prompt = nil
        do {
            let read = try await writer.readStamped(path: path)
            loaded = read.text
            text = read.text
            stamp = read.stamp
            shape = VaultTextShape.of(read.text)
            stash.clear(path: path)
        } catch {
            self.error = VaultIndexer.describe(error)
        }
    }

    /// Conflict → Overwrite, once confirmed: the editor's text wins.
    ///
    /// STILL GUARDED. It re-reads to get the CURRENT stamp and writes against that, so
    /// this is "overwrite what is there now", not "write without looking". The difference
    /// matters: between choosing Overwrite and confirming it, a third write can land, and
    /// an unguarded version would discard that one too — silently, and without the person
    /// who confirmed ever having been told it existed.
    public func overwrite() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        prompt = nil
        error = nil
        let payload = shape.applied(to: text)
        do {
            let fresh = try await writer.readStamped(path: path)
            let written = try await writer.replace(path: path, expected: fresh.stamp,
                                                   with: payload, kind: .edit)
            stamp = written
            loaded = payload
            text = payload
            stash.clear(path: path)
            didSave = true
        } catch VaultFileError.changedSinceRead {
            // A third write landed inside the confirmation. Back to the conflict rather
            // than through it.
            prompt = .conflict
        } catch {
            self.error = VaultIndexer.describe(error)
        }
    }

    /// Overwrite pressed: ask again.
    public func requestOverwrite() { prompt = .confirmOverwrite }

    // MARK: - Backgrounding

    /// Keep the unsaved text, or clear a stash that is no longer needed.
    ///
    /// Called on the scene leaving the foreground AND on the editor going away, because
    /// those are different events and only one of them is guaranteed.
    public func stashIfNeeded() {
        guard case .editing = phase else { return }
        guard isDirty, let stamp else {
            stash.clear(path: path)
            return
        }
        stash.stash(VaultEditStashEntry(path: path, text: text, stashed: Date(),
                                        baseStamp: stamp))
    }
}
