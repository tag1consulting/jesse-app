import Foundation

// `[[WIKI LINKS]]`, AND THE ONE QUESTION THAT MATTERS ABOUT THEM: which file is that?
//
// A vault link names a note the way a person would, not the way a filesystem would.
// All four of these appear in this vault and all four mean one file:
//
//     [[Projects/Perseido/Perseido]]        a path, no extension
//     [[Perseido]]                          a bare name, resolved by searching
//     [[Perseido|the fibre company]]        an alias for the reader
//     [[Perseido#Billing]]                  a section of it
//
// So a target is NORMALIZED first — alias dropped, `#heading` dropped, a `.md` that
// somebody typed dropped — and then resolved against the files that actually exist.
//
// ## Resolution is three steps, in this order, and stops at the first that is certain
//
//   1. An EXACT relative path (with `.md` appended). A link that spells the whole path
//      means that file and nothing else.
//   2. A UNIQUE basename anywhere in the vault. This is the common case and the reason
//      the step exists: the vault's own convention writes links as full paths from the
//      WORKSPACE root (`todo-list/Projects/...`) while the folder Obsidian syncs is one
//      level inside that (`Projects/...`), so step 1 misses almost every real link and
//      the file name is what actually identifies it.
//   3. A unique CASE-INSENSITIVE basename, for `[[perseido]]` written in a hurry.
//
// SEVERAL MATCHES RESOLVES TO NOTHING, deliberately. Two notes named `Overview.md` in
// different folders are two different notes, and quietly opening the alphabetically
// first one is the failure mode that costs a reader an afternoon. Obsidian itself
// refuses to guess in the same situation.

public enum VaultWikiLink {

    /// Every `[[target]]` in `text`, normalized, in source order, de-duplicated.
    ///
    /// Deliberately the same scan the day file's own link extraction performs
    /// (`TodayNoteMarkdown.links(in:)`, itself a port of the bridge's `extract_links`):
    /// a link the app resolves locally must name the file the bridge would have
    /// resolved, or the offline copy of a note would be a different note.
    public static func targets(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            guard rest.hasPrefix("[[") else {
                rest = rest.dropFirst()
                continue
            }
            guard let close = rest.range(of: "]]") else { break }
            let inner = rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]
            let target = normalized(String(inner))
            if !target.isEmpty, !out.contains(target) { out.append(target) }
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// One raw target's canonical form: alias dropped, `#heading` dropped, a trailing
    /// `.md` dropped, surrounding whitespace and slashes trimmed.
    public static func normalized(_ raw: String) -> String {
        var s = raw
        if let pipe = s.firstIndex(of: "|") { s = String(s[s.startIndex..<pipe]) }
        if let hash = s.firstIndex(of: "#") { s = String(s[s.startIndex..<hash]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("/") { s.removeFirst() }
        if s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix(".md") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file name a normalized target names, with `.md` on it.
    public static func fileName(for target: String) -> String {
        let leaf = target.split(separator: "/").last.map(String.init) ?? target
        return leaf + ".md"
    }

    /// The relative path `target` resolves to among `paths`, or nil when nothing matches
    /// or more than one does.
    ///
    /// PURE, so the three steps and the ambiguous case are asserted directly rather than
    /// inferred from what a database answered. `VaultIndex.resolve(target:)` runs the
    /// same three steps as SQL over the `files` table; the two must stay in step, and the
    /// index's own test drives it over a real tree for exactly that reason.
    public static func resolve(target rawTarget: String, among paths: [String]) -> String? {
        let target = normalized(rawTarget)
        guard !target.isEmpty else { return nil }

        // 1. The whole path, spelled out.
        let exact = target + ".md"
        if paths.contains(exact) { return exact }

        // 2. A unique basename.
        let wanted = fileName(for: target)
        let byName = paths.filter { basename($0) == wanted }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { return nil }

        // 3. A unique basename, case folded.
        let foldedWanted = wanted.lowercased()
        let folded = paths.filter { basename($0).lowercased() == foldedWanted }
        return folded.count == 1 ? folded[0] : nil
    }

    /// The last path component of a `/`-separated relative path.
    public static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
