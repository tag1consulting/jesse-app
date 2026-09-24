import Foundation

// THE VAULT'S FOLDERS, DERIVED RATHER THAN STORED.
//
// The index holds one column that matters here: `files.path`, a vault relative path with
// `/` separators and no leading slash, exactly as `VaultScanner` produces it. Every folder
// in the vault, and the number of notes under each, is a function of that column — so this
// is a fold over the paths the index already has, and NOT a new table.
//
// That is a deliberate choice and worth stating, because the obvious alternative is a
// `folders` table maintained by the indexer. It would cost a schema change, and a schema
// change costs every device on the previous version a FULL REBUILD of its index (7,600
// notes re-read and re-chunked) to learn a value that can be recomputed from a column
// those devices already carry. Folding 7,600 strings in memory is microseconds; the walk
// that would replace it is minutes of somebody's morning.

/// One folder in the vault, and how many notes are under it.
public struct VaultFolderCount: Equatable, Sendable, Identifiable {
    /// The folder's vault relative path: `/` separated, no leading or trailing slash.
    public let path: String
    /// Every note under it, at ANY depth — so `Projects` counts the drafts inside
    /// `Projects/drafts/archive/` too. A folder picker whose count stopped at the first
    /// level would say "2" over a folder holding two hundred notes.
    public let noteCount: Int

    public var id: String { path }

    public init(path: String, noteCount: Int) {
        self.path = path
        self.noteCount = noteCount
    }
}

/// Every folder in a set of note paths, with its count. Pure.
public enum VaultFolderTree {

    /// The folders implied by `paths`, sorted and total-ordered.
    ///
    /// `paths` are note paths as the index stores them; the index holds `.md` files and
    /// nothing else, so every path counted is a note. A file at the vault ROOT belongs to
    /// no folder and contributes nothing — there is no synthetic "/" row, because the row
    /// for "everything" is the picker's own "All folders" and two of them would be one
    /// too many.
    public static func folders(fromPaths paths: [String]) -> [VaultFolderCount] {
        var counts: [String: Int] = [:]
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            // The last component is the file; a path with only one component is a note at
            // the vault root.
            guard parts.count > 1 else { continue }
            var prefix = ""
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                counts[prefix, default: 0] += 1
            }
        }
        return counts
            .map { VaultFolderCount(path: $0.key, noteCount: $0.value) }
            .sorted(by: isOrderedBefore)
    }

    /// Case insensitive first, so `Projects` and `people` read as a person expects them
    /// to; case sensitive second, so the order is TOTAL and two folders differing only in
    /// case cannot swap places between two calls. `lowercased()` rather than a localized
    /// compare on purpose: the order must not depend on the device's locale, or a test
    /// passes here and fails on a phone set to Turkish.
    static func isOrderedBefore(_ a: VaultFolderCount, _ b: VaultFolderCount) -> Bool {
        let (la, lb) = (a.path.lowercased(), b.path.lowercased())
        if la != lb { return la < lb }
        return a.path < b.path
    }
}
