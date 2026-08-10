import Foundation
import JesseNetworking

// A vault note, split into the blocks a view draws — plus the link extraction the
// chips need.
//
// ## Why not `AttributedString(markdown:)`
//
// Foundation's markdown parser is real and would handle emphasis and `[text](url)` for
// free. It also knows nothing about `[[wiki links]]`, which are the single most
// important thing in a vault note: a note's links are how the day's work connects, and
// through the existing `TodayLinkChip` they are the one part of a note the app can act
// on. Handing the note to a parser that renders `[[todo-list/Projects/Tag1/HR-Finance]]`
// as literal brackets, and gives the app no way to know a link was there, would be
// worse than the small block model below.
//
// So the note is split into blocks here, each block's text is stripped with the SAME
// `TodaySemantics.strippedMarkdown` the rows already use (so a note and the row that
// links it read alike), and each block's links come out as `TodayLink`s the existing
// chip renders. One markdown treatment, two surfaces.
//
// This is deliberately a SMALL model — headings, bullets, quotes, fenced code,
// paragraphs, rules. A vault note is a hand-written page, not a document format, and
// every construct this does not know about survives as its own paragraph rather than
// vanishing. Nothing is ever dropped.

/// One block of a note.
public struct TodayNoteBlock: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: Equatable, Hashable, Sendable {
        /// `#` … `######`, carrying its level (1...6).
        case heading(level: Int)
        /// `- ` / `* ` / `1. `, carrying its indent depth (0 for a top-level bullet).
        case bullet(depth: Int)
        /// `> quoted`.
        case quote
        /// The inside of a ``` fence, verbatim: never stripped, never link-scanned.
        case code
        /// `---`.
        case rule
        /// Anything else.
        case paragraph
    }

    /// Position in the note, which is also the only stable identity a block has: two
    /// identical lines of a note are two blocks, and keying by text would collapse them.
    public var id: Int
    public var kind: Kind
    /// The text to draw — markdown decoration stripped, except in a code block.
    public var text: String
    /// The links this block carries, in source order.
    public var links: [TodayLink]
    /// The block's RAW source line, which is what a link tap carries as its origin: a
    /// conversation about a linked note needs the line that referenced it, verbatim.
    public var source: String

    public init(id: Int, kind: Kind, text: String, links: [TodayLink] = [], source: String = "") {
        self.id = id
        self.kind = kind
        self.text = text
        self.links = links
        self.source = source
    }
}

public enum TodayNoteMarkdown {

    /// Split a note into blocks. Blank lines are separators and never become blocks;
    /// everything else does.
    public nonisolated static func blocks(_ markdown: String) -> [TodayNoteBlock] {
        var out: [TodayNoteBlock] = []
        var inCode = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                // Verbatim, including indentation: a code block that was stripped of its
                // markdown would be a code block that no longer compiles.
                out.append(TodayNoteBlock(id: out.count, kind: .code, text: line, source: line))
                continue
            }
            if trimmed.isEmpty { continue }
            out.append(block(id: out.count, line: line, trimmed: trimmed))
        }
        return out
    }

    private nonisolated static func block(id: Int, line: String,
                                          trimmed: String) -> TodayNoteBlock {
        func made(_ kind: TodayNoteBlock.Kind, _ body: String) -> TodayNoteBlock {
            TodayNoteBlock(id: id, kind: kind,
                           text: TodaySemantics.strippedMarkdown(body)
                               .trimmingCharacters(in: .whitespaces),
                           links: links(in: line), source: line)
        }
        if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 3 {
            return TodayNoteBlock(id: id, kind: .rule, text: "", source: line)
        }
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                return made(.heading(level: hashes),
                            String(trimmed.dropFirst(hashes)))
            }
        }
        if trimmed.hasPrefix("> ") || trimmed == ">" {
            return made(.quote, String(trimmed.dropFirst(1)))
        }
        if let body = bulletBody(trimmed) {
            // Indent depth by leading whitespace: a tab, or every two spaces, is one
            // level. The vault's notes use tabs; two-space indentation is what a
            // markdown editor produces.
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            return made(.bullet(depth: min(depth, 4)), body)
        }
        return made(.paragraph, trimmed)
    }

    /// The body of a bullet or numbered-list line, or nil when the line is neither.
    /// A day-file-style task box (`- [ ] `) is kept as part of the text: a note's
    /// checkboxes belong to the note, and the app must never make them look tappable.
    private nonisolated static func bulletBody(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        // `12. ` — a digit run, a dot, a space.
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") {
            return String(trimmed.dropFirst(digits.count + 2))
        }
        return nil
    }

    /// Every link in one line, in source order, de-duplicated by target.
    ///
    /// A deliberate port of the bridge's `extract_links`, and it must stay one: a chip
    /// the app shows for a note has to name the same target the bridge would resolve, or
    /// tapping it would start a conversation about a different file. The rules, from
    /// there: `[[target|alias]]` keeps the TARGET and drops the alias; `[[target#heading]]`
    /// keeps the heading (a link to a section is still a link to that note); a markdown
    /// `[text](url)` yields its url; a bare `http(s)://…` runs to the first whitespace or
    /// closing bracket, with sentence punctuation trimmed off the end.
    public nonisolated static func links(in line: String) -> [TodayLink] {
        var out: [TodayLink] = []
        func push(_ target: some StringProtocol, _ kind: String) {
            let target = target.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !out.contains(where: { $0.target == target }) else { return }
            out.append(TodayLink(target: target, kind: kind))
        }
        var rest = Substring(line)
        while !rest.isEmpty {
            if rest.hasPrefix("[["), let close = rest.range(of: "]]") {
                let inner = rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]
                push(inner.split(separator: "|", maxSplits: 1).first ?? inner, "wiki")
                rest = rest[close.upperBound...]
            } else if rest.hasPrefix("]("), let close = rest.dropFirst(2).firstIndex(of: ")") {
                push(rest[rest.index(rest.startIndex, offsetBy: 2)..<close], "url")
                rest = rest[rest.index(after: close)...]
            } else if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
                let end = rest.firstIndex { $0.isWhitespace || ")]>\"'".contains($0) }
                    ?? rest.endIndex
                var url = String(rest[rest.startIndex..<end])
                while let last = url.last, ".,;:".contains(last) { url.removeLast() }
                push(url, "url")
                rest = rest[end...]
            } else {
                rest = rest.dropFirst()
            }
        }
        return out
    }
}
