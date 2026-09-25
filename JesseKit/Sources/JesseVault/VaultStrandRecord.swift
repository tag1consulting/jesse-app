import Foundation

// THE STRANDS SCOPE AS A RECORD, not a second board.
//
// The Today tab's board answers "what runs next?" from the live notes. This scope answers
// "what happened?", which is a different question with a different shape of answer: it
// reaches into the archive, and it is asked of one SECTION across many notes. "Every
// decision about the bridge" is twelve lines from six notes, and a search that returns
// one row per file answers it with six titles and no decisions.
//
// So a section chip changes the unit from a file to a LINE. The index already holds what
// that needs: every chunk records the innermost `##` or `###` heading it sits under
// (`VaultChunker`), so `### Done` under `## Drafts` is a chunk headed `Done`, and the
// `## Drafts` body above `### Later` is a chunk headed `Drafts`. Nothing new is stored;
// a chunk is split into its lines here, and each line carries its own number, its own
// date, and the strand it came from.
//
// Pure and Foundation-only, like the chunker, so every rule is asserted directly.

/// One section of a strand note, as the chips name them. `.all` is no section at all:
/// the scope's ordinary one-row-per-note behaviour.
public enum VaultStrandSection: String, CaseIterable, Identifiable, Equatable, Hashable,
                                Sendable {
    case all
    case decisions
    case done
    case status
    case drafts
    case later

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "All"
        case .decisions: return "Decisions"
        case .done: return "Done"
        case .status: return "Status"
        case .drafts: return "Drafts"
        case .later: return "Later"
        }
    }

    /// The heading a chunk must sit under, or nil for every chunk. `Drafts` is the
    /// `## Drafts` body ABOVE `### Later`, because below that line the chunker has
    /// already moved on to the subsection's own heading.
    public var heading: String? {
        self == .all ? nil : label
    }

    /// Whether a chunk's recorded heading is this section's.
    public func matches(heading: String) -> Bool {
        guard let wanted = self.heading else { return true }
        return heading.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(wanted) == .orderedSame
    }

    /// Whether this section's lines are a dated log, read newest first. The three that
    /// are: a decision, a finished step and a status entry are each stamped with the day
    /// they happened, and the day is the order a record is read in.
    public var isDatedLog: Bool {
        self == .decisions || self == .done || self == .status
    }
}

/// One line of one section of one strand: a row of the section view.
public struct VaultSectionLine: Equatable, Sendable, Identifiable {
    public let path: String
    /// The strand's title, shown as the row's caption.
    public let title: String
    public let heading: String
    /// The 1-based line in the whole file, which is what the reader scrolls to.
    public let line: Int
    /// The line with its list marker, checkbox and leading date taken off.
    public let text: String
    /// The leading `YYYY-MM-DD`, or nil when the line does not start with one.
    public let date: String?
    /// The chunk's weighted bm25, carried so a section that is not a dated log keeps the
    /// search's own order. Zero for the empty-query log, which is not ranked.
    public let score: Double

    public var id: String { "\(path)#\(line)" }

    public init(path: String, title: String, heading: String, line: Int, text: String,
                date: String?, score: Double = 0) {
        self.path = path
        self.title = title
        self.heading = heading
        self.line = line
        self.text = text
        self.date = date
        self.score = score
    }
}

/// One chunk as the index stores it, body included. What the section view reads.
public struct VaultStoredChunk: Equatable, Sendable {
    public let path: String
    public let title: String
    public let heading: String
    public let lineStart: Int
    public let body: String

    public init(path: String, title: String, heading: String, lineStart: Int, body: String) {
        self.path = path
        self.title = title
        self.heading = heading
        self.lineStart = lineStart
        self.body = body
    }
}

public enum VaultStrandRecord {

    /// The folder every strand note lives under, and the one a finished strand moves to.
    public static let folder = "Strands/"
    public static let archiveFolder = "Strands/archive/"

    /// How many lines the empty-query log shows.
    public static let logLimit = 50

    public static func isArchived(_ path: String) -> Bool {
        path.hasPrefix(archiveFolder)
    }

    /// A note's slug: its file name without `.md`, which is how the vault names a strand
    /// (`[[todo-list/Strands/Jesse]]`).
    public static func slug(of path: String) -> String {
        let leaf = path.split(separator: "/").last.map(String.init) ?? path
        return leaf.lowercased().hasSuffix(".md") ? String(leaf.dropLast(3)) : leaf
    }

    /// The note a slug names, among `paths`. A live note wins over an archived one of the
    /// same name, because a strand revived after archiving is the one being asked about.
    /// Case-insensitive, and a slug given with its folder or its `.md` is still a slug.
    public static func path(forSlug rawSlug: String, among paths: [String]) -> String? {
        let wanted = slug(of: rawSlug.trimmingCharacters(in: .whitespaces))
        let candidates = paths.filter {
            $0.hasPrefix(folder) && slug(of: $0).caseInsensitiveCompare(wanted) == .orderedSame
        }
        return candidates.first { !isArchived($0) } ?? candidates.first
    }

    /// One markdown line as a record entry: the text with its list marker and checkbox
    /// removed, and its leading date split off. Nil for a line that is not an entry at
    /// all: blank, a heading, or a bare marker.
    public static func entry(_ raw: String) -> (date: String?, text: String)? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            s = s.dropFirst(marker.count)
            break
        }
        for box in ["[ ] ", "[x] ", "[X] "] where s.hasPrefix(box) {
            s = s.dropFirst(box.count)
            break
        }
        s = s.drop(while: { $0 == " " })
        var date: String?
        let head = String(s.prefix(10))
        if VaultStrandOrder.isISODay(head) {
            let rest = s.dropFirst(10)
            if rest.isEmpty || rest.first == " " || rest.first == ":" {
                date = head
                s = rest.drop(while: { $0 == " " || $0 == ":" })
            }
        }
        let text = String(s).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty || date != nil else { return nil }
        return (date, text)
    }

    /// A chunk's entries, each with its own 1-based line in the file. The chunk's body is
    /// its section's lines verbatim from `lineStart`, so an entry's line is the chunk's
    /// plus its offset.
    public static func lines(of chunk: VaultStoredChunk, score: Double = 0)
        -> [VaultSectionLine] {
        chunk.body.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { offset, raw in
                guard let entry = entry(String(raw)) else { return nil }
                return VaultSectionLine(path: chunk.path, title: chunk.title,
                                        heading: chunk.heading,
                                        line: chunk.lineStart + offset,
                                        text: entry.text, date: entry.date, score: score)
            }
    }

    /// Whether one line answers a query. Every token must be satisfied, and a token is
    /// satisfied by a WORD in the line that starts with it (the index's own prefix rule),
    /// or by the strand's title or path: "scolta bridge" under Decisions is the Scolta
    /// strand's decisions that mention the bridge, not only lines that say both words.
    public static func line(_ line: VaultSectionLine, matches tokens: [String]) -> Bool {
        tokens.allSatisfy { token in
            hasWord(startingWith: token, in: line.text)
                || (line.date.map { $0.hasPrefix(token) } ?? false)
                || line.title.localizedStandardContains(token)
                || line.path.localizedStandardContains(token)
        }
    }

    /// Folded for case and diacritics, as the index's tokenizer folds them.
    static func hasWord(startingWith token: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: token,
                                     options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchRange) {
            if found.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: found.lowerBound)]
            if !(before.isLetter || before.isNumber) { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    /// The order a section's lines are shown in. A dated log is newest first, undated
    /// lines after every dated one, then path and line so the order is stable. Any other
    /// section keeps the search's ranking: the chunk's score, then path and line.
    public static func ordered(_ lines: [VaultSectionLine],
                               section: VaultStrandSection) -> [VaultSectionLine] {
        lines.sorted { a, b in
            if section.isDatedLog {
                let (da, db) = (a.date ?? "", b.date ?? "")
                if da != db { return da > db }
            } else if a.score != b.score {
                return a.score < b.score
            }
            if a.path != b.path { return a.path < b.path }
            return a.line < b.line
        }
    }

    /// The empty-query view of a section: its newest `limit` DATED lines across every
    /// chunk given, newest first. An undated line has no place in a log read by date.
    public static func log(_ chunks: [VaultStoredChunk], section: VaultStrandSection,
                           limit: Int = logLimit) -> [VaultSectionLine] {
        let dated = chunks
            .filter { section.matches(heading: $0.heading) }
            .flatMap { lines(of: $0) }
            .filter { $0.date != nil }
        return Array(ordered(dated, section: .decisions).prefix(limit))
    }

    /// The typed-query view of a section: every line, in the chunks the index matched,
    /// that answers the query on its own. `scores` is each matched chunk's bm25 keyed by
    /// `path#line_start`; a chunk the index did not match contributes nothing.
    public static func search(_ chunks: [VaultStoredChunk], scores: [String: Double],
                              tokens: [String], section: VaultStrandSection,
                              limit: Int) -> [VaultSectionLine] {
        let found = chunks
            .filter { section.matches(heading: $0.heading) }
            .flatMap { chunk -> [VaultSectionLine] in
                guard let score = scores["\(chunk.path)#\(chunk.lineStart)"] else { return [] }
                return lines(of: chunk, score: score).filter { line($0, matches: tokens) }
            }
        return Array(ordered(found, section: section).prefix(limit))
    }
}
