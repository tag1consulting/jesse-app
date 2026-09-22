import Foundation

// TURNING ONE NOTE INTO THE UNITS A SEARCH ANSWERS WITH.
//
// A hit that names a FILE is nearly useless in this vault: the files are long —
// a person's journal, a project overview, a guideline page — and "the answer is
// somewhere in these 900 lines" is not an answer. So the unit is a SECTION, and a
// hit carries the heading it was found under and the line it starts at.
//
// THREE RULES, and each one is here because of something the vault actually contains:
//
//   * Split at `##` AND DEEPER, never at `#`. A vault note's `# ` line is its title,
//     one per file; splitting there would produce one chunk for the whole note and
//     defeat the exercise. Everything below `##` is a real section boundary.
//   * A section longer than 1,500 characters is split again AT PARAGRAPH BOUNDARIES.
//     Some guideline sections run for pages, and a chunk that large drags a snippet's
//     relevance down to nothing. A blank line is the only place a split is allowed:
//     cutting mid-paragraph would put half a sentence in one hit and half in another.
//   * FRONTMATTER IS NOT A CHUNK. It is metadata — `title:`, tags, dates — and
//     indexing it would let every note match the word "title". Its `title:` key is
//     read for the file's title and the rest is dropped.
//
// Every chunk records the 1-BASED LINE its first line sits on, because that is what a
// reader can be scrolled to and what a person can type into an editor. Counting from
// zero here would be counting in a unit no note-taking tool uses.
//
// Pure, Foundation-only, no filesystem: everything below decides from a path and a
// string, which is what lets the rules be asserted directly rather than inferred from
// what ended up in a database.

/// One indexed unit of a note.
public struct VaultChunk: Equatable, Sendable {
    /// The `##`-or-deeper heading this chunk sits under, hashes stripped. Empty for the
    /// text above the first such heading (which is where a note's `# ` title and its
    /// opening paragraphs live).
    public let heading: String
    /// The 1-based line, in the whole file, of this chunk's first line.
    public let lineStart: Int
    /// The chunk's text, verbatim, INCLUDING its heading line when it has one.
    ///
    /// The heading is deliberately in both places — here and in `heading` — because the
    /// two are read differently: `heading` is a separately weighted FTS column and a
    /// caption on the hit, and the body is what a snippet is cut from. A snippet that
    /// could never include the heading it sits under reads as though it came from
    /// nowhere.
    public let body: String

    public init(heading: String, lineStart: Int, body: String) {
        self.heading = heading
        self.lineStart = lineStart
        self.body = body
    }
}

/// One parsed note: what the index stores about it.
public struct VaultNoteParse: Equatable, Sendable {
    /// The frontmatter `title:`, else the first `# ` heading, else the file name.
    public let title: String
    public let chunks: [VaultChunk]
    /// Every `[[wiki link]]` target in the file, normalized, in source order.
    public let linkTargets: [String]
    /// How many lines the frontmatter block occupied, fences included. 0 when there is
    /// none. Carried so the reader can fold exactly those lines away.
    public let frontmatterLineCount: Int

    public init(title: String, chunks: [VaultChunk], linkTargets: [String],
                frontmatterLineCount: Int) {
        self.title = title
        self.chunks = chunks
        self.linkTargets = linkTargets
        self.frontmatterLineCount = frontmatterLineCount
    }
}

public enum VaultChunker {

    /// The size above which a section is split again at a paragraph boundary.
    public static let maxChunkCharacters = 1_500

    /// A split that would leave a piece SHORTER than this is not made.
    ///
    /// Without it, a long section's own heading line becomes a chunk of its own — "## Long"
    /// and nothing else — because the blank line after a heading is a paragraph boundary
    /// like any other. A chunk that is only a heading matches the heading and answers
    /// nothing, and it is exactly the row a reader would be sent to.
    public static let minChunkCharacters = 200

    /// Split one note into the units the index holds.
    public static func parse(relativePath: String, text: String) -> VaultNoteParse {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let front = frontmatter(lines)

        var chunks: [VaultChunk] = []
        var heading = ""
        var firstH1: String?
        // The section being accumulated: its lines, and the 1-based line its first line
        // sits on.
        var sectionLines: [String] = []
        var sectionStart = front.lineCount + 1

        func flush() {
            defer { sectionLines = [] }
            guard !sectionLines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty })
            else { return }
            chunks.append(contentsOf: split(sectionLines, heading: heading,
                                            firstLine: sectionStart))
        }

        var lineNumber = front.lineCount
        for line in lines.dropFirst(front.lineCount) {
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = trimmed.prefix { $0 == "#" }.count
            let isHeading = hashes >= 1 && hashes <= 6 && trimmed.dropFirst(hashes).hasPrefix(" ")
            if isHeading, hashes == 1, firstH1 == nil {
                firstH1 = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if isHeading, hashes >= 2 {
                flush()
                heading = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                sectionStart = lineNumber
            }
            sectionLines.append(line)
        }
        flush()

        return VaultNoteParse(
            title: title(relativePath: relativePath,
                         frontmatterTitle: front.title,
                         firstHeading: firstH1),
            chunks: chunks,
            linkTargets: VaultWikiLink.targets(in: text),
            frontmatterLineCount: front.lineCount)
    }

    /// The note's title, by the three-step rule: frontmatter `title:`, the first `# `
    /// heading, the file name without its extension.
    public static func title(relativePath: String, frontmatterTitle: String?,
                             firstHeading: String?) -> String {
        if let t = frontmatterTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        if let h = firstHeading?.trimmingCharacters(in: .whitespaces), !h.isEmpty { return h }
        let leaf = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        return leaf.lowercased().hasSuffix(".md") ? String(leaf.dropLast(3)) : leaf
    }

    /// The leading `---` block: how many lines it occupies (fences included) and the
    /// `title:` it declares.
    ///
    /// A note whose FIRST line is `---` but which never closes the block is treated as
    /// having no frontmatter at all. That is the conservative reading: the alternative
    /// is swallowing the entire note as metadata because of one horizontal rule.
    static func frontmatter(_ lines: [String]) -> (title: String?, lineCount: Int) {
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, 0) }
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return (nil, 0) }
        var title: String?
        for line in lines[1..<close] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard title == nil, trimmed.lowercased().hasPrefix("title:") else { continue }
            var value = String(trimmed.dropFirst("title:".count))
                .trimmingCharacters(in: .whitespaces)
            // `title: "A Note"` and `title: 'A Note'` are both YAML for the same thing.
            for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote)
                && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { title = value }
        }
        return (title, close + 1)
    }

    /// One section's lines as one or more chunks, splitting at BLANK LINES when the
    /// section is longer than `maxChunkCharacters`.
    ///
    /// A single paragraph longer than the cap stays whole: the cap is a target, and the
    /// alternative — cutting inside a sentence — is worse than an oversized chunk.
    static func split(_ lines: [String], heading: String, firstLine: Int) -> [VaultChunk] {
        let whole = lines.joined(separator: "\n")
        if whole.count <= maxChunkCharacters {
            return [VaultChunk(heading: heading, lineStart: firstLine,
                               body: trimmedTrailing(whole))]
        }
        var out: [VaultChunk] = []
        var current: [String] = []
        var currentStart = firstLine
        var currentCount = 0
        // One "paragraph" is a run of non-blank lines plus the blank lines that follow
        // it, so a split always lands ON a boundary rather than just before one.
        var paragraph: [String] = []
        var paragraphStart = firstLine
        var lineNumber = firstLine - 1

        func closeParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            if currentCount >= minChunkCharacters,
               currentCount + text.count + 1 > maxChunkCharacters {
                out.append(VaultChunk(heading: heading, lineStart: currentStart,
                                      body: trimmedTrailing(current.joined(separator: "\n"))))
                current = []
                currentCount = 0
                currentStart = paragraphStart
            }
            if current.isEmpty { currentStart = paragraphStart }
            current.append(contentsOf: paragraph)
            currentCount += text.count + 1
            paragraph = []
        }

        for line in lines {
            lineNumber += 1
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank {
                if paragraph.isEmpty { continue }
                paragraph.append(line)
                closeParagraph()
                continue
            }
            if paragraph.isEmpty { paragraphStart = lineNumber }
            paragraph.append(line)
        }
        closeParagraph()
        if !current.isEmpty {
            out.append(VaultChunk(heading: heading, lineStart: currentStart,
                                  body: trimmedTrailing(current.joined(separator: "\n"))))
        }
        return out.filter { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Trailing blank lines off a chunk body. They are separators, not content, and
    /// carrying them would put them in every snippet.
    private static func trimmedTrailing(_ s: String) -> String {
        var out = s
        while let last = out.last, last == "\n" || last == " " || last == "\t" {
            out.removeLast()
        }
        return out
    }
}
