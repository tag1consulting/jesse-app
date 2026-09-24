import Foundation

// SCOPING THE VAULT TAB, and the one folder it is worth scoping to.
//
// The Vault tab searches 7,600 notes, which is the right default and the wrong one for
// the question "what is going on with my work": the strand notes are fifteen files, and
// a search for a project name finds the fifty drafts about it before it finds the one
// note that says where it stands. A scope is the cheapest possible answer — the same
// index, the same query, a path predicate.
//
// The scope set is deliberately TINY and deliberately not user defined. A general
// folder picker would be a different feature (and a worse one: the vault's folders are
// a filing system, not a set of views), whereas `Strands/` is the one folder whose
// contents are a board rather than a pile.

/// Which part of the vault the tab is looking at.
public enum VaultSearchScope: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case all
    case strands

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "All"
        case .strands: return "Strands"
        }
    }

    /// The path prefix a file must carry, or nil for every file.
    public var pathPrefix: String? {
        switch self {
        case .all: return nil
        case .strands: return "Strands/"
        }
    }

    /// The prefix under it that is excluded. A strand that is finished is MOVED to
    /// `Strands/archive/`, and a board that listed its own archive would grow without
    /// bound while saying less every month.
    public var excludedPrefix: String? {
        switch self {
        case .all: return nil
        case .strands: return "Strands/archive/"
        }
    }

    /// Whether one vault relative path is in scope.
    public func includes(_ path: String) -> Bool {
        if let excluded = excludedPrefix, path.hasPrefix(excluded) { return false }
        guard let prefix = pathPrefix else { return true }
        return path.hasPrefix(prefix)
    }

    /// Whether this scope orders its recents by a note's own `updated` stamp rather
    /// than by the file's modification time. See `VaultStrandOrder`.
    public var ordersByFrontmatterUpdated: Bool { self == .strands }
}

/// **The order the Strands scope lists its notes in**, as a pure function.
///
/// A strand note's `updated:` frontmatter is a CLAIM about when the work last moved,
/// written by whoever moved it. The file's modification time is a fact about the file,
/// and on a synced folder it is routinely a lie: a sync that rewrites a note gives it
/// today's mtime without a word of it having changed. So the stamp wins where the note
/// carries one, and mtime is the fallback for a note that does not — which is also the
/// case the nightly audit already has a finding for.
public enum VaultStrandOrder {

    /// Newest first, by `updated[path]` where the note has a usable one and by the
    /// file's modification time otherwise.
    ///
    /// Stable: ties fall through to mtime and then to path, so two notes stamped the
    /// same day keep one order rather than swapping on every redraw.
    public static func ordered(_ files: [VaultIndexedFile],
                               updated: [String: String]) -> [VaultIndexedFile] {
        files.sorted { a, b in
            let (ka, kb) = (key(a, updated: updated), key(b, updated: updated))
            if ka != kb { return ka > kb }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.path < b.path
        }
    }

    /// The comparable day for one file: its stamp when that is a plain ISO day, else
    /// the ISO day of its mtime. ISO days compare lexicographically, so the string IS
    /// the ordering.
    static func key(_ file: VaultIndexedFile, updated: [String: String]) -> String {
        if let stamp = updated[file.path], isISODay(stamp) { return stamp }
        return isoDay(file.modified)
    }

    /// `yyyy-MM-dd`, checked structurally rather than parsed. A frontmatter value that
    /// is not one is not repaired into a guess.
    static func isISODay(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Reading one value out of a note's frontmatter.
public enum VaultFrontmatter {

    /// The value of `key:` in the leading `---` block, or nil when the note has no such
    /// block or no such key.
    ///
    /// A LINE SCANNER, not a YAML parser, and that is the right size for this: the
    /// vault's frontmatter is a flat list of `key: value` lines written by hand and by
    /// the bridge, and a real parser would be a dependency plus a class of failures
    /// (a tab, a stray colon) that would make a note unreadable rather than a key
    /// unreadable. Quotes around a value are dropped; everything else is verbatim.
    public static func value(for key: String, in text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard let first = lines.next(),
              first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        let wanted = key.lowercased() + ":"
        while let line = lines.next() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return nil }
            guard trimmed.lowercased().hasPrefix(wanted) else { continue }
            var value = String(trimmed.dropFirst(wanted.count))
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let head = value.first, let tail = value.last,
               head == tail, head == "\"" || head == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
