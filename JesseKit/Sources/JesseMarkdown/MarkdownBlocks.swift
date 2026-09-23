import Foundation

// A NOTE'S SHAPE, NOT ITS MEANING.
//
// The reader's first block model was one block per non-blank line, which was the right
// amount of machinery to prove a reader could exist and the wrong amount to read a real
// note through. A soft-wrapped paragraph came out as a stack of short lines; a numbered
// list lost its numbers; a table came out as rows of pipe characters; a callout came out
// as a quote with `[!note]` showing. This file is the replacement: the ordinary markdown
// block grammar, plus Obsidian's callout, parsed once.
//
// IT KNOWS NOTHING ABOUT A VAULT. There is no wiki link here, no frontmatter and no task
// box: those are the vault layer's, added on top in `VaultNoteDocument`. What is here is
// what any markdown reader needs, which is what makes it safe for the reply renderers to
// adopt later without inheriting a vault's opinions.
//
// THE INVARIANT, tested by fuzz rather than by inspection: every non-blank source line's
// text ends up in some block — in its joined text, in a table cell, or in a code body. A
// parser is allowed to be wrong about what a line MEANS. It is never allowed to make a
// line disappear, because a reader cannot notice the absence of something they have never
// seen.

/// One block of a markdown document, before anybody has decided how to draw it.
public struct MarkdownSourceBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case bullet(depth: Int)
        /// `number` is what RENDERS, which is not always what was typed — see
        /// `MarkdownBlockParser.displayNumbers`.
        case ordered(depth: Int, number: Int)
        case quote
        /// `> [!warning] Mind the arch`. `type` is lowercased; `title` is what was written
        /// after the marker, or the type capitalised when nothing was.
        case callout(type: String, title: String)
        /// One fence, whole. `language` is whatever followed the opening backticks, and ""
        /// when nothing did.
        case code(language: String)
        case rule
        /// Headers, rows and alignments are all padded to the SAME width, so a ragged row
        /// keeps every cell it had and a grid drawn from this is rectangular.
        case table(headers: [String], rows: [[String]], alignments: [TableAlignment])
        case image(alt: String, target: String)
    }

    public let kind: Kind
    /// The block's text with its own markers removed and its inline markdown left in.
    /// Empty for a rule, and for a table, whose content is in its cells.
    public let text: String
    /// The 1-based line the block STARTS at.
    public let line: Int

    public init(kind: Kind, text: String, line: Int) {
        self.kind = kind
        self.text = text
        self.line = line
    }
}

public enum MarkdownBlockParser {

    /// Parse `lines` into blocks, numbering them from `firstLine` (1-based).
    ///
    /// `lines` arrives already split so a caller that has split the file once — for
    /// frontmatter, for a raw view, for line numbers — does not pay for it twice.
    public static func parse(lines: [String], firstLine: Int = 1) -> [MarkdownSourceBlock] {
        var out: [MarkdownSourceBlock] = []
        var pending: Pending?
        var index = 0

        func flush() {
            if let open = pending { out.append(open.block()) }
            pending = nil
        }

        while index < lines.count {
            let raw = lines[index]
            let number = firstLine + index
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // 1. A FENCE WINS OVER EVERYTHING, a blank line included: what is inside one
            //    is not markdown and must not be read as any.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = Character(trimmed.hasPrefix("```") ? "`" : "~")
                let opening = trimmed.prefix { $0 == fence }.count
                let language = String(trimmed.drop { $0 == fence })
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count {
                    if isClosingFence(lines[index], fence: fence, opening: opening) {
                        index += 1
                        break
                    }
                    // VERBATIM, indentation included: a code block stripped of its own
                    // whitespace is a code block that no longer compiles. An UNCLOSED
                    // fence runs to the end of the note rather than swallowing it silently
                    // — the text is all still here, drawn as code.
                    body.append(lines[index])
                    index += 1
                }
                out.append(MarkdownSourceBlock(kind: .code(language: language),
                                               text: body.joined(separator: "\n"),
                                               line: number))
                continue
            }

            // 2. A blank line ends whatever was open, and is otherwise nothing.
            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }

            // 3. A rule, checked before a list item so `---` is not read as an empty one.
            if isRule(trimmed) {
                flush()
                out.append(MarkdownSourceBlock(kind: .rule, text: "", line: number))
                index += 1
                continue
            }

            // 4. A heading.
            if let level = headingLevel(trimmed) {
                flush()
                out.append(MarkdownSourceBlock(
                    kind: .heading(level: level),
                    text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces),
                    line: number))
                index += 1
                continue
            }

            // 5. A table: a row-looking line IMMEDIATELY followed by a delimiter row. A
            //    line with a pipe in it and no delimiter under it is prose about pipes.
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableDelimiterRow(lines[index + 1]) {
                flush()
                let headers = splitTableRow(trimmed)
                let alignments = parseTableAlignments(lines[index + 1])
                var rows: [[String]] = []
                var j = index + 2
                while j < lines.count {
                    let row = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(splitTableRow(row))
                    j += 1
                }
                out.append(MarkdownSourceBlock(
                    kind: tableKind(headers: headers, rows: rows, alignments: alignments),
                    text: "", line: number))
                index = j
                continue
            }

            // 6. A quote, which may be a callout. Consumed as a RUN: a multi-line quote is
            //    one quote, not four.
            if isQuote(trimmed) {
                flush()
                var body: [Line] = []
                var j = index
                while j < lines.count {
                    let quoted = lines[j].trimmingCharacters(in: .whitespaces)
                    guard isQuote(quoted) else { break }
                    body.append(Line(text: stripQuoteMarkers(quoted),
                                     hardBreak: hasHardBreak(lines[j])))
                    j += 1
                }
                out.append(quoteBlock(body, line: number))
                index = j
                continue
            }

            // 7. An image on a line of its own.
            if let image = loneImage(trimmed) {
                flush()
                out.append(MarkdownSourceBlock(
                    kind: .image(alt: image.alt, target: image.target),
                    text: image.alt, line: number))
                index += 1
                continue
            }

            // 8. A list item starts a new block; anything else joins whatever is open.
            //
            //    An indented line under an open item is that item's CONTINUATION, which is
            //    what the indent was for. An unindented one is markdown's lazy
            //    continuation and joins it too — either way it joins, so the two cases do
            //    not need telling apart, and neither of them can drop a line.
            if let item = listItem(raw, trimmed: trimmed) {
                flush()
                pending = Pending(kind: item.kind, line: number,
                                  first: Line(text: item.text, hardBreak: hasHardBreak(raw)))
            } else if pending != nil {
                pending?.append(Line(text: stripTrailingBackslash(trimmed),
                                     hardBreak: hasHardBreak(raw)))
            } else {
                pending = Pending(kind: .paragraph, line: number,
                                  first: Line(text: stripTrailingBackslash(trimmed),
                                              hardBreak: hasHardBreak(raw)))
            }
            index += 1
        }
        flush()
        return renumbered(out)
    }

    // MARK: - Joining

    /// One source line on its way into a block: its text, and whether the writer asked for
    /// a break after it.
    struct Line {
        var text: String
        var hardBreak: Bool
    }

    /// Whatever block is being built out of consecutive lines. One accumulator serves
    /// paragraphs, quotes and list items because the joining rule is the same for all
    /// three, and three accumulators would be three places to forget to flush.
    struct Pending {
        let kind: MarkdownSourceBlock.Kind
        let line: Int
        var lines: [Line]

        init(kind: MarkdownSourceBlock.Kind, line: Int, first: Line) {
            self.kind = kind
            self.line = line
            var first = first
            first.text = MarkdownBlockParser.stripTrailingBackslash(first.text)
            lines = [first]
        }

        mutating func append(_ line: Line) {
            var line = line
            line.text = MarkdownBlockParser.stripTrailingBackslash(line.text)
            lines.append(line)
        }

        func block() -> MarkdownSourceBlock {
            MarkdownSourceBlock(kind: kind, text: MarkdownBlockParser.join(lines), line: line)
        }
    }

    /// Consecutive lines as one block's text: joined with a space, except after a line the
    /// writer ended with two spaces or a backslash, which is markdown for "break here" and
    /// the one way a writer can shape a paragraph.
    static func join(_ lines: [Line]) -> String {
        guard var out = lines.first?.text else { return "" }
        for i in 1..<max(lines.count, 1) {
            out += (lines[i - 1].hardBreak ? "\n" : " ") + lines[i].text
        }
        return out
    }

    /// Did the writer ask for a break after this RAW line? Asked of the raw line because
    /// the two-space form does not survive being trimmed.
    static func hasHardBreak(_ raw: String) -> Bool {
        if raw.hasSuffix("  ") { return true }
        return raw.trimmingCharacters(in: .whitespaces).hasSuffix("\\")
    }

    static func stripTrailingBackslash(_ text: String) -> String {
        text.hasSuffix("\\")
            ? String(text.dropLast()).trimmingCharacters(in: .whitespaces)
            : text
    }

    // MARK: - The constructs

    /// Three or more `-`, `*` or `_`, alone on a line, spaces allowed between them.
    static func isRule(_ trimmed: String) -> Bool {
        let bare = trimmed.filter { $0 != " " }
        guard bare.count >= 3, let first = bare.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return bare.allSatisfy { $0 == first }
    }

    /// 1 to 6 `#` followed by a space, and how many.
    static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") else {
            return nil
        }
        return hashes
    }

    /// CommonMark's closing-fence rule: at least as many of the SAME fence character as
    /// opened the block, and nothing after them but spaces.
    ///
    /// "Nothing after them" is load-bearing rather than pedantry. A line reading
    /// ```` ```swift ```` is an OPENING fence's info string, so it cannot close one — and
    /// a parser that let it would silently swallow the word `swift`, which is exactly the
    /// kind of disappearance the fuzz test exists to catch, and did.
    static func isClosingFence(_ raw: String, fence: Character, opening: Int) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == fence }.count
        return run >= opening && run == trimmed.count
    }

    static func isQuote(_ trimmed: String) -> Bool { trimmed.first == ">" }

    /// Every leading `>` and the spaces around them removed. Nested quotes FLATTEN to one
    /// level with the inner text kept: a reader gains nothing from four nested bars, and
    /// loses the sentence inside them if the nesting is drawn wrong.
    static func stripQuoteMarkers(_ trimmed: String) -> String {
        var rest = Substring(trimmed)
        while rest.first == ">" {
            rest = rest.dropFirst()
            while rest.first == " " { rest = rest.dropFirst() }
        }
        return String(rest)
    }

    /// A quote run as a block: a callout when its first line carries a `[!type]` marker,
    /// an ordinary quote otherwise.
    static func quoteBlock(_ body: [Line], line: Int) -> MarkdownSourceBlock {
        guard let first = body.first, let marker = calloutMarker(first.text) else {
            return MarkdownSourceBlock(kind: .quote, text: join(body), line: line)
        }
        // The marker line's own remainder is the TITLE, so the body is what follows it —
        // unless the writer put text on the marker line and nothing under it, in which
        // case the title is all there is and the body is empty.
        let rest = Array(body.dropFirst())
        return MarkdownSourceBlock(
            kind: .callout(type: marker.type,
                           title: marker.title.isEmpty ? capitalised(marker.type) : marker.title),
            text: join(rest), line: line)
    }

    /// `[!type]`, an optional `+`/`-` fold marker, and an optional title, at the head of a
    /// quote's first line.
    static func calloutMarker(_ line: String) -> (type: String, title: String)? {
        guard line.hasPrefix("[!"), let close = line.firstIndex(of: "]") else { return nil }
        let type = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
        guard !type.isEmpty,
              type.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        var rest = Substring(line[line.index(after: close)...])
        // The fold marker says whether Obsidian opens the callout collapsed. This reader
        // draws every callout OPEN — hiding a paragraph because the writer's editor had it
        // folded is still hiding a paragraph — so it is consumed and dropped.
        if rest.first == "+" || rest.first == "-" { rest = rest.dropFirst() }
        return (type.lowercased(), rest.trimmingCharacters(in: .whitespaces))
    }

    static func capitalised(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// `![alt](target)` and nothing else on the line.
    static func loneImage(_ trimmed: String) -> (alt: String, target: String)? {
        guard trimmed.hasPrefix("!["),
              let found = MarkdownInline.imageLink(trimmed, from: trimmed.startIndex),
              found.end == trimmed.endIndex else { return nil }
        return (found.alt, found.target)
    }

    /// A bullet or ordered item: its kind, and the text after the marker.
    static func listItem(_ raw: String,
                         trimmed: String) -> (kind: MarkdownSourceBlock.Kind, text: String)? {
        let depth = indentDepth(raw)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return (.bullet(depth: depth), String(trimmed.dropFirst(marker.count)))
        }
        let digits = trimmed.prefix { $0.isNumber }
        // Nine digits, because `Int(...)` of a line of them is how a parser meets a crash
        // it did not need to meet.
        if !digits.isEmpty, digits.count <= 9,
           trimmed.dropFirst(digits.count).hasPrefix(". "), let number = Int(digits) {
            return (.ordered(depth: depth, number: number),
                    String(trimmed.dropFirst(digits.count + 2)))
        }
        return nil
    }

    /// Indent depth by leading whitespace: a tab, or every two spaces, is one level,
    /// capped at 4. The vault's own notes use tabs; a markdown editor produces two spaces.
    public static func indentDepth(_ line: String) -> Int {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return min(indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2, 4)
    }

    /// Headers, rows and alignments squared off to one width.
    ///
    /// The width is the WIDEST of them, not the header's: a row with an extra cell is a
    /// row somebody typed something into, and truncating to the header count would drop
    /// that something on the floor.
    static func tableKind(headers: [String], rows: [[String]],
                          alignments: [TableAlignment]) -> MarkdownSourceBlock.Kind {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        func padded(_ row: [String]) -> [String] {
            row + Array(repeating: "", count: max(0, columns - row.count))
        }
        return .table(headers: padded(headers),
                      rows: rows.map(padded),
                      alignments: alignments
                        + Array(repeating: .leading,
                                count: max(0, columns - alignments.count)))
    }

    // MARK: - Numbering

    /// What an ordered list's items actually show.
    ///
    /// Markdown's own convention is that a list written `1. 1. 1.` renders `1. 2. 3.` —
    /// the writer is saying "a numbered list", not "three items all numbered one". But a
    /// writer who numbered their own items `3. 4. 5.` meant those numbers, and renumbering
    /// them from one would be the reader overruling them.
    ///
    /// So: a run whose written numbers are ALL THE SAME counts up from the first; any
    /// other run keeps what was written. Both halves are asserted.
    static func displayNumbers(_ written: [Int]) -> [Int] {
        guard let first = written.first else { return [] }
        guard written.allSatisfy({ $0 == first }) else { return written }
        return (0..<written.count).map { first + $0 }
    }

    /// Apply `displayNumbers` to each run of consecutive ordered items at one depth.
    static func renumbered(_ blocks: [MarkdownSourceBlock]) -> [MarkdownSourceBlock] {
        var out = blocks
        var run: [Int] = []
        var runDepth: Int?

        func close() {
            defer { run = []; runDepth = nil }
            guard !run.isEmpty, let depth = runDepth else { return }
            let written = run.map { index -> Int in
                guard case .ordered(_, let number) = out[index].kind else { return 0 }
                return number
            }
            for (slot, number) in zip(run, displayNumbers(written)) {
                out[slot] = MarkdownSourceBlock(kind: .ordered(depth: depth, number: number),
                                                text: out[slot].text, line: out[slot].line)
            }
        }

        for (index, block) in blocks.enumerated() {
            guard case .ordered(let depth, _) = block.kind else {
                close()
                continue
            }
            if runDepth != depth { close() }
            runDepth = depth
            run.append(index)
        }
        close()
        return out
    }
}
