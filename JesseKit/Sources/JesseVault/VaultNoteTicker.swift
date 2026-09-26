import Foundation

// WHAT HAPPENS BETWEEN THE TAP AND THE BOX STAYING TICKED.
//
// A tap on a checkbox is not one operation, it is a small state machine, and every
// interesting state in it is one somebody else's edit caused. The whole of it is here,
// away from the view, because a decision taken inside a `body` is a decision nobody can
// test and everybody has to reproduce by hand with two devices and a sync delay.
//
// THE ONE RETRY, AND WHY THERE IS EXACTLY ONE. When the stamp is stale the note has
// changed on disk, and in the overwhelmingly common case the change has nothing to do with
// this box — the Studio's autocommit touched a different line, Obsidian saved a word
// somewhere else. Reloading and re-applying the tick is right there, and refusing would
// make a tick fail for a reason a person cannot see. But a SECOND failure means the file
// is being written while we work, and a loop that kept retrying would be this app fighting
// another writer over one byte. It stops, says so, and lets the person reload.
//
// THE RETRY CHECKS WHAT IT IS ABOUT TO CHANGE. If the line is no longer a checkbox, or is
// already in the state being asked for, the retry does NOT write: somebody else ticked it,
// or the line is not that line any more, and writing anyway is how a tap that meant "tick
// this" becomes "untick what somebody else just did".

/// One tap, resolved.
public enum VaultTickOutcome: Equatable, Sendable {
    /// Written. The reader holds this text and this stamp now.
    case written(text: String, stamp: VaultFileStamp)
    /// The line is not a checkbox line any more, so the note the reader is showing is not
    /// the note on disk. Reload rather than write.
    case notACheckbox
    /// Stale twice, or stale and no longer the line it was. The glyph goes back and the
    /// reader says so.
    case stale
    case failed(String)

    /// The one line the reader shows under the block. Nil when there is nothing to say.
    public var message: String? {
        switch self {
        case .written:      return nil
        case .notACheckbox: return "This note changed while it was open; reload and try again."
        case .stale:        return "This note changed while it was open; reload and try again."
        case .failed(let why): return why
        }
    }

    public var didWrite: Bool {
        if case .written = self { return true }
        return false
    }
}

/// Ticking one box in one note, through whatever can write.
public struct VaultNoteTicker: Sendable {
    /// The writer queues every write for the Studio (`VaultWriteOutbox`), a strand step's
    /// tick included: the record carries the step, and the bridge starts the turn that
    /// closes it. So a tick here is a write and nothing more.
    private let writer: any VaultNoteWriting

    public init(writer: any VaultNoteWriting) {
        self.writer = writer
    }

    /// Set the box on 1-based `line` of `path` to `checked`, given the text and stamp the
    /// reader is holding.
    ///
    /// The new text is the old text with ONE CHARACTER different — `VaultCheckboxEdit`
    /// rebuilds nothing — so no line-ending or trailing-newline shaping is applied here
    /// and none is wanted. The bytes handed to `replace` are the bytes that were read,
    /// with one `[ ]` now reading `[x]`. That is the strongest form the promise "nothing
    /// he did not touch is changed" can take: not restored afterwards, never altered.
    public func tick(path: String, line: Int, to checked: Bool,
                     text: String, stamp: VaultFileStamp) async -> VaultTickOutcome {
        guard let edited = VaultCheckboxEdit.setting(text, line: line, checked: checked) else {
            return .notACheckbox
        }
        let kind = VaultEditKind.box(checked: checked)
        do {
            let written = try await writer.replace(path: path, expected: stamp,
                                                   with: edited, kind: kind)
            return .written(text: edited, stamp: written)
        } catch VaultFileError.changedSinceRead {
            return await retry(path: path, line: line, to: checked, kind: kind)
        } catch {
            return .failed(VaultIndexer.describe(error))
        }
    }

    /// The one retry: read what is there now, and tick it only if it is still the box this
    /// tap meant.
    private func retry(path: String, line: Int, to checked: Bool,
                       kind: VaultEditKind) async -> VaultTickOutcome {
        guard let fresh = try? await writer.readStamped(path: path) else { return .stale }
        // Still a checkbox, and still in the state the tap was moving it OUT of. Either
        // half failing means the tap no longer describes anything true about the file.
        guard VaultCheckboxEdit.state(of: fresh.text, line: line) == !checked,
              let edited = VaultCheckboxEdit.setting(fresh.text, line: line, checked: checked)
        else {
            return .stale
        }
        guard let written = try? await writer.replace(path: path, expected: fresh.stamp,
                                                      with: edited, kind: kind) else {
            // Stale twice, or a write failure on the retry. Either way this stops here:
            // see the file comment on why there is no second retry.
            return .stale
        }
        return .written(text: edited, stamp: written)
    }
}
