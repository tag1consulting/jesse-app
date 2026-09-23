import Foundation
@testable import JesseVault

// A VAULT THAT IS ONE STRING, SO THE INTERESTING STATES ARE ONE LINE TO SET UP.
//
// Every state worth testing in the tick machine and the editor is caused by somebody
// else's write landing between a read and a save. Against a real folder that means two
// processes and a sync delay; here it is `writer.diskText = "..."` between two awaits.
//
// It enforces the stamp exactly as `VaultFile.replace` does, because a fake that did not
// would let every conflict test pass by accident.
final class FakeNoteWriter: VaultNoteWriting, @unchecked Sendable {

    private let lock = NSLock()
    private var text: String
    /// Writes that should fail, and how. Consumed one per `replace`.
    private var failures: [Error?] = []
    private(set) var writes: [(text: String, kind: VaultEditKind)] = []
    private(set) var reads = 0

    init(text: String) {
        self.text = text
    }

    /// What is "on disk". Setting it is how a test stages somebody else's edit.
    var diskText: String {
        get { lock.withLock { text } }
        set { lock.withLock { text = newValue } }
    }

    var diskStamp: VaultFileStamp { VaultFileStamp(text: diskText) }

    /// Make the next `replace` calls fail. `nil` in the list means "this one succeeds".
    func failNextWrites(_ errors: [Error?]) {
        lock.withLock { failures = errors }
    }

    func readStamped(path: String) async throws -> (text: String, stamp: VaultFileStamp) {
        lock.withLock {
            reads += 1
            return (text, VaultFileStamp(text: text))
        }
    }

    func replace(path: String, expected: VaultFileStamp, with newText: String,
                 kind: VaultEditKind) async throws -> VaultFileStamp {
        try lock.withLock {
            if !failures.isEmpty {
                let next = failures.removeFirst()
                if let next { throw next }
            }
            // THE SAME GUARD THE REAL ONE APPLIES.
            guard VaultFileStamp(text: text) == expected else {
                throw VaultFileError.changedSinceRead(path)
            }
            text = newText
            writes.append((newText, kind))
            return VaultFileStamp(text: newText)
        }
    }
}

/// A writer that cannot read, for the editor's load-failure path.
final class FailingNoteWriter: VaultNoteWriting, @unchecked Sendable {
    func readStamped(path: String) async throws -> (text: String, stamp: VaultFileStamp) {
        throw VaultFileError.unreadable(path, "the folder is not reachable")
    }

    func replace(path: String, expected: VaultFileStamp, with text: String,
                 kind: VaultEditKind) async throws -> VaultFileStamp {
        throw VaultFileError.unwritable(path, "the folder is not reachable")
    }
}
